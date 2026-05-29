################################################################################
# FinnPRIO: Compare Simulation Traces  (e.g. AI vs. Human)  — v2
#
# Loads two .rds files produced by export_simulation_traces.R, pairs assessments
# by scientificName, and compares per-iteration distributions.
#
# Statistics per variable:
#   - Two-sample Kolmogorov-Smirnov (D statistic + p-value)
#   - Wasserstein-1 distance  (raw, in original units)
#   - Normalised Wasserstein  (W / pooled IQR → comparable across variables)
#   - IQR ratio  (A / B → dispersion comparison)
#   - Cliff's delta  (stochastic dominance, [-1, 1])
#   - Mean & median differences (A − B)
#
# Classification:
#   Primary classification is on RISKA (the composite risk score), using
#   Cliff's delta with Romano et al. (2006) thresholds:
#     |δ| < 0.147 → Negligible
#     |δ| < 0.33  → Small
#     |δ| < 0.474 → Medium
#     |δ| ≥ 0.474 → Large
#   Per-component deltas (INVASION, ESTABLISHMENT, IMPACT) are retained as
#   diagnostics to show *where* the divergence comes from.
#
#   Bootstrap 95% CIs on Cliff's delta are provided to flag boundary cases.
#
# Outputs:
#   - comparison_stats.csv         full per-variable statistics
#   - classification.csv           per-pest risk classification + diagnostics
#   - plots/heatmap_wasserstein_normalised.png
#   - plots/boxplot_*.png          per-group paired boxplots
#   - plots/boxplot_invasion_vs_impact.png
#   - plots/classification_heatmap.png
#   - plots/classification_summary.png
#   - plots/risk_matrix_*.png
#
# Reference:
#   Romano J, Kromrey JD, Coraggio J, Skowronek J (2006). Appropriate
#   statistics for ordinal level data: Should we really be using t-test
#   and Cohen's d for evaluating group differences on the NSSE and similar
#   surveys? Annual Meeting of the Florida Association of Institutional
#   Research, Cocoa Beach, FL.
################################################################################

library(tidyverse)

# =============================================================================
TRACE_A <- "./scripts/exploration/output/trace_ai.rds"
TRACE_B <- "./scripts/exploration/output/trace_human.rds"
LABEL_A <- "AI"
LABEL_B <- "Human"

OUT_STATS_CSV <- "./scripts/exploration/output/comparison_stats.csv"
OUT_CLASS_CSV <- "./scripts/exploration/output/classification.csv"
PLOTS_DIR     <- "./scripts/exploration/output/plots"

# Bootstrap settings for Cliff's delta CIs
N_BOOT        <- 2000
BOOT_SEED     <- 42
# =============================================================================

# -- Helper functions ---------------------------------------------------------

load_trace <- function(path) {
  x <- readRDS(path)
  meta <- x$metadata %>%
    arrange(desc(idAssessment)) %>%
    distinct(scientificName, .keep_all = TRUE)
  traces <- x$traces[meta$sheet]
  names(traces) <- meta$scientificName
  list(meta = meta, traces = traces)
}

#' Wasserstein-1 (earth mover's distance) between two empirical distributions
#' Uses the exact closed-form: integral of |F(x) - G(x)| dx
wasserstein1 <- function(x, y) {
  x <- x[is.finite(x)]; y <- y[is.finite(y)]
  if (length(x) == 0 || length(y) == 0) return(NA_real_)
  # Exact computation via sorted pooled values
  all_vals <- sort(unique(c(x, y)))
  if (length(all_vals) < 2) return(0)
  Fx <- ecdf(x)(all_vals)
  Fy <- ecdf(y)(all_vals)
  diffs <- diff(all_vals)
  # Trapezoidal integration of |F - G|
  abs_diff <- abs(Fx - Fy)
  sum(diffs * (abs_diff[-length(abs_diff)] + abs_diff[-1]) / 2)
}

