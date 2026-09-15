# ed-gender — stops and places from app check-in pings

Pipeline for turning opportunistic app check-in pings (Edinburgh, 26 Aug – 13 Oct
2024, ~111M pings, ~1M users) into **stops** (stay-points per user) and
**places** (locations shared across users), as input to a gender-and-mobility
analysis.

The data are not continuous GPS traces: a ping is an isolated check-in, sampling
is highly irregular between users, and a "stop" therefore means "pings clustered
in space and time", nothing more. Durations are lower bounds.

## Pipeline

| Step | Script | In → out | Runs |
|---|---|---|---|
| 1 | `code/01_stops.R` | pings → stops | R, per bucket, parallel |
| 2 | `code/02_places.py` | stops → shared `place_id` | Python, **all users at once** |

**`01_stops.R`** cleans the pings (analysis window, excluded holiday dates,
bounding box, duplicates, impossible-speed spikes, impossible out-and-back
excursions), then runs sequential stay-point detection per user, merges stops
fragmented within one visit, and labels each stop `passing` (< 5 min) or
`staying`. Nothing is discarded: single-ping stops are kept as evidence of
presence. Input is split into 16 buckets on the first hex character of the user
id; since every step is per-user, bucketed output is identical to a single pass,
and buckets run as forked workers. Resumable per bucket.

**`02_places.py`** takes the stop medians from step 1 and runs Infostop's
stage 2 (`SpatialInfomap`) to assign every stop a `place_id` shared across
users, plus one H3 res-9 cell per place. It deliberately skips Infostop's
stage 1 (stop detection), which `01_stops.R` replaces with thresholds tuned to
this noisier data. This step cannot be bucketed — per-bucket runs would give
16 unrelated label spaces.

## Running

Locally (data in `data/bucket_*.csv`):

```bash
Rscript code/01_stops.R
source code/env.sh            # written by code/setup_python.sh
python code/02_places.py
```

Set `ONLY_BUCKETS <- c("0")` in `01_stops.R` for a 1/16 pilot; outputs are
suffixed `_pilot` and cannot collide with a full run. Pilot `place_id`s are not
comparable with a full run.

On Eddie (Univa Grid Engine):

```bash
qsub code/job_stops.sge        # 01_stops.R, 16 slots x 4G, ~20 min
qsub code/job_places.sge      # 02_places.py, 16 slots x 8G (memory, not cores)
```

`job_stops.sge` refuses to run while `ONLY_BUCKETS` is set to a pilot value.
`job_places.sge` refuses to run without a full `output/stops.csv`.

## Environment

- R ≥ 4.x with **data.table** only (`sf` is loaded lazily and only if
  `WRITE_GPKG = TRUE`).
- Python **3.10** venv built by `code/setup_python.sh`: infostop 0.1.9 (needs
  pybind11 and `setuptools<81` installed first, and `--no-build-isolation`),
  pandas, pyarrow, h3. Build it on a login node; compute nodes have no internet.

## Outputs

```
output/stops.rds, stops.csv       one row per (registration_id, stop_id)
output/buckets/stops_<b>.rds      per-bucket stops + counters
output/buckets/pings_<b>.rds      per-bucket labelled pings (never recombined)
output/stop_places.parquet        registration_id, stop_id, place_id
output/places.parquet             place_id, lat, lon, h3_9, n_stops, n_users
```

Stop columns: `arrival_time`, `departure_time`, `duration_min`,
`duration_class`, `n_pings`, `n_merged`, `lat`, `lon`, `h3_9`.

## Key parameters

| Where | Parameter | Value | Note |
|---|---|---|---|
| `01_stops.R` | `DIST_THRESH_M` | 200 m | max distance from cluster reference (Infostop's r1 default is 10 m) |
| `01_stops.R` | `MAX_GAP_MIN` | 240 min | silence that closes a stop |
| `01_stops.R` | `DRIFT_MODE` | `centroid` | running mean vs first ping (`anchor`) as reference |
| `01_stops.R` | `SAME_PLACE_M` / `MERGE_GAP_MIN` | 400 m / 60 min | fragment merge |
| `01_stops.R` | `STAY_THRESHOLD_MIN` | 5 min | passing/staying label |
| `01_stops.R` | `EXCLUDE_DATES` | 2024-08-26, 2024-09-16 | bank holiday; autumn holiday (inferred, unconfirmed) |
| `02_places.py` | `R2_METRES` | 50 m | Infostop stage-2 link radius |
| `02_places.py` | `LABEL_SINGLETON` | `True` | must stay true; `-1` labels are silently dropped downstream |

Defaults are starting points, not findings.

## Not in this repository

`data/`, `output/` and `logs/` are ignored (the extract is ~10 GB; outputs are
several GB). The BigQuery extraction script (`00_query.R`) and the downstream
home/work and sequence scripts live in a separate copy of the project.
