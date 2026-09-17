#!/usr/bin/env python3
"""
03_howde.py — home and work detection with HoWDe.

Home and work per user via the HoWDe algorithm (Alessandretti et al., CEUS
2025), run on the stops from 01_stops.R and the place ids from 02_places.py.

    source code/env.sh
    python code/03_howde.py
    python code/03_howde.py --limit-users 13000 --in-suffix _pilot --out-suffix _pilot
    python code/03_howde.py --f-hours-h 0.9 --out-suffix _fH0.9     # paper's "maximum"

REQUIRES code/env.sh TO BE SOURCED. HoWDe runs on PySpark, which needs Java 17
(the default JDK here is 26 and Spark dies on it) and needs PYSPARK_PYTHON
pinned to the venv interpreter. setup_python.sh writes env.sh with both.

Outputs
    output/home_work_stops.parquet   stop-level rows with H/W labels
    output/home_work.parquet         one row per user: home_place, work_place
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import pandas as pd

# ---------------------------------------------------------------------------
# parameters — HoWDe's own defaults unless noted
# ---------------------------------------------------------------------------

# Sliding window lengths in days. These are the reason the extract is seven
# weeks: 49 days clears the 42-day work window, where six weeks (42 days, or
# 41 after excluding the autumn holiday) would not have.
RANGE_WINDOW_HOME = 28
RANGE_WINDOW_WORK = 42

# Data-completeness thresholds: how much observation a day/window needs before
# HoWDe will commit to a label. Left at package defaults.
C_HOURS = 0.4    # min fraction of night/business hourly bins with data in a day
C_DAYS_H = 0.4   # min fraction of days with data in the home window
C_DAYS_W = 0.5   # min fraction of days with data in the work window

# Behavioural thresholds — fractions, not absolute time, which is what lets
# HoWDe cope with wildly uneven sampling between users.
#
# f_hours_H is the paper's hfH. Its "minimum" configuration uses 0.5 and its
# "maximum" 0.9; the maximum reaches 97% home accuracy but EXCLUDES ~39% OF
# USERS. This cohort is already selected on app engagement (and, after the
# coarse-location filter, on sharing precise location), so stacking a second
# observability filter on top compounds a bias that lands on exactly the
# comparison this project is about. 0.7 is the package default and the middle
# course. Whatever you use, report it.
F_HOURS_H = 0.7
F_HOURS_W = 0.4
F_DAYS_W = 0.6

# Europe/London is UTC+1 for the whole 26 Aug - 13 Oct 2024 window (BST ends
# 27 Oct), so the offset is constant and there is no DST ambiguity to resolve.
# Revisit if the window is ever extended past late October.
TZ_HOUR, TZ_MINUTE = 1, 0
LOCAL_TZ = "Europe/London"

STOPS_CSV = Path("output/stops.csv")
OUT_DIR = Path("output")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _to_epoch(s: pd.Series) -> pd.Series:
    """Datetime column -> Unix seconds, whatever timezone form it arrives in.

    data.table::fwrite writes POSIXct as UTC with a 'Z' suffix — it CONVERTS
    rather than dropping the zone, so pandas reads it back already tz-aware and
    the instants are correct. Do not localize those: relabelling UTC as
    Europe/London would shift every timestamp by the BST offset, silently.

    A naive column would mean fwrite behaved differently (or the file was
    written by something else), in which case the wall clock is the local one
    and attaching LOCAL_TZ is right. Both cases are handled so this cannot
    depend on an assumption about the writer.

    Unix time is timezone-independent; HoWDe gets the local offset separately
    via tz_hour_start / tz_minute_start.
    """
    if s.dt.tz is None:
        log("  NOTE timestamps are timezone-naive — assuming they are "
            f"{LOCAL_TZ} wall-clock.")
        s = s.dt.tz_localize(LOCAL_TZ)
    return s.astype("int64") // 10**9


def check_env() -> None:
    missing = [v for v in ("JAVA_HOME", "PYSPARK_PYTHON") if not os.environ.get(v)]
    if missing:
        sys.exit(
            f"ERROR: {', '.join(missing)} not set.\n"
            "  Run:  source code/env.sh\n"
            "  PySpark needs Java 17 (the default JDK on this machine is 26, "
            "which Spark 4.2 cannot start on) and a worker interpreter matching "
            "the driver."
        )


def build_input(in_suffix: str, limit_users: int | None,
                allow_noise: bool = False) -> pd.DataFrame:
    """Assemble the HoWDe input contract from stops + place labels.

    HoWDe expects: useruuid, loc, start, end  (+ optional tz_hour_start,
    tz_minute_start, country). `start`/`end` are Unix timestamps as long.
    """
    sp_path = OUT_DIR / f"stop_places{in_suffix}.parquet"
    if not sp_path.exists():
        sys.exit(f"{sp_path} not found — run code/02_places.py first.")
    if not STOPS_CSV.exists():
        sys.exit(f"{STOPS_CSV} not found — run code/01_stops.R first.")

    log(f"reading {STOPS_CSV} ...")
    stops = pd.read_csv(
        STOPS_CSV,
        usecols=["registration_id", "stop_id", "arrival_time", "departure_time"],
        dtype={"registration_id": "string", "stop_id": "int32"},
        parse_dates=["arrival_time", "departure_time"],
    )
    log(f"  {len(stops):,} stops")

    log(f"reading {sp_path} ...")
    places = pd.read_parquet(sp_path)
    df = stops.merge(places, on=["registration_id", "stop_id"], how="inner")
    log(f"  {len(df):,} stops carry a place_id")
    if df.empty:
        sys.exit("No stops joined to a place — check that 01 and 02 ran on the "
                 "same data.")

    if limit_users:
        keep = set(df.registration_id.drop_duplicates().head(limit_users))
        df = df[df.registration_id.isin(keep)].copy()
        log(f"  PILOT: {limit_users:,} users -> {len(df):,} stops")

    out = pd.DataFrame({
        "useruuid": df.registration_id,
        "loc": df.place_id.astype("int64"),
        "start": _to_epoch(df.arrival_time),
        "end": _to_epoch(df.departure_time),
    })
    out["tz_hour_start"] = TZ_HOUR
    out["tz_minute_start"] = TZ_MINUTE

    # HoWDe DROPS rows whose loc is -1, without warning. 02_places.py already
    # refuses to emit -1, so this should be unreachable; it is here because a
    # silent row-drop is worse than a loud failure.
    n_bad = int((out.loc[:, "loc"] == -1).sum())
    if n_bad and not allow_noise:
        sys.exit(f"ERROR: {n_bad:,} rows have loc == -1, which HoWDe silently "
                 f"discards. Re-run 02_places.py with LABEL_SINGLETON = True, "
                 f"or pass --allow-singleton-noise if this is the A/B test.")
    if n_bad:
        log(f"  loc == -1: {n_bad:,} rows ({100 * n_bad / len(out):.1f}%) will be "
            f"DROPPED by HoWDe. This is the coverage loss under test.")

    # Zero-length stops are the norm here, not an anomaly: 50% of stops are
    # single-ping, so arrival == departure. Reported rather than dropped —
    # HoWDe works in hourly bins and tolerates them.
    log(f"  zero-duration stops: {int((out.end == out.start).sum()):,} "
        f"({100 * (out.end == out.start).mean():.1f}%) — expected, kept")
    return out


def run_howde(pdf: pd.DataFrame):
    from pyspark.sql import SparkSession
    from howde import HoWDe_labelling

    log("starting Spark ...")
    spark = (SparkSession.builder
             .master(os.environ.get("SPARK_MASTER", "local[*]"))
             .appName("ed-gender-howde")
             .config("spark.driver.memory", os.environ.get("SPARK_DRIVER_MEM", "4g"))
             .config("spark.sql.session.timeZone", "UTC")
             .getOrCreate())
    spark.sparkContext.setLogLevel("ERROR")

    log(f"running HoWDe on {len(pdf):,} stops "
        f"(home window {RANGE_WINDOW_HOME}d, work window {RANGE_WINDOW_WORK}d) ...")
    t0 = time.time()
    out = HoWDe_labelling(
        spark.createDataFrame(pdf),
        range_window_home=RANGE_WINDOW_HOME,
        range_window_work=RANGE_WINDOW_WORK,
        C_hours=C_HOURS, C_days_H=C_DAYS_H, C_days_W=C_DAYS_W,
        f_hours_H=F_HOURS_H, f_hours_W=F_HOURS_W, f_days_W=F_DAYS_W,
        output_format="stop",
        verbose=False,
    )
    # HoWDe returns a list when any parameter is given as a list; we pass
    # scalars, so there is exactly one result.
    if isinstance(out, list):
        out = out[0]
    res = out.toPandas() if hasattr(out, "toPandas") else out
    log(f"  done in {time.time() - t0:.1f}s -> {len(res):,} labelled rows")
    spark.stop()
    return res


def summarise(res: pd.DataFrame) -> pd.DataFrame:
    """Collapse stop-level output to one row per user."""
    # NOTE HoWDe emits MORE rows than it is given: a stop spanning local
    # midnight is split at the day boundary, so row counts are not comparable
    # with the input. Verified on synthetic data.
    log("")
    log(f"  location_type: {res.location_type.value_counts(dropna=False).to_dict()}")

    per_user = (
        res.groupby("useruuid")
           .agg(home_place=("detect_H_loc", lambda s: s.dropna().mode().iloc[0]
                            if s.notna().any() else pd.NA),
                work_place=("detect_W_loc", lambda s: s.dropna().mode().iloc[0]
                            if s.notna().any() else pd.NA),
                n_days=("date", "nunique"),
                n_rows=("loc", "size"))
           .reset_index()
    )
    n = len(per_user)
    log(f"  users with a home: {per_user.home_place.notna().sum():,} / {n:,} "
        f"({100 * per_user.home_place.notna().mean():.1f}%)")
    log(f"  users with a work: {per_user.work_place.notna().sum():,} / {n:,} "
        f"({100 * per_user.work_place.notna().mean():.1f}%)")
    log("  For comparison, the pilot (before the coarse-location filter) found "
        "home for 23.3% and work for 4.7% of users.")
    return per_user


def main() -> None:
    global STOPS_CSV, F_HOURS_H
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit-users", type=int, default=None)
    ap.add_argument("--in-suffix", default="")
    ap.add_argument("--out-suffix", default="")
    ap.add_argument("--stops-csv", default=str(STOPS_CSV))
    ap.add_argument("--allow-singleton-noise", action="store_true",
                    help="permit loc == -1 in the input; ONLY for the A/B test")
    ap.add_argument("--f-hours-h", type=float, default=F_HOURS_H,
                    help=f"HoWDe f_hours_H (default {F_HOURS_H}; the paper's "
                         "'minimum' is 0.5 and 'maximum' 0.9)")
    args = ap.parse_args()

    STOPS_CSV = Path(args.stops_csv)
    F_HOURS_H = args.f_hours_h
    log(f"f_hours_H = {F_HOURS_H}")

    check_env()
    pdf = build_input(args.in_suffix, args.limit_users, args.allow_singleton_noise)
    res = run_howde(pdf)
    per_user = summarise(res)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    a = OUT_DIR / f"home_work_stops{args.out_suffix}.parquet"
    b = OUT_DIR / f"home_work{args.out_suffix}.parquet"
    res.to_parquet(a, index=False)
    per_user.to_parquet(b, index=False)
    log("")
    log(f"wrote {a}")
    log(f"wrote {b}")


if __name__ == "__main__":
    main()