#' Cliff's delta = P(X > Y) - P(X < Y), computed via Mann-Whitney U.
#' Uses is.finite() to exclude NA, NaN, and Inf.
#' Subsamples to max_n per side for numerical stability with large vectors;
#' with 10k the estimate is precise to ~±0.01.
cliffs_delta <- function(x, y, max_n = 10000, seed = 1L) {
  n_orig_x <- length(x); n_orig_y <- length(y)
  x <- x[is.finite(x)]; y <- y[is.finite(y)]
  n_dropped <- (n_orig_x - length(x)) + (n_orig_y - length(y))
  if (n_dropped > 0) {
    message(sprintf("  cliffs_delta: dropped %d non-finite values", n_dropped))
  }
  nx <- length(x); ny <- length(y)
  if (nx == 0 || ny == 0) return(NA_real_)
  if (nx > max_n || ny > max_n) {
    set.seed(seed)
    if (nx > max_n) x <- sample(x, max_n)
    if (ny > max_n) y <- sample(y, max_n)
    nx <- length(x); ny <- length(y)
  }
  r <- rank(c(x, y))
  U <- sum(r[seq_len(nx)]) - nx * (nx + 1) / 2
  (2 * U / (nx * ny)) - 1
}

#' Bootstrap 95% CI for Cliff's delta (percentile method)
#' Subsamples to keep computation tractable for large n.
cliffs_delta_ci <- function(x, y, n_boot = 2000, seed = 42,
                            max_subsample = 5000) {
  x <- x[is.finite(x)]; y <- y[is.finite(y)]
  if (length(x) < 2 || length(y) < 2) return(c(lo = NA_real_, hi = NA_real_))
  # Subsample for speed if needed
  set.seed(seed)
  if (length(x) > max_subsample) x <- sample(x, max_subsample)
  if (length(y) > max_subsample) y <- sample(y, max_subsample)
  boot_d <- numeric(n_boot)
  nx <- length(x); ny <- length(y)
  for (i in seq_len(n_boot)) {
    bx <- sample(x, nx, replace = TRUE)
    by <- sample(y, ny, replace = TRUE)
    r  <- rank(c(bx, by))
    U  <- sum(r[seq_len(nx)]) - nx * (nx + 1) / 2
    boot_d[i] <- (2 * U / (nx * ny)) - 1
  }
  q <- quantile(boot_d, c(0.025, 0.975), names = FALSE)
  c(lo = q[1], hi = q[2])
}

#' Romano et al. (2006) magnitude labels for |Cliff's delta|
romano_label <- function(d) {
  ad <- abs(d)
  dplyr::case_when(
    is.na(ad)    ~ NA_character_,
    ad < 0.147   ~ "Negligible",
    ad < 0.33    ~ "Small",
    ad < 0.474   ~ "Medium",
    TRUE         ~ "Large"
  )
}

#' Compare two numeric vectors: full stats row
compare_vectors <- function(x, y) {
  x <- x[is.finite(x)]; y <- y[is.finite(y)]
  if (length(x) < 2 || length(y) < 2) return(NULL)
  
  # Short-circuit for identical constant vectors
  if (max(abs(range(x) - range(y))) < .Machine$double.eps * 100 &&
      stats::var(x) < .Machine$double.eps &&
      stats::var(y) < .Machine$double.eps) {
    return(data.frame(
      n_A = length(x), n_B = length(y),
      mean_A = mean(x), mean_B = mean(y),
      median_A = median(x), median_B = median(y),
      iqr_A = 0, iqr_B = 0, iqr_ratio = NA_real_,
      mean_diff = 0, median_diff = 0,
      wasserstein = 0, wasserstein_norm = 0,
      cliffs_delta = 0,
      ks_stat = 0, ks_pvalue = 1))
  }
  
  iqr_a <- IQR(x); iqr_b <- IQR(y)
  pooled_iqr <- (iqr_a + iqr_b) / 2
  iqr_ratio  <- if (iqr_b > 0) iqr_a / iqr_b else NA_real_
  
  mean_diff <- mean(x) - mean(y)
  w <- wasserstein1(x, y)
  w_norm <- if (pooled_iqr > 0) w / pooled_iqr else NA_real_
  ks <- suppressWarnings(ks.test(x, y))
  
  data.frame(
    n_A             = length(x),
    n_B             = length(y),
    mean_A          = mean(x),
    mean_B          = mean(y),
    median_A        = median(x),
    median_B        = median(y),
    iqr_A           = iqr_a,
    iqr_B           = iqr_b,
    iqr_ratio       = iqr_ratio,
    mean_diff       = mean_diff,
    median_diff     = median(x) - median(y),
    wasserstein     = w,
    wasserstein_norm = w_norm,
    cliffs_delta    = cliffs_delta(x, y),
    ks_stat         = unname(ks$statistic),
    ks_pvalue       = ks$p.value
  )
}

