# =============================================================================
# 04_sequences.R — anchors, then each person's day as a sequence of labelled places
#
#   Rscript code/04_sequences.R              # full run: home_work.parquet etc.
#   Rscript code/04_sequences.R _fH0.9       # the same on a sweep variant
#
# Combines the pilot's 05_anchors.R and 06_semantic_seq.R, unchanged in logic.
#
# PART A — ANCHORS. Places a user returns to repeatedly in the DAYTIME that are
# neither home nor work. Recurrence is a FRACTION of the user's observed
# daytime days (like HoWDe's f_days_W), with a completeness floor below which
# no anchor is claimed, an absolute floor of two days, and a requirement that
# the place was actually stayed at at least once (not just driven past).
#
# PART B — SEQUENCES. Every visit to a significant place (HOME / WORK / ANCHOR)
# becomes an element; other visits are dropped but counted (n_other_between,
# n_other_today). Each element gets a semantic label:
#   HOME, WORK   fixed by behaviour (HoWDe), never overridden by land use
#   ANCHOR       read from the land-use layer for that place at the time bin
#                the person was there; where the LLM gave two readings the
#                primary stands unless the school rule fires
# Output is one row per element and one row per (user, date), the latter with
# each day twice: over all significant visits, and over "staying" visits only.
#
# COHORT: users with a HoWDe home. This selects on observation (a home needs
# enough nights to establish) and, since 2026-09-16, on sharing precise
# location — see 01_stops_notes.txt. Belongs in the write-up as such.
#
# Inputs   output/stops.rds, stop_places.parquet, places.parquet,
#          home_work<sfx>.parquet, data/land_use_res9_*.csv (precise LBCS layer)
# Outputs  output/anchors<sfx>.rds|csv
#          output/stop_sequences_long<sfx>.rds|csv
#          output/daily_sequences<sfx>.rds|csv
# =============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
})

# --------------------------- config -----------------------------------------

args   <- commandArgs(trailingOnly = TRUE)
SUFFIX <- if (length(args)) args[1] else ""     # "" full run; "_fH0.9" etc.

OUTPUT_DIR <- "output"

# stops / stop_places / places come from the single full run; only home_work
# varies across the f_hours_H sweep. Outputs carry the suffix.
STOPS_IN       <- file.path(OUTPUT_DIR, "stops.rds")
STOP_PLACES_IN <- file.path(OUTPUT_DIR, "stop_places.parquet")
PLACES_IN      <- file.path(OUTPUT_DIR, "places.parquet")
HOME_WORK_IN   <- file.path(OUTPUT_DIR, sprintf("home_work%s.parquet", SUFFIX))

LAND_USE_PRECISE_CSV <- "data/land_use_res9_gpt-4o_20260801_024540.csv" # precise + secondary readings

ANCHOR_OUT_RDS <- file.path(OUTPUT_DIR, sprintf("anchors%s.rds", SUFFIX))
ANCHOR_OUT_CSV <- file.path(OUTPUT_DIR, sprintf("anchors%s.csv", SUFFIX))
SEQ_LONG_RDS   <- file.path(OUTPUT_DIR, sprintf("stop_sequences_long%s.rds", SUFFIX))
SEQ_LONG_CSV   <- file.path(OUTPUT_DIR, sprintf("stop_sequences_long%s.csv", SUFFIX))
DAILY_OUT_RDS  <- file.path(OUTPUT_DIR, sprintf("daily_sequences%s.rds", SUFFIX))
DAILY_OUT_CSV  <- file.path(OUTPUT_DIR, sprintf("daily_sequences%s.csv", SUFFIX))

TZ <- "Europe/London"   # must match 01_stops.R

# Optional cohort tightening, both computed from the user's stops (any place):
#   MIN_OBS_DAYS  observed on at least this many distinct days
#   MIN_WEEKS     observed in at least this many distinct ISO weeks
# 0 = off. A day count alone does not separate residents from visitors — of
# homed users with >= 5 days, 21% were seen within a single fortnight. Presence
# across weeks does: MIN_WEEKS = 3 keeps ~49% of homes, and with MIN_OBS_DAYS =
# 5 as well ~42%. See diag_howde_sweep.py and 01_stops_notes.txt.
MIN_OBS_DAYS <- 5
MIN_WEEKS    <- 3

