################################################################################
# FinnPRIO: Compare Simulation Traces  (e.g. AI vs. Human)
#
# Loads two .rds files produced by export_simulation_traces.R, pairs assessments by
# scientificName, and for every shared per-iteration variable runs:
#   - Two-sample Kolmogorov-Smirnov (D statistic + p-value)
#   - Wasserstein-1 distance  (effect size in original units)
#   - Mean / median difference (A - B)
# Produces a stats CSV and a PDF of density + ECDF overlays per pest.
#
# With 50k iterations per distribution, KS p-values will be near 0 for even
# trivial differences. Rank results by the D statistic and Wasserstein-1
# distance, not by p-value.
################################################################################

library(tidyverse)

# =============================================================================
TRACE_A <- "./scripts/exploration/output/trace_ai.rds"
TRACE_B <- "./scripts/exploration/output/trace_human.rds"
LABEL_A <- "AI"
LABEL_B <- "Human"

OUT_STATS_CSV <- "./scripts/exploration/output/comparison_stats.csv"
PLOTS_DIR     <- "./scripts/exploration/output/plots"
# =============================================================================

load_trace <- function(path) {
  x <- readRDS(path)
  meta <- x$metadata %>%
    arrange(desc(idAssessment)) %>%
    distinct(scientificName, .keep_all = TRUE)
  traces <- x$traces[meta$sheet]
  names(traces) <- meta$scientificName
  list(meta = meta, traces = traces)
}

wasserstein1 <- function(x, y) {
  x <- x[!is.na(x)]; y <- y[!is.na(y)]
  if (length(x) == 0 || length(y) == 0) return(NA_real_)
  if (length(x) == length(y)) return(mean(abs(sort(x) - sort(y))))
  n <- max(length(x), length(y))
  qx <- quantile(x, ppoints(n), names = FALSE)
  qy <- quantile(y, ppoints(n), names = FALSE)
  mean(abs(qx - qy))
}

# Cliff's delta = P(x > y) - P(x < y), in [-1, 1]. Computed via Mann-Whitney U.
cliffs_delta <- function(x, y) {
  x <- x[!is.na(x)]; y <- y[!is.na(y)]
  nx <- length(x); ny <- length(y)
  if (nx == 0 || ny == 0) return(NA_real_)
  r <- rank(c(x, y))
  U <- sum(r[seq_len(nx)]) - nx * (nx + 1) / 2
  (2 * U / (nx * ny)) - 1
}

compare_vectors <- function(x, y) {
  x <- x[!is.na(x)]; y <- y[!is.na(y)]
  if (length(x) < 2 || length(y) < 2) return(NULL)
  if (stats::var(x) == 0 && stats::var(y) == 0 && x[1] == y[1]) {
    return(data.frame(
      n_A = length(x), n_B = length(y),
      mean_A = mean(x), mean_B = mean(y),
      median_A = median(x), median_B = median(y),
      mean_diff = 0, median_diff = 0,
      wasserstein = 0, wasserstein_signed = 0,
      cliffs_delta = 0,
      ks_stat = 0, ks_pvalue = 1))
  }
  mean_diff <- mean(x) - mean(y)
  w <- wasserstein1(x, y)
  ks <- suppressWarnings(ks.test(x, y))
  data.frame(
    n_A = length(x), n_B = length(y),
    mean_A = mean(x), mean_B = mean(y),
    median_A = median(x), median_B = median(y),
    mean_diff          = mean_diff,
    median_diff        = median(x) - median(y),
    wasserstein        = w,
    wasserstein_signed = w * sign(mean_diff),
    cliffs_delta       = cliffs_delta(x, y),
    ks_stat            = unname(ks$statistic),
    ks_pvalue          = ks$p.value
  )
}

message("Loading traces...")
A <- load_trace(TRACE_A)
B <- load_trace(TRACE_B)

common_pests <- intersect(names(A$traces), names(B$traces))
message(sprintf("Shared pests: %d", length(common_pests)))
if (length(common_pests) == 0) stop("No matching pests between the two files.")

# -- Stats --------------------------------------------------------------------
dir.create(dirname(OUT_STATS_CSV), recursive = TRUE, showWarnings = FALSE)

stats_tbl <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]; b <- B$traces[[pest]]
  vars <- setdiff(intersect(names(a), names(b)), "iteration")
  map_dfr(vars, function(v) {
    res <- compare_vectors(a[[v]], b[[v]])
    if (is.null(res)) return(NULL)
    cbind(data.frame(pest = pest, variable = v), res)
  })
}) %>%
  arrange(desc(wasserstein))