# =============================================================================
# Main
# =============================================================================

message("Loading traces...")
A <- load_trace(TRACE_A)
B <- load_trace(TRACE_B)

common_pests <- intersect(names(A$traces), names(B$traces))
message(sprintf("Shared pests: %d", length(common_pests)))
if (length(common_pests) == 0) stop("No matching pests between the two files.")

# -- Stats --------------------------------------------------------------------
dir.create(dirname(OUT_STATS_CSV), recursive = TRUE, showWarnings = FALSE)

message("Computing comparison statistics...")
stats_tbl <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]; b <- B$traces[[pest]]
  vars <- setdiff(intersect(names(a), names(b)), "iteration")
  map_dfr(vars, function(v) {
    res <- compare_vectors(a[[v]], b[[v]])
    if (is.null(res)) return(NULL)
    cbind(data.frame(pest = pest, variable = v), res)
  })
}) %>%
  mutate(romano_magnitude = romano_label(cliffs_delta)) %>%
  arrange(desc(wasserstein_norm))

write.csv(stats_tbl, OUT_STATS_CSV, row.names = FALSE)
message(sprintf("Saved stats: %s  (%d rows)", OUT_STATS_CSV, nrow(stats_tbl)))

# -- Classification on RISKA --------------------------------------------------
message("Classifying pests on RISKA with bootstrap CIs...")

CORE_VARS <- c("ENT1", "ENTRYA", "ENTRYB",
               "EST1", "EST2", "EST3", "EST4", "SPR1", "ESTABLISHMENT",
               "INVASIONA", "INVASIONB",
               "IMP1", "IMP2", "IMP3", "IMP4", "IMPACT",
               "RISKA", "RISKB",
               "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
               "PREVENTABILITY", "CONTROLLABILITY", "MANAGEABILITY")

# Primary classification variable
PRIMARY_VAR <- "RISKA"
# Diagnostic decomposition variables
DIAG_VARS   <- c("INVASIONA", "ESTABLISHMENT", "IMPACT")
DIAG_LABELS <- c("INVASION",  "ESTABLISHMENT", "IMPACT")

