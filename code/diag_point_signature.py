#!/usr/bin/env python3
"""
diag_point_signature.py — behavioural signature of shared coordinates.

    python code/diag_point_signature.py                 # top 15 by users
    python code/diag_point_signature.py --top 30 --stops-csv output/stops.csv

Reads output/shared_coordinates<sfx>.csv (written by diag_shared_coords.py)
and, for each of the top-N points by user count, asks the question that
separates a fallback from a real network fix at a busy site:

    nothing_else   share of the point's users who appear NOWHERE else in the
                   whole window. Real visitors also go home; a phone that
                   produces a real fix at a station produces one at home too.
                   Fallback centroids scored 22-42% on the original data;
                   St Andrew Square (a plausible real fix) scored 15%.

Also reported per point: median stops per user, pings per stop, median dwell,
share "staying" — and the overall baseline for nothing_else.
"""
import argparse
from pathlib import Path

import pandas as pd

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--stops-csv", default="output/stops.csv")
ap.add_argument("--shared-csv", default=None, help="default output/shared_coordinates<suffix>.csv")
ap.add_argument("--out-suffix", default="")
ap.add_argument("--top", type=int, default=15)
args = ap.parse_args()

shared = Path(args.shared_csv or f"output/shared_coordinates{args.out_suffix}.csv")
if not shared.exists():
    raise SystemExit(f"{shared} not found — run code/diag_shared_coords.py first.")
pts = pd.read_csv(shared).sort_values("n_users", ascending=False).head(args.top)

st = pd.read_csv(args.stops_csv,
                 usecols=["registration_id", "stop_id", "lat", "lon", "n_pings", "duration_min"],
                 dtype={"registration_id": "string", "stop_id": "int32"})
st["key"] = st.lat.round(7).astype(str) + "," + st.lon.round(7).astype(str)
user_n = st.groupby("registration_id").stop_id.size()

rows = []
for r in pts.itertuples():
    key = f"{round(r.lat, 7)},{round(r.lon, 7)}"
    s = st[st.key == key]
    if s.empty:
        continue
    per_user = s.groupby("registration_id").size()
    only = (user_n.loc[per_user.index] == per_user).mean()
    rows.append(dict(lat=r.lat, lon=r.lon, cls=r.cls, dec=r.dec, users=len(per_user),
                     nothing_else=f"{100*only:.0f}%",
                     stops_per_user=round(per_user.median(), 1),
                     pings_per_stop=round(s.n_pings.mean(), 1),
                     median_dur=round(s.duration_min.median(), 1),
                     staying=f"{100*(s.duration_min >= 5).mean():.0f}%"))

pd.set_option("display.width", 220)
print(pd.DataFrame(rows).to_string(index=False))

nloc = st.groupby("registration_id").key.nunique()
print(f"\nbaseline: users with a single distinct location overall: {100*(nloc == 1).mean():.1f}%")
print("rule of thumb (from the original data): fallback centroids 22-42% nothing_else; "
      "St Andrew Square 15%.")