# --- anchors -----------------------------------------------------------------
DAY_HOURS          <- 8:18   # "daytime" window for anchor recurrence
F_DAYS_ANCHOR      <- 0.20   # present on >= this share of observed daytime days
F_DAYS_ANCHOR_HIGH <- 0.40   # confidence tier boundary
C_DAYTIME_DAYS     <- 4      # completeness floor: fewer observed daytime days -> no anchors
MIN_ANCHOR_DAYS    <- 2      # absolute floor: one visit is never a routine
MIN_STAYING_DATES  <- 1      # must have been STAYED at on >= this many days (0 disables)
MAX_ANCHORS        <- 3      # per person, strongest first

# --- sequences ---------------------------------------------------------------
MERGE_GAP_MIN      <- 60     # merge same-place consecutive stops separated by <= this
STAY_THRESHOLD_MIN <- 5      # must match 01_stops.R

# The school rule (R1): recurring, punctual daytime presence at an ANCHOR whose
# land use includes a school. Pupils/staff would be WORK, so what remains is
# the brief recurring visit — delivering or collecting someone.
R1_TIME_BINS      <- c("Morning", "Midday", "Afternoon")
R1_MIN_DAYS       <- 2
R1_MAX_ARR_SPREAD <- 90      # minutes between earliest and latest arrival
SCHOOL_CODE       <- "4100"

report <- function(label, n) message(sprintf("  %-48s %s", label, format(n, big.mark = ",")))

# place_id is int64 in parquet; home_place/work_place are strings (pandas
# object column). Coerce both so joins cannot silently miss.
as_place_id <- function(x) as.integer(as.character(x))

# =============================================================================
# 1. Load
# =============================================================================

for (f in c(STOPS_IN, STOP_PLACES_IN, PLACES_IN, HOME_WORK_IN,
            LAND_USE_PRECISE_CSV)) {
  if (!file.exists(f)) stop("Missing input: ", f)
}

message("Loading stops from ", STOPS_IN, " ...")
stops <- as.data.table(readRDS(STOPS_IN))
stops[, h3_9 := NULL]    # the PLACE's cell is used, not the stop's — see places below
report("stops loaded", nrow(stops))
report("users with a stop", uniqueN(stops$registration_id))

stop_places <- as.data.table(read_parquet(STOP_PLACES_IN))
stop_places[, place_id := as_place_id(place_id)]
stops <- merge(stops, stop_places, by = c("registration_id", "stop_id"), all.x = FALSE)
rm(stop_places)
report("stops carrying a place_id", nrow(stops))
if (nrow(stops) == 0L) stop("No stops joined to a place — check 01 and 02 ran on the same data.")

# The place centroid's h3_9 is the land-use join key: a building straddling a
# cell boundary cannot flip its reading between visits.
places <- as.data.table(read_parquet(PLACES_IN))
places[, place_id := as_place_id(place_id)]
places <- places[, .(place_id, place_lat = lat, place_lon = lon, h3_9)]

home_work <- as.data.table(read_parquet(HOME_WORK_IN))
setnames(home_work, "useruuid", "registration_id")
home_work[, `:=`(home_place = as_place_id(home_place), work_place = as_place_id(work_place))]
report("users in HoWDe output", nrow(home_work))
report("  with a home_place", home_work[!is.na(home_place), .N])
report("  with a work_place", home_work[!is.na(work_place), .N])

# =============================================================================
# 2. Cohort
# =============================================================================

cohort <- home_work[!is.na(home_place)]
report("cohort: users with a HoWDe home", nrow(cohort))
if (MIN_OBS_DAYS > 0 || MIN_WEEKS > 0) {
  obs <- stops[, {
    d <- as.Date(format(arrival_time, "%Y-%m-%d", tz = TZ))
    .(n_obs_days = uniqueN(d), n_weeks = uniqueN(format(d, "%G-%V")))
  }, by = registration_id]
  keep <- obs[n_obs_days >= MIN_OBS_DAYS & n_weeks >= MIN_WEEKS, registration_id]
  n0 <- nrow(cohort)
  cohort <- cohort[registration_id %in% keep]
  report(sprintf("cohort after MIN_OBS_DAYS = %d, MIN_WEEKS = %d (was %s)",
                 MIN_OBS_DAYS, MIN_WEEKS, format(n0, big.mark = ",")), nrow(cohort))
}
if (nrow(cohort) == 0L) stop("No user has a home_place — check 03_howde.py.")