# Compute primary classification with bootstrap CIs
set.seed(BOOT_SEED)
classification <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]; b <- B$traces[[pest]]
  
  # Primary: Cliff's delta on RISKA + bootstrap CI
  delta_risk <- cliffs_delta(a[[PRIMARY_VAR]], b[[PRIMARY_VAR]])
  ci_risk    <- cliffs_delta_ci(a[[PRIMARY_VAR]], b[[PRIMARY_VAR]],
                                n_boot = N_BOOT, seed = BOOT_SEED)
  
  # Direction label for the primary classification
  direction <- dplyr::case_when(
    is.na(delta_risk)             ~ NA_character_,
    abs(delta_risk) < 0.147       ~ "Similar",
    delta_risk > 0                ~ sprintf("%s higher", LABEL_A),
    TRUE                          ~ sprintf("%s lower",  LABEL_A)
  )
  
  # Diagnostic: Cliff's delta per component
  diag_deltas <- setNames(
    map_dbl(DIAG_VARS, ~ cliffs_delta(a[[.x]], b[[.x]])),
    paste0("delta_", DIAG_LABELS)
  )
  diag_magnitudes <- setNames(
    map_chr(diag_deltas, romano_label),
    paste0("magnitude_", DIAG_LABELS)
  )
  
  # Wasserstein (normalised) for RISKA
  w_risk <- compare_vectors(a[[PRIMARY_VAR]], b[[PRIMARY_VAR]])
  
  tibble(
    pest            = pest,
    delta_RISK      = delta_risk,
    delta_RISK_lo   = ci_risk["lo"],
    delta_RISK_hi   = ci_risk["hi"],
    magnitude_RISK  = romano_label(delta_risk),
    direction       = direction,
    median_A        = median(a[[PRIMARY_VAR]], na.rm = TRUE),
    median_B        = median(b[[PRIMARY_VAR]], na.rm = TRUE),
    median_diff     = median(a[[PRIMARY_VAR]], na.rm = TRUE) -
      median(b[[PRIMARY_VAR]], na.rm = TRUE),
    wasserstein_norm = if (!is.null(w_risk)) w_risk$wasserstein_norm else NA_real_,
    !!!diag_deltas,
    !!!diag_magnitudes
  )
}) %>%
  arrange(desc(abs(delta_RISK)))

write.csv(classification, OUT_CLASS_CSV, row.names = FALSE)
message(sprintf("Saved classification: %s  (%d pests)",
                OUT_CLASS_CSV, nrow(classification)))

# Print summary
cat("\n=== Classification summary (RISKA) ===\n")
classification %>%
  count(magnitude_RISK, direction) %>%
  print(n = 20)
cat("\n")

# -- Plots --------------------------------------------------------------------
dir.create(PLOTS_DIR, recursive = TRUE, showWarnings = FALSE)

palette2 <- setNames(c("#E64B35", "#4DBBD5"), c(LABEL_A, LABEL_B))

pretty_theme <- theme_minimal(base_size = 11) +
  theme(
    plot.title          = element_text(face = "bold", size = 14),
    plot.subtitle       = element_text(colour = "grey35", size = 10),
    plot.caption        = element_text(colour = "grey55", size = 8, hjust = 1),
    plot.title.position = "plot",
    strip.background    = element_rect(fill = "grey94", colour = NA),
    strip.text          = element_text(face = "bold", size = 9),
    panel.grid.minor    = element_blank(),
    panel.grid.major    = element_line(colour = "grey92"),
    panel.spacing       = unit(0.6, "lines"),
    legend.position     = "bottom",
    legend.title        = element_blank(),
    legend.key.width    = unit(1.2, "cm")
  )

# Sort pests by |Cliff's delta on RISKA| (most divergent first)
pest_order <- classification %>%
  arrange(desc(abs(delta_RISK))) %>%
  pull(pest)

# ---- Heatmap: Normalised Wasserstein per pest × variable --------------------
message("Building heatmap (normalised Wasserstein)...")
heat_df <- stats_tbl %>%
  filter(variable %in% CORE_VARS) %>%
  mutate(variable = factor(variable, levels = CORE_VARS),
         pest     = factor(pest, levels = rev(pest_order)))

p_heat <- ggplot(heat_df, aes(variable, pest, fill = wasserstein_norm)) +
  geom_tile(colour = "white", linewidth = 0.15) +
  scale_fill_viridis_c(option = "magma", direction = -1,
                       name = "Normalised\nWasserstein",
                       na.value = "grey92") +
  labs(title = sprintf("Divergence heatmap — %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf(
         "%d pests × %d variables · normalised by pooled IQR · rows by |δ(RISK)|",
         length(pest_order), length(CORE_VARS)),
       x = NULL, y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 60, hjust = 1, size = 8),
        axis.text.y = element_text(face = "italic", size = 7),
        panel.grid  = element_blank())

