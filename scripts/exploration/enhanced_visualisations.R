################################################################################
# FinnPRIO: Enhanced Visualisations for AI vs Human comparison
#
# Companion to compare_simulation_traces_v2.R
# Loads the comparison_stats.csv and classification.csv outputs,
# then produces a suite of plots designed to answer:
#
#   1. "Overall, how different is the AI?"
#      → Signed Cliff's δ lollipop (per pest, on RISKA)
#      → Radar/profile plot of mean δ per TEASI component
#
#   2. "Where does the AI diverge most — which questions?"
#      → Signed normalised-Wasserstein heatmap (pest × variable)
#      → Variable-level δ strip plot showing spread across pests
#
#   3. "Is there a systematic bias?"
#      → Scatter: AI median vs Human median per variable
#      → Bland-Altman (difference vs average) per variable group
#
#   4. "How uncertain is each comparison?"
#      → Forest plot with bootstrap CIs (already in v2)
#      → Uncertainty ratio plot: IQR_AI / IQR_Human
#
#   5. "Can we group the pests by divergence pattern?"
#      → PCA/clustering on the δ profile across questions
#
################################################################################

library(tidyverse)
library(patchwork)  # install.packages("patchwork") if needed

# =============================================================================
# Paths — match compare_simulation_traces_v2.R outputs
STATS_CSV <- "./scripts/exploration/output/comparison_stats.csv"
CLASS_CSV <- "./scripts/exploration/output/classification.csv"
PLOTS_DIR <- "./scripts/exploration/output/plots"

LABEL_A <- "AI"
LABEL_B <- "Human"
# =============================================================================

stats  <- read.csv(STATS_CSV, stringsAsFactors = FALSE)
class_df <- read.csv(CLASS_CSV, stringsAsFactors = FALSE)

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
    legend.position     = "bottom",
    legend.title        = element_blank()
  )

# Core variables (the 18 TEASI questions + composites)
CORE_VARS <- c("ENT1", "ENTRYA", "ENTRYB",
               "EST1", "EST2", "EST3", "EST4", "SPR1", "ESTABLISHMENT",
               "INVASIONA", "INVASIONB",
               "IMP1", "IMP2", "IMP3", "IMP4", "IMPACT",
               "RISKA", "RISKB",
               "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
               "PREVENTABILITY", "CONTROLLABILITY", "MANAGEABILITY")

var_group <- function(v) {
  dplyr::case_when(
    v %in% c("ENT1","ENTRYA","ENTRYB")                            ~ "1. Entry",
    v %in% c("EST1","EST2","EST3","EST4","SPR1","ESTABLISHMENT")   ~ "2. Establishment",
    v %in% c("INVASIONA","INVASIONB")                              ~ "3. Invasion",
    v %in% c("IMP1","IMP2","IMP3","IMP4","IMPACT")                 ~ "4. Impact",
    v %in% c("RISKA","RISKB")                                      ~ "5. Risk",
    TRUE                                                           ~ "6. Manageability")
}

# Filter to core variables
core_stats <- stats %>%
  filter(variable %in% CORE_VARS) %>%
  mutate(group = var_group(variable),
         variable = factor(variable, levels = CORE_VARS))


# =============================================================================
# PLOT 1 — Signed lollipop: Cliff's δ per pest on RISKA
# =============================================================================
message("Plot 1: Cliff's δ lollipop on RISKA...")

risk_stats <- core_stats %>%
  filter(variable == "RISKA") %>%
  arrange(cliffs_delta) %>%
  mutate(pest = factor(pest, levels = pest),
         direction = case_when(
           is.na(cliffs_delta)      ~ "NA",
           abs(cliffs_delta) < 0.147 ~ "Similar",
           cliffs_delta > 0         ~ sprintf("%s higher", LABEL_A),
           TRUE                     ~ sprintf("%s lower",  LABEL_A)),
         direction = factor(direction,
                            levels = c(sprintf("%s lower", LABEL_A),
                                       "Similar",
                                       sprintf("%s higher", LABEL_A),
                                       "NA")))

dir_fill <- c(setNames(c("#4DBBD5", "#AAAAAA", "#E64B35"),
                       c(sprintf("%s lower", LABEL_A),
                         "Similar",
                         sprintf("%s higher", LABEL_A))),
              "NA" = "grey80")

p1 <- ggplot(risk_stats, aes(x = cliffs_delta, y = pest, colour = direction)) +
  geom_vline(xintercept = 0, colour = "grey50") +
  geom_vline(xintercept = c(-0.147, 0.147), linetype = "dashed",
             colour = "grey75", linewidth = 0.3) +
  geom_segment(aes(x = 0, xend = cliffs_delta, y = pest, yend = pest),
               linewidth = 0.6) +
  geom_point(size = 2.2) +
  scale_colour_manual(values = dir_fill, drop = FALSE) +
  labs(title = sprintf("Overall risk divergence: %s vs %s", LABEL_A, LABEL_B),
       subtitle = "Cliff's δ on RISKA · dashed = ±0.147 negligible boundary",
       x = sprintf("Cliff's δ  (← %s lower risk   |   %s higher risk →)",
                   LABEL_A, LABEL_A),
       y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 6.5))