n_before <- uniqueN(stops$registration_id)
stops <- stops[registration_id %in% cohort$registration_id]
report("users dropped (no HoWDe home)", n_before - uniqueN(stops$registration_id))
report("users retained (analysis cohort)", uniqueN(stops$registration_id))
report("stops retained", nrow(stops))
stops[cohort, on = "registration_id", `:=`(home_place = i.home_place, work_place = i.work_place)]
setorder(stops, registration_id, arrival_time)

# =============================================================================
# PART A — ANCHORS
# =============================================================================
# 3. Daytime presence per (user, place). A stop is expanded to every local
#    date it touches so a stay across midnight counts for both dates.

message("\nPART A: anchors")
message("Expanding stops to the dates they cover ...")

stops[, `:=`(d0 = as.Date(format(arrival_time,   "%Y-%m-%d", tz = TZ)),
             d1 = as.Date(format(departure_time, "%Y-%m-%d", tz = TZ)))]
stops[, span_days := as.integer(d1 - d0) + 1L]

cover <- stops[rep(seq_len(.N), span_days),
               .(registration_id, place_id, arrival_time, departure_time, d0, duration_class)]
cover[, local_date := d0 + (sequence(stops$span_days) - 1L)]
cover[, d0 := NULL]
stops[, c("d0", "d1", "span_days") := NULL]

day_from <- min(DAY_HOURS) * 3600
day_to   <- (max(DAY_HOURS) + 1L) * 3600
cover[, day_start := as.POSIXct(paste(local_date, "00:00:00"), tz = TZ)]
cover[, covers_day := arrival_time < day_start + day_to & departure_time > day_start + day_from]
report("stop-days after expansion", nrow(cover))
report("  covering the daytime window", cover[covers_day == TRUE, .N])

# distinct daytime dates per (user, place): days are unioned, not summed
by_place <- cover[covers_day == TRUE, .(n_day_dates = uniqueN(local_date)),
                  by = .(registration_id, place_id)]
# denominator: daytime days the user was observed anywhere
observed <- cover[covers_day == TRUE, .(n_daytime_days_observed = uniqueN(local_date)),
                  by = registration_id]
by_place[observed, on = "registration_id", n_daytime_days_observed := i.n_daytime_days_observed]
by_place[, frac_daytime_days := n_day_dates / n_daytime_days_observed]
report("median daytime days observed per user", as.integer(median(observed$n_daytime_days_observed)))
report("users below C_DAYTIME_DAYS (no anchors possible)",
       observed[n_daytime_days_observed < C_DAYTIME_DAYS, .N])

staying_dates <- cover[covers_day == TRUE & duration_class == "staying",
                       .(n_staying_dates = uniqueN(local_date)), by = .(registration_id, place_id)]
by_place[staying_dates, on = .(registration_id, place_id), n_staying_dates := i.n_staying_dates]
by_place[is.na(n_staying_dates), n_staying_dates := 0L]
rm(cover, staying_dates)

visits <- stops[, .(n_visits = .N, n_pings = sum(n_pings)), by = .(registration_id, place_id)]
by_place[visits, on = .(registration_id, place_id), `:=`(n_visits = i.n_visits, n_pings = i.n_pings)]
rm(visits)
report("(user, place) pairs with daytime presence", nrow(by_place))

# 4. Anchors: whatever recurs in the daytime and is not home or work.
message("Detecting recurring daytime anchors ...")
by_place[cohort, on = "registration_id", `:=`(home_place = i.home_place, work_place = i.work_place)]
not_hw <- by_place[place_id != home_place & (is.na(work_place) | place_id != work_place)]
report("candidate places (not home or work)", nrow(not_hw))
report("  failing the absolute floor (< MIN_ANCHOR_DAYS)", not_hw[n_day_dates < MIN_ANCHOR_DAYS, .N])
report("  failing the completeness floor (< C_DAYTIME_DAYS)",
       not_hw[n_day_dates >= MIN_ANCHOR_DAYS & n_daytime_days_observed < C_DAYTIME_DAYS, .N])