heat_file <- file.path(PLOTS_DIR, "heatmap_wasserstein_normalised.png")
ggsave(heat_file, p_heat,
       width  = max(10, length(CORE_VARS) * 0.45),
       height = max(8,  length(pest_order) * 0.18 + 2),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", heat_file))

# ---- Paired boxplots per variable group ------------------------------------
message("Building per-group boxplots...")

var_group <- function(v) {
  dplyr::case_when(
    v %in% c("ENT1","ENTRYA","ENTRYB")                            ~ "Entry",
    v %in% c("EST1","EST2","EST3","EST4","SPR1","ESTABLISHMENT")   ~ "Establishment",
    v %in% c("INVASIONA","INVASIONB")                              ~ "Invasion",
    v %in% c("IMP1","IMP2","IMP3","IMP4","IMPACT")                 ~ "Impact",
    v %in% c("RISKA","RISKB")                                      ~ "Risk",
    TRUE                                                           ~ "Manageability")
}

qs <- function(x, p) quantile(x, p, na.rm = TRUE, names = FALSE)

box_summary <- bind_rows(
  map_dfr(common_pests, function(pest) {
    a <- A$traces[[pest]]
    map_dfr(intersect(CORE_VARS, names(a)), function(v) {
      x <- a[[v]]
      data.frame(pest = pest, source = LABEL_A, variable = v,
                 ymin = qs(x,.05), lower = qs(x,.25), middle = qs(x,.50),
                 upper = qs(x,.75), ymax  = qs(x,.95))
    })
  }),
  map_dfr(common_pests, function(pest) {
    b <- B$traces[[pest]]
    map_dfr(intersect(CORE_VARS, names(b)), function(v) {
      x <- b[[v]]
      data.frame(pest = pest, source = LABEL_B, variable = v,
                 ymin = qs(x,.05), lower = qs(x,.25), middle = qs(x,.50),
                 upper = qs(x,.75), ymax  = qs(x,.95))
    })
  })
) %>%
  mutate(source   = factor(source, levels = c(LABEL_A, LABEL_B)),
         variable = factor(variable, levels = CORE_VARS),
         pest     = factor(pest, levels = rev(pest_order)),
         group    = var_group(as.character(variable)))

for (grp in unique(box_summary$group)) {
  d <- filter(box_summary, group == grp)
  n_vars <- n_distinct(d$variable)
  ncol_fac <- min(3, n_vars)
  nrow_fac <- ceiling(n_vars / ncol_fac)
  
  p_box <- ggplot(d, aes(x = pest, fill = source)) +
    geom_boxplot(aes(ymin = ymin, lower = lower, middle = middle,
                     upper = upper, ymax = ymax),
                 stat = "identity",
                 position = position_dodge(0.75),
                 width = 0.7, colour = "grey25", linewidth = 0.25) +
    facet_wrap(~ variable, scales = "free_x", ncol = ncol_fac) +
    scale_fill_manual(values = palette2) +
    coord_flip() +
    labs(title    = sprintf("%s — %s vs %s", grp, LABEL_A, LABEL_B),
         subtitle = "Boxes: 25/50/75 percentiles · whiskers: 5/95",
         x = NULL, y = NULL,
         caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
    pretty_theme +
    theme(axis.text.y = element_text(face = "italic", size = 7),
          axis.text.x = element_text(size = 8))
  
  f <- file.path(PLOTS_DIR, sprintf("boxplot_%s.png", tolower(grp)))
  ggsave(f, p_box,
         width  = max(9, ncol_fac * 4.5),
         height = max(6, nrow_fac * (length(pest_order) * 0.14 + 0.8) + 1.5),
         dpi = 150, bg = "white")
  message(sprintf("Saved: %s", f))
}

# ---- Headline: INVASION(A) + IMPACT side-by-side --------------------------
message("Building INVASION-vs-IMPACT boxplot...")
headline_df <- box_summary %>%
  filter(variable %in% c("INVASIONA", "IMPACT")) %>%
  mutate(variable = factor(variable,
                           levels = c("INVASIONA", "IMPACT"),
                           labels = c("INVASION (scenario A)", "IMPACT")))

p_head <- ggplot(headline_df, aes(x = pest, fill = source)) +
  geom_boxplot(aes(ymin = ymin, lower = lower, middle = middle,
                   upper = upper, ymax = ymax),
               stat = "identity",
               position = position_dodge(0.75),
               width = 0.7, colour = "grey25", linewidth = 0.25) +
  facet_wrap(~ variable, scales = "free_x") +
  scale_fill_manual(values = palette2) +
  coord_flip() +
  labs(title    = sprintf("INVASION vs IMPACT — %s vs %s", LABEL_A, LABEL_B),
       subtitle = "Boxes: 25/50/75 · whiskers: 5/95 · pests sorted by |δ(RISK)|",
       x = NULL, y = NULL,
       caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 7),
        axis.text.x = element_text(size = 8))

head_file <- file.path(PLOTS_DIR, "boxplot_invasion_vs_impact.png")
ggsave(head_file, p_head,
       width  = 12,
       height = max(6, length(pest_order) * 0.14 + 2),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", head_file))

# ---- Classification heatmap (RISKA-based, Romano thresholds) ---------------
message("Building classification plots...")

# Reshape for heatmap: primary RISK + diagnostic components
class_heat <- classification %>%
  select(pest, delta_RISK, all_of(paste0("delta_", DIAG_LABELS))) %>%
  pivot_longer(-pest, names_to = "component", values_to = "delta") %>%
  mutate(
    component = str_remove(component, "^delta_"),
    magnitude = romano_label(delta),
    magnitude = factor(magnitude,
                       levels = c("Large", "Medium", "Small", "Negligible")),
    direction_label = case_when(
      is.na(delta)        ~ NA_character_,
      abs(delta) < 0.147  ~ "Similar",
      delta > 0           ~ sprintf("%s higher", LABEL_A),
      TRUE                ~ sprintf("%s lower",  LABEL_A)),
    component = factor(component,
                       levels = c("RISK", DIAG_LABELS)),
    pest = factor(pest, levels = rev(pest_order))
  )

dir_levels <- c(sprintf("%s lower", LABEL_A),
                "Similar",
                sprintf("%s higher", LABEL_A))
dir_fill   <- setNames(c("#4DBBD5", "#CCCCCC", "#E64B35"), dir_levels)

p_class <- ggplot(class_heat,
                  aes(component, pest, fill = direction_label)) +
  geom_tile(colour = "white", linewidth = 0.4) +
  geom_text(aes(label = sprintf("%.2f", delta)),
            size = 2.2, colour = "grey20") +
  scale_fill_manual(values = dir_fill, name = sprintf("vs %s", LABEL_B),
                    na.value = "grey92", drop = FALSE) +
  labs(title    = sprintf("Classification — %s vs %s", LABEL_A, LABEL_B),
       subtitle = paste0(
         "Primary: Cliff's δ on RISK · Romano et al. thresholds\n",
         sprintf("|δ| < 0.147 = negligible · < 0.33 = small · < 0.474 = medium · ≥ 0.474 = large · n = %d pests",
                 length(pest_order))),
       x = NULL, y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 7),
        axis.text.x = element_text(size = 10, face = "bold"),
        panel.grid  = element_blank())

class_file <- file.path(PLOTS_DIR, "classification_heatmap.png")
ggsave(class_file, p_class,
       width  = max(8, 4 * 1.4 + 3),
       height = max(8, length(pest_order) * 0.18 + 2.5),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", class_file))

# ---- Stacked summary bar chart --------------------------------------------
summary_bar <- classification %>%
  mutate(direction = factor(direction, levels = dir_levels)) %>%
  filter(!is.na(direction)) %>%
  count(magnitude_RISK, direction, .drop = FALSE) %>%
  mutate(magnitude_RISK = factor(magnitude_RISK,
                                 levels = c("Large", "Medium",
                                            "Small", "Negligible")))

p_bar <- ggplot(summary_bar, aes(x = magnitude_RISK, y = n, fill = direction)) +
  geom_col(position = "stack", colour = "white", linewidth = 0.3) +
  geom_text(aes(label = ifelse(n > 0, n, "")),
            position = position_stack(vjust = 0.5),
            colour = "grey15", size = 3.4) +
  scale_fill_manual(values = dir_fill, name = sprintf("vs %s", LABEL_B),
                    drop = FALSE) +
  labs(title    = sprintf("How does %s compare to %s?", LABEL_A, LABEL_B),
       subtitle = sprintf(
         "Classification on RISK (Cliff's δ) · Romano et al. thresholds · n = %d pests",
         nrow(classification)),
       x = "Effect magnitude", y = "Number of pests",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme

bar_file <- file.path(PLOTS_DIR, "classification_summary.png")
ggsave(bar_file, p_bar, width = 9, height = 5.5, dpi = 150, bg = "white")
message(sprintf("Saved: %s", bar_file))

# ---- Bootstrap CI forest plot for RISKA ------------------------------------
message("Building Cliff's delta forest plot...")

forest_df <- classification %>%
  mutate(pest = factor(pest, levels = rev(pest_order)),
         direction = factor(direction, levels = dir_levels))

p_forest <- ggplot(forest_df, aes(y = pest, x = delta_RISK, colour = direction)) +
  geom_vline(xintercept = 0, linetype = "solid", colour = "grey50") +
  geom_vline(xintercept = c(-0.147, 0.147), linetype = "dashed",
             colour = "grey70", linewidth = 0.4) +
  geom_vline(xintercept = c(-0.33, 0.33), linetype = "dotted",
             colour = "grey70", linewidth = 0.4) +
  geom_errorbarh(aes(xmin = delta_RISK_lo, xmax = delta_RISK_hi),
                 height = 0.3, linewidth = 0.4) +
  geom_point(size = 2) +
  scale_colour_manual(values = dir_fill, name = NULL, drop = FALSE) +
  annotate("text", x = 0, y = Inf, label = "δ = 0", vjust = -0.5,
           size = 3, colour = "grey40") +
  labs(title    = sprintf("Cliff's δ on RISK — %s vs %s", LABEL_A, LABEL_B),
       subtitle = paste0(
         "Points: δ · error bars: bootstrap 95% CI\n",
         "Dashed lines: |δ| = 0.147 (negligible boundary) · ",
         "dotted: |δ| = 0.33 (small/medium boundary)"),
       x = sprintf("Cliff's δ  (positive = %s > %s)", LABEL_A, LABEL_B),
       y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 7))

forest_file <- file.path(PLOTS_DIR, "forest_cliffs_delta_RISK.png")
ggsave(forest_file, p_forest,
       width  = 10,
       height = max(6, length(pest_order) * 0.22 + 2),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", forest_file))

# -- Risk matrix (overview): AI vs Human -------------------------------------
message("Building risk matrix...")

risk_summary <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]; b <- B$traces[[pest]]
  bind_rows(
    data.frame(pest = pest, source = LABEL_A,
               inv_q5 = qs(a$INVASIONA, 0.05),
               inv_median = qs(a$INVASIONA, 0.50),
               inv_q95 = qs(a$INVASIONA, 0.95),
               imp_q5 = qs(a$IMPACT, 0.05),
               imp_median = qs(a$IMPACT, 0.50),
               imp_q95 = qs(a$IMPACT, 0.95)),
    data.frame(pest = pest, source = LABEL_B,
               inv_q5 = qs(b$INVASIONA, 0.05),
               inv_median = qs(b$INVASIONA, 0.50),
               inv_q95 = qs(b$INVASIONA, 0.95),
               imp_q5 = qs(b$IMPACT, 0.05),
               imp_median = qs(b$IMPACT, 0.50),
               imp_q95 = qs(b$IMPACT, 0.95))
  )
}) %>%
  filter(!is.na(inv_median), !is.na(imp_median)) %>%
  mutate(source = factor(source, levels = c(LABEL_A, LABEL_B)))