write.csv(stats_tbl, OUT_STATS_CSV, row.names = FALSE)
message(sprintf("Saved stats: %s  (%d rows)", OUT_STATS_CSV, nrow(stats_tbl)))

# -- Plots --------------------------------------------------------------------
dir.create(PLOTS_DIR, recursive = TRUE, showWarnings = FALSE)

palette2 <- setNames(c("#E64B35", "#4DBBD5"), c(LABEL_A, LABEL_B))

pretty_theme <- theme_minimal(base_size = 11) +
  theme(
    plot.title         = element_text(face = "bold", size = 14),
    plot.subtitle      = element_text(colour = "grey35", size = 10),
    plot.caption       = element_text(colour = "grey55", size = 8, hjust = 1),
    plot.title.position = "plot",
    strip.background   = element_rect(fill = "grey94", colour = NA),
    strip.text         = element_text(face = "bold", size = 9),
    panel.grid.minor   = element_blank(),
    panel.grid.major   = element_line(colour = "grey92"),
    panel.spacing      = unit(0.6, "lines"),
    legend.position    = "bottom",
    legend.title       = element_blank(),
    legend.key.width   = unit(1.2, "cm")
  )

CORE_VARS <- c("ENT1", "ENTRYA", "ENTRYB",
               "EST1", "EST2", "EST3", "EST4", "SPR1", "ESTABLISHMENT",
               "INVASIONA", "INVASIONB",
               "IMP1", "IMP2", "IMP3", "IMP4", "IMPACT",
               "RISKA", "RISKB",
               "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
               "PREVENTABILITY", "CONTROLLABILITY", "MANAGEABILITY")

var_group <- function(v) {
  dplyr::case_when(
    v %in% c("ENT1","ENTRYA","ENTRYB")                              ~ "Entry",
    v %in% c("EST1","EST2","EST3","EST4","SPR1","ESTABLISHMENT")    ~ "Establishment",
    v %in% c("INVASIONA","INVASIONB")                               ~ "Invasion",
    v %in% c("IMP1","IMP2","IMP3","IMP4","IMPACT")                  ~ "Impact",
    v %in% c("RISKA","RISKB")                                       ~ "Risk",
    TRUE                                                            ~ "Manageability")
}