report("  failing the fraction (< F_DAYS_ANCHOR)",
       not_hw[n_day_dates >= MIN_ANCHOR_DAYS & n_daytime_days_observed >= C_DAYTIME_DAYS &
              frac_daytime_days < F_DAYS_ANCHOR, .N])
report("  failing the stay bar (< MIN_STAYING_DATES)",
       not_hw[n_day_dates >= MIN_ANCHOR_DAYS & n_daytime_days_observed >= C_DAYTIME_DAYS &
              frac_daytime_days >= F_DAYS_ANCHOR & n_staying_dates < MIN_STAYING_DATES, .N])

anchors <- not_hw[n_day_dates >= MIN_ANCHOR_DAYS & n_daytime_days_observed >= C_DAYTIME_DAYS &
                  frac_daytime_days >= F_DAYS_ANCHOR & n_staying_dates >= MIN_STAYING_DATES]
report("candidate anchors passing all bars", nrow(anchors))

# rank on STAYING evidence first, so the MAX_ANCHORS cap is spent on places
# the person actually spent time at rather than on drive-pasts
setorder(anchors, registration_id, -n_staying_dates, -n_day_dates, -n_pings, -n_visits)
anchors[, anchor_rank := seq_len(.N), by = registration_id]
anchors <- anchors[anchor_rank <= MAX_ANCHORS]
anchors[, anchor_confidence := fifelse(frac_daytime_days >= F_DAYS_ANCHOR_HIGH, "high", "medium")]
anchors[places, on = "place_id", `:=`(anchor_lat = i.place_lat, anchor_lon = i.place_lon, h3_9 = i.h3_9)]

report("anchors retained (<= MAX_ANCHORS)", nrow(anchors))
report("users with >= 1 anchor", uniqueN(anchors$registration_id))
report("  of cohort", nrow(cohort))
report("users with >= 2 anchors", anchors[, .N, by = registration_id][N >= 2, .N])
report("  confidence = high", anchors[anchor_confidence == "high", .N])
report("  never actually stayed at (n_staying_dates = 0)", anchors[n_staying_dates == 0L, .N])
message(sprintf("  %.1f%% of the cohort has no anchor at all",
                100 * (1 - uniqueN(anchors$registration_id) / nrow(cohort))))

anchors_out <- anchors[, .(registration_id, anchor_rank, place_id, anchor_lat, anchor_lon, h3_9,
                           n_day_dates, n_staying_dates, n_daytime_days_observed,
                           frac_daytime_days, n_visits, n_pings, anchor_confidence)]
setorder(anchors_out, registration_id, anchor_rank)
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)
saveRDS(anchors_out, ANCHOR_OUT_RDS)
fwrite(anchors_out, ANCHOR_OUT_CSV)
message("Saved anchors to ", ANCHOR_OUT_RDS, " and ", ANCHOR_OUT_CSV)
rm(by_place, not_hw)

# =============================================================================
# PART B — SEQUENCES
# =============================================================================
# 5. Merge stop-splitting artefacts: consecutive stops at the same PLACE
#    separated by a short gap are one visit split by sampling.

message("\nPART B: sequences")
message("Merging same-place stops split by short data gaps ...")

stops[, prev_place     := shift(place_id), by = registration_id]
stops[, prev_departure := shift(departure_time), by = registration_id]
stops[, gap_min := as.numeric(difftime(arrival_time, prev_departure, units = "mins"))]
stops[, same_place_short_gap := !is.na(prev_place) & place_id == prev_place &
        !is.na(gap_min) & gap_min <= MERGE_GAP_MIN]
stops[, merge_group := cumsum(!same_place_short_gap), by = registration_id]

n_before_merge <- nrow(stops)
seq_dt <- stops[, .(
  place_id       = place_id[1],
  arrival_time   = min(arrival_time),
  departure_time = max(departure_time),
  n_pings        = sum(n_pings),
  n_stops_merged = .N
), by = .(registration_id, merge_group)]
seq_dt[, duration_min := as.numeric(difftime(departure_time, arrival_time, units = "mins"))]
seq_dt[, duration_class := fifelse(duration_min < STAY_THRESHOLD_MIN, "passing", "staying")]
seq_dt[, merge_group := NULL]
rm(stops)
report("stops before merge", n_before_merge)
report("visits after merge", nrow(seq_dt))

