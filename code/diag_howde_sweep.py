#!/usr/bin/env python3
"""
diag_howde_sweep.py — compare HoWDe runs across f_hours_H thresholds.

    python code/diag_howde_sweep.py                       # 0.7 0.75 0.8 0.85 0.9
    python code/diag_howde_sweep.py --values 0.7 0.9
    python code/diag_howde_sweep.py --baseline 0.7 --min-days 14

Reads output/home_work_fH<v>.parquet for each value (written by
job_howde_sweep.sge) and reports, per threshold:

    coverage    users with a home / with a work / with both, as counts and as
                a share of the cohort (all users in stops.csv) and of the users
                HoWDe emitted rows for
    agreement   against the baseline threshold: users whose home is the SAME
                place, a DIFFERENT place, LOST (had one at baseline, none now)
                or GAINED; likewise for work
    evidence    median days observed for users with a home, and the share of
                homes resting on fewer than --min-days observed days
    places      distinct home / work places, and the largest one (users)
    commute     median and p90 home-work distance for users with both

Then, for the highest threshold vs the baseline, profiles the users whose home
is LOST against those who KEEP it: days observed, stops, stops per observed
day, night stops, distinct night places, weekend share. If the lost users are
the better-observed ones with more night places, the stricter threshold is
removing complex routines rather than weak evidence.

Writes output/howde_sweep_summary.csv and output/howde_sweep_lost_profile.csv.
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

OUT = Path("output")


def hav_m(lat1, lon1, lat2, lon2):
    r = np.pi / 180
    a = (np.sin((lat2 - lat1) * r / 2) ** 2
         + np.cos(lat1 * r) * np.cos(lat2 * r) * np.sin((lon2 - lon1) * r / 2) ** 2)
    return 2 * 6371000 * np.arcsin(np.sqrt(a))


def load(v: str) -> pd.DataFrame:
    p = OUT / f"home_work_fH{v}.parquet"
    if not p.exists():
        raise SystemExit(f"{p} not found — has job_howde_sweep.sge run for {v}?")
    df = pd.read_parquet(p)
    for c in ("home_place", "work_place"):
        df[c] = pd.to_numeric(df[c], errors="coerce").astype("Int64")
    return df.set_index("useruuid")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--values", nargs="+", default=["0.7", "0.75", "0.8", "0.85", "0.9"])
    ap.add_argument("--baseline", default="0.7")
    ap.add_argument("--min-days", type=int, default=14,
                    help="days observed below which a home label counts as thin evidence")
    ap.add_argument("--stops-csv", default="output/stops.csv")
    args = ap.parse_args()

    pl = pd.read_parquet(OUT / "places.parquet").set_index("place_id")[["lat", "lon"]]

    # per-user observation profile from stops (independent of HoWDe's row filter)
    st = pd.read_csv(args.stops_csv,
                     usecols=["registration_id", "stop_id", "arrival_time", "duration_min", "duration_class"],
                     dtype={"registration_id": "string", "stop_id": "int32", "duration_class": "category"})
    t = pd.to_datetime(st.arrival_time, utc=True).dt.tz_convert("Europe/London")
    st["date"] = t.dt.date
    st["weekend"] = t.dt.dayofweek >= 5
    # "overnight": the stop spans 03:00 local — the person was there in the
    # middle of the night. A 22:40 single ping on the way home is NOT a night
    # place; on this data 77% of night-ARRIVAL stops away from home are such
    # passing pings, so arrival hour alone badly overstates nights elsewhere.
    arr_min = t.dt.hour * 60 + t.dt.minute
    end_min = arr_min + st.duration_min
    st["overnight"] = ((arr_min < 180) & (end_min >= 180)) | ((arr_min >= 180) & (end_min >= 24 * 60 + 180))
    sp = pd.read_parquet(OUT / "stop_places.parquet")
    st = st.merge(sp, on=["registration_id", "stop_id"], how="left")
    del sp
    g = st.groupby("registration_id")
    prof = pd.DataFrame({
        "days_observed": g.date.nunique(),
        "stops": g.size(),
        "staying_stops": g.duration_class.apply(lambda s: (s == "staying").sum()),
        "overnight_stops": g.overnight.sum(),
        "overnight_places": st[st.overnight].groupby("registration_id").place_id.nunique(),
        "distinct_places": g.place_id.nunique(),
        "weekend_share": g.weekend.mean(),
    })
    prof["overnight_places"] = prof.overnight_places.fillna(0).astype(int)
    prof["stops_per_day"] = prof.stops / prof.days_observed
    days = prof.days_observed
    n_cohort = len(prof)
    print(f"cohort: {n_cohort:,} users in {args.stops_csv}")

    runs = {v: load(v) for v in args.values}
    base = runs[args.baseline]
    rows = []
    for v, df in runs.items():
        home, work = df.home_place.notna(), df.work_place.notna()
        both = home & work
        d = days.reindex(df.index)
        hd = d[home]
        # agreement vs baseline
        b = base.reindex(df.index)
        bh, bw = b.home_place, b.work_place
        same_h = (home & bh.notna() & (df.home_place == bh)).sum()
        diff_h = (home & bh.notna() & (df.home_place != bh)).sum()
        lost_h = (bh.notna() & ~home).sum()
        gain_h = (home & bh.isna()).sum()
        same_w = (work & bw.notna() & (df.work_place == bw)).sum()
        diff_w = (work & bw.notna() & (df.work_place != bw)).sum()
        lost_w = (bw.notna() & ~work).sum()
        gain_w = (work & bw.isna()).sum()
        # places
        hc, wc = df.home_place.dropna().value_counts(), df.work_place.dropna().value_counts()
        # commute
        hb = df[both]
        cm = hav_m(pl.lat.reindex(hb.home_place).values, pl.lon.reindex(hb.home_place).values,
                   pl.lat.reindex(hb.work_place).values, pl.lon.reindex(hb.work_place).values)
        rows.append(dict(
            f_hours_H=v, users_in_output=len(df),
            home=int(home.sum()), home_pct_cohort=round(100 * home.sum() / n_cohort, 1),
            home_pct_output=round(100 * home.mean(), 1),
            work=int(work.sum()), work_pct_cohort=round(100 * work.sum() / n_cohort, 1),
            both=int(both.sum()),
            home_same=int(same_h), home_diff=int(diff_h), home_lost=int(lost_h), home_gained=int(gain_h),
            work_same=int(same_w), work_diff=int(diff_w), work_lost=int(lost_w), work_gained=int(gain_w),
            home_median_days=float(hd.median()), home_thin_pct=round(100 * (hd < args.min_days).mean(), 1),
            home_places=len(hc), home_place_max_users=int(hc.max()) if len(hc) else 0,
            work_places=len(wc), work_place_max_users=int(wc.max()) if len(wc) else 0,
            commute_median_km=round(float(np.nanmedian(cm)) / 1000, 2) if len(cm) else np.nan,
            commute_p90_km=round(float(np.nanpercentile(cm, 90)) / 1000, 2) if len(cm) else np.nan,
        ))

    res = pd.DataFrame(rows).set_index("f_hours_H")
    pd.set_option("display.width", 250)
    print(f"\n(agreement columns are against f_hours_H = {args.baseline}; "
          f"'thin' = home resting on < {args.min_days} observed days)\n")
    print(res.T.to_string())
    res.to_csv(OUT / "howde_sweep_summary.csv")
    print(f"\nwrote {OUT / 'howde_sweep_summary.csv'}")

    # ---- who loses their home at the strictest threshold? ------------------
    strict = args.values[-1]
    if strict == args.baseline:
        return
    hi = runs[strict]
    homed_base = base.index[base.home_place.notna()]
    lost = homed_base[hi.home_place.reindex(homed_base).isna()]
    kept = homed_base.difference(lost)
    cols = ["days_observed", "stops", "stops_per_day", "staying_stops", "overnight_stops",
            "overnight_places", "distinct_places", "weekend_share"]

    def q(idx):
        p = prof.reindex(idx)
        out = p[cols].median().rename("median")
        out = pd.concat([out, p[cols].mean().rename("mean")], axis=1)
        out.loc["users", :] = [len(idx), len(idx)]
        return out

    lk = pd.concat({"lost": q(lost), "kept": q(kept)}, axis=1)
    lk[("ratio", "median")] = (lk[("lost", "median")] / lk[("kept", "median")]).round(2)
    print(f"\n=== users with a home at {args.baseline} who LOSE it at {strict} "
          f"({len(lost):,}) vs those who KEEP it ({len(kept):,}) ===")
    print(lk.round(2).to_string())
    print("\nreading: ratio > 1 on days_observed / overnight_places means the strict threshold "
          "removes the better-observed users who occasionally sleep elsewhere, not thin evidence.")
    for name, idx in (("lost", lost), ("kept", kept)):
        d = prof.days_observed.reindex(idx)
        op = prof.overnight_places.reindex(idx)
        print(f"  {name}: {100*(d >= args.min_days).mean():.1f}% observed on >= {args.min_days} days; "
              f"{100*(op >= 2).mean():.1f}% slept (spanned 03:00) at >= 2 places; "
              f"{100*(op == 0).mean():.1f}% never spanned 03:00 anywhere")
    lk.to_csv(OUT / "howde_sweep_lost_profile.csv")
    print(f"wrote {OUT / 'howde_sweep_lost_profile.csv'}")


if __name__ == "__main__":
    main()