# Sort pests by total divergence (most-different first)
pest_order <- stats_tbl %>%
  filter(variable %in% CORE_VARS) %>%
  group_by(pest) %>%
  summarise(total_w = sum(wasserstein, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(total_w)) %>%
  pull(pest)

# ---- Heatmap: Wasserstein-1 distance per pest x variable -------------------
message("Building heatmap...")
heat_df <- stats_tbl %>%
  filter(variable %in% CORE_VARS) %>%
  mutate(variable = factor(variable, levels = CORE_VARS),
         pest     = factor(pest, levels = rev(pest_order)))

p_heat <- ggplot(heat_df, aes(variable, pest, fill = wasserstein)) +
  geom_tile(colour = "white", linewidth = 0.15) +
  scale_fill_viridis_c(option = "magma", direction = -1,
                       name = "Wasserstein-1",
                       na.value = "grey92") +
  labs(title = sprintf("Divergence heatmap — %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf("%d pests × %d variables · rows sorted by total divergence",
                          length(pest_order), length(CORE_VARS)),
       x = NULL, y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.x = element_text(angle = 60, hjust = 1, size = 8),
        axis.text.y = element_text(face = "italic", size = 7),
        panel.grid  = element_blank())

heat_file <- file.path(PLOTS_DIR, "heatmap_wasserstein.png")
ggsave(heat_file, p_heat,
       width  = max(10, length(CORE_VARS) * 0.45),
       height = max(8,  length(pest_order) * 0.18 + 2),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", heat_file))

# ---- Paired boxplots per variable group ------------------------------------
message("Building per-group boxplots...")

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
       subtitle = "Boxes: 25/50/75 percentiles · whiskers: 5/95 · pests sorted by total divergence",
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

# ---- Classification: similar / AI pessimistic / AI optimistic -------------
message("Classifying pests via Cliff's delta...")

HEADLINE_VARS <- c("INVASIONA", "ESTABLISHMENT", "IMPACT", "RISKA")
HEADLINE_LBL  <- c("INVASION",  "ESTABLISHMENT", "IMPACT", "RISK")
DELTA_THRESH  <- 0.15

cat_optim  <- sprintf("%s optimistic",  LABEL_A)
cat_pessim <- sprintf("%s pessimistic", LABEL_A)
cat_levels <- c(cat_optim, "Similar", cat_pessim)

classification <- stats_tbl %>%
  filter(variable %in% HEADLINE_VARS) %>%
  mutate(variable = factor(variable, levels = HEADLINE_VARS, labels = HEADLINE_LBL),
         category = case_when(
           is.na(cliffs_delta)                 ~ NA_character_,
           abs(cliffs_delta) < DELTA_THRESH    ~ "Similar",
           cliffs_delta >=  DELTA_THRESH       ~ cat_pessim,
           cliffs_delta <= -DELTA_THRESH       ~ cat_optim),
         category = factor(category, levels = cat_levels),
         pest = factor(pest, levels = rev(pest_order)))

OUT_CLASS_CSV <- "./scripts/exploration/output/classification.csv"
write.csv(classification %>%
            select(pest, variable, cliffs_delta, wasserstein_signed,
                   median_A, median_B, median_diff, category),
          OUT_CLASS_CSV, row.names = FALSE)
message(sprintf("Saved classification: %s  (%d rows)",
                OUT_CLASS_CSV, nrow(classification)))

class_fill <- setNames(c("#4DBBD5", "#CCCCCC", "#E64B35"), cat_levels)

# Per-pest classification heatmap
p_class <- ggplot(classification, aes(variable, pest, fill = category)) +
  geom_tile(colour = "white", linewidth = 0.4) +
  scale_fill_manual(values = class_fill, name = sprintf("vs %s", LABEL_B),
                    na.value = "grey92", drop = FALSE) +
  labs(title    = sprintf("Classification — %s vs %s", LABEL_A, LABEL_B),
       subtitle = sprintf("Cliff's |δ| ≥ %.2f required to call a shift · %d pests",
                          DELTA_THRESH, length(pest_order)),
       x = NULL, y = NULL,
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 7),
        axis.text.x = element_text(size = 10, face = "bold"),
        panel.grid  = element_blank())

class_file <- file.path(PLOTS_DIR, "classification_heatmap.png")
ggsave(class_file, p_class,
       width  = max(8, length(HEADLINE_VARS) * 1.1 + 3),
       height = max(8, length(pest_order) * 0.18 + 2),
       dpi = 150, bg = "white")
message(sprintf("Saved: %s", class_file))

# Stacked summary bar chart
summary_bar <- classification %>%
  filter(!is.na(category)) %>%
  count(variable, category, .drop = FALSE)

p_bar <- ggplot(summary_bar, aes(x = variable, y = n, fill = category)) +
  geom_col(position = "stack", colour = "white", linewidth = 0.3) +
  geom_text(aes(label = ifelse(n > 0, n, "")),
            position = position_stack(vjust = 0.5),
            colour = "grey15", size = 3.4) +
  scale_fill_manual(values = class_fill, name = sprintf("vs %s", LABEL_B),
                    drop = FALSE) +
  labs(title    = sprintf("How does %s compare to %s?", LABEL_A, LABEL_B),
       subtitle = sprintf("Pests per category · n = %d · Cliff's |δ| ≥ %.2f",
                          length(common_pests), DELTA_THRESH),
       x = NULL, y = "Number of pests",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme

bar_file <- file.path(PLOTS_DIR, "classification_summary.png")
ggsave(bar_file, p_bar, width = 8, height = 5, dpi = 150, bg = "white")
message(sprintf("Saved: %s", bar_file))

# -- Risk matrix (overview): AI vs Human -------------------------------------
message("Building risk matrix...")

risk_summary <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]; b <- B$traces[[pest]]
  qs <- function(x, p) quantile(x, p, na.rm = TRUE, names = FALSE)
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
                    guide = guide_legend(order = 1, override.aes = list(alpha = 0.7))) +
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
       subtitle = sprintf("%d shared pests · points mark the medians · bars: 5–95%% CI · arrow: %s → %s",
                          nrow(pairs_df), LABEL_B, LABEL_A),
       x = "INVASION (scenario A)  —  ENTRY × ESTABLISHMENT",
       y = "IMPACT",
       fill = "Risk category",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  theme_minimal(base_size = 14) +
  theme(plot.title       = element_text(size = 18, face = "bold", hjust = 0.5),
        plot.subtitle    = element_text(size = 12, margin = margin(b = 15), hjust = 0.5),
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