xmax <- max(risk_summary$inv_q95, 0.1, na.rm = TRUE) * 1.05
ymax <- max(risk_summary$imp_q95, 0.1, na.rm = TRUE) * 1.05
grid_max <- max(xmax, ymax)

n_bins <- 4
step   <- grid_max / n_bins
grid <- expand.grid(ix = 0:(n_bins - 1), iy = 0:(n_bins - 1)) %>%
  mutate(xmin = ix * step, xmax = xmin + step,
         ymin = iy * step, ymax = ymin + step,
         Risk = ((xmin + xmax) / 2) * ((ymin + ymax) / 2),
         Risk_Area = cut(Risk,
                         breaks = c(-Inf, 0.05, 0.15, 0.30, Inf),
                         labels = c("Low", "Moderate", "High", "Severe")))

risk_fill <- c(Low = "#2ca02c", Moderate = "#f4e04d",
               High = "#ff7f0e", Severe = "#d62728")

pairs_df <- risk_summary %>%
  select(pest, source, inv_median, imp_median) %>%
  pivot_wider(names_from = source,
              values_from = c(inv_median, imp_median),
              names_glue = "{.value}__{source}") %>%
  filter(if_all(everything(), ~ !is.na(.x)))

col_invB <- paste0("inv_median__", LABEL_B)
col_impB <- paste0("imp_median__", LABEL_B)
col_invA <- paste0("inv_median__", LABEL_A)
col_impA <- paste0("imp_median__", LABEL_A)