seq_dt[places, on = "place_id", `:=`(lat = i.place_lat, lon = i.place_lon, h3_9 = i.h3_9)]
# a visit belongs to the date it ARRIVED on
seq_dt[, local_date := as.Date(format(arrival_time, "%Y-%m-%d", tz = TZ))]
seq_dt[, weekday    := format(arrival_time, "%a", tz = TZ)]

# 6. Behavioural labels, then drop to significant places only
message("Applying behavioural place labels ...")
seq_dt[cohort, on = "registration_id", `:=`(home_place = i.home_place, work_place = i.work_place)]
seq_dt[anchors, on = .(registration_id, place_id), anchor_rank := i.anchor_rank]
seq_dt[, place_type := fcase(
  place_id == home_place,                       "HOME",
  !is.na(work_place) & place_id == work_place,  "WORK",
  !is.na(anchor_rank),                          "ANCHOR",
  default                                     = "OTHER"
)]
report("HOME visits",   seq_dt[place_type == "HOME", .N])
report("WORK visits",   seq_dt[place_type == "WORK", .N])
report("ANCHOR visits", seq_dt[place_type == "ANCHOR", .N])
report("OTHER visits (dropped from sequences)", seq_dt[place_type == "OTHER", .N])

# n_other_today: all non-significant visits that user made that date.
# n_other_between: the non-significant visits immediately before this element
# within the same day, so HOME -> WORK is not read as direct when a shop sat
# between. Grouped by (user, date), so trailing visits in a day are absent from
# n_other_between by design — the daily table reports n_other_today instead.
setorder(seq_dt, registration_id, arrival_time)
seq_dt[, is_sig := place_type != "OTHER"]
other_today <- seq_dt[is_sig == FALSE, .(n_other_today = .N), by = .(registration_id, local_date)]
n_other_total <- seq_dt[is_sig == FALSE, .N]
sig_days     <- unique(seq_dt[is_sig == TRUE,  .(registration_id, local_date)])
other_days   <- unique(seq_dt[is_sig == FALSE, .(registration_id, local_date)])
dropped_days <- fsetdiff(other_days, sig_days)

seq_dt[, sig_run := cumsum(is_sig), by = .(registration_id, local_date)]
other_between <- seq_dt[is_sig == FALSE, .(n_other_between = .N),
                        by = .(registration_id, local_date, sig_run)]
seq_dt <- seq_dt[is_sig == TRUE]
seq_dt[, sig_run_prev := sig_run - 1L]
seq_dt[other_between, on = c("registration_id", "local_date", sig_run_prev = "sig_run"),
       n_other_between := i.n_other_between]
seq_dt[is.na(n_other_between), n_other_between := 0L]
seq_dt[, c("is_sig", "sig_run", "sig_run_prev") := NULL]
report("significant visits retained", nrow(seq_dt))
report("users with >= 1 significant visit", uniqueN(seq_dt$registration_id))
if (nrow(seq_dt) == 0L) stop("No significant visits.")

# 7. Sequence and day structure
setorder(seq_dt, registration_id, arrival_time)
seq_dt[, seq_index  := seq_len(.N), by = registration_id]
seq_dt[, day_index  := frank(local_date, ties.method = "dense"), by = registration_id]
seq_dt[, seq_in_day := seq_len(.N), by = .(registration_id, local_date)]
seq_dt[, arr_min_of_day := as.integer(format(arrival_time, "%H", tz = TZ)) * 60L +
                            as.integer(format(arrival_time, "%M", tz = TZ))]
seq_dt[, prev_place_type := shift(place_type), by = .(registration_id, local_date)]
seq_dt[, next_place_type := shift(place_type, type = "lead"), by = .(registration_id, local_date)]

# 8. Land-use readings
message("Attaching land-use readings ...")

