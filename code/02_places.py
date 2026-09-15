#!/usr/bin/env python3
"""
02_places.py — global place identity via Infostop stage 2.

Assigns every stop a `place_id` that is SHARED ACROSS USERS, replacing the
chained SAME_PLACE_M merge and the H3-cell proxy that 02_routines.R used.

    python code/02_places.py                    # full run
    python code/02_places.py --limit-users 13000 --out-suffix _pilot

WHY THIS STEP IS NOT BUCKETED
Every other ping-level stage fans out over user buckets. This one must not.
Infostop's documented advantage is precisely that it clusters many users'
traces into one shared label space, and the paper reports that detected
location sizes stabilise as users are added. Run it per bucket and you get 16
independent label spaces — the same cafe carrying 16 different ids — which
discards the property that motivated using it.

That is affordable because the input is stops, not pings: ~20M stop medians,
two columns, heavily duplicated in space. Hundreds of MB, not tens of GB.

WHY STAGE 1 IS NOT USED
infostop.Infostop would redo stop detection from raw traces. Its stage 1 is
close to detect_stops_one() in 01_stops.R, so swapping it buys nothing and
would mean shipping ~96M cleaned pings across the language boundary.
SpatialInfomap is stage 2 on its own, which is the part worth having.

label_singleton=True IS NOT OPTIONAL HERE — see LABEL_SINGLETON below.

Outputs
    output/stop_places.parquet   registration_id, stop_id, place_id
    output/places.parquet        place_id, lat, lon, h3_9, n_stops, n_users
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# parameters
# ---------------------------------------------------------------------------

# r2 — two stop medians within this many metres are candidates for the same
# place. Infostop's own default is 10 m, which is tight for opportunistic app
# check-ins: this source has far worse positional accuracy than the continuous
# GPS traces Infostop was demonstrated on. 50 m is a starting point, not a
# finding — it is the first thing to vary in a sensitivity check, and it
# interacts with DIST_THRESH_M (200 m) and SAME_PLACE_M (400 m) in 01_stops.R.
R2_METRES = 50.0

# Pre-deduplication grid, in degrees. Stop medians are rounded to this before
# clustering and the labels mapped back afterwards, which cuts the number of
# points Infomap has to graph without changing which physical places exist.
# 1e-5 deg is ~1.1 m — far below R2_METRES, so it cannot merge places that
# would otherwise be distinct.
#
# Set to 0 to disable and cluster every stop median individually.
DEDUP_RESOLUTION_DEG = 1e-5

# MUST STAY TRUE.
#
# With label_singleton=False, Infostop labels any place too sparse to form a
# cluster as -1. Two consequences, both bad here:
#   * Half of all stops in this data are single-ping (measured: 50.4%), and a
#     lone 3am ping is deliberately retained as home evidence — see the header
#     of 01_stops.R. Collapsing them into one "noise" bucket destroys that.
#   * HoWDe drops rows whose location id is -1, silently. So the two defaults
#     interact: label_singleton=False would delete that evidence twice over,
#     without an error either time.
# Both halves of this were verified against the installed packages, not assumed.
LABEL_SINGLETON = True   # default; --allow-singleton-noise flips it for the A/B test

H3_RESOLUTION = 9  # must match the land-use layer joined in 03/04

STOPS_CSV = Path("output/stops.csv")
OUT_DIR = Path("output")

EARTH_R = 6_371_000.0


# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_stops(limit_users: int | None) -> pd.DataFrame:
    if not STOPS_CSV.exists():
        sys.exit(f"{STOPS_CSV} not found — run code/01_stops.R first.")

    log(f"reading {STOPS_CSV} ...")
    df = pd.read_csv(
        STOPS_CSV,
        usecols=["registration_id", "stop_id", "lat", "lon"],
        dtype={"registration_id": "string", "stop_id": "int32",
               "lat": "float64", "lon": "float64"},
    )
    log(f"  {len(df):,} stops, {df.registration_id.nunique():,} users")

    if limit_users:
        keep = df.registration_id.drop_duplicates().head(limit_users)
        df = df[df.registration_id.isin(set(keep))].copy()
        log(f"  PILOT: restricted to {limit_users:,} users -> {len(df):,} stops")
        log("  NOTE pilot place ids are NOT comparable with a full run — the "
            "label space depends on which users are present.")
    return df


def cluster_places(lat: np.ndarray, lon: np.ndarray,
                   label_singleton: bool = LABEL_SINGLETON,
                   allow_noise: bool = False) -> np.ndarray:
    """Return a place label per input row, via Infostop stage 2."""
    from infostop import SpatialInfomap

    coords = np.column_stack([lat, lon])

    if DEDUP_RESOLUTION_DEG > 0:
        key = np.round(coords / DEDUP_RESOLUTION_DEG) * DEDUP_RESOLUTION_DEG
        uniq, inverse = np.unique(key, axis=0, return_inverse=True)
        log(f"  deduplicated {len(coords):,} stop medians -> {len(uniq):,} "
            f"distinct points at {DEDUP_RESOLUTION_DEG} deg")
    else:
        uniq, inverse = coords, np.arange(len(coords))

    log(f"  clustering with r2={R2_METRES} m, label_singleton={label_singleton} ...")
    t0 = time.time()
    model = SpatialInfomap(
        r2=R2_METRES,
        label_singleton=label_singleton,
        distance_metric="haversine",   # inputs are lat/lon degrees
        verbose=False,
    )
    labels_u = np.asarray(model.fit_predict(uniq))
    log(f"  done in {time.time() - t0:.1f}s -> {len(np.unique(labels_u)):,} places")

    n_noise = int((labels_u == -1).sum())
    if n_noise and not allow_noise:
        # Unreachable with the default. Refuse rather than hand HoWDe a column
        # it will silently drop rows on.
        sys.exit(f"ERROR: {n_noise:,} points labelled -1 (noise). HoWDe drops "
                 f"loc == -1 without warning. Use the default label_singleton, "
                 f"or pass --allow-singleton-noise if this is the A/B test.")
    if n_noise:
        log(f"  {n_noise:,} distinct points labelled -1 (isolated places). "
            f"HoWDe WILL DROP these rows — that is the effect under test.")

    return labels_u[inverse]


def build_place_table(df: pd.DataFrame) -> pd.DataFrame:
    """One row per place: centroid, H3 cell, and how much evidence backs it."""
    import h3

    places = (
        df.groupby("place_id")
          .agg(lat=("lat", "mean"),
               lon=("lon", "mean"),
               n_stops=("stop_id", "size"),
               n_users=("registration_id", "nunique"))
          .reset_index()
    )

    # H3 from the place CENTROID, assigned once per place.
    #
    # This is what keeps the land-use join in 03/04 working after place_id
    # replaces h3_9 as the unit of place. It also fixes the artefact called out
    # in the 02_routines.R header: previously each stop got its own cell, so a
    # building straddling a boundary could flip cells between visits. Now a
    # place has exactly one cell, chosen once.
    places["h3_9"] = [
        h3.latlng_to_cell(la, lo, H3_RESOLUTION)
        for la, lo in zip(places.lat, places.lon)
    ]
    return places


def report(df: pd.DataFrame, places: pd.DataFrame) -> None:
    log("")
    log("place summary")
    log(f"  places                         {len(places):,}")
    log(f"  stops                          {len(df):,}")
    log(f"  stops per place   median/max   {places.n_stops.median():.0f} / {places.n_stops.max():,}")
    log(f"  single-stop places             {(places.n_stops == 1).sum():,} "
        f"({100 * (places.n_stops == 1).mean():.1f}%)")
    log(f"  places seen by >1 user         {(places.n_users > 1).sum():,} "
        f"({100 * (places.n_users > 1).mean():.1f}%)")
    log(f"  distinct h3_{H3_RESOLUTION} cells used        {places.h3_9.nunique():,}")

    # If many places share a cell, place_id is finer than the old h3_9 unit —
    # which is the point. If the ratio is ~1 the clustering is adding nothing
    # over the cell grid, and r2 probably needs revisiting.
    ratio = len(places) / max(places.h3_9.nunique(), 1)
    log(f"  places per h3 cell             {ratio:.2f}"
        + ("   <- ~1.0 means clustering adds little over the H3 grid; check r2"
           if ratio < 1.2 else ""))


def main() -> None:
    global STOPS_CSV
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit-users", type=int, default=None,
                    help="pilot on the first N users (place ids are then not "
                         "comparable with a full run)")
    ap.add_argument("--out-suffix", default="",
                    help="suffix for output filenames, e.g. _pilot")
    ap.add_argument("--stops-csv", default=str(STOPS_CSV),
                    help="stops file to read (e.g. output/stops_pilot.csv)")
    ap.add_argument("--allow-singleton-noise", action="store_true",
                    help="run with label_singleton=False, permitting -1 labels. "
                         "ONLY for the A/B test — HoWDe drops loc == -1 silently.")
    args = ap.parse_args()

    STOPS_CSV = Path(args.stops_csv)

    df = load_stops(args.limit_users)
    df["place_id"] = cluster_places(
        df.lat.to_numpy(), df.lon.to_numpy(),
        label_singleton=not args.allow_singleton_noise,
        allow_noise=args.allow_singleton_noise)
    places = build_place_table(df)
    report(df, places)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sp = OUT_DIR / f"stop_places{args.out_suffix}.parquet"
    pl = OUT_DIR / f"places{args.out_suffix}.parquet"
    df[["registration_id", "stop_id", "place_id"]].to_parquet(sp, index=False)
    places.to_parquet(pl, index=False)
    log("")
    log(f"wrote {sp}")
    log(f"wrote {pl}")


if __name__ == "__main__":
    main()
