#!/usr/bin/env python3
"""
diag_shared_coords.py — find exact coordinates shared by many users in stops.csv.

    python code/diag_shared_coords.py                      # output/stops.csv
    python code/diag_shared_coords.py --stops-csv output/stops_pilot.csv --out-suffix _pilot

Why this exists (2026-09-15). The first full run of 02_places.py produced
"places" with 80k users each, all sitting on one identical coordinate. Those
turned out to be OS coarse-location fallbacks: one fixed point per district,
with <= 4 decimal places, handed to the app when no precise fix is available.
43 such points held 24% of all pings and 22% of users had nothing else.
01_stops.R now drops them (COARSE_MAX_DECIMALS). Run this after a rerun to
confirm the red class is gone and to keep an eye on the others.

Classes:
    coarse  a 4-decimal value, exactly or as its float32 rendering
            (55.9632 -> 55.96319961) — area fallbacks; zero after the filter
    near    rounds to a centroid listed in code/coarse_fallback_coords.csv
            but is not itself 4-dp (perturbed < 1 m) — also zero after the filter
    hi      >= 8 decimals and not coarse — shared full-precision values
    other   5–7 decimals — GPS-like values that many users still share
            (e.g. St Andrew Square at 55.95415, -3.20277: plausibly a real
            network fix at the bus/tram interchange; kept)

Outputs
    output/shared_coordinates<sfx>.csv        one row per shared coordinate
    output/shared_coordinates_map<sfx>.html   Leaflet map, self-contained
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

MIN_USERS = 100


def ndec(x: pd.Series) -> pd.Series:
    return x.astype(str).str.split(".").str[1].str.len().fillna(0).astype(int)


def is_coarse(x: pd.Series, dp: int = 4, tol: float = 2e-8) -> pd.Series:
    """Same test as is_coarse_coord() in 01_stops.R: a dp-decimal value, either
    exactly or as its float32 rendering (55.9632 -> 55.96319961)."""
    r = x.round(dp)
    f32 = r.astype(np.float32).astype(np.float64)
    return ((x - r).abs() < 1e-9) | ((x - f32).abs() < tol)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stops-csv", default="output/stops.csv")
    ap.add_argument("--out-suffix", default="")
    ap.add_argument("--min-users", type=int, default=MIN_USERS)
    args = ap.parse_args()

    st = pd.read_csv(args.stops_csv,
                     usecols=["registration_id", "stop_id", "lat", "lon", "n_pings"],
                     dtype={"registration_id": "string", "stop_id": "int32"})
    tot = dict(stops=len(st), pings=int(st.n_pings.sum()), users=int(st.registration_id.nunique()))
    print(f"{tot['stops']:,} stops, {tot['pings']:,} pings, {tot['users']:,} users")

    st["key"] = st.lat.round(7).astype(str) + "," + st.lon.round(7).astype(str)
    g = (st.groupby("key")
           .agg(lat=("lat", "first"), lon=("lon", "first"),
                n_stops=("stop_id", "size"), n_users=("registration_id", "nunique"),
                n_pings=("n_pings", "sum")))
    big = g[g.n_users >= args.min_users].copy()
    big["dec"] = np.maximum(ndec(big.lat), ndec(big.lon))
    coarse = is_coarse(big.lat) & is_coarse(big.lon)
    # "near": rounds to a known fallback centroid but is not itself a 4-dp value
    # (the sub-metre perturbed variant). Needs code/coarse_fallback_coords.csv.
    near = pd.Series(False, index=big.index)
    bl_path = Path("code/coarse_fallback_coords.csv")
    if bl_path.exists():
        bl = pd.read_csv(bl_path)
        keys = set(zip(bl.lat4.round(4), bl.lon4.round(4)))
        near = pd.Series([(a, b) in keys for a, b in zip(big.lat.round(4), big.lon.round(4))],
                         index=big.index) & ~coarse
    big["cls"] = np.where(coarse, "coarse", np.where(near, "near",
                 np.where(big.dec >= 8, "hi", "other")))
    big = big.sort_values("n_users", ascending=False)

    by_cls = (big.groupby("cls")
                 .agg(n=("lat", "size"), stops=("n_stops", "sum"),
                      pings=("n_pings", "sum"), users_max=("n_users", "max")))
    print(f"\ncoordinates shared by >= {args.min_users} users: {len(big)}")
    print(f"  holding {100*big.n_stops.sum()/tot['stops']:.1f}% of stops, "
          f"{100*big.n_pings.sum()/tot['pings']:.1f}% of pings")
    print(by_cls.to_string())

    # per-user share of stops on coarse coordinates (index of big is the key)
    st["on_coarse"] = st.key.isin(big.index[big.cls.isin(["coarse", "near"])])
    u = st.groupby("registration_id").on_coarse.mean()
    print(f"\nusers with ALL stops on a coarse coordinate: {(u == 1).sum():,} ({100*(u == 1).mean():.1f}%)")
    print(f"users with ANY stop on a coarse coordinate: {(u > 0).sum():,} ({100*(u > 0).mean():.1f}%)")

    out_dir = Path("output")
    csv = out_dir / f"shared_coordinates{args.out_suffix}.csv"
    big.to_csv(csv, index=False)
    print(f"\nwrote {csv}")

    summary = dict(n_coords=int(len(big)), by_class=by_cls.to_dict("index"),
                   total_stops=tot["stops"], total_pings=tot["pings"], total_users=tot["users"],
                   share_stops=float(big.n_stops.sum() / tot["stops"]),
                   share_pings=float(big.n_pings.sum() / tot["pings"]))
    pts = [dict(lat=round(float(r.lat), 7), lon=round(float(r.lon), 7), stops=int(r.n_stops),
                users=int(r.n_users), pings=int(r.n_pings), dec=int(r.dec), cls=r.cls)
           for r in big.itertuples()]
    html = MAP_HTML.replace("__DATA__", json.dumps(dict(summary=summary, points=pts), default=int))
    hp = out_dir / f"shared_coordinates_map{args.out_suffix}.html"
    hp.write_text(html, encoding="utf-8")
    print(f"wrote {hp}")


MAP_HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shared Coordinates Map</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<style>
  html, body { height: 100%; margin: 0; font: 14px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; color: #222; }
  #map { position: absolute; inset: 0; }
  .panel { position: absolute; z-index: 1000; background: rgba(255,255,255,.95); border-radius: 8px;
           box-shadow: 0 1px 6px rgba(0,0,0,.25); padding: 10px 12px; }
  #info { top: 12px; left: 56px; max-width: 360px; }
  #info h1 { font-size: 15px; margin: 0 0 6px; }
  #info p { margin: 4px 0; }
  #legend { bottom: 24px; right: 12px; }
  .sw { display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 6px; vertical-align: -1px; border: 1px solid rgba(0,0,0,.4); }
  label { display: block; cursor: pointer; margin: 2px 0; }
  .muted { color: #666; font-size: 12px; }
</style></head><body>
<div id="map"></div>
<div id="info" class="panel">
  <h1>Exact coordinates shared by many users</h1>
  <p id="summary"></p>
  <p class="muted">Circle area &prop; number of users. Click a circle for details.</p>
</div>
<div id="legend" class="panel">
  <label><input type="checkbox" checked data-cls="coarse"> <span class="sw" style="background:#d7301f"></span><b>4-dp value</b> (exact or float32) &mdash; area fallbacks</label>
  <label><input type="checkbox" checked data-cls="near"> <span class="sw" style="background:#f4a582"></span><b>near a known centroid</b> &mdash; perturbed fallbacks</label>
  <label><input type="checkbox" checked data-cls="hi"> <span class="sw" style="background:#2b8cbe"></span><b>8 decimals</b> &mdash; shared full-precision values</label>
  <label><input type="checkbox" checked data-cls="other"> <span class="sw" style="background:#7a7a7a"></span><b>5&ndash;7 decimals</b> &mdash; shared but GPS-like</label>
</div>
<script>
const DATA = __DATA__;
const s = DATA.summary, bc = s.by_class;
const fmt = n => n.toLocaleString("en-GB"), pct = x => (100 * x).toFixed(1) + "%";
const co = bc.coarse || {n: 0, stops: 0, pings: 0, users_max: 0};
document.getElementById("summary").innerHTML =
  `<b>${s.n_coords}</b> coordinates hold <b>${pct(s.share_stops)}</b> of ${fmt(s.total_stops)} stops and <b>${pct(s.share_pings)}</b> of ${fmt(s.total_pings)} pings.<br>` +
  `Red (&le;4 dp): <b>${co.n}</b> points, ${fmt(co.pings)} pings (${pct(co.pings / s.total_pings)}), up to ${fmt(co.users_max)} users on one point.`;
const map = L.map("map", { preferCanvas: true }).setView([55.94, -3.20], 12);
L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
  { maxZoom: 19, attribution: "&copy; OpenStreetMap contributors &copy; CARTO" }).addTo(map);
const COL = { coarse: "#d7301f", near: "#f4a582", hi: "#2b8cbe", other: "#7a7a7a" };
const layers = { coarse: L.layerGroup(), near: L.layerGroup(), hi: L.layerGroup(), other: L.layerGroup() };
for (const p of DATA.points.slice().sort((a, b) => b.users - a.users)) {
  L.circleMarker([p.lat, p.lon], { radius: Math.max(4, Math.sqrt(p.users) / 6), color: COL[p.cls],
      weight: 1, fillColor: COL[p.cls], fillOpacity: 0.45 })
   .bindPopup(`<b>${p.lat}, ${p.lon}</b><br>${p.dec} decimal places<br>` +
              `users: <b>${fmt(p.users)}</b> (${pct(p.users / s.total_users)} of all)<br>` +
              `stops: <b>${fmt(p.stops)}</b> &nbsp; pings: <b>${fmt(p.pings)}</b><br>` +
              `pings per stop: ${(p.pings / p.stops).toFixed(1)}`)
   .addTo(layers[p.cls]);
}
for (const k of ["other", "hi", "near", "coarse"]) layers[k].addTo(map);
document.querySelectorAll("#legend input").forEach(cb => cb.addEventListener("change", () => {
  const k = cb.dataset.cls; if (cb.checked) layers[k].addTo(map); else map.removeLayer(layers[k]);
}));
</script></body></html>
"""


if __name__ == "__main__":
    main()