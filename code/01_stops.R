# 01_stops.R — raw check-in pings -> stops (stay-point detection).
# Input: data/bucket_<0-f>.csv (users partitioned on first hex char of id).
# Output: output/stops.rds|csv, plus per-bucket labelled pings in output/buckets/.
# Every step is per-user, so buckets are independent and can run in parallel.
# Full rationale and comparison with Infostop stage 1: code/01_stops_notes.txt

suppressPackageStartupMessages({
  library(data.table)
})

# ---- config -----------------------------------------------------------------

BUCKET_DIR     <- "data"
BUCKET_GLOB    <- "^bucket_.\\.csv$"
OUTPUT_DIR     <- "output"

ONLY_BUCKETS <- NULL   # e.g. c("0") for a 1/16 pilot; outputs get "_pilot" suffix
OUT_SUFFIX   <- if (is.null(ONLY_BUCKETS)) "" else "_pilot"

BUCKET_OUT_DIR <- file.path(OUTPUT_DIR, paste0("buckets", OUT_SUFFIX))
STOPS_OUT_RDS  <- file.path(OUTPUT_DIR, sprintf("stops%s.rds",  OUT_SUFFIX))
STOPS_OUT_CSV  <- file.path(OUTPUT_DIR, sprintf("stops%s.csv",  OUT_SUFFIX))
STOPS_OUT_GPKG <- file.path(OUTPUT_DIR, sprintf("stops%s.gpkg", OUT_SUFFIX))

OVERWRITE <- FALSE     # FALSE = skip buckets that already have an output (resume)

WRITE_GPKG <- FALSE    # optional spatial layer; needs sf (loaded lazily below)

# DATETIME strings are naive; SOURCE_TZ is what they mean, TZ is the analysis clock.
SOURCE_TZ <- "Europe/London"
TZ        <- "Europe/London"

DATE_START <- as.Date("2024-08-26")   # inclusive, local date
DATE_END   <- as.Date("2024-10-14")   # exclusive

# Summer bank holiday / Fringe close; Edinburgh autumn holiday (inferred, unconfirmed)
EXCLUDE_DATES <- as.Date(c("2024-08-26", "2024-09-16"))

# Edinburgh + margin; pings outside are treated as errors
BBOX <- list(lat_min = 55.70, lat_max = 56.10,
             lon_min = -3.50, lon_max = -2.90)

MAX_SPEED_KMH      <- 200   # spike filter: implied speed above this is impossible
DIST_THRESH_M      <- 200   # max distance from cluster reference point
MAX_GAP_MIN        <- 240   # silence longer than this closes a stop
MIN_PINGS_PER_USER <- 2

SAME_PLACE_M       <- 400   # "same place" for excursion filter and stop merge

EXCURSION_MIN_M    <- 1000  # out-and-back filter: ping must be this far from both neighbours
EXCURSION_MAX_KMH  <- 120   # ... and the round trip faster than this

MERGE_GAP_MIN      <- 60    # consecutive stops within SAME_PLACE_M and this gap are merged

STAY_THRESHOLD_MIN <- 5     # "passing" below, "staying" at or above (label only, nothing dropped)

DRIFT_MODE <- "centroid"    # "centroid" = running mean of cluster; "anchor" = first ping

# ---- threads / parallelism --------------------------------------------------
# Take the scheduler's slot count (NSLOTS etc.), not detectCores(), on shared nodes.
.sched_threads <- function() {
  for (v in c("NSLOTS", "SLURM_CPUS_PER_TASK", "PBS_NP", "NCPUS", "OMP_NUM_THREADS")) {
    n <- suppressWarnings(as.integer(Sys.getenv(v, "")))
    if (!is.na(n) && n > 0L) {
      message(sprintf("Threads: %d (from %s)", n, v))
      return(n)
    }
  }
  n <- max(1L, parallel::detectCores() - 1L)
  message(sprintf("Threads: %d (detectCores; no scheduler variable found)", n))
  n
}
N_THREADS <- .sched_threads()
setDTthreads(N_THREADS)
Sys.setenv(OMP_NUM_THREADS = N_THREADS)