p_risk <- ggplot() +
  geom_rect(data = grid,
            aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax,
                fill = Risk_Area),
            colour = "white", linewidth = 0.8, alpha = 0.55) +
  scale_fill_manual(values = risk_fill, name = "Risk category",
                    guide = guide_legend(order = 1,
                                         override.aes = list(alpha = 0.7))) +
  geom_segment(data = pairs_df,
               aes(x    = .data[[col_invB]], y    = .data[[col_impB]],
                   xend = .data[[col_invA]], yend = .data[[col_impA]]),
               colour = "grey30", linewidth = 0.35, alpha = 0.7,
               arrow = arrow(length = unit(0.10, "cm"), type = "closed")) +
  geom_errorbarh(data = risk_summary,
                 aes(y = imp_median, xmin = inv_q5, xmax = inv_q95,
                     colour = source),
                 height = 0, linewidth = 0.5, alpha = 0.65) +
  geom_errorbar(data = risk_summary,
                aes(x = inv_median, ymin = imp_q5, ymax = imp_q95,
                    colour = source),
                width = 0, linewidth = 0.5, alpha = 0.65) +
  geom_point(data = risk_summary,
             aes(x = inv_median, y = imp_median,
                 colour = source, shape = source),
             size = 2.6, stroke = 0.8) +
  scale_colour_manual(values = palette2, name = "Source",
                      guide = guide_legend(order = 2)) +
  scale_shape_manual(values = c(16, 17), name = "Source",
                     guide = guide_legend(order = 2)) +
  labs(title    = sprintf("Risk matrix — %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf(
         "%d shared pests · medians · bars: 5–95%% CI · arrow: %s → %s",
         nrow(pairs_df), LABEL_B, LABEL_A),
       x = "INVASION (scenario A)  —  ENTRY × ESTABLISHMENT",
       y = "IMPACT",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  theme_minimal(base_size = 14) +
  theme(plot.title       = element_text(size = 18, face = "bold", hjust = 0.5),
        plot.subtitle    = element_text(size = 12, margin = margin(b = 15),
                                        hjust = 0.5),
        axis.title       = element_text(face = "bold"),
        legend.position  = "bottom",
        legend.title     = element_text(face = "bold"),
        panel.grid.major = element_line(color = "grey90"),
        panel.grid.minor = element_blank()) +
  coord_fixed(xlim = c(0, xmax), ylim = c(0, ymax))

risk_file <- file.path(PLOTS_DIR,
                       sprintf("risk_matrix_%s_vs_%s.png", LABEL_A, LABEL_B))
ggsave(risk_file, p_risk, width = 10, height = 10, dpi = 150, bg = "white")
message(sprintf("Saved risk matrix: %s", risk_file))

message("\nDone.")