ggsave(file.path(PLOTS_DIR, "01_lollipop_risk_delta.png"), p1,
       width = 10, height = max(6, nrow(risk_stats) * 0.2 + 2),
       dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 2 — Variable-level profile: mean |δ| per question across all pests
#           Shows WHERE the AI tends to diverge (which questions)
# =============================================================================
message("Plot 2: Mean |δ| per variable (profile plot)...")

var_profile <- core_stats %>%
  filter(!is.na(cliffs_delta)) %>%
  group_by(variable, group) %>%
  summarise(
    mean_abs_delta  = mean(abs(cliffs_delta)),
    mean_delta      = mean(cliffs_delta),
    median_delta    = median(cliffs_delta),
    n_pests         = n(),
    pct_higher = mean(cliffs_delta > 0.147) * 100,
    pct_lower  = mean(cliffs_delta < -0.147) * 100,
    pct_similar     = 100 - pct_higher - pct_lower,
    .groups = "drop"
  ) %>%
  arrange(desc(mean_abs_delta))

p2 <- ggplot(var_profile, aes(x = reorder(variable, mean_abs_delta),
                              y = mean_abs_delta, fill = group)) +
  geom_col(width = 0.7) +
  geom_hline(yintercept = 0.147, linetype = "dashed", colour = "grey50") +
  annotate("text", x = 0.5, y = 0.155, label = "negligible\nthreshold",
           hjust = 0, size = 2.5, colour = "grey45") +
  coord_flip() +
  scale_fill_brewer(palette = "Set2") +
  labs(title = "Which questions drive AI–Human divergence?",
       subtitle = "Mean |Cliff's δ| across all pests per variable",
       x = NULL, y = "Mean |Cliff's δ|",
       fill = "TEASI component",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme

ggsave(file.path(PLOTS_DIR, "02_variable_divergence_profile.png"), p2,
       width = 10, height = 8, dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 3 — Signed δ strip plot: distribution of δ across pests, per variable
#           Shows both WHERE and DIRECTION of divergence
# =============================================================================
message("Plot 3: Signed δ strip plot...")

strip_df <- core_stats %>%
  filter(!is.na(cliffs_delta)) %>%
  mutate(group = var_group(as.character(variable)))

p3 <- ggplot(strip_df, aes(x = variable, y = cliffs_delta)) +
  geom_hline(yintercept = 0, colour = "grey50") +
  geom_hline(yintercept = c(-0.147, 0.147), linetype = "dashed",
             colour = "grey70", linewidth = 0.3) +
  geom_jitter(aes(colour = group), width = 0.2, alpha = 0.5, size = 1.5) +
  geom_boxplot(width = 0.5, alpha = 0.3, outlier.shape = NA,
               colour = "grey30", fill = NA, linewidth = 0.4) +
  facet_wrap(~ group, scales = "free_x", nrow = 1) +
  scale_colour_brewer(palette = "Set2", guide = "none") +
  labs(title = sprintf("Cliff's δ distribution per question — %s vs %s",
                       LABEL_A, LABEL_B),
       subtitle = sprintf(
         "Each dot = 1 pest · above 0 = %s higher · dashed = ±0.147 negligible",
         LABEL_A),
       x = NULL,
       y = sprintf("Cliff's δ  (← %s lower | %s higher →)", LABEL_A, LABEL_A),
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 55, hjust = 1, size = 7),
        strip.text  = element_text(size = 8))

ggsave(file.path(PLOTS_DIR, "03_delta_strip_by_variable.png"), p3,
       width = 16, height = 7, dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 4 — Signed heatmap: Cliff's δ per pest × variable
#           Diverging colour scale (blue = AI lower, red = AI higher)
# =============================================================================
message("Plot 4: Signed δ heatmap...")

# Order pests by RISKA delta
pest_order_risk <- core_stats %>%
  filter(variable == "RISKA") %>%
  arrange(cliffs_delta) %>%
  pull(pest)

# Fall back: if some pests lack RISKA, append them
all_pests <- unique(core_stats$pest)
pest_order_risk <- c(pest_order_risk,
                     setdiff(all_pests, pest_order_risk))

heat_signed <- core_stats %>%
  filter(!is.na(cliffs_delta)) %>%
  mutate(pest = factor(pest, levels = rev(pest_order_risk)),
         variable = factor(variable, levels = CORE_VARS))

# Symmetric colour limit
dlim <- max(abs(heat_signed$cliffs_delta), na.rm = TRUE)

p4 <- ggplot(heat_signed, aes(variable, pest, fill = cliffs_delta)) +
  geom_tile(colour = "white", linewidth = 0.15) +
  scale_fill_gradient2(low = "#4DBBD5", mid = "grey95", high = "#E64B35",
                       midpoint = 0, limits = c(-dlim, dlim),
                       name = "Cliff's δ") +
  labs(title = sprintf("AI divergence profile — %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf(
         "Blue = %s lower · Red = %s higher · sorted by RISKA δ · %d pests",
         LABEL_A, LABEL_A, length(pest_order_risk)),
       x = NULL, y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 60, hjust = 1, size = 8),
        axis.text.y = element_text(face = "italic", size = 6),
        panel.grid  = element_blank())

ggsave(file.path(PLOTS_DIR, "04_heatmap_signed_delta.png"), p4,
       width  = max(11, length(CORE_VARS) * 0.5),
       height = max(8,  length(pest_order_risk) * 0.18 + 2),
       dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 5 — Bland-Altman: difference vs average (per variable group)
#           Classic agreement plot — shows if bias scales with magnitude
# =============================================================================
message("Plot 5: Bland-Altman plots...")

ba_df <- core_stats %>%
  filter(!is.na(median_A), !is.na(median_B)) %>%
  mutate(average    = (median_A + median_B) / 2,
         difference = median_A - median_B,
         group      = var_group(as.character(variable)))

# One Bland-Altman per group
for (grp in sort(unique(ba_df$group))) {
  d <- filter(ba_df, group == grp)
  if (nrow(d) < 3) next
  
  mean_diff <- mean(d$difference, na.rm = TRUE)
  sd_diff   <- sd(d$difference, na.rm = TRUE)
  loa_upper <- mean_diff + 1.96 * sd_diff
  loa_lower <- mean_diff - 1.96 * sd_diff
  
  p_ba <- ggplot(d, aes(x = average, y = difference)) +
    geom_hline(yintercept = 0, colour = "grey50") +
    geom_hline(yintercept = mean_diff, linetype = "dashed",
               colour = "#E64B35", linewidth = 0.5) +
    geom_hline(yintercept = c(loa_lower, loa_upper), linetype = "dotted",
               colour = "#E64B35", linewidth = 0.4) +
    geom_point(aes(colour = variable), alpha = 0.6, size = 2) +
    scale_colour_brewer(palette = "Dark2") +
    annotate("text", x = Inf, y = mean_diff, label = sprintf("bias = %.3f", mean_diff),
             hjust = 1.1, vjust = -0.5, size = 3, colour = "#E64B35") +
    annotate("text", x = Inf, y = loa_upper, label = "+1.96 SD",
             hjust = 1.1, vjust = -0.5, size = 2.5, colour = "#E64B35") +
    annotate("text", x = Inf, y = loa_lower, label = "−1.96 SD",
             hjust = 1.1, vjust = 1.5, size = 2.5, colour = "#E64B35") +
    labs(title = sprintf("Bland-Altman: %s — %s vs %s",
                         gsub("^[0-9]+\\. ", "", grp), LABEL_A, LABEL_B),
         subtitle = "Each dot = 1 pest × variable · dashed = mean bias · dotted = limits of agreement",
         x = sprintf("Average of %s and %s medians", LABEL_A, LABEL_B),
         y = sprintf("Difference (%s − %s)", LABEL_A, LABEL_B),
         colour = "Variable",
         caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
    pretty_theme
  
  grp_clean <- gsub("^[0-9]+\\. ", "", grp) %>% tolower()
  ggsave(file.path(PLOTS_DIR, sprintf("05_bland_altman_%s.png", grp_clean)),
         p_ba, width = 10, height = 7, dpi = 150, bg = "white")
}
message("  Saved.")


# =============================================================================
# PLOT 6 — Uncertainty ratio: IQR_AI / IQR_Human per variable
#           Shows whether the AI is more or less certain than humans
# =============================================================================
message("Plot 6: Uncertainty ratio...")

iqr_df <- core_stats %>%
  filter(!is.na(iqr_ratio), is.finite(iqr_ratio), iqr_ratio > 0) %>%
  mutate(log_ratio = log2(iqr_ratio))

p6 <- ggplot(iqr_df, aes(x = variable, y = log_ratio)) +
  geom_hline(yintercept = 0, colour = "grey50") +
  geom_jitter(aes(colour = group), width = 0.2, alpha = 0.5, size = 1.5) +
  geom_boxplot(width = 0.5, alpha = 0.3, outlier.shape = NA,
               colour = "grey30", fill = NA, linewidth = 0.4) +
  facet_wrap(~ group, scales = "free_x", nrow = 1) +
  scale_colour_brewer(palette = "Set2", guide = "none") +
  labs(title = sprintf("Uncertainty comparison: %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf(
         "log₂(IQR_%s / IQR_%s) · above 0 = %s more uncertain · below 0 = %s more precise",
         LABEL_A, LABEL_B, LABEL_A, LABEL_A),
       x = NULL,
       y = sprintf("log₂(IQR ratio)  ← %s more precise | %s more uncertain →",
                   LABEL_A, LABEL_A),
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 55, hjust = 1, size = 7))

ggsave(file.path(PLOTS_DIR, "06_uncertainty_ratio.png"), p6,
       width = 16, height = 7, dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 7 — PCA on δ profiles: group pests by divergence pattern
# =============================================================================
message("Plot 7: PCA clustering of divergence profiles...")

# Build a pest × variable matrix of Cliff's δ
CLUSTER_VARS <- c("ENT1", "EST1", "EST2", "EST3", "EST4", "SPR1",
                  "IMP1", "IMP2", "IMP3", "IMP4",
                  "MAN1", "MAN2", "MAN3", "MAN4", "MAN5")

delta_wide <- core_stats %>%
  filter(variable %in% CLUSTER_VARS, !is.na(cliffs_delta)) %>%
  select(pest, variable, cliffs_delta) %>%
  pivot_wider(names_from = variable, values_from = cliffs_delta)

# Drop pests with any missing variable
delta_mat <- delta_wide %>%
  column_to_rownames("pest") %>%
  drop_na()

if (nrow(delta_mat) >= 5 && ncol(delta_mat) >= 3) {
  pca <- prcomp(delta_mat, scale. = TRUE, center = TRUE)
  
  pca_df <- as.data.frame(pca$x[, 1:2]) %>%
    rownames_to_column("pest")
  
  # K-means clustering (3 groups: lower / similar / higher pattern)
  set.seed(42)
  k <- min(4, nrow(delta_mat) - 1)
  km <- kmeans(pca$x[, 1:min(5, ncol(pca$x))], centers = k, nstart = 25)
  pca_df$cluster <- factor(km$cluster)
  
  # Loadings for biplot arrows
  rot <- as.data.frame(pca$rotation[, 1:2]) %>%
    rownames_to_column("variable") %>%
    mutate(group = var_group(variable))
  
  var_explained <- summary(pca)$importance[2, 1:2] * 100
  
  p7 <- ggplot(pca_df, aes(PC1, PC2)) +
    geom_hline(yintercept = 0, colour = "grey85") +
    geom_vline(xintercept = 0, colour = "grey85") +
    # Loadings as arrows
    geom_segment(data = rot,
                 aes(x = 0, y = 0, xend = PC1 * 4, yend = PC2 * 4),
                 arrow = arrow(length = unit(0.15, "cm")),
                 colour = "grey55", linewidth = 0.3, alpha = 0.7) +
    geom_text(data = rot,
              aes(x = PC1 * 4.3, y = PC2 * 4.3, label = variable,
                  colour = group),
              size = 2.8) +
    # Pest points
    geom_point(aes(fill = cluster), shape = 21, size = 3.5,
               colour = "grey25", stroke = 0.5) +
    ggrepel::geom_text_repel(aes(label = pest), size = 2.2,
                             fontface = "italic", colour = "grey30",
                             max.overlaps = 15, segment.size = 0.2) +
    scale_fill_brewer(palette = "Set1", name = "Cluster") +
    scale_colour_brewer(palette = "Set2", name = "Variable group") +
    labs(title = "Divergence patterns across pests (PCA + k-means)",
         subtitle = sprintf(
           "PC1 = %.0f%% · PC2 = %.0f%% of variance · %d pests × %d questions · k = %d clusters",
           var_explained[1], var_explained[2],
           nrow(delta_mat), ncol(delta_mat), k),
         x = sprintf("PC1 (%.0f%%)", var_explained[1]),
         y = sprintf("PC2 (%.0f%%)", var_explained[2]),
         caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
    pretty_theme +
    theme(legend.position = "right")
  
  ggsave(file.path(PLOTS_DIR, "07_pca_divergence_profiles.png"), p7,
         width = 13, height = 10, dpi = 150, bg = "white")
  message("  Saved.")
} else {
  message("  Skipped PCA: not enough complete cases.")
}


# =============================================================================
# PLOT 8 — Stacked direction bar: per variable, % pests in each category
# =============================================================================
message("Plot 8: Direction summary per variable...")

dir_by_var <- core_stats %>%
  filter(!is.na(cliffs_delta)) %>%
  mutate(
    direction = case_when(
      abs(cliffs_delta) < 0.147 ~ "Similar",
      cliffs_delta > 0          ~ sprintf("%s higher", LABEL_A),
      TRUE                      ~ sprintf("%s lower",  LABEL_A)),
    direction = factor(direction,
                       levels = c(sprintf("%s lower", LABEL_A),
                                  "Similar",
                                  sprintf("%s higher", LABEL_A))),
    group = var_group(as.character(variable))
  ) %>%
  count(variable, group, direction, .drop = FALSE) %>%
  group_by(variable) %>%
  mutate(pct = n / sum(n) * 100) %>%
  ungroup()

dir_fill_3 <- c(setNames(c("#4DBBD5", "#CCCCCC", "#E64B35"),
                         c(sprintf("%s lower", LABEL_A),
                           "Similar",
                           sprintf("%s higher", LABEL_A))))

p8 <- ggplot(dir_by_var, aes(x = variable, y = pct, fill = direction)) +
  geom_col(position = "stack", colour = "white", linewidth = 0.3) +
  geom_text(aes(label = ifelse(pct >= 5, sprintf("%.0f%%", pct), "")),
            position = position_stack(vjust = 0.5),
            size = 2.5, colour = "grey15") +
  facet_wrap(~ group, scales = "free_x", nrow = 1) +
  scale_fill_manual(values = dir_fill_3, name = sprintf("vs %s", LABEL_B)) +
  labs(title = sprintf("Per-question agreement: %s vs %s", LABEL_A, LABEL_B),
       subtitle = "% of pests where AI scores lower, similar, or higher (|δ| < 0.147 = similar)",
       x = NULL, y = "% of pests",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 55, hjust = 1, size = 7))

ggsave(file.path(PLOTS_DIR, "08_direction_by_variable.png"), p8,
       width = 16, height = 7, dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
# PLOT 9 — Scatter: AI median vs Human median (coloured by divergence)
#           One facet per TEASI component
# =============================================================================
message("Plot 9: Median scatter plots...")

SCATTER_VARS <- c("INVASIONA", "ESTABLISHMENT", "IMPACT", "RISKA")
SCATTER_LABELS <- c("INVASION (A)", "ESTABLISHMENT", "IMPACT", "RISK (A)")

scatter_df <- core_stats %>%
  filter(variable %in% SCATTER_VARS) %>%
  mutate(variable = factor(variable, levels = SCATTER_VARS,
                           labels = SCATTER_LABELS),
         divergent = !is.na(cliffs_delta) & abs(cliffs_delta) >= 0.147)

p9 <- ggplot(scatter_df, aes(x = median_B, y = median_A)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey60") +
  geom_point(aes(colour = divergent), size = 2.5, alpha = 0.7) +
  ggrepel::geom_text_repel(
    data = filter(scatter_df, divergent),
    aes(label = pest), size = 2, fontface = "italic",
    max.overlaps = 10, segment.size = 0.2, colour = "grey30") +
  facet_wrap(~ variable, scales = "free") +
  scale_colour_manual(values = c("TRUE" = "#E64B35", "FALSE" = "grey70"),
                      labels = c("|δ| < 0.147", "|δ| ≥ 0.147"),
                      name = "Divergence") +
  labs(title = sprintf("Median comparison: %s vs %s", LABEL_A, LABEL_B),
       subtitle = "Dashed = perfect agreement · red = divergent pests (|Cliff's δ| ≥ 0.147)",
       x = sprintf("%s median", LABEL_B),
       y = sprintf("%s median", LABEL_A),
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(legend.position = "bottom")

ggsave(file.path(PLOTS_DIR, "09_median_scatter.png"), p9,
       width = 12, height = 10, dpi = 150, bg = "white")
message("  Saved.")


# =============================================================================
message("\nAll enhanced plots saved to: ", PLOTS_DIR)


# =============================================================================
# PLOT 10 — Interactive risk matrix (plotly) with hover-highlight
#           Hover any point → that pest's AI point, Human point, and
#           connecting dashed line all light up; everything else dims.
#
# Requires: plotly, htmlwidgets, jsonlite
# Paste this block into enhanced_visualisations.R (after loading data)
# =============================================================================
message("Plot 10: Interactive risk matrix (plotly)...")

if (!requireNamespace("plotly", quietly = TRUE)) install.packages("plotly")
if (!requireNamespace("htmlwidgets", quietly = TRUE)) install.packages("htmlwidgets")
if (!requireNamespace("jsonlite", quietly = TRUE)) install.packages("jsonlite")
library(plotly)
library(htmlwidgets)
library(jsonlite)

# -- Rebuild risk_summary from traces (needs A, B objects from v2 script) ------
if (exists("A") && exists("B") && exists("common_pests")) {
  
  qs <- function(x, p) quantile(x, p, na.rm = TRUE, names = FALSE)
  
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
  
} else {
  inv_stats <- stats %>% filter(variable == "INVASIONA") %>%
    select(pest, inv_median_A = median_A, inv_median_B = median_B)
  imp_stats <- stats %>% filter(variable == "IMPACT") %>%
    select(pest, imp_median_A = median_A, imp_median_B = median_B)

  # Column names are now <value>_(A|B), so pivot produces inv_median & imp_median
  risk_summary <- inv_stats %>%
    inner_join(imp_stats, by = "pest") %>%
    pivot_longer(cols = -pest,
                 names_to = c(".value", "source"),
                 names_pattern = "(.+)_(A|B)") %>%
    mutate(source = ifelse(source == "A", LABEL_A, LABEL_B),
           inv_q5 = NA, inv_q95 = NA, imp_q5 = NA, imp_q95 = NA,
           source = factor(source, levels = c(LABEL_A, LABEL_B)))
}

# -- Join classification data for hover info ----------------------------------
risk_delta <- class_df %>%
  select(pest, delta_RISK, magnitude_RISK, direction,
         starts_with("delta_")) %>%
  distinct(pest, .keep_all = TRUE)

# -- Build paired data -------------------------------------------------------
pairs_wide <- risk_summary %>%
  select(pest, source, inv_median, imp_median) %>%
  pivot_wider(names_from = source,
              values_from = c(inv_median, imp_median),
              names_glue = "{.value}__{source}") %>%
  left_join(risk_delta, by = "pest")

col_invA <- paste0("inv_median__", LABEL_A)
col_impA <- paste0("imp_median__", LABEL_A)
col_invB <- paste0("inv_median__", LABEL_B)
col_impB <- paste0("imp_median__", LABEL_B)

# -- Axis limits --------------------------------------------------------------
xmax <- 1
ymax <- 1

# -- Risk zone grid (3×3, matching FinnPRIO risk matrix) ----------------------
# Breaks at 1/3 and 2/3 on both axes
# Risk categories follow the diagonal pattern from the reference figure:
#   Bottom-left  = Very low risk
#   Anti-diagonal low = Low risk
#   Middle diagonal  = Moderate risk
#   Anti-diagonal high = High risk
#   Top-right    = Very high risk

grid <- tribble(
  ~xmin, ~xmax, ~ymin, ~ymax, ~Risk_Area,
  0,     1/3,   0,     1/3,   "Very low",
  1/3,   2/3,   0,     1/3,   "Low",
  2/3,   1,     0,     1/3,   "Moderate",
  0,     1/3,   1/3,   2/3,   "Low",
  1/3,   2/3,   1/3,   2/3,   "Moderate",
  2/3,   1,     1/3,   2/3,   "High",
  0,     1/3,   2/3,   1,     "Moderate",
  1/3,   2/3,   2/3,   1,     "High",
  2/3,   1,     2/3,   1,     "Very high"
)

risk_colours <- c(
  "Very low"  = "rgba(34,139,34,0.30)",
  "Low"       = "rgba(44,160,44,0.25)",
  "Moderate"  = "rgba(244,224,77,0.35)",
  "High"      = "rgba(255,127,14,0.30)",
  "Very high" = "rgba(214,39,40,0.30)"
)

colour_A <- "#E64B35"
colour_B <- "#4DBBD5"

# -- Build plotly figure ------------------------------------------------------
fig <- plot_ly() %>%
  layout(
    title = list(
      text = sprintf(
        "<b>Risk Matrix — %s vs %s</b><br><sup>Hover to highlight species pair · Dashed lines: %s → %s</sup>",
        LABEL_A, LABEL_B, LABEL_B, LABEL_A),
      font = list(family = "Libre Franklin, Helvetica, sans-serif", size = 18)
    ),
    xaxis = list(
      title = list(text = "<b>INVASION (A)</b>  —  ENTRY × ESTABLISHMENT",
                   font = list(size = 13)),
      range = c(0, xmax),
      gridcolor = "rgba(0,0,0,0.06)",
      zeroline = FALSE
    ),
    yaxis = list(
      title = list(text = "<b>IMPACT</b>",
                   font = list(size = 13)),
      range = c(0, ymax),
      gridcolor = "rgba(0,0,0,0.06)",
      zeroline = FALSE
    ),
    plot_bgcolor = "white",
    paper_bgcolor = "white",
    legend = list(
      orientation = "h", x = 0.5, xanchor = "center", y = -0.08,
      font = list(size = 12)
    ),
    margin = list(t = 80, b = 80),
    hoverlabel = list(
      bgcolor = "white",
      bordercolor = "grey",
      font = list(family = "Fira Code, monospace", size = 12)
    ),
    hovermode = "closest"
  )

# Risk zone rectangles (as layout shapes — no scatter trace warnings)
risk_shapes <- lapply(seq_len(nrow(grid)), function(i) {
  list(
    type = "rect",
    x0 = grid$xmin[i], x1 = grid$xmax[i],
    y0 = grid$ymin[i], y1 = grid$ymax[i],
    xref = "x", yref = "y",
    fillcolor = risk_colours[as.character(grid$Risk_Area[i])],
    line = list(color = "white", width = 1.5),
    layer = "below"
  )
})

# Risk zone labels in center of each cell
risk_annotations <- lapply(seq_len(nrow(grid)), function(i) {
  list(
    x = (grid$xmin[i] + grid$xmax[i]) / 2,
    y = (grid$ymin[i] + grid$ymax[i]) / 2,
    text = as.character(grid$Risk_Area[i]),
    showarrow = FALSE,
    font = list(size = 10, color = "rgba(0,0,0,0.18)",
                family = "Libre Franklin, Helvetica, sans-serif"),
    xref = "x", yref = "y"
  )
})

fig <- fig %>% layout(shapes = risk_shapes, annotations = risk_annotations)
n_bg_traces <- 0  # no scatter traces used for grid

# Dashed connector lines — one trace per pest
for (i in seq_len(nrow(pairs_wide))) {
  fig <- fig %>% add_trace(
    type = "scatter", mode = "lines",
    x = c(pairs_wide[[col_invB]][i], pairs_wide[[col_invA]][i]),
    y = c(pairs_wide[[col_impB]][i], pairs_wide[[col_impA]][i]),
    line = list(color = "rgba(100,100,100,0.35)", width = 1.3, dash = "dash"),
    showlegend = FALSE,
    hoverinfo = "skip"
  )
}
n_line_traces <- nrow(pairs_wide)

# Prepare hover text
plot_data <- risk_summary %>%
  left_join(risk_delta, by = "pest") %>%
  mutate(
    hover_text = sprintf(
      "<b><i>%s</i></b><br>Source: %s<br>INVASION median: %.4f<br>IMPACT median: %.4f<br>Cliff's δ (RISK): %s<br>Magnitude: %s<br>Direction: %s",
      pest, source,
      inv_median, imp_median,
      ifelse(is.na(delta_RISK), "NA", sprintf("%.3f", delta_RISK)),
      ifelse(is.na(magnitude_RISK), "NA", magnitude_RISK),
      ifelse(is.na(direction), "NA", as.character(direction))
    )
  )

data_A <- filter(plot_data, source == LABEL_A)
data_B <- filter(plot_data, source == LABEL_B)

# AI points
has_ci <- all(c("inv_q5", "inv_q95") %in% names(data_A)) && !all(is.na(data_A$inv_q5))
ai_args <- list(
  data = data_A, type = "scatter", mode = "markers",
  x = ~inv_median, y = ~imp_median,
  marker = list(color = colour_A, size = 9, symbol = "circle",
                line = list(color = "white", width = 1)),
  text = ~hover_text, hoverinfo = "text",
  customdata = ~pest,
  name = LABEL_A
)
if (has_ci) {
  ai_args$error_x <- list(type = "data",
                          array = data_A$inv_q95 - data_A$inv_median,
                          arrayminus = data_A$inv_median - data_A$inv_q5,
                          color = colour_A, thickness = 1, width = 0)
  ai_args$error_y <- list(type = "data",
                          array = data_A$imp_q95 - data_A$imp_median,
                          arrayminus = data_A$imp_median - data_A$imp_q5,
                          color = colour_A, thickness = 1, width = 0)
}
fig <- do.call(add_trace, c(list(p = fig), ai_args))

# Human points
hu_args <- list(
  data = data_B, type = "scatter", mode = "markers",
  x = ~inv_median, y = ~imp_median,
  marker = list(color = colour_B, size = 9, symbol = "triangle-up",
                line = list(color = "white", width = 1)),
  text = ~hover_text, hoverinfo = "text",
  customdata = ~pest,
  name = LABEL_B
)
if (has_ci) {
  hu_args$error_x <- list(type = "data",
                          array = data_B$inv_q95 - data_B$inv_median,
                          arrayminus = data_B$inv_median - data_B$inv_q5,
                          color = colour_B, thickness = 1, width = 0)
  hu_args$error_y <- list(type = "data",
                          array = data_B$imp_q95 - data_B$imp_median,
                          arrayminus = data_B$imp_median - data_B$imp_q5,
                          color = colour_B, thickness = 1, width = 0)
}
fig <- do.call(add_trace, c(list(p = fig), hu_args))

ai_trace_idx <- n_bg_traces + n_line_traces
human_trace_idx <- ai_trace_idx + 1

# Risk zone legend (fake traces — use numeric(0) to avoid "Ignoring" warnings)
for (zone in c("Very low", "Low", "Moderate", "High", "Very high")) {
  zone_col <- c("Very low"  = "rgba(34,139,34,0.6)",
                "Low"       = "rgba(44,160,44,0.5)",
                "Moderate"  = "rgba(244,224,77,0.6)",
                "High"      = "rgba(255,127,14,0.5)",
                "Very high" = "rgba(214,39,40,0.5)")
  fig <- fig %>% add_trace(
    type = "scatter", mode = "markers",
    x = numeric(0), y = numeric(0),
    marker = list(color = zone_col[zone], size = 12, symbol = "square"),
    name = sprintf("Risk: %s", zone),
    showlegend = TRUE, hoverinfo = "skip"
  )
}

# ============================================================================
# JavaScript: hover-highlight logic
# ============================================================================

# Build pest → { line_trace_idx, ai_point_idx, human_point_idx } lookup
pest_lookup <- list()
for (i in seq_along(pairs_wide$pest)) {
  p <- pairs_wide$pest[i]
  ai_idx <- which(data_A$pest == p) - 1    # 0-indexed
  hu_idx <- which(data_B$pest == p) - 1
  pest_lookup[[p]] <- list(
    line = unname(n_bg_traces + i - 1),     # 0-indexed trace index
    ai   = if (length(ai_idx) > 0) ai_idx[1] else -1,
    hu   = if (length(hu_idx) > 0) hu_idx[1] else -1
  )
}

js_lookup <- jsonlite::toJSON(pest_lookup, auto_unbox = TRUE)

highlight_js <- sprintf('
function(el) {
  var lookup = %s;
  var nBg    = %d;
  var nLines = %d;
  var aiTr   = %d;
  var huTr   = %d;
  var active = false;

  el.on("plotly_hover", function(ev) {
    var pest = ev.points[0].customdata;
    if (!pest || !lookup[pest]) return;
    active = true;
    var info = lookup[pest];

    var nAi = el.data[aiTr].x.length;
    var nHu = el.data[huTr].x.length;

    // --- Dim all connector lines, highlight the one ---
    var lineUpdates = [];
    var lineIndices = [];
    for (var i = nBg; i < nBg + nLines; i++) {
      lineIndices.push(i);
      if (i === info.line) {
        lineUpdates.push({
          "line.color": "rgba(40,40,40,0.85)",
          "line.width": 2.8
        });
      } else {
        lineUpdates.push({
          "line.color": "rgba(200,200,200,0.10)",
          "line.width": 0.7
        });
      }
    }
    for (var j = 0; j < lineIndices.length; j++) {
      Plotly.restyle(el, lineUpdates[j], [lineIndices[j]]);
    }

    // --- Dim all AI points, highlight the one ---
    var aiCol  = new Array(nAi).fill("rgba(230,75,53,0.10)");
    var aiSz   = new Array(nAi).fill(5);
    var aiLW   = new Array(nAi).fill(0);
    var aiLC   = new Array(nAi).fill("rgba(0,0,0,0)");
    if (info.ai >= 0 && info.ai < nAi) {
      aiCol[info.ai]  = "#E64B35";
      aiSz[info.ai]   = 14;
      aiLW[info.ai]   = 2.5;
      aiLC[info.ai]   = "#222";
    }
    Plotly.restyle(el, {
      "marker.color":      [aiCol],
      "marker.size":       [aiSz],
      "marker.line.width": [aiLW],
      "marker.line.color": [aiLC]
    }, [aiTr]);

    // --- Dim all Human points, highlight the one ---
    var huCol  = new Array(nHu).fill("rgba(77,187,213,0.10)");
    var huSz   = new Array(nHu).fill(5);
    var huLW   = new Array(nHu).fill(0);
    var huLC   = new Array(nHu).fill("rgba(0,0,0,0)");
    if (info.hu >= 0 && info.hu < nHu) {
      huCol[info.hu]  = "#4DBBD5";
      huSz[info.hu]   = 14;
      huLW[info.hu]   = 2.5;
      huLC[info.hu]   = "#222";
    }
    Plotly.restyle(el, {
      "marker.color":      [huCol],
      "marker.size":       [huSz],
      "marker.line.width": [huLW],
      "marker.line.color": [huLC]
    }, [huTr]);
  });

  el.on("plotly_unhover", function() {
    if (!active) return;
    active = false;

    // Restore all connector lines
    for (var i = nBg; i < nBg + nLines; i++) {
      Plotly.restyle(el, {
        "line.color": "rgba(100,100,100,0.35)",
        "line.width": 1.3
      }, [i]);
    }

    var nAi = el.data[aiTr].x.length;
    var nHu = el.data[huTr].x.length;

    // Restore AI markers
    Plotly.restyle(el, {
      "marker.color":      [new Array(nAi).fill("#E64B35")],
      "marker.size":       [new Array(nAi).fill(9)],
      "marker.line.width": [new Array(nAi).fill(1)],
      "marker.line.color": [new Array(nAi).fill("white")]
    }, [aiTr]);

    // Restore Human markers
    Plotly.restyle(el, {
      "marker.color":      [new Array(nHu).fill("#4DBBD5")],
      "marker.size":       [new Array(nHu).fill(9)],
      "marker.line.width": [new Array(nHu).fill(1)],
      "marker.line.color": [new Array(nHu).fill("white")]
    }, [huTr]);
  });
}
', js_lookup, n_bg_traces, n_line_traces, ai_trace_idx, human_trace_idx)

fig <- fig %>% htmlwidgets::onRender(highlight_js)

# Save
interactive_file <- file.path(PLOTS_DIR, "10_risk_matrix_interactive.html")
htmlwidgets::saveWidget(
  fig, interactive_file,
  selfcontained = TRUE,
  title = sprintf("Risk Matrix — %s vs %s", LABEL_A, LABEL_B)
)
message(sprintf("Saved interactive risk matrix: %s", interactive_file))

# Save as RDS for embedding in R Markdown presentations
rds_file <- file.path(PLOTS_DIR, "plotly_risk_matrix.rds")
saveRDS(fig, rds_file)
message(sprintf("Saved plotly RDS: %s", rds_file))

if (interactive()) print(fig)


# -------------------------------------------------------------------------

# =============================================================================
# PLOT 11 — Risk category shift: slope graph
#
# For each pest, assigns a FinnPRIO 3×3 risk category based on the median
# INVASION(A) and IMPACT scores, separately for AI and Human. Then shows:
#   - A slope graph: Human category (left) → AI category (right)
#   - Lines coloured by shift direction (AI higher / AI lower / Same)
#   - Species labels on shifted pests
#   - A summary table of category transitions
#
# Paste into enhanced_visualisations.R (after loading data + stats)
# =============================================================================
message("Plot 11: Risk category shift slope graph...")

# -- Assign risk categories ---------------------------------------------------
# FinnPRIO 3×3 grid: breaks at 1/3, 2/3 on both INVASION and IMPACT axes
# Risk follows the diagonal pattern:
#   (low inv, low imp) = Very low
#   (low, mid) or (mid, low) = Low
#   (low, high) or (mid, mid) or (high, low) = Moderate
#   (mid, high) or (high, mid) = High
#   (high, high) = Very high

assign_risk_category <- function(invasion, impact) {
  inv_bin <- cut(invasion, breaks = c(-Inf, 1/3, 2/3, Inf),
                 labels = c("L", "M", "H"), right = FALSE)
  imp_bin <- cut(impact,   breaks = c(-Inf, 1/3, 2/3, Inf),
                 labels = c("L", "M", "H"), right = FALSE)
  combo <- paste0(as.character(inv_bin), as.character(imp_bin))
  dplyr::case_when(
    combo == "LL"                          ~ "Very low",
    combo %in% c("ML", "LM")              ~ "Low",
    combo %in% c("HL", "MM", "LH")        ~ "Moderate",
    combo %in% c("HM", "MH")              ~ "High",
    combo == "HH"                          ~ "Very high",
    TRUE                                   ~ NA_character_
  )
}

RISK_LEVELS <- c("Very low", "Low", "Moderate", "High", "Very high")

# Get INVASIONA and IMPACT medians per pest per source
inv_df <- core_stats %>%
  filter(variable == "INVASIONA") %>%
  select(pest, inv_median_A = median_A, inv_median_B = median_B)

imp_df <- core_stats %>%
  filter(variable == "IMPACT") %>%
  select(pest, imp_median_A = median_A, imp_median_B = median_B)

cat_df <- inv_df %>%
  inner_join(imp_df, by = "pest") %>%
  mutate(
    cat_AI    = assign_risk_category(inv_median_A, imp_median_A),
    cat_Human = assign_risk_category(inv_median_B, imp_median_B),
    cat_AI    = factor(cat_AI, levels = RISK_LEVELS),
    cat_Human = factor(cat_Human, levels = RISK_LEVELS),
    cat_AI_num    = as.numeric(cat_AI),
    cat_Human_num = as.numeric(cat_Human),
    shift = cat_AI_num - cat_Human_num,
    shift_dir = case_when(
      shift > 0  ~ sprintf("%s higher", LABEL_A),
      shift < 0  ~ sprintf("%s lower", LABEL_A),
      TRUE       ~ "Same category"
    ),
    shift_dir = factor(shift_dir,
                       levels = c(sprintf("%s lower", LABEL_A),
                                  "Same category",
                                  sprintf("%s higher", LABEL_A)))
  ) %>%
  filter(!is.na(cat_AI), !is.na(cat_Human))

# Summary
cat("\n=== Risk category shifts ===\n")
cat_df %>%
  count(shift_dir) %>%
  print()
cat("\n")

cat_df %>%
  count(cat_Human, cat_AI, .drop = FALSE) %>%
  filter(n > 0) %>%
  arrange(cat_Human, cat_AI) %>%
  as.data.frame() %>%
  print()
cat("\n")

# Save classification
OUT_CATSHIFT <- file.path(dirname(STATS_CSV), "risk_category_shifts.csv")
write.csv(cat_df %>%
            select(pest, cat_Human, cat_AI, shift, shift_dir,
                   inv_median_A, inv_median_B, imp_median_A, imp_median_B),
          OUT_CATSHIFT, row.names = FALSE)
message(sprintf("Saved: %s", OUT_CATSHIFT))



# -- Slope graph --------------------------------------------------------------
shift_colours <- c(
  setNames(c("#4DBBD5", "#BBBBBB", "#E64B35"),
           c(sprintf("%s lower", LABEL_A),
             "Same category",
             sprintf("%s higher", LABEL_A)))
)

# Jitter within category to avoid overplotting
set.seed(42)
n_pests <- nrow(cat_df)
cat_df <- cat_df %>%
  group_by(cat_Human_num) %>%
  mutate(jitter_left = cat_Human_num +
           seq(-0.15, 0.15, length.out = n()) *
           (n() > 1)) %>%
  ungroup() %>%
  group_by(cat_AI_num) %>%
  mutate(jitter_right = cat_AI_num +
           seq(-0.15, 0.15, length.out = n()) *
           (n() > 1)) %>%
  ungroup()

# Label only shifted pests (or all if few enough)
cat_df <- cat_df %>%
  mutate(label = ifelse(shift != 0, pest, NA_character_))

# Short pest names for readability (take just the genus + species)
cat_df <- cat_df %>%
  mutate(label_short = ifelse(
    is.na(label), NA_character_,
    gsub("\\s*\\(.*\\)$", "", label)  # remove EPPO code in parentheses
  ))

# Pre-compute counts for subtitle and legend labels
n_total  <- nrow(cat_df)
n_higher <- sum(cat_df$shift > 0)
n_lower  <- sum(cat_df$shift < 0)
n_same   <- sum(cat_df$shift == 0)

# Legend labels include per-direction counts
shift_labels <- c(
  sprintf("%s lower (n=%d)", LABEL_A, n_lower),
  sprintf("Same category (n=%d)", n_same),
  sprintf("%s higher (n=%d)", LABEL_A, n_higher)
)
names(shift_colours) <- c(
  sprintf("%s lower", LABEL_A),
  "Same category",
  sprintf("%s higher", LABEL_A)
)

p11 <- ggplot(cat_df) +
  # Connecting lines
  geom_segment(aes(x = 1, xend = 2,
                   y = jitter_left, yend = jitter_right,
                   colour = shift_dir),
               linewidth = 0.7, alpha = 0.7) +
  # Human points (left)
  geom_point(aes(x = 1, y = jitter_left, colour = shift_dir),
             size = 2.5, shape = 16) +
  # AI points (right)
  geom_point(aes(x = 2, y = jitter_right, colour = shift_dir),
             size = 2.5, shape = 16) +
  # Labels for shifted pests (right side)
  ggrepel::geom_text_repel(
    aes(x = 2, y = jitter_right, label = label_short, colour = shift_dir),
    size = 2.3, fontface = "italic",
    direction = "y", nudge_x = 0.15, hjust = 0,
    segment.size = 0.2, segment.color = "grey70",
    max.overlaps = 30, na.rm = TRUE,
    show.legend = FALSE
  ) +
  scale_colour_manual(
    values = shift_colours,
    labels = shift_labels,
    name = NULL,
    drop = FALSE
  ) +
  scale_x_continuous(breaks = c(1, 2), labels = c(LABEL_B, LABEL_A),
                     limits = c(0.6, 3.2),
                     expand = expansion(0)) +
  scale_y_continuous(breaks = 1:5, labels = RISK_LEVELS,
                     limits = c(0.5, 5.5)) +
  labs(title = "Risk category shifts between assessors",
       subtitle = sprintf(
         "%d species · %d move up (%.1f%%) · %d move down (%.1f%%) · %d unchanged (%.1f%%)",
         n_total,
         n_higher, 100 * n_higher / n_total,
         n_lower,  100 * n_lower  / n_total,
         n_same,   100 * n_same   / n_total)) +
  pretty_theme +
  theme(panel.grid.major.x = element_blank(),
        panel.grid.minor   = element_blank(),
        axis.text.x = element_text(face = "bold", size = 13))

ggsave(file.path(PLOTS_DIR, "11_risk_category_shifts.png"), p11,
       width = 11, height = 9, dpi = 150, bg = "white")
message("  Saved slope graph.")



# -- Transition matrix heatmap ------------------------------------------------
trans_mat <- cat_df %>%
  count(cat_Human, cat_AI, .drop = FALSE) %>%
  mutate(cat_Human = factor(cat_Human, levels = RISK_LEVELS),
         cat_AI    = factor(cat_AI, levels = RISK_LEVELS),
         is_diag   = cat_Human == cat_AI)

p11b <- ggplot(trans_mat, aes(x = cat_AI, y = cat_Human)) +
  geom_tile(aes(fill = n), colour = "white", linewidth = 1) +
  geom_text(aes(label = n), size = 5, fontface = "bold",
            colour = ifelse(trans_mat$n > max(trans_mat$n) * 0.6,
                            "white", "grey20")) +
  # Diagonal highlight
  geom_tile(data = filter(trans_mat, is_diag),
            fill = NA, colour = "grey30", linewidth = 1.2, linetype = "dashed") +
  scale_fill_gradient(low = "grey95", high = "#E64B35", name = "n pests") +
  scale_x_discrete(position = "top") +
  labs(title = "Risk category transition matrix",
       subtitle = sprintf(
         "%s (rows) → %s (columns) · dashed = agreement diagonal · n = %d",
         LABEL_B, LABEL_A, nrow(cat_df)),
       x = sprintf("%s category", LABEL_A),
       y = sprintf("%s category", LABEL_B),
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(panel.grid = element_blank(),
        axis.text  = element_text(size = 10))

ggsave(file.path(PLOTS_DIR, "11b_transition_matrix.png"), p11b,
       width = 8, height = 7, dpi = 150, bg = "white")
message("  Saved transition matrix.")