# data.table threads do not parallelise the per-user detection loop; forking
# one worker per bucket does. Buckets share no users, so this needs no locking.
BUCKET_WORKERS <- N_THREADS
if (nzchar(Sys.getenv("BUCKET_WORKERS", "")))
  BUCKET_WORKERS <- max(1L, as.integer(Sys.getenv("BUCKET_WORKERS")))

WORKER_DT_THREADS <- max(1L, N_THREADS %/% BUCKET_WORKERS)

# Fork safety: drop to 1 thread in the parent before mclapply; children set their own.
if (BUCKET_WORKERS > 1L) setDTthreads(1L)

# ---- counters (accumulated per bucket, saved with it, summed at the end) ----

.COUNTS <- list()
count_reset    <- function() .COUNTS <<- list()
count_snapshot <- function() .COUNTS
count <- function(label, n) {
  prev <- .COUNTS[[label]]
  .COUNTS[[label]] <<- (if (is.null(prev)) 0 else prev) + as.numeric(n)
  invisible(n)
}

report <- function(label, n)
  message(sprintf("  %-42s %s", label, format(n, big.mark = ",")))

combine_counts <- function(all) {
  out <- list()
  for (cs in all) for (nm in names(cs))
    out[[nm]] <- (if (is.null(out[[nm]])) 0 else out[[nm]]) + cs[[nm]]
  out
}

# ---- helpers ----------------------------------------------------------------