# The precise (2-digit LBCS) layer is the only one used: it is what
# resolved_activity_final is built from. The coarse gpkg covered more cells but
# only with a 1-digit class, and a visit outside the precise layer is
# "no_landuse" either way — so it is not read (and sf/GDAL is not needed).
land_use <- fread(
  LAND_USE_PRECISE_CSV,
  select = c("h3_index", "time_bin_name", "primary_land_use", "precise_land_use",
             "secondary_land_use", "secondary_precise_land_use",
             "primary_confidence", "secondary_confidence"),
  colClasses = list(character = c("h3_index", "primary_land_use", "precise_land_use",
                                   "secondary_land_use", "secondary_precise_land_use"))
)
land_use <- unique(land_use, by = c("h3_index", "time_bin_name"))
for (col in c("primary_land_use", "precise_land_use", "secondary_land_use", "secondary_precise_land_use")) {
  set(land_use, i = which(land_use[[col]] == ""), j = col, value = NA_character_)
}
report("land-use (cell, time bin) rows", nrow(land_use))
report("  cells with a precise reading", uniqueN(land_use$h3_index))

# LBCS labels
lbcs1 <- data.table(
  code = c("1000", "2000", "3000", "4000", "5000", "6000", "7000", "8000", "9000"),
  name = c("Residential activities", "Shopping, business, trade activities",
           "Industrial, manufacturing, and waste-related activities",
           "Social, institutional, or infrastructure-related activities",
           "Travel or movement activities", "Mass assembly of people",
           "Leisure activities", "Natural resources-related activities",
           "No human activity or unclassifiable")
)
lbcs2 <- data.table(
  code = c("1100", "1200", "1300", "2100", "2200", "2300", "4100", "4200", "4300",
           "4400", "4500", "4600", "4700", "5100", "5200", "5400", "5600", "6100",
           "6200", "6300", "6600", "6700", "6800", "7100", "7200", "8100", "8200",
           "9100", "9200", "9900"),
  name = c(
    "Household activities", "Transient living", "Institutional living",
    "Shopping", "Restaurant-type activity", "Office activities",
    "School or library activities", "Emergency response or public-safety-related activities",
    "Activities associated with utilities (water, sewer, power, etc.)",
    "Mass storage, inactive", "Health care, medical, or treatment activities",
    "Interment, cremation, or grave digging activities", "Military base activities",
    "Pedestrian movement", "Vehicular movement", "Trains or other rail movement",
    "Aircraft takeoff, landing, taxiing, and parking",
    "Passenger assembly", "Spectator sports assembly",
    "Movies, concerts, or entertainment shows",
    "Social, cultural, or religious assembly",
    "Gatherings at galleries, museums, aquariums, zoological parks, etc.",
    "Historical or cultural celebrations, parades, reenactments, etc.",
    "Active leisure sports and related activities", "Passive leisure activity",
    "Farming, tilling, plowing, harvesting, or related activities",
    "Livestock related activities",
    "Not applicable to this dimension", "Unclassifiable activity", "To be determined"
  )
)
land_use[lbcs1, on = c(primary_land_use = "code"),           activity_name := i.name]
land_use[lbcs2, on = c(precise_land_use = "code"),           precise_activity_name := i.name]
land_use[lbcs1, on = c(secondary_land_use = "code"),         secondary_activity_name := i.name]
land_use[lbcs2, on = c(secondary_precise_land_use = "code"), secondary_precise_activity_name := i.name]
unmapped <- unique(c(
  land_use[!is.na(primary_land_use) & is.na(activity_name), primary_land_use],
  land_use[!is.na(precise_land_use) & is.na(precise_activity_name), precise_land_use],
  land_use[!is.na(secondary_land_use) & is.na(secondary_activity_name), secondary_land_use],
  land_use[!is.na(secondary_precise_land_use) & is.na(secondary_precise_activity_name),
           secondary_precise_land_use]))
if (length(unmapped) > 0) warning("Unlabelled LBCS code(s): ", paste(sort(unmapped), collapse = ", "))

