# 03_HW_exploration.R — map HoWDe homes and workplaces across Edinburgh
#
#   Rscript code/03_HW_exploration.R                 # output/home_work.parquet
#   Rscript code/03_HW_exploration.R _fH0.9          # output/home_work_fH0.9.parquet
#
# Joins each user's home_place / work_place to places.parquet (which carries
# the H3 res-9 cell of every place), counts users per cell, and draws:
#   output/figs/homes_h3r9<sfx>.png       users whose home is in the cell
#   output/figs/works_h3r9<sfx>.png       users whose work is in the cell
#   output/figs/commute_km<sfx>.png       home-work distance, users with both
#   output/hw_hexes<sfx>.gpkg             both layers, for QGIS
#
# Hexagon geometry: H3 res-9 cells via h3jsr if it is installed; otherwise an
# sf hexagonal grid of the same area (~0.105 km2) with a note in the log.
# h3jsr needs the V8 package, which is not always installable on a cluster.
#
# Needs: arrow, data.table, sf, ggplot2 (+ h3jsr optionally).

suppressPackageStartupMessages({
  library(data.table)
  library(sf)
  library(ggplot2)
})
if (!requireNamespace("arrow", quietly = TRUE))
  stop("The 'arrow' package is needed to read parquet: install.packages('arrow')")

args <- commandArgs(trailingOnly = TRUE)
SFX  <- if (length(args)) args[1] else ""

# Cohort filters, computed from the user's stops (same definitions as
# 04_sequences.R). MIN_WEEKS is the one that separates residents from
# visitors: a week-long stay clears any day count but not "seen in >= 3 of the
# 7 weeks". 0 = off.
MIN_DAYS  <- 5
MIN_WEEKS <- 3
OUT_DIR   <- "output"
FIG_DIR  <- file.path(OUT_DIR, "figs")
dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- load -------------------------------------------------------------------
hw <- as.data.table(arrow::read_parquet(file.path(OUT_DIR, sprintf("home_work%s.parquet", SFX))))
pl <- as.data.table(arrow::read_parquet(file.path(OUT_DIR, "places.parquet")))
hw[, home_place := suppressWarnings(as.integer(as.character(home_place)))]
hw[, work_place := suppressWarnings(as.integer(as.character(work_place)))]
message(sprintf("users: %s   home: %s   work: %s",
                format(nrow(hw), big.mark = ","),
                format(sum(!is.na(hw$home_place)), big.mark = ","),
                format(sum(!is.na(hw$work_place)), big.mark = ",")))

if (MIN_DAYS > 0 || MIN_WEEKS > 0) {
  st  <- readRDS(file.path(OUT_DIR, "stops.rds"))
  obs <- as.data.table(st)[, {
    d <- as.Date(format(arrival_time, "%Y-%m-%d", tz = "Europe/London"))
    .(n_obs_days = uniqueN(d), n_weeks = uniqueN(format(d, "%G-%V")))
  }, by = registration_id]
  rm(st)
  hw[obs, on = .(useruuid = registration_id), `:=`(n_obs_days = i.n_obs_days, n_weeks = i.n_weeks)]
  n0 <- sum(!is.na(hw$home_place))
  hw[is.na(n_obs_days) | n_obs_days < MIN_DAYS | n_weeks < MIN_WEEKS, home_place := NA_integer_]
  message(sprintf("MIN_DAYS = %d, MIN_WEEKS = %d: homes kept %s of %s", MIN_DAYS, MIN_WEEKS,
                  format(sum(!is.na(hw$home_place)), big.mark = ","), format(n0, big.mark = ",")))
}

# ---- users per H3 cell ------------------------------------------------------
hw[pl, on = .(home_place = place_id), `:=`(home_h3 = i.h3_9, home_lat = i.lat, home_lon = i.lon)]
hw[pl, on = .(work_place = place_id), `:=`(work_h3 = i.h3_9, work_lat = i.lat, work_lon = i.lon)]

homes <- hw[!is.na(home_h3), .(n_home = .N), by = .(h3_9 = home_h3)]
works <- hw[!is.na(work_h3), .(n_work = .N), by = .(h3_9 = work_h3)]
cells <- merge(homes, works, by = "h3_9", all = TRUE)
cells[is.na(n_home), n_home := 0L][is.na(n_work), n_work := 0L]
message(sprintf("cells: %d with homes, %d with works", nrow(homes), nrow(works)))