haversine_m <- function(lat1, lon1, lat2, lon2) {
  R <- 6371000
  to_rad <- pi / 180
  dlat <- (lat2 - lat1) * to_rad
  dlon <- (lon2 - lon1) * to_rad
  a <- sin(dlat / 2)^2 + cos(lat1 * to_rad) * cos(lat2 * to_rad) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

# Sequential stay-point detection for one user (pings sorted by time). Grow a
# cluster while the next ping is within dist_thresh_m of the reference point and
# the time gap is <= max_gap_s. Every ping gets a stop id; lone pings are 1-ping stops.
detect_stops_one <- function(t_sec, lat, lon,
                             dist_thresh_m = DIST_THRESH_M,
                             max_gap_s     = MAX_GAP_MIN * 60,
                             mode          = DRIFT_MODE) {
  n <- length(t_sec)
  stop_id <- integer(n)
  if (n == 0L) return(stop_id)
  use_centroid <- identical(mode, "centroid")

  cur <- 0L
  i <- 1L
  while (i <= n) {
    j <- i
    rlat <- lat[i]; rlon <- lon[i]; k <- 1L   # reference point (updated if centroid)

    while (j < n) {
      gap <- t_sec[j + 1L] - t_sec[j]
      if (gap > max_gap_s) break
      d <- haversine_m(rlat, rlon, lat[j + 1L], lon[j + 1L])
      if (d > dist_thresh_m) break
      j <- j + 1L
      if (use_centroid) {
        k <- k + 1L
        rlat <- rlat + (lat[j] - rlat) / k
        rlon <- rlon + (lon[j] - rlon) / k
      }
    }
    cur <- cur + 1L
    stop_id[i:j] <- cur
    i <- j + 1L
  }
  stop_id
}

`%||%` <- function(a, b) if (length(a)) a else b

# Modal value of a character vector (fast paths for the common 1-ping / 1-cell cases)
mode_chr <- function(x) {
  if (length(x) == 1L) return(x)
  x <- x[!is.na(x)]
  if (!length(x)) return(NA_character_)
  ux <- unique(x)
  if (length(ux) == 1L) return(ux)
  ux[which.max(tabulate(match(x, ux), nbins = length(ux)))]
}

# ---- per-bucket pipeline: load -> clean -> detect -> aggregate -> merge -----

process_bucket <- function(path) {
  count_reset()

  # DATETIME must be read as character: auto-parsing labels it UTC and the
  # explicit as.POSIXct() below then silently shifts every timestamp.
  dt <- fread(path,
              colClasses = list(character = c("registration_id", "h3_9",
                                              "DATETIME")),
              nThread = data.table::getDTthreads())
  count("rows read", nrow(dt))
  if (!nrow(dt)) return(list(stops = NULL, counts = count_snapshot()))

  need <- c("registration_id", "LATITUDE", "LONGITUDE", "DATETIME", "h3_9")
  miss <- setdiff(need, names(dt))
  if (length(miss))
    stop("Bucket file ", path, " is missing column(s): ",
         paste(miss, collapse = ", "),
         "\n  Found: ", paste(names(dt), collapse = ", "),
         "\n  The extract should carry exactly: ", paste(need, collapse = ", "))

  stopifnot(is.character(dt$DATETIME))
  dt[, DATETIME := as.POSIXct(DATETIME, format = "%Y-%m-%d %H:%M:%S", tz = SOURCE_TZ)]

  n_bad <- sum(is.na(dt$DATETIME))
  if (n_bad > 0.01 * nrow(dt))
    stop(sprintf("%.1f%% of DATETIME failed to parse in %s — check the string format.",
                 100 * n_bad / nrow(dt), path))
  count("pings dropped: unparseable timestamp", n_bad)
  dt <- dt[!is.na(DATETIME)]

  if (!identical(SOURCE_TZ, TZ)) setattr(dt$DATETIME, "tzone", TZ)

  # -- cleaning: window, excluded dates, NAs, bbox, duplicates
  dt[, local_date := as.Date(format(DATETIME, "%Y-%m-%d", tz = TZ))]
  dt <- dt[local_date >= DATE_START & local_date < DATE_END]
  count("after analysis-window filter", nrow(dt))

  if (length(EXCLUDE_DATES)) {
    n_before <- nrow(dt)
    dt <- dt[!(local_date %in% EXCLUDE_DATES)]
    count("pings dropped: excluded dates", n_before - nrow(dt))
  }
  dt[, local_date := NULL]

  dt <- dt[!is.na(registration_id) & !is.na(LATITUDE) & !is.na(LONGITUDE)]
  count("after dropping NA id/coords", nrow(dt))

  dt <- dt[LATITUDE  >= BBOX$lat_min & LATITUDE  <= BBOX$lat_max &
             LONGITUDE >= BBOX$lon_min & LONGITUDE <= BBOX$lon_max]
  count("after bounding-box filter", nrow(dt))

  dt <- unique(dt, by = c("registration_id", "DATETIME", "LATITUDE", "LONGITUDE"))
  count("after removing exact duplicate pings", nrow(dt))

  count("duplicate-timestamp pings (kept first)",
        dt[, .N, by = .(registration_id, DATETIME)][N > 1, sum(N - 1)])

  setorder(dt, registration_id, DATETIME)
  dt <- unique(dt, by = c("registration_id", "DATETIME"))

  # -- spike filter: ping is bad only if BOTH legs (in and out) are impossibly fast
  dt[, `:=`(
    prev_lat = shift(LATITUDE), prev_lon = shift(LONGITUDE), prev_time = shift(DATETIME),
    next_lat = shift(LATITUDE, type = "lead"), next_lon = shift(LONGITUDE, type = "lead"),
    next_time = shift(DATETIME, type = "lead")
  ), by = registration_id]

  dt[, `:=`(
    speed_prev_kmh = (haversine_m(LATITUDE, LONGITUDE, prev_lat, prev_lon) / 1000) /
      pmax(as.numeric(difftime(DATETIME, prev_time, units = "hours")), 1e-6),
    speed_next_kmh = (haversine_m(LATITUDE, LONGITUDE, next_lat, next_lon) / 1000) /
      pmax(as.numeric(difftime(next_time, DATETIME, units = "hours")), 1e-6)
  )]

  is_spike <- !is.na(dt$speed_prev_kmh) & !is.na(dt$speed_next_kmh) &
    dt$speed_prev_kmh > MAX_SPEED_KMH & dt$speed_next_kmh > MAX_SPEED_KMH

  # -- excursion filter: neighbours are the same place, but the ping claims an
  #    impossible round trip between them (per-leg speed test misses these)
  dt[, `:=`(
    d_prev    = haversine_m(LATITUDE, LONGITUDE, prev_lat, prev_lon),
    d_next    = haversine_m(LATITUDE, LONGITUDE, next_lat, next_lon),
    d_gap     = haversine_m(prev_lat, prev_lon, next_lat, next_lon),
    round_min = as.numeric(difftime(next_time, prev_time, units = "mins"))
  )]
  dt[, round_kmh := ((d_prev + d_next) / 1000) / pmax(round_min / 60, 1e-6)]

  is_excursion <- !is.na(dt$d_gap) &
    dt$d_gap    <= SAME_PLACE_M      &
    dt$d_prev   >= EXCURSION_MIN_M   &
    dt$d_next   >= EXCURSION_MIN_M   &
    dt$round_kmh > EXCURSION_MAX_KMH

  count("pings dropped: implausible-speed spikes", sum(is_spike))
  count("pings dropped: impossible out-and-back", sum(is_excursion & !is_spike))
  dt <- dt[!(is_spike | is_excursion)]
  count("after removing bad pings", nrow(dt))

  dt[, c("prev_lat", "prev_lon", "prev_time", "next_lat", "next_lon", "next_time",
         "speed_prev_kmh", "speed_next_kmh",
         "d_prev", "d_next", "d_gap", "round_min", "round_kmh") := NULL]

  n_users_before <- uniqueN(dt$registration_id)
  dt[, n_pings := .N, by = registration_id]
  dt <- dt[n_pings >= MIN_PINGS_PER_USER]
  dt[, n_pings := NULL]
  count("users dropped (< MIN_PINGS_PER_USER)", n_users_before - uniqueN(dt$registration_id))
  count("rows entering stop detection", nrow(dt))
  count("users entering stop detection", uniqueN(dt$registration_id))

  if (!nrow(dt)) return(list(stops = NULL, counts = count_snapshot()))

  # -- stop detection, per user
  dt[, t_sec := as.numeric(DATETIME)]
  dt[, raw_stop_id := detect_stops_one(t_sec, LATITUDE, LONGITUDE), by = registration_id]
  dt[, t_sec := NULL]

  # -- aggregate pings to raw stops (location = median of pings)
  stops <- dt[, .(
    arrival_time   = min(DATETIME),
    departure_time = max(DATETIME),
    n_pings        = .N,
    lat            = median(LATITUDE),
    lon            = median(LONGITUDE),
    h3_9           = mode_chr(h3_9)
  ), by = .(registration_id, raw_stop_id)]
  setorder(stops, registration_id, arrival_time)
  count("stops before merging", nrow(stops))

  # -- merge fragmented stops: consecutive, within SAME_PLACE_M and MERGE_GAP_MIN.
  #    Chained, so n_merged is kept to spot over-reach.
  stops[, `:=`(prev_lat = shift(lat), prev_lon = shift(lon),
               prev_departure = shift(departure_time)), by = registration_id]
  stops[, gap_min     := as.numeric(difftime(arrival_time, prev_departure, units = "mins"))]
  stops[, dist_prev_m := haversine_m(lat, lon, prev_lat, prev_lon)]
  stops[, continues   := !is.na(dist_prev_m) & dist_prev_m <= SAME_PLACE_M &
                         !is.na(gap_min)     & gap_min     <= MERGE_GAP_MIN]
  stops[, stop_id := cumsum(!continues), by = registration_id]

  merge_map <- stops[, .(registration_id, raw_stop_id, stop_id)]

  stops <- stops[, .(
    arrival_time   = min(arrival_time),
    departure_time = max(departure_time),
    n_pings        = sum(n_pings),
    lat            = weighted.mean(lat, n_pings),
    lon            = weighted.mean(lon, n_pings),
    h3_9           = h3_9[which.max(n_pings)],
    n_merged       = .N
  ), by = .(registration_id, stop_id)]

  count("stops after merging", nrow(stops))
  count("  merged from 2+ raw stops", stops[n_merged > 1, .N])

  # -- label by duration; nothing is dropped
  stops[, duration_min := as.numeric(difftime(departure_time, arrival_time, units = "mins"))]
  stops[, duration_class := fifelse(duration_min < STAY_THRESHOLD_MIN, "passing", "staying")]
  setorder(stops, registration_id, arrival_time)

  count("  of which passing", stops[duration_class == "passing", .N])
  count("  of which staying", stops[duration_class == "staying", .N])

  # -- point the ping table at the merged stop ids
  dt[merge_map, on = c("registration_id", "raw_stop_id"), stop_id := i.stop_id]
  dt[, raw_stop_id := NULL]

  list(stops = stops, pings = dt, counts = count_snapshot())
}

# ---- driver: run pending buckets (parallel on unix), then combine ----------

dir.create(BUCKET_OUT_DIR, showWarnings = FALSE, recursive = TRUE)

bucket_files <- list.files(BUCKET_DIR, BUCKET_GLOB, full.names = TRUE)
if (!length(bucket_files))
  stop("No bucket files matching ", BUCKET_GLOB, " in ", BUCKET_DIR,
       ".\nRun code/00_query.R (start_download + resume_download) first.")

if (!is.null(ONLY_BUCKETS)) {
  bucket_files <- bucket_files[
    sub(".*bucket_(.)\\.csv$", "\\1", bucket_files) %in% ONLY_BUCKETS]
  if (!length(bucket_files))
    stop("ONLY_BUCKETS = ", paste(ONLY_BUCKETS, collapse = ", "),
         " matched no files in ", BUCKET_DIR)
  message(sprintf(
    "PILOT MODE: %d of 16 buckets (%s). Outputs suffixed '%s'.\n",
    length(bucket_files), paste(ONLY_BUCKETS, collapse = ", "), OUT_SUFFIX))
}

message(sprintf("Found %d bucket files. DRIFT_MODE = %s. Window %s to %s%s.",
                length(bucket_files), DRIFT_MODE, DATE_START, DATE_END,
                if (length(EXCLUDE_DATES))
                  sprintf(", excluding %s", paste(EXCLUDE_DATES, collapse = ", ")) else ""))

BUCKET_WORKERS <- min(BUCKET_WORKERS, length(bucket_files))
run_parallel <- BUCKET_WORKERS > 1L && .Platform$OS.type == "unix"
if (BUCKET_WORKERS > 1L && !run_parallel)
  message("BUCKET_WORKERS > 1 requested but mclapply needs a Unix fork; ",
          "running sequentially. (Fine on Windows/RStudio-on-Windows; on the ",
          "cluster this should not trigger.)")
message(sprintf(
  "Bucket workers: %d%s  |  per-worker data.table threads: %d",
  BUCKET_WORKERS, if (run_parallel) " (parallel, forked)" else " (sequential)",
  WORKER_DT_THREADS))

t_start <- Sys.time()

# Process one bucket and save stops_<b>.rds (+ counters) and pings_<b>.rds.
.run_one_bucket <- function(path, dt_threads) {
  data.table::setDTthreads(dt_threads)   # child sets its own threads after fork

  b   <- sub(".*bucket_(.)\\.csv$", "\\1", path)
  out <- file.path(BUCKET_OUT_DIR, sprintf("stops_%s.rds", b))

  t0  <- Sys.time()
  message(sprintf("bucket %s: processing %s ...", b, basename(path)))
  res <- process_bucket(path)

  if (!is.null(res$pings)) {
    saveRDS(res$pings, file.path(BUCKET_OUT_DIR, sprintf("pings_%s.rds", b)))
    res$pings <- NULL
  }
  saveRDS(res, out)
  rm(res); gc()

  message(sprintf("bucket %s: done in %.1f min", b,
                  as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  invisible(TRUE)
}

# Skip buckets already done (unless OVERWRITE) so a failed run resumes.
pending <- Filter(function(path) {
  b <- sub(".*bucket_(.)\\.csv$", "\\1", path)
  out <- file.path(BUCKET_OUT_DIR, sprintf("stops_%s.rds", b))
  keep <- OVERWRITE || !file.exists(out)
  if (!keep) message(sprintf("bucket %s: already done, skipping", b))
  keep
}, bucket_files)

if (length(pending)) {
  if (run_parallel) {
    results <- parallel::mclapply(pending, .run_one_bucket,
                                  dt_threads = WORKER_DT_THREADS,
                                  mc.cores   = BUCKET_WORKERS,
                                  mc.preschedule = FALSE)
    failed <- vapply(results, function(r) inherits(r, "try-error"), logical(1))
    if (any(failed)) {
      msgs <- vapply(results[failed], function(r) conditionMessage(attr(r, "condition")), "")
      stop(sum(failed), " of ", length(pending), " bucket(s) failed:\n  ",
           paste(msgs, collapse = "\n  "))
    }
  } else {
    for (path in pending) .run_one_bucket(path, WORKER_DT_THREADS)
  }
}

setDTthreads(N_THREADS)

# ---- combine: stops recombined (stop_id is per-user, so no renumbering);
#      pings stay sharded in output/buckets/ because they do not fit in memory.

message("Combining buckets ...")
parts  <- lapply(list.files(BUCKET_OUT_DIR, "^stops_.\\.rds$", full.names = TRUE), readRDS)
stops  <- rbindlist(lapply(parts, `[[`, "stops"), use.names = TRUE)
counts <- combine_counts(lapply(parts, `[[`, "counts"))
rm(parts); gc()

setorder(stops, registration_id, arrival_time)

message("\nTotals across all buckets:")
for (nm in names(counts)) report(nm, counts[[nm]])
report("users with at least one stop", uniqueN(stops$registration_id))

saveRDS(stops, STOPS_OUT_RDS)
fwrite(stops, STOPS_OUT_CSV)
message("\nSaved stops to ", STOPS_OUT_RDS, " and ", STOPS_OUT_CSV)
message(sprintf("Labelled pings left sharded in %s/pings_<b>.rds — 02_routines.R must loop.",
                BUCKET_OUT_DIR))
message(sprintf("Total elapsed: %.1f min",
                as.numeric(difftime(Sys.time(), t_start, units = "mins"))))

if (WRITE_GPKG) {
  if (!requireNamespace("sf", quietly = TRUE))
    stop("WRITE_GPKG is TRUE but the 'sf' package is not installed.\n",
         "  sf needs GDAL/GEOS/PROJ, which on a cluster usually means\n",
         "  'module load gdal geos proj' before install.packages(\"sf\").\n",
         "  Or leave WRITE_GPKG = FALSE — stops.csv carries lat/lon and loads\n",
         "  straight into QGIS as a delimited-text layer.")
  stops_sf <- sf::st_as_sf(stops, coords = c("lon", "lat"), crs = 4326, remove = FALSE)
  sf::st_write(stops_sf, STOPS_OUT_GPKG, layer = "stops", delete_dsn = TRUE, quiet = TRUE)
  message("Saved stops to ", STOPS_OUT_GPKG)
}