# the land-use layer's six time-of-day bins; a visit takes the bin of its arrival
hour_to_time_bin <- function(hour) {
  fcase(hour >= 0  & hour <= 3,  "Night",
        hour >= 4  & hour <= 7,  "Early Morning",
        hour >= 8  & hour <= 11, "Morning",
        hour >= 12 & hour <= 15, "Midday",
        hour >= 16 & hour <= 19, "Afternoon",
        hour >= 20 & hour <= 23, "Evening")
}
seq_dt[, time_bin_name := hour_to_time_bin(arr_min_of_day %/% 60L)]
seq_dt[land_use, on = c("h3_9" = "h3_index", "time_bin_name"),
       `:=`(primary_land_use = i.primary_land_use, activity_name = i.activity_name,
            precise_land_use = i.precise_land_use, precise_activity_name = i.precise_activity_name,
            secondary_land_use = i.secondary_land_use, secondary_activity_name = i.secondary_activity_name,
            secondary_precise_land_use = i.secondary_precise_land_use,
            secondary_precise_activity_name = i.secondary_precise_activity_name,
            primary_confidence = i.primary_confidence, secondary_confidence = i.secondary_confidence)]
report("visits outside land-use coverage", seq_dt[is.na(precise_land_use), .N])

# 9. Semantic status
seq_dt[, semantic_status := fcase(
  place_type == "HOME",               "home",
  place_type == "WORK",               "work",
  is.na(precise_land_use),            "no_landuse",
  !is.na(secondary_precise_land_use), "ambiguous",
  default                             = "unambiguous"
)]
for (s in c("home", "work", "unambiguous", "ambiguous", "no_landuse"))
  report(paste("semantic_status =", s), seq_dt[semantic_status == s, .N])

# 10. The school rule — recurrence per (person, place, time_bin)
message("Applying the school rule to ambiguous anchor visits ...")
ctx <- seq_dt[, .(ctx_visits = .N, ctx_days = uniqueN(local_date),
                  ctx_arr_spread = max(arr_min_of_day) - min(arr_min_of_day)),
              by = .(registration_id, place_id, time_bin_name)]
seq_dt[ctx, on = .(registration_id, place_id, time_bin_name),
       `:=`(ctx_visits = i.ctx_visits, ctx_days = i.ctx_days, ctx_arr_spread = i.ctx_arr_spread)]
seq_dt[, `:=`(resolved_code = NA_character_, rule_applied = NA_character_, resolution_note = NA_character_)]

open <- seq_dt$semantic_status == "ambiguous" & seq_dt$place_type == "ANCHOR" &
        !is.na(seq_dt$precise_land_use) & !is.na(seq_dt$secondary_precise_land_use)
report("ambiguous visits at anchors (eligible)", sum(open))
has_school <- (!is.na(seq_dt$precise_land_use) & seq_dt$precise_land_use == SCHOOL_CODE) |
              (!is.na(seq_dt$secondary_precise_land_use) & seq_dt$secondary_precise_land_use == SCHOOL_CODE)
i_r1 <- open & has_school & seq_dt$time_bin_name %in% R1_TIME_BINS &
        seq_dt$ctx_days >= R1_MIN_DAYS & seq_dt$ctx_arr_spread <= R1_MAX_ARR_SPREAD
seq_dt[i_r1, `:=`(resolved_code = SCHOOL_CODE, rule_applied = "R1_school_recurring_daytime",
                  resolution_note = "drop-off / pick-up")]
report("  resolved to school by R1", sum(i_r1))
seq_dt[semantic_status == "ambiguous" & is.na(rule_applied), rule_applied := "no_rule_primary_stands"]

# 11. Final semantic label
seq_dt[lbcs2, on = c(resolved_code = "code"), resolved_code_name := i.name]
seq_dt[, resolved_activity_final := fcase(
  semantic_status == "home",        "Home",
  semantic_status == "work",        "Work",
  semantic_status == "unambiguous", precise_activity_name,
  !is.na(resolved_code_name),       resolved_code_name,
  semantic_status == "ambiguous",   precise_activity_name,
  default                           = NA_character_
)]
seq_dt[, resolution_basis := fcase(
  semantic_status == "home",        "home",
  semantic_status == "work",        "work",
  semantic_status == "unambiguous", "llm_unambiguous",
  semantic_status == "no_landuse",  "no_landuse",
  !is.na(resolved_code_name),       "rule_override",
  default                           = "llm_primary_default"
)]
message("\n--- resolution_basis ---")
print(seq_dt[, .N, by = resolution_basis][order(-N)])
message("\n--- top anchor semantics ---")
print(head(seq_dt[place_type == "ANCHOR", .N, by = resolved_activity_final][order(-N)], 12))