# ---- hexagon geometry -------------------------------------------------------
if (requireNamespace("h3jsr", quietly = TRUE)) {
  message("hexagons: H3 res 9 via h3jsr")
  hex <- h3jsr::cell_to_polygon(cells$h3_9, simple = FALSE)
  hex <- st_as_sf(hex)
  hex$h3_9 <- cells$h3_9
  hex <- merge(hex, cells, by = "h3_9")
} else {
  message("hexagons: h3jsr not installed — using an sf hex grid of equivalent area (~0.105 km2)")
  # place a hexagonal grid over the study area in British National Grid metres,
  # then assign each cell's users to the hexagon containing the place centroid
  pts_home <- st_as_sf(hw[!is.na(home_h3)], coords = c("home_lon", "home_lat"), crs = 4326)
  pts_work <- st_as_sf(hw[!is.na(work_h3)], coords = c("work_lon", "work_lat"), crs = 4326)
  allpts   <- st_transform(rbind(pts_home["useruuid"], pts_work["useruuid"]), 27700)
  cellsize <- sqrt(105000 / (3 * sqrt(3) / 2)) * sqrt(3)   # hexagon of ~0.105 km2
  grid <- st_sf(hex_id = seq_along(g <- st_make_grid(allpts, cellsize = cellsize, square = FALSE)),
                geometry = g)
  hi <- st_join(st_transform(pts_home, 27700), grid, join = st_within)
  wi <- st_join(st_transform(pts_work, 27700), grid, join = st_within)
  nh <- as.data.table(st_drop_geometry(hi))[, .(n_home = .N), by = hex_id]
  nw <- as.data.table(st_drop_geometry(wi))[, .(n_work = .N), by = hex_id]
  hex <- merge(grid, merge(nh, nw, by = "hex_id", all = TRUE), by = "hex_id")
  hex$n_home[is.na(hex$n_home)] <- 0L
  hex$n_work[is.na(hex$n_work)] <- 0L
  hex <- st_transform(hex, 4326)
}

# ---- maps -------------------------------------------------------------------
theme_map <- theme_void(base_size = 11) +
  theme(legend.position = "right", plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(colour = "grey30"))

map_layer <- function(sfobj, var, title, subtitle, palette_end) {
  d <- sfobj[sfobj[[var]] > 0, ]
  ggplot(d) +
    geom_sf(aes(fill = .data[[var]]), colour = NA) +
    scale_fill_gradient(low = "#fee8c8", high = palette_end, trans = "log10",
                        name = "users", breaks = c(1, 10, 100, 1000)) +
    coord_sf(xlim = c(-3.45, -3.05), ylim = c(55.85, 56.00), expand = FALSE) +
    labs(title = title, subtitle = subtitle) +
    theme_map
}

p_home <- map_layer(hex, "n_home",
                    "Where users sleep: HoWDe home locations",
                    sprintf("%s users with a home, H3 res-9 cells, log colour scale%s",
                            format(sum(hex$n_home), big.mark = ","),
                            if (nzchar(SFX)) paste0("  [", SFX, "]") else ""),
                    "#b30000")
p_work <- map_layer(hex, "n_work",
                    "HoWDe work locations",
                    sprintf("%s users with a work, H3 res-9 cells, log colour scale%s",
                            format(sum(hex$n_work), big.mark = ","),
                            if (nzchar(SFX)) paste0("  [", SFX, "]") else ""),
                    "#08519c")
ggsave(file.path(FIG_DIR, sprintf("homes_h3r9%s.png", SFX)), p_home, width = 10, height = 7, dpi = 150)
ggsave(file.path(FIG_DIR, sprintf("works_h3r9%s.png", SFX)), p_work, width = 10, height = 7, dpi = 150)

# ---- commute distance -------------------------------------------------------
both <- hw[!is.na(home_lat) & !is.na(work_lat)]
if (nrow(both)) {
  R <- 6371000; to_rad <- pi / 180
  both[, commute_km := {
    dlat <- (work_lat - home_lat) * to_rad; dlon <- (work_lon - home_lon) * to_rad
    a <- sin(dlat / 2)^2 + cos(home_lat * to_rad) * cos(work_lat * to_rad) * sin(dlon / 2)^2
    2 * R * asin(pmin(1, sqrt(a))) / 1000
  }]
  message(sprintf("commute km (users with both): median %.2f, p90 %.2f, n = %s",
                  median(both$commute_km), quantile(both$commute_km, .9),
                  format(nrow(both), big.mark = ",")))
  p_comm <- ggplot(both, aes(commute_km)) +
    geom_histogram(binwidth = 0.5, fill = "#54278f", colour = "white", linewidth = .2) +
    coord_cartesian(xlim = c(0, 20)) +
    labs(title = "Home-work distance", x = "km (straight line)", y = "users",
         subtitle = sprintf("%s users with both; median %.1f km",
                            format(nrow(both), big.mark = ","), median(both$commute_km))) +
    theme_minimal(base_size = 11)
  ggsave(file.path(FIG_DIR, sprintf("commute_km%s.png", SFX)), p_comm, width = 8, height = 5, dpi = 150)
}

# ---- export for QGIS --------------------------------------------------------
gpkg <- file.path(OUT_DIR, sprintf("hw_hexes%s.gpkg", SFX))
st_write(hex, gpkg, layer = "hexes", delete_dsn = TRUE, quiet = TRUE)
message("wrote ", gpkg, " and figures in ", FIG_DIR)
