
# ==============================================================================
# 9_POPULATE_DATA.R
# Extracts simulation summaries from master_database_2026.db and produces
# risk matrix plots matching the FinnPRIO assessment plotting style.
# ==============================================================================

# ==============================================================================
# 0. CONFIGURATION
# ==============================================================================

DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/finnprio_2026/master_database_2026/master_database_2026.db"

MASTER_SPECIES_FILE <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/Prosjektdata - Dokumenter/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/data/2_processed_data/master_species.xlsx"

OUTPUT_DIR <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/finnprio_2026/master_database_2026/plots"

ONLY_FINISHED     <- FALSE   # TRUE = exclude unfinished assessments
ONLY_VALID        <- FALSE   # TRUE = only valid assessments
EXPORT_DATA       <- TRUE    # export wide data frame as Excel alongside plots
REFERENCE_SPECIES <- c("XXXXX", "XX!X!X!" ) # excluded from plots

# ==============================================================================
# 1. LIBRARIES
# ==============================================================================

library(DBI)
library(RSQLite)
library(tidyverse)
library(readxl)
library(ggrepel)
library(ragg)


# ==============================================================================
# 2. DATA LOADING FROM DB
# ==============================================================================

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(RSQLite::SQLite(), DB_PATH)

sims_long <- dbGetQuery(con, "
  SELECT a.idAssessment, p.eppoCode, p.scientificName, a.endDate,
         a.finished, a.valid,
         ss.variable, ss.median, ss.q5, ss.q95
  FROM assessments a
  JOIN pests p ON a.idPest = p.idPest
  JOIN simulations s ON s.idAssessment = a.idAssessment
  JOIN simulationSummaries ss ON ss.idSimulation = s.idSimulation
  WHERE s.idSimulation = (
    SELECT MAX(s2.idSimulation) FROM simulations s2 WHERE s2.idAssessment = a.idAssessment
  )
")

dbDisconnect(con)
cat("Loaded", length(unique(sims_long$idAssessment)), "assessments with simulations.\n")

# ==============================================================================
# 3. DATA PREPARATION
# ==============================================================================

if (ONLY_FINISHED) sims_long <- filter(sims_long, finished == 1)
if (ONLY_VALID)    sims_long <- filter(sims_long, valid    == 1)

# Pivot to one row per assessment
sims_wide <- sims_long %>%
  pivot_wider(
    names_from  = variable,
    values_from = c(median, q5, q95),
    names_glue  = "{variable}_{.value}"
  )

# Rename to reference plotting convention (hyphens + spaces match reference script)
df <- sims_wide %>%
  rename(
    `INVASION-A_MEDIAN`           = INVASIONA_median,
    `INVASION-A_5 percentile`     = INVASIONA_q5,
    `INVASION-A_95 percentile`    = INVASIONA_q95,
    ESTABLISHMENT_MEDIAN          = ESTABLISHMENT_median,
    `ESTABLISHMENT_5 percentile`  = ESTABLISHMENT_q5,
    `ESTABLISHMENT_95 percentile` = ESTABLISHMENT_q95,
    IMPACT_MEDIAN                 = IMPACT_median,
    `IMPACT_5 percentile`         = IMPACT_q5,
    `IMPACT_95 percentile`        = IMPACT_q95,
    `ENTRY-A_MEDIAN`              = ENTRYA_median
  ) %>%
  mutate(
    Species               = paste0(scientificName, " (", eppoCode, ")"),
    use_this_species_name = scientificName,
    eppocode              = tolower(eppoCode),
    Date                  = as.Date(substr(endDate, 1, 10)),
    Total_risk_score      = `ENTRY-A_MEDIAN` * ESTABLISHMENT_MEDIAN * IMPACT_MEDIAN
  )

# Drop rows where key simulation variables are missing (no simulation run)
df <- df %>%
  filter(!is.na(`INVASION-A_MEDIAN`), !is.na(ESTABLISHMENT_MEDIAN), !is.na(IMPACT_MEDIAN))

# Keep newest entry per species when duplicates exist
df <- df %>%
  group_by(eppoCode) %>%
  slice_max(Date, n = 1, with_ties = FALSE) %>%
  ungroup()

# ==============================================================================
# 4. TAXONOMY JOIN (master_species.xlsx)
# ==============================================================================

master <- tryCatch(
  read_excel(MASTER_SPECIES_FILE),
  error = function(e) {
    warning("Could not load master_species.xlsx: ", e$message, "\nTaxonomy will be 'Unknown'.")
    NULL
  }
)

if (!is.null(master)) {
  df <- df %>%
    left_join(select(master, eppocode, kingdom, phylum, class),
              by = c("eppoCode" = "eppocode"))
} else {
  df <- df %>%
    mutate(kingdom = NA_character_, phylum = NA_character_, class = NA_character_)
}

df <- df %>%
  mutate(
    kingdom    = if_else(is.na(kingdom) | kingdom == "", "Unknown", kingdom),
    custom_tax = case_when(
      kingdom %in% c("Bacteria", "Fungi", "Viruses", "Chromista") ~ kingdom,
      kingdom == "Animalia" & phylum == "Nematoda"                 ~ "Nematoda",
      kingdom == "Animalia" & phylum == "Arthropoda"               ~ "Arthropoda",
      kingdom == "Animalia"                                         ~ class,
      TRUE                                                          ~ kingdom
    )
  )

# ==============================================================================
# 5. COLORS, SHAPES, REFERENCE SPLIT
# ==============================================================================

risk_colors <- c(
  "Very low risk"  = "#27AE60",
  "Low risk"       = "#A8E6A3",
  "Moderate risk"  = "#FDE725",
  "High risk"      = "#E67E22",
  "Very high risk" = "#C0392B"
)

custom_tax_shapes <- c(
  "Bacteria"   = 15,
  "Fungi"      = 18,
  "Viruses"    = 17,
  "Arthropoda" = 16,
  "Nematoda"   = 8,
  "Chromista"  = 11,
  "Unknown"    = 4
)

present_groups <- intersect(unique(df$custom_tax), names(custom_tax_shapes))
if (length(present_groups) < length(unique(df$custom_tax))) {
  missing <- setdiff(unique(df$custom_tax), names(custom_tax_shapes))
  cat("custom_tax values not in custom_tax_shapes (mapped to 'Unknown'):", paste(missing, collapse = ", "), "\n")
}

df <- df %>%
  mutate(
    custom_tax = if_else(custom_tax %in% names(custom_tax_shapes), custom_tax, "Unknown"),
    custom_tax = factor(custom_tax, levels = names(custom_tax_shapes))
  )

df_ref <- df %>% filter(eppoCode %in% REFERENCE_SPECIES)
df     <- df %>% filter(!eppoCode %in% REFERENCE_SPECIES)

cat("Plotting", nrow(df), "species (", nrow(df_ref), "reference species excluded).\n")

# 3x3 background grid (start at 0 to avoid out-of-range tile warnings)
grid <- expand.grid(
  `INVASION-A_MEDIAN` = seq(0, 1, length.out = 100),
  IMPACT_MEDIAN       = seq(0, 1, length.out = 100)
) %>%
  mutate(
    prob_bin   = case_when(`INVASION-A_MEDIAN` <= 0.33 ~ 1, `INVASION-A_MEDIAN` <= 0.66 ~ 2, TRUE ~ 3),
    impact_bin = case_when(IMPACT_MEDIAN <= 0.33 ~ 1, IMPACT_MEDIAN <= 0.66 ~ 2, TRUE ~ 3),
    risk_score = prob_bin * impact_bin,
    Risk_Area  = case_when(
      risk_score == 1         ~ "Very low risk",
      risk_score == 2         ~ "Low risk",
      risk_score %in% c(3,4) ~ "Moderate risk",
      risk_score == 6         ~ "High risk",
      risk_score == 9         ~ "Very high risk"
    ),
    Risk_Area = factor(Risk_Area, levels = names(risk_colors))
  )

# Shared theme for matrix plots
matrix_theme <- theme_minimal(base_size = 11) +
  theme(
    plot.title    = element_text(size = 20, face = "bold", hjust = 0.5, margin = margin(b = 10)),
    axis.title    = element_text(face = "bold", size = 14),
    axis.title.x  = element_text(margin = margin(t = 10)),
    axis.title.y  = element_text(margin = margin(r = 10)),
    axis.text     = element_text(size = 12, color = "black"),
    axis.line     = element_line(color = "black", linewidth = 0.6),
    axis.ticks    = element_line(color = "black", linewidth = 0.4),
    axis.ticks.length = unit(0.15, "cm"),
    panel.grid    = element_blank(),
    panel.background = element_rect(fill = "white", color = NA),
    plot.background  = element_rect(fill = "white", color = NA),
    legend.position  = "right",
    legend.title  = element_text(size = 12, face = "bold"),
    legend.text   = element_text(size = 11),
    legend.key.size     = unit(0.6, "cm"),
    legend.key          = element_rect(fill = NA, color = NA),
    legend.spacing.y    = unit(0.3, "cm"),
    legend.box.spacing  = unit(0.5, "cm"),
    legend.margin       = margin(l = 10),
    plot.margin         = margin(15, 15, 15, 15)
  )

# ==============================================================================
# 6. PLOT FUNCTIONS
# ==============================================================================

plot_invasion <- function(data, title_suffix = "All Species", filename = NULL, show_legend = TRUE) {
  if (nrow(data) == 0) {
    cat(paste0("  Skipping (no data): ", filename, "\n"))
    return(invisible(NULL))
  }
  if (is.null(filename)) filename <- file.path(OUTPUT_DIR, "plot_invasion_all_species.png")
  
  p <- ggplot() +
    geom_tile(data = grid,
              aes(x = `INVASION-A_MEDIAN`, y = IMPACT_MEDIAN, fill = Risk_Area), alpha = 1) +
    geom_errorbarh(data = data,
                   aes(y = IMPACT_MEDIAN,
                       xmin = `INVASION-A_5 percentile`,
                       xmax = `INVASION-A_95 percentile`),
                   width = 0, colour = "black", alpha = 0.5, linewidth = 0.2) +
    geom_errorbar(data = data,
                  aes(x = `INVASION-A_MEDIAN`,
                      ymin = `IMPACT_5 percentile`,
                      ymax = `IMPACT_95 percentile`),
                  width = 0, colour = "black", alpha = 0.5, linewidth = 0.2) +
    geom_point(data = data,
               aes(x = `INVASION-A_MEDIAN`, y = IMPACT_MEDIAN, shape = custom_tax),
               fill = "black", colour = "black", size = 3, stroke = 1.2) +
    geom_text_repel(data = data,
                    aes(x = `INVASION-A_MEDIAN`, y = IMPACT_MEDIAN, label = eppoCode),
                    size = 3.5, max.overlaps = Inf, box.padding = 0.4) +
    scale_x_continuous(breaks = seq(0, 1, 0.1), limits = c(-0.05, 1),
                       expand = c(0, 0), name = "Invasion (Median INVASION-A)") +
    scale_y_continuous(breaks = seq(0, 1, 0.1), limits = c(-0.05, 1),
                       expand = c(0, 0), name = "Impact (Median IMPACT)") +
    scale_fill_manual(values = risk_colors, name = "Total risk class", drop = FALSE) +
    scale_shape_manual(values = custom_tax_shapes, name = "Group",
                       guide = if (show_legend) "legend" else "none") +
    geom_hline(yintercept = 0, color = "black", linewidth = 0.5) +
    geom_vline(xintercept = 0, color = "black", linewidth = 0.5) +
    matrix_theme +
    coord_fixed()
  
  ggsave(filename, p, width = 12, height = 10, dpi = 300, device = agg_png)
  cat(paste0("  Saved: ", basename(filename), "\n"))
  invisible(p)
}

plot_establishment <- function(data, title_suffix = "All Species", filename = NULL, show_legend = TRUE) {
  if (nrow(data) == 0) {
    cat(paste0("  Skipping (no data): ", filename, "\n"))
    return(invisible(NULL))
  }
  if (is.null(filename)) filename <- file.path(OUTPUT_DIR, "plot_establishment_all_species.png")
  
  p <- ggplot() +
    geom_tile(data = grid,
              aes(x = `INVASION-A_MEDIAN`, y = IMPACT_MEDIAN, fill = Risk_Area), alpha = 1) +
    geom_errorbarh(data = data,
                   aes(y = IMPACT_MEDIAN,
                       xmin = `ESTABLISHMENT_5 percentile`,
                       xmax = `ESTABLISHMENT_95 percentile`),
                   width = 0, colour = "black", alpha = 0.5, linewidth = 0.2) +
    geom_errorbar(data = data,
                  aes(x = ESTABLISHMENT_MEDIAN,
                      ymin = `IMPACT_5 percentile`,
                      ymax = `IMPACT_95 percentile`),
                  width = 0, colour = "black", alpha = 0.5, linewidth = 0.2) +
    geom_point(data = data,
               aes(x = ESTABLISHMENT_MEDIAN, y = IMPACT_MEDIAN, shape = custom_tax),
               fill = "black", colour = "black", size = 3, stroke = 1.2) +
    geom_text_repel(data = data,
                    aes(x = ESTABLISHMENT_MEDIAN, y = IMPACT_MEDIAN, label = eppoCode),
                    size = 3.5, max.overlaps = Inf, box.padding = 0.4) +
    scale_x_continuous(breaks = seq(0, 1, 0.1), limits = c(-0.05, 1),
                       expand = c(0, 0), name = "Establishment (Median ESTABLISHMENT)") +
    scale_y_continuous(breaks = seq(0, 1, 0.1), limits = c(-0.05, 1),
                       expand = c(0, 0), name = "Impact (Median IMPACT)") +
    scale_fill_manual(values = risk_colors, name = "Risk, given pest entry", drop = FALSE) +
    scale_shape_manual(values = custom_tax_shapes, name = "Group",
                       guide = if (show_legend) "legend" else "none") +
    geom_hline(yintercept = 0, color = "black", linewidth = 0.5) +
    geom_vline(xintercept = 0, color = "black", linewidth = 0.5) +
    matrix_theme +
    coord_fixed()
  
  ggsave(filename, p, width = 12, height = 10, dpi = 300, device = agg_png)
  cat(paste0("  Saved: ", basename(filename), "\n"))
  invisible(p)
}

# ==============================================================================
# 7. GENERATE PLOTS
# ==============================================================================

cat("\n=== MAIN PLOTS ===\n")
plot_invasion(df,
              filename    = file.path(OUTPUT_DIR, "plot_invasion_all_species.png"),
              show_legend = TRUE)
plot_establishment(df,
                   filename    = file.path(OUTPUT_DIR, "plot_establishment_all_species.png"),
                   show_legend = TRUE)

cat("\n=== PER-GROUP PLOTS ===\n")
for (grp in levels(df$custom_tax)) {
  grp_data <- df %>% filter(custom_tax == grp)
  if (nrow(grp_data) == 0) next
  slug <- tolower(grp)
  plot_invasion(grp_data,
                filename    = file.path(OUTPUT_DIR, paste0("plot_invasion_", slug, ".png")),
                show_legend = FALSE)
  plot_establishment(grp_data,
                     filename    = file.path(OUTPUT_DIR, paste0("plot_establishment_", slug, ".png")),
                     show_legend = FALSE)
}

cat("\n=== LOLLIPOP: TOTAL RISK SCORE ===\n")
lollipop_data <- df %>%
  filter(!is.na(eppoCode), Total_risk_score > 0) %>%
  mutate(eppoCode = forcats::fct_reorder(eppoCode, Total_risk_score, .desc = FALSE))

plot_total_risk_score <- ggplot(lollipop_data,
                                aes(x = Total_risk_score, y = eppoCode, shape = custom_tax)) +
  geom_segment(aes(x = 0, xend = Total_risk_score, y = eppoCode, yend = eppoCode),
               color = "black", linewidth = 0.3) +
  geom_point(fill = "black", colour = "black", size = 3, stroke = 1.2) +
  geom_text(aes(label = use_this_species_name), hjust = -0.1, size = 4) +
  scale_shape_manual(values = custom_tax_shapes, name = "") +
  scale_x_continuous(breaks = seq(0, 0.5, 0.05)) +
  expand_limits(x = c(0, 0.5)) +
  labs(x = "Total Risk Score", y = "EPPO Code") +
  theme_minimal(base_size = 16) +
  theme(
    axis.title      = element_text(face = "bold", size = 12),
    axis.text       = element_text(size = 12, face = "bold"),
    panel.grid      = element_blank(),
    plot.background = element_rect(fill = "white", color = NA),
    panel.background= element_rect(fill = "white", color = NA),
    axis.line       = element_line(color = "black", linewidth = 0.5)
  )

ggsave(file.path(OUTPUT_DIR, "plot_total_risk_score.png"),
       plot_total_risk_score, width = 30, height = 20, units = "cm", dpi = 300, device = agg_png)
cat("  Saved: plot_total_risk_score.png\n")

# ==============================================================================
# 8. OPTIONAL DATA EXPORT
# ==============================================================================

if (EXPORT_DATA) {
  out_file <- file.path(OUTPUT_DIR, "finnprio_simulation_results.xlsx")
  rio::export(df, out_file)
  cat("\n  Data exported: finnprio_simulation_results.xlsx\n")
}

# ==============================================================================
# 9. SUMMARY STATISTICS
# ==============================================================================

cat("\n=== SUMMARY ===\n")
cat("Total species plotted:", nrow(df), "\n")
cat("Reference species excluded:", nrow(df_ref), "\n")

cat("\n--- Risk distribution (INVASION-A) ---\n")
df %>%
  mutate(
    prob_bin   = case_when(`INVASION-A_MEDIAN` <= 0.33 ~ 1, `INVASION-A_MEDIAN` <= 0.66 ~ 2, TRUE ~ 3),
    impact_bin = case_when(IMPACT_MEDIAN <= 0.33 ~ 1, IMPACT_MEDIAN <= 0.66 ~ 2, TRUE ~ 3),
    risk_score = prob_bin * impact_bin,
    risk_cat   = factor(case_when(
      risk_score == 1         ~ "Very low risk",
      risk_score == 2         ~ "Low risk",
      risk_score %in% c(3,4) ~ "Moderate risk",
      risk_score == 6         ~ "High risk",
      risk_score == 9         ~ "Very high risk"
    ), levels = names(risk_colors))
  ) %>%
  count(risk_cat, .drop = FALSE) %>%
  mutate(pct = round(n / sum(n) * 100, 1)) %>%
  print(n = Inf)

cat("\n--- Taxonomic groups ---\n")
df %>%
  count(custom_tax) %>%
  arrange(desc(n)) %>%
  mutate(pct = round(n / sum(n) * 100, 1)) %>%
  print(n = Inf)

cat("\n--- Total risk score stats ---\n")
cat("Mean:  ", round(mean(df$Total_risk_score, na.rm = TRUE), 4), "\n")
cat("Median:", round(median(df$Total_risk_score, na.rm = TRUE), 4), "\n")
cat("Range: ", round(min(df$Total_risk_score, na.rm = TRUE), 4), "-",
    round(max(df$Total_risk_score, na.rm = TRUE), 4), "\n")

cat("\nDone. Plots saved to:", OUTPUT_DIR, "\n")

# ==============================================================================
# DIAGNOSIS: which species are missing from the plots and why?
# ==============================================================================

con_diag <- dbConnect(RSQLite::SQLite(), DB_PATH)

all_assessments <- dbGetQuery(con_diag, "
  SELECT a.idAssessment, p.eppoCode, p.scientificName, a.finished, a.valid,
         ao.firstName || ' ' || ao.lastName AS assessor,
         CASE WHEN s.idSimulation IS NOT NULL THEN 1 ELSE 0 END AS has_simulation
  FROM assessments a
  JOIN pests p ON a.idPest = p.idPest
  JOIN assessors ao ON ao.idAssessor = a.idAssessor
  LEFT JOIN (
    SELECT idAssessment, MAX(idSimulation) AS idSimulation FROM simulations GROUP BY idAssessment
  ) s ON s.idAssessment = a.idAssessment
")

dbDisconnect(con_diag)

plotted_codes <- df$eppoCode

diagnosis <- all_assessments %>%
  mutate(
    in_plot = eppoCode %in% plotted_codes,
    reason  = case_when(
      in_plot                         ~ "plotted",
      eppoCode %in% REFERENCE_SPECIES ~ "reference species (excluded)",
      has_simulation == 0             ~ "no simulation run",
      TRUE                            ~ "simulation exists but key variables NA"
    )
  )

cat("\n=== DIAGNOSIS: SPECIES STATUS ===\n")
diagnosis %>%
  count(reason) %>%
  arrange(desc(n)) %>%
  print()

cat("\n--- Species NOT in plots ---\n")

diagnosis %>%
  filter(reason != "plotted") %>%
  select(eppoCode, scientificName, assessor, finished, valid, has_simulation, reason) %>%
  arrange(reason, eppoCode) 

# --- Expected species (batch 2) vs DB ---
eppo_codes_batch_2 <- c(
  "DIAACI", "NEOLEL", "LIBEAS", "XANTCI", "EPOCCA", "HOMLTR",
  "PRODER", "ANOLHO", "DACUDO", "CERTCA", "PHECPI", "CHRBFE",
  "CHRBMA", "DENDSU", "EPIXCU", "EPIXSU", "EPIXTU", "MALADI",
  "PHYCFR", "RHYCFE", "LAPHFR", "PRODOR", "PRODPR", "ARGPLE",
  "TOUMPA", "XYLOCH", "AROMBU", "IPSXHA", "IPSXFA", "XYLEFA",
  "TOXOCI", "CHONFU", "HELIZE", "CTV000", "ANTHBI", "ANTHSI",
  "NUMOPI", "CERTRO", "CHONRO", "CYDIIN", "LASPPA", "LOPLJA",
  "TYLCV0", "PEPMV0", "TOBRFV", "APRICI", "APRIGE", "APRIJA",
  "XYLOAL", "XYLONM", "XYLOPY", "XYLBFO", "PHYTKE", "ALECSN",
  "ALECWO", "ANTHEU", "PARZCO", "CRTZCL", "GNORLY", "HYROBO",
  "GRAGLE", "SCITDO", "LIBEPS", "CORBIN", "RALSPS", "RALSSY",
  "XANTAA", "GIBBCI", "THEKMI"
)

con_diag2 <- dbConnect(RSQLite::SQLite(), DB_PATH)

in_db <- dbGetQuery(con_diag2, "
  SELECT p.eppoCode, p.scientificName,
         COUNT(DISTINCT a.idAssessment) AS n_assessments,
         SUM(CASE WHEN s.idSimulation IS NOT NULL THEN 1 ELSE 0 END) AS n_with_sim,
         GROUP_CONCAT(DISTINCT ao.firstName || ' ' || ao.lastName) AS assessors
  FROM pests p
  LEFT JOIN assessments a ON a.idPest = p.idPest
  LEFT JOIN assessors ao ON ao.idAssessor = a.idAssessor
  LEFT JOIN (
    SELECT idAssessment, MAX(idSimulation) AS idSimulation FROM simulations GROUP BY idAssessment
  ) s ON s.idAssessment = a.idAssessment
  GROUP BY p.eppoCode, p.scientificName
")

dbDisconnect(con_diag2)

missing_from_db   <- setdiff(eppo_codes_batch_2, in_db$eppoCode)

no_sim_has_assess <- in_db[in_db$eppoCode %in% eppo_codes_batch_2 &
                             in_db$n_assessments > 0 &
                             in_db$n_with_sim == 0, ]

cat("\n=== BATCH 2 COMPLETENESS CHECK ===\n")
cat("Expected:                 ", length(eppo_codes_batch_2), "\n")
cat("Found in DB:              ", sum(eppo_codes_batch_2 %in% in_db$eppoCode), "\n")
cat("Missing from DB:          ", length(missing_from_db), "\n")
cat("Has assessment, no sim:   ", nrow(no_sim_has_assess), "\n")

cat("\n--- Missing from DB (need to be added) ---\n")

if (length(missing_from_db) == 0) cat("None\n") else cat(paste(missing_from_db, collapse = "\n"), "\n")

cat("\n--- Assessment exists but no simulation run yet ---\n")

if (nrow(no_sim_has_assess) == 0) {
  cat("None\n")
} else {
  print(no_sim_has_assess[, c("eppoCode", "scientificName", "assessors", "n_assessments", "n_with_sim")],
        row.names = FALSE)
}