# 12. Outputs
seq_long <- seq_dt[, .(
  registration_id, seq_index, day_index, seq_in_day, local_date, weekday,
  arrival_time, departure_time, arr_min_of_day, duration_min, duration_class,
  place_id, place_type, anchor_rank, prev_place_type, next_place_type, n_other_between,
  semantic_status, resolution_basis, rule_applied, resolution_note, resolved_activity_final,
  ctx_visits, ctx_days, ctx_arr_spread, time_bin_name,
  primary_land_use, activity_name, precise_land_use, precise_activity_name,
  secondary_land_use, secondary_activity_name,
  secondary_precise_land_use, secondary_precise_activity_name,
  primary_confidence, secondary_confidence, n_pings, n_stops_merged, lat, lon, h3_9
)]
setorder(seq_long, registration_id, arrival_time)
saveRDS(seq_long, SEQ_LONG_RDS)
fwrite(seq_long, SEQ_LONG_CSV)
message("\nSaved sequence elements to ", SEQ_LONG_RDS, " and ", SEQ_LONG_CSV)

# One row per (user, date), each day twice: over all significant visits and
# over "staying" visits only. A passing element is typically a single ping with
# zero duration — someone driving past — and giving it equal weight
# manufactures apparent oscillation between places. staying_* is NA on days
# with no staying visit at all.
seq_str <- function(x, keep) if (any(keep)) paste(x[keep], collapse = " -> ") else NA_character_

daily <- seq_long[, {
  stay <- duration_class == "staying"
  lab  <- fifelse(is.na(resolved_activity_final), "Unknown", resolved_activity_final)
  .(weekday            = weekday[1],
    n_places           = .N,
    n_home             = sum(place_type == "HOME"),
    n_work             = sum(place_type == "WORK"),
    n_anchor           = sum(place_type == "ANCHOR"),
    n_distinct_places  = uniqueN(place_id),
    n_staying          = sum(stay),
    n_passing          = sum(!stay),
    first_arrival      = min(arrival_time),
    last_departure     = max(departure_time),
    place_sequence     = paste(place_type, collapse = " -> "),
    semantic_sequence  = paste(lab, collapse = " -> "),
    time_bin_sequence  = paste(time_bin_name, collapse = " -> "),
    staying_place_sequence    = seq_str(place_type, stay),
    staying_semantic_sequence = seq_str(lab, stay),
    staying_time_bin_sequence = seq_str(time_bin_name, stay),
    n_ambiguous        = sum(semantic_status == "ambiguous"),
    n_no_landuse       = sum(semantic_status == "no_landuse"),
    n_school_runs      = sum(rule_applied == "R1_school_recurring_daytime", na.rm = TRUE))
}, by = .(registration_id, local_date)]

daily[other_today, on = .(registration_id, local_date), n_other_today := i.n_other_today]
daily[is.na(n_other_today), n_other_today := 0L]
setorder(daily, registration_id, local_date)

report("user-days", nrow(daily))
report("  non-significant visits on days WITH a sequence", sum(daily$n_other_today))
report("  non-significant visits on days WITHOUT one", n_other_total - sum(daily$n_other_today))
report("  user-days lost entirely (no significant visit)", nrow(dropped_days))
report("  user-days with no STAYING visit (staying_* is NA)", daily[n_staying == 0L, .N])
report("users", uniqueN(daily$registration_id))
report("  user-days containing a school run", daily[n_school_runs > 0, .N])

message("\n--- most common daily place sequences (all visits) ---")
print(head(daily[, .N, by = place_sequence][order(-N)], 8))
message("\n--- most common daily place sequences (staying visits only) ---")
print(head(daily[!is.na(staying_place_sequence), .N, by = staying_place_sequence][order(-N)], 8))

saveRDS(daily, DAILY_OUT_RDS)
fwrite(daily, DAILY_OUT_CSV)
message("\nSaved daily sequences to ", DAILY_OUT_RDS, " and ", DAILY_OUT_CSV)
