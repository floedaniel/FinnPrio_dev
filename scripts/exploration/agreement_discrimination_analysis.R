################################################################################
# FinnPRIO: Inter-Rater Agreement & Discrimination Analysis
#
# =============================================================================
# EPISTEMOLOGICAL FOUNDATION — read before interpreting any output
# =============================================================================
#
#   There is no ground truth. Human expert scores are not correct answers —
#   they are one set of expert judgements. LLM scores are another. The study
#   is an inter-rater agreement study, not an accuracy study. Everything that
#   presupposes human = truth is invalid.
#
#   Consequences for analysis:
#   - Sensitivity / specificity / false-negative rate: INVALID. These require
#     one rater to be designated correct. Removed from this script.
#   - ROC / AUC using human category as "outcome": INVALID for the same reason.
#     Removed.
#   - Bland-Altman "bias": reframed as "mean inter-rater difference". Neither
#     rater is biased — they systematically disagree.
#   - "Overestimation / underestimation": INVALID. Replaced with directional
#     disagreement language.
#
#   What IS valid:
#   - Agreement metrics (kappa, CCC, Spearman rho): measure concordance between
#     two raters without assigning truth to either.
#   - Bland-Altman as a method-comparison tool: characterises the pattern of
#     inter-rater differences without implying one is correct.
#   - Cliff's delta direction profile: describes where and in which direction
#     the two raters systematically differ.
#   - Kruskal-Wallis concordance test: asks whether LLM scores differentiate
#     between the categories that human raters also differentiate — a concordance
#     question, not an accuracy question.
#   - PERT width: an internal LLM property. Wide distributions indicate the LLM
#     is uncertain regardless of what humans score.
#   - ICC / Fleiss kappa across replicate runs: purely internal LLM consistency.
#     No human comparison involved.
#   - D1 OLR: predicts inter-rater disagreement magnitude from LLM uncertainty.
#     Valid because it characterises a property of the two-rater system.
#
# =============================================================================
#
# SECTIONS
#   A1. Weighted Cohen's kappa       (ordinal category agreement)
#   A2. Bland-Altman                 (inter-rater difference pattern + proportional test)
#   A3. Lin's Concordance Correlation Coefficient
#   A4. Spearman & Kendall           (rank concordance between raters)
#   A5. Cliff's delta direction profile
#   B1. Kruskal-Wallis concordance   (does LLM score track human category strata?)
#   B2. PERT width                   (LLM internal uncertainty signal)
#   C1. ICC stub                     (LLM self-consistency — needs replicate runs)
#   C2. Fleiss kappa stub            (ditto)
#   D1. Ordinal logistic regression  (predictors of inter-rater disagreement)
#
# INPUT:  two .rds trace files from export_simulation_traces.R
# OUTPUT: CSV tables + PNG plots to ./scripts/exploration/output/agreement/
#
# Dependencies: tidyverse, irr, DescTools, ggrepel, ordinal
#   install.packages(c("irr", "DescTools", "ggrepel", "ordinal"))
################################################################################

library(tidyverse)
library(irr)        # kappa2, icc, kappam.fleiss
library(DescTools)  # CCC (Lin's concordance)
library(ggrepel)    # geom_text_repel

# =============================================================================
# CONFIGURATION
# =============================================================================
TRACE_A      <- "./scripts/exploration/output/trace_ai.rds"
TRACE_B      <- "./scripts/exploration/output/trace_human.rds"
LABEL_A      <- "AI"
LABEL_B      <- "Human"
OUT_DIR      <- "./scripts/exploration/output/agreement"

# Minimum Cliff's |delta| to flag as divergent
DELTA_THRESH <- 0.147
# =============================================================================

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Helpers ───────────────────────────────────────────────────────────────────

RISK_LEVELS <- c("Very low", "Low", "Moderate", "High", "Very high")

# Assign 5-level FinnPRIO risk category from median INVASION and IMPACT scores.
# Neither rater's categories are "correct" — this is purely a descriptive label.
assign_risk_category <- function(invasion, impact) {
  inv_bin <- cut(invasion, breaks = c(-Inf, 1/3, 2/3, Inf),
                 labels = c("L", "M", "H"), right = FALSE)
  imp_bin <- cut(impact,   breaks = c(-Inf, 1/3, 2/3, Inf),
                 labels = c("L", "M", "H"), right = FALSE)
  combo <- paste0(as.character(inv_bin), as.character(imp_bin))
  factor(dplyr::case_when(
    combo == "LL"                    ~ "Very low",
    combo %in% c("ML", "LM")        ~ "Low",
    combo %in% c("HL", "MM", "LH")  ~ "Moderate",
    combo %in% c("HM", "MH")        ~ "High",
    combo == "HH"                    ~ "Very high",
    TRUE                             ~ NA_character_
  ), levels = RISK_LEVELS, ordered = TRUE)
}

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

palette2 <- setNames(c("#E64B35", "#4DBBD5"), c(LABEL_A, LABEL_B))

# ── Load traces ───────────────────────────────────────────────────────────────
message("Loading traces ...")
load_trace <- function(path) {
  x <- readRDS(path)
  meta <- x$metadata %>%
    arrange(desc(idAssessment)) %>%
    distinct(scientificName, .keep_all = TRUE)
  traces <- x$traces[meta$sheet]
  names(traces) <- meta$scientificName
  list(meta = meta, traces = traces)
}
A <- load_trace(TRACE_A)
B <- load_trace(TRACE_B)

common_pests <- intersect(names(A$traces), names(B$traces))
n_pests      <- length(common_pests)
message(sprintf("Shared pests: %d", n_pests))
if (n_pests == 0) stop("No matching pests between the two trace files.")

# ── Build per-species summary table ──────────────────────────────────────────
message("Building species summary ...")

qs <- function(x, p) quantile(x, p, na.rm = TRUE, names = FALSE)

summary_df <- map_dfr(common_pests, function(pest) {
  a <- A$traces[[pest]]
  b <- B$traces[[pest]]

  vars <- c("INVASIONA", "IMPACT", "RISKA", "ESTABLISHMENT",
            "ENTRYA", "IMP1", "IMP2", "IMP3", "IMP4",
            "EST1", "EST2", "EST3", "EST4",
            "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
            "MANAGEABILITY")

  row <- data.frame(pest = pest)
  for (v in vars) {
    if (v %in% names(a)) {
      row[[paste0(v, "_median_A")]] <- qs(a[[v]], 0.50)
      row[[paste0(v, "_IQR_A")]]    <- qs(a[[v]], 0.75) - qs(a[[v]], 0.25)
      row[[paste0(v, "_span_A")]]   <- qs(a[[v]], 0.95) - qs(a[[v]], 0.05)
    }
    if (v %in% names(b)) {
      row[[paste0(v, "_median_B")]] <- qs(b[[v]], 0.50)
      row[[paste0(v, "_IQR_B")]]    <- qs(b[[v]], 0.75) - qs(b[[v]], 0.25)
      row[[paste0(v, "_span_B")]]   <- qs(b[[v]], 0.95) - qs(b[[v]], 0.05)
    }
  }

  row$cat_A     <- as.character(assign_risk_category(row$INVASIONA_median_A,
                                                      row$IMPACT_median_A))
  row$cat_B     <- as.character(assign_risk_category(row$INVASIONA_median_B,
                                                      row$IMPACT_median_B))
  row$cat_A_num <- as.integer(factor(row$cat_A, levels = RISK_LEVELS))
  row$cat_B_num <- as.integer(factor(row$cat_B, levels = RISK_LEVELS))
  row
}) %>%
  filter(!is.na(cat_A_num), !is.na(cat_B_num))

write.csv(summary_df, file.path(OUT_DIR, "species_summary.csv"), row.names = FALSE)
message(sprintf("Species summary: %d rows, %d columns",
                nrow(summary_df), ncol(summary_df)))

n <- nrow(summary_df)

# =============================================================================
# A1. WEIGHTED COHEN'S KAPPA
# Inter-rater agreement on ordinal risk category, corrected for chance.
# Quadratic weights penalise larger category disagreements more.
# Neither rater is designated correct — this is symmetric agreement.
# =============================================================================
message("\n── A1. Weighted kappa ──")

safe_kappa <- function(ratings, weight) {
  # irr::kappa2 with weight="equal" may error on some versions — catch it
  tryCatch(
    irr::kappa2(ratings, weight = weight),
    error = function(e) list(value = NA, statistic = NA, p.value = NA,
                              error = conditionMessage(e))
  )
}

ratings_mat <- cbind(summary_df$cat_A_num, summary_df$cat_B_num)

kq <- safe_kappa(ratings_mat, "quadratic")
ku <- safe_kappa(ratings_mat, "unweighted")
kl <- safe_kappa(ratings_mat, "equal")

kappa_summary <- data.frame(
  method  = c("Unweighted", "Linear weighted", "Quadratic weighted"),
  kappa   = c(ku$value,  kl$value,  kq$value),
  z       = c(ku$statistic, kl$statistic, kq$statistic),
  p_value = c(ku$p.value,   kl$p.value,   kq$p.value),
  n       = n,
  interpretation = c(
    "Exact category agreement corrected for chance",
    "Partial credit: disagreements weighted linearly by category distance",
    "Partial credit: disagreements weighted by squared category distance (recommended)"
  )
)
write.csv(kappa_summary, file.path(OUT_DIR, "A1_kappa_summary.csv"), row.names = FALSE)
message("Saved: A1_kappa_summary.csv")
print(kappa_summary[, 1:5])
message("  Benchmarks (Landis & Koch 1977): < 0.00 poor, 0.00-0.20 slight,")
message("  0.21-0.40 fair, 0.41-0.60 moderate, 0.61-0.80 substantial, > 0.80 almost perfect")
message("  Note: these benchmarks are conventional, not universal — report value + CI.")

# Transition matrix — describes PATTERN of disagreement between two raters
# Framing: rows = rater B category, cols = rater A category.
# Neither axis is "correct". Diagonal = agreement.
trans_mat <- table(
  `Rater B (Human)` = factor(summary_df$cat_B, levels = RISK_LEVELS),
  `Rater A (AI)`    = factor(summary_df$cat_A, levels = RISK_LEVELS)
)
write.csv(as.data.frame.matrix(trans_mat),
          file.path(OUT_DIR, "A1_transition_matrix.csv"))
message("Saved: A1_transition_matrix.csv")

# Summary stats
n_agree   <- sum(diag(trans_mat))
n_a_higher <- sum(summary_df$cat_A_num > summary_df$cat_B_num)
n_b_higher <- sum(summary_df$cat_A_num < summary_df$cat_B_num)
message(sprintf("  Exact agreement: %d/%d (%.1f%%)", n_agree, n, 100*n_agree/n))
message(sprintf("  %s higher than %s: %d species", LABEL_A, LABEL_B, n_a_higher))
message(sprintf("  %s higher than %s: %d species", LABEL_B, LABEL_A, n_b_higher))

trans_df <- as.data.frame(trans_mat)
names(trans_df) <- c("rater_B", "rater_A", "count")
trans_df <- trans_df %>%
  mutate(
    rater_B = factor(rater_B, levels = rev(RISK_LEVELS)),
    rater_A = factor(rater_A, levels = RISK_LEVELS),
    on_diag = rater_B == rater_A
  )

p_trans <- ggplot(trans_df, aes(rater_A, rater_B, fill = count)) +
  geom_tile(colour = "white", linewidth = 0.8) +
  geom_text(aes(label = ifelse(count > 0, count, ""),
                fontface = ifelse(on_diag, "bold", "plain")),
            size = 4.5) +
  geom_tile(data = filter(trans_df, on_diag),
            colour = "grey30", fill = NA, linewidth = 1.2) +
  scale_fill_gradient(low = "white", high = "#E64B35", name = "Count") +
  labs(
    title    = sprintf("Inter-rater agreement matrix: %s vs %s", LABEL_A, LABEL_B),
    subtitle = sprintf(
      "n = %d species · diagonal = agreement · neither rater designated correct",
      n),
    x = sprintf("Rater A: %s", LABEL_A),
    y = sprintf("Rater B: %s", LABEL_B),
    caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme +
  theme(panel.grid = element_blank(),
        axis.text.x = element_text(angle = 30, hjust = 1))

ggsave(file.path(OUT_DIR, "A1_transition_matrix.png"),
       p_trans, width = 7, height = 6, dpi = 150, bg = "white")
message("Saved: A1_transition_matrix.png")


# =============================================================================
# A2. BLAND-ALTMAN: inter-rater difference pattern
#
# NOTE ON FRAMING:
#   Standard B-A language ("bias", "overestimation") presupposes a reference
#   standard. We use it here as a method-comparison tool only.
#   "Bias" = mean inter-rater difference (A minus B). Sign indicates direction
#   of systematic disagreement, not error. "Proportional disagreement" replaces
#   "proportional bias": the finding that differences grow with score magnitude
#   is a property of the two-rater system, not evidence that one rater is wrong.
# =============================================================================
message("\n── A2. Bland-Altman (inter-rater difference pattern) ──")

ba_df <- summary_df %>%
  mutate(
    mean_score = (RISKA_median_A + RISKA_median_B) / 2,
    diff_score = RISKA_median_A - RISKA_median_B   # A minus B; sign = direction only
  )

mean_diff <- mean(ba_df$diff_score, na.rm = TRUE)
sd_diff   <- sd(ba_df$diff_score,   na.rm = TRUE)
loa_lo    <- mean_diff - 1.96 * sd_diff
loa_hi    <- mean_diff + 1.96 * sd_diff

# Proportional disagreement: regress (A - B) on (A + B)/2
# Significant slope = disagreement grows with score magnitude
pd_model <- lm(diff_score ~ mean_score, data = ba_df)
pd_sum   <- summary(pd_model)
pd_slope <- coef(pd_model)[2]
pd_p     <- coef(pd_sum)[2, 4]

ba_stats <- data.frame(
  statistic = c(
    "n",
    "Mean inter-rater difference (A minus B)",
    "SD of inter-rater differences",
    "Limits of agreement lower (mean - 1.96*SD)",
    "Limits of agreement upper (mean + 1.96*SD)",
    "Proportional disagreement slope",
    "Proportional disagreement p-value"
  ),
  value = c(
    n,
    round(mean_diff, 4),
    round(sd_diff,   4),
    round(loa_lo,    4),
    round(loa_hi,    4),
    round(pd_slope,  4),
    round(pd_p,      4)
  ),
  note = c(
    "",
    "Positive = A scores higher than B on average. No accuracy implied.",
    "",
    "", "",
    "Slope of (A-B) regressed on (A+B)/2",
    "p < 0.05 = disagreement grows with score magnitude (proportional disagreement)"
  )
)
write.csv(ba_stats, file.path(OUT_DIR, "A2_bland_altman_stats.csv"), row.names = FALSE)
message("Saved: A2_bland_altman_stats.csv")
print(ba_stats[, 1:2])

if (pd_p < 0.05) {
  message(sprintf(
    "  Significant proportional disagreement (slope = %.4f, p = %.4f).",
    pd_slope, pd_p))
  message("  Inter-rater differences grow with the magnitude of the composite score.")
  message("  Neither rater is correct — this characterises the structure of their disagreement.")
} else {
  message(sprintf(
    "  No proportional disagreement (slope = %.4f, p = %.4f). Differences are constant.",
    pd_slope, pd_p))
}

# Plot: Bland-Altman with proportional disagreement line
p_ba <- ggplot(ba_df, aes(x = mean_score, y = diff_score)) +
  geom_hline(yintercept = mean_diff, colour = "#E64B35", linewidth = 0.8) +
  geom_hline(yintercept = loa_lo, colour = "#E64B35", linetype = "dashed") +
  geom_hline(yintercept = loa_hi, colour = "#E64B35", linetype = "dashed") +
  geom_hline(yintercept = 0, colour = "grey40", linetype = "dotted") +
  geom_smooth(method = "lm", se = TRUE, colour = "#4DBBD5",
              linewidth = 0.7, fill = "#4DBBD5", alpha = 0.15) +
  geom_point(size = 2.2, alpha = 0.75, colour = "grey30") +
  ggrepel::geom_text_repel(
    aes(label = pest),
    data = filter(ba_df, abs(diff_score) > abs(mean_diff) + 1.5 * sd_diff),
    size = 2.2, fontface = "italic",
    max.overlaps = 15, segment.size = 0.2, colour = "grey40"
  ) +
  annotate("text",
    x     = max(ba_df$mean_score, na.rm = TRUE),
    y     = c(mean_diff, loa_hi, loa_lo),
    label = c(
      sprintf("Mean diff = %.4f", mean_diff),
      sprintf("+1.96 SD = %.4f", loa_hi),
      sprintf("-1.96 SD = %.4f", loa_lo)),
    hjust = 1, vjust = -0.3, size = 3, colour = "#E64B35") +
  labs(
    title    = sprintf("Inter-rater difference plot: %s minus %s (RISK-A)", LABEL_A, LABEL_B),
    subtitle = sprintf(
      "n = %d · Mean difference = %.4f · LoA [%.4f, %.4f] · Proportional disagreement p = %.3f",
      n, mean_diff, loa_lo, loa_hi, pd_p),
    x        = sprintf("Mean of %s and %s scores", LABEL_A, LABEL_B),
    y        = sprintf("%s minus %s difference", LABEL_A, LABEL_B),
    caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme

ggsave(file.path(OUT_DIR, "A2_bland_altman.png"),
       p_ba, width = 9, height = 6, dpi = 150, bg = "white")
message("Saved: A2_bland_altman.png")


# =============================================================================
# A3. LIN'S CONCORDANCE CORRELATION COEFFICIENT
# Combines precision (correlation) and accuracy (proximity to identity line).
# Both axes are raters — neither is designated reference.
# CCC = 1 only if all points lie exactly on the identity line (perfect agreement).
# =============================================================================
message("\n── A3. Lin's CCC ──")

ccc_result <- DescTools::CCC(
  x          = summary_df$RISKA_median_B,
  y          = summary_df$RISKA_median_A,
  ci         = "z-transform",
  conf.level = 0.95
)

# Fix: extract from named list slots, not positional [[]] to avoid column clash
ccc_df <- data.frame(
  statistic = c(
    "Lin's CCC (rho_c)",
    "95% CI lower",
    "95% CI upper",
    "Pearson r (precision component)",
    "Bias correction Cb (location/scale component)"
  ),
  value = c(
    round(ccc_result$rho.c$est,    4),
    round(ccc_result$rho.c$lwr.ci, 4),
    round(ccc_result$rho.c$upr.ci, 4),
    round(ccc_result$r,             4),
    round(ccc_result$C.b,           4)
  ),
  interpretation = c(
    "Overall concordance: < 0.90 poor, 0.90-0.95 moderate, > 0.95 substantial",
    "", "",
    "How correlated are the two raters? (precision, ignores systematic shift)",
    "How close to the identity line? 1 = perfect location/scale agreement"
  )
)
write.csv(ccc_df, file.path(OUT_DIR, "A3_lin_ccc.csv"), row.names = FALSE)
message("Saved: A3_lin_ccc.csv")
print(ccc_df[, 1:2])

# Plot: identity-line scatter — both axes are raters, not reference vs test
p_ccc <- ggplot(summary_df, aes(x = RISKA_median_B, y = RISKA_median_A)) +
  geom_abline(slope = 1, intercept = 0, colour = "grey60",
              linetype = "dashed", linewidth = 0.7) +
  geom_smooth(method = "lm", se = TRUE, colour = "#E64B35",
              linewidth = 0.7, fill = "#E64B35", alpha = 0.12) +
  geom_point(size = 2.2, alpha = 0.75, colour = "grey30") +
  ggrepel::geom_text_repel(
    aes(label = pest),
    data = summary_df %>%
      mutate(resid = abs(RISKA_median_A - RISKA_median_B)) %>%
      slice_max(resid, n = 8),
    size = 2.2, fontface = "italic",
    max.overlaps = 10, segment.size = 0.2, colour = "grey40"
  ) +
  coord_equal() +
  annotate("text",
    x     = min(summary_df$RISKA_median_B, na.rm = TRUE),
    y     = max(summary_df$RISKA_median_A, na.rm = TRUE),
    label = sprintf(
      "Lin's CCC = %.3f [%.3f, %.3f]\nPearson r = %.3f\nCb = %.3f",
      ccc_result$rho.c$est,
      ccc_result$rho.c$lwr.ci,
      ccc_result$rho.c$upr.ci,
      ccc_result$r,
      ccc_result$C.b),
    hjust = 0, vjust = 1, size = 3.2, colour = "#333333",
    family = "mono") +
  labs(
    title    = sprintf("Concordance scatter: %s vs %s", LABEL_A, LABEL_B),
    subtitle = "Dashed = perfect agreement (identity line) · Both axes are raters · Neither is reference",
    x        = sprintf("%s median RISK-A", LABEL_B),
    y        = sprintf("%s median RISK-A", LABEL_A),
    caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme

ggsave(file.path(OUT_DIR, "A3_ccc_scatter.png"),
       p_ccc, width = 7, height = 7, dpi = 150, bg = "white")
message("Saved: A3_ccc_scatter.png")


# =============================================================================
# A4. SPEARMAN & KENDALL RANK CONCORDANCE
# Do the two raters rank species in the same order?
# Neither rater's ordering is "correct" — this is a symmetric rank agreement.
# =============================================================================
message("\n── A4. Rank concordance ──")

spearman <- cor.test(summary_df$RISKA_median_A,
                     summary_df$RISKA_median_B,
                     method = "spearman", exact = FALSE)
kendall  <- cor.test(summary_df$RISKA_median_A,
                     summary_df$RISKA_median_B,
                     method = "kendall", exact = FALSE)

rank_cor_df <- data.frame(
  method        = c("Spearman rho", "Kendall tau-b"),
  estimate      = c(round(spearman$estimate, 4), round(kendall$estimate, 4)),
  statistic     = c(round(spearman$statistic, 4), round(kendall$statistic, 4)),
  p_value       = c(spearman$p.value, kendall$p.value),
  n             = n,
  interpretation = c(
    "Rank concordance between raters. 1 = same order; 0 = no concordance.",
    "More conservative than Spearman; preferred when many ties exist."
  )
)
write.csv(rank_cor_df, file.path(OUT_DIR, "A4_rank_concordance.csv"), row.names = FALSE)
message("Saved: A4_rank_concordance.csv")
print(rank_cor_df[, 1:4])
message("  Low rho means the two raters produce different priority orderings.")
message("  Neither ordering is 'correct' — this characterises concordance, not accuracy.")


# =============================================================================
# A5. CLIFF'S DELTA DIRECTION PROFILE
# For each sub-parameter: what proportion of species show rater A scoring
# higher, similar, or lower than rater B?
# Framing: describes WHERE and in WHICH DIRECTION systematic disagreement
# concentrates — not which rater is right.
# =============================================================================
message("\n── A5. Cliff's delta direction profile ──")

stats_csv <- "./scripts/exploration/output/comparison_stats.csv"
if (!file.exists(stats_csv)) {
  message("  comparison_stats.csv not found. Run compare_distributions.R first.")
} else {
  comp_stats <- read.csv(stats_csv)

  CORE_VARS <- c(
    "ENT1", "ENTRYA", "ENTRYB",
    "EST1", "EST2", "EST3", "EST4",
    "IMP1", "IMP2", "IMP3", "IMP4",
    "RISKA", "RISKB",
    "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
    "MANAGEABILITY"
  )

  direction_profile <- comp_stats %>%
    filter(!is.na(cliffs_delta)) %>%
    group_by(variable) %>%
    summarise(
      n_species          = n(),
      mean_delta         = mean(cliffs_delta,              na.rm = TRUE),
      sd_delta           = sd(cliffs_delta,                na.rm = TRUE),
      pct_A_higher       = mean(cliffs_delta >  DELTA_THRESH, na.rm = TRUE) * 100,
      pct_similar        = mean(abs(cliffs_delta) <= DELTA_THRESH, na.rm = TRUE) * 100,
      pct_B_higher       = mean(cliffs_delta < -DELTA_THRESH, na.rm = TRUE) * 100,
      prop_large_effect  = mean(abs(cliffs_delta) >= 0.474, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(abs(mean_delta)))

  write.csv(direction_profile,
            file.path(OUT_DIR, "A5_delta_direction_profile.csv"),
            row.names = FALSE)
  message("Saved: A5_delta_direction_profile.csv")

  # Plot: stacked bar — direction of disagreement per sub-parameter
  dir_plot_df <- direction_profile %>%
    filter(variable %in% CORE_VARS) %>%
    mutate(variable = factor(variable, levels = CORE_VARS)) %>%
    select(variable, pct_A_higher, pct_similar, pct_B_higher) %>%
    pivot_longer(-variable, names_to = "direction", values_to = "pct") %>%
    mutate(direction = factor(direction,
      levels = c("pct_A_higher", "pct_similar", "pct_B_higher"),
      labels = c(
        sprintf("%s scores higher", LABEL_A),
        "Similar (|δ| ≤ threshold)",
        sprintf("%s scores higher", LABEL_B)
      )
    ))

  dir_colours <- setNames(
    c("#E64B35", "#BBBBBB", "#4DBBD5"),
    c(
      sprintf("%s scores higher", LABEL_A),
      "Similar (|δ| ≤ threshold)",
      sprintf("%s scores higher", LABEL_B)
    )
  )

  p_dir <- ggplot(dir_plot_df, aes(x = variable, y = pct, fill = direction)) +
    geom_col(position = "stack", colour = "white", linewidth = 0.3) +
    geom_text(aes(label = ifelse(pct >= 8, sprintf("%.0f%%", pct), "")),
              position = position_stack(vjust = 0.5),
              colour = "grey15", size = 3) +
    geom_hline(yintercept = 50, linetype = "dashed",
               colour = "grey40", linewidth = 0.4) +
    scale_fill_manual(values = dir_colours) +
    scale_y_continuous(labels = scales::percent_format(scale = 1)) +
    labs(
      title    = sprintf("Direction of inter-rater disagreement: %s vs %s",
                         LABEL_A, LABEL_B),
      subtitle = sprintf(
        "Proportion of species where |Cliff's δ| > %.3f in each direction · n = %d · neither rater is reference",
        DELTA_THRESH, n_pests),
      x = NULL, y = "% species",
      caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
    ) +
    pretty_theme +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))

  ggsave(file.path(OUT_DIR, "A5_direction_profile.png"),
         p_dir, width = 11, height = 5, dpi = 150, bg = "white")
  message("Saved: A5_direction_profile.png")
}


# =============================================================================
# B1. KRUSKAL-WALLIS CONCORDANCE TEST
#
# Question: Do rater A's continuous scores differentiate between the risk
# strata that rater B assigned?
# This is a CONCORDANCE question, not an accuracy question. It does not imply
# rater B is correct. It asks: when the two raters disagree in category, does
# rater A's score at least track rater B's ordering?
# Run symmetrically in both directions (A predicts B strata; B predicts A strata).
# =============================================================================
message("\n── B1. Kruskal-Wallis concordance ──")

kw_results <- list()

# Direction 1: does rater A's continuous score vary across rater B's categories?
kw_ab <- kruskal.test(RISKA_median_A ~ factor(cat_B_num), data = summary_df)
# Direction 2: does rater B's continuous score vary across rater A's categories?
kw_ba <- kruskal.test(RISKA_median_B ~ factor(cat_A_num), data = summary_df)

kw_df <- data.frame(
  direction   = c(
    sprintf("%s score across %s categories", LABEL_A, LABEL_B),
    sprintf("%s score across %s categories", LABEL_B, LABEL_A)
  ),
  H_statistic = c(round(kw_ab$statistic, 3), round(kw_ba$statistic, 3)),
  df          = c(kw_ab$parameter, kw_ba$parameter),
  p_value     = c(kw_ab$p.value, kw_ba$p.value),
  n           = n,
  interpretation = c(
    sprintf(
      "p < 0.05: %s scores differ across %s risk strata — raters concordant in ordering",
      LABEL_A, LABEL_B),
    sprintf(
      "p < 0.05: %s scores differ across %s risk strata — raters concordant in ordering",
      LABEL_B, LABEL_A)
  )
)
write.csv(kw_df, file.path(OUT_DIR, "B1_kruskal_wallis_concordance.csv"),
          row.names = FALSE)
message("Saved: B1_kruskal_wallis_concordance.csv")
print(kw_df[, 1:4])
message("  A significant result means the raters' continuous scores track each")
message("  other's categorical strata — concordance, NOT accuracy.")

# Plot: boxplots of rater A score across rater B categories (and vice versa)
p_kw1 <- ggplot(summary_df,
                aes(x = factor(cat_B, levels = RISK_LEVELS),
                    y = RISKA_median_A)) +
  geom_boxplot(fill = palette2[LABEL_A], alpha = 0.7,
               colour = "grey30", outlier.shape = 16) +
  geom_jitter(width = 0.15, size = 1.5, alpha = 0.6, colour = "grey30") +
  labs(
    title    = sprintf("%s scores by %s risk category", LABEL_A, LABEL_B),
    subtitle = sprintf(
      "Kruskal-Wallis H = %.2f, df = %d, p = %.4f · n = %d",
      kw_ab$statistic, kw_ab$parameter, kw_ab$p.value, n),
    x        = sprintf("%s risk category (neither axis is reference)", LABEL_B),
    y        = sprintf("%s median RISK-A score", LABEL_A),
    caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme

ggsave(file.path(OUT_DIR, "B1_kw_A_by_B_categories.png"),
       p_kw1, width = 8, height = 5, dpi = 150, bg = "white")
message("Saved: B1_kw_A_by_B_categories.png")

p_kw2 <- ggplot(summary_df,
                aes(x = factor(cat_A, levels = RISK_LEVELS),
                    y = RISKA_median_B)) +
  geom_boxplot(fill = palette2[LABEL_B], alpha = 0.7,
               colour = "grey30", outlier.shape = 16) +
  geom_jitter(width = 0.15, size = 1.5, alpha = 0.6, colour = "grey30") +
  labs(
    title    = sprintf("%s scores by %s risk category", LABEL_B, LABEL_A),
    subtitle = sprintf(
      "Kruskal-Wallis H = %.2f, df = %d, p = %.4f · n = %d",
      kw_ba$statistic, kw_ba$parameter, kw_ba$p.value, n),
    x        = sprintf("%s risk category (neither axis is reference)", LABEL_A),
    y        = sprintf("%s median RISK-A score", LABEL_B),
    caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme

ggsave(file.path(OUT_DIR, "B1_kw_B_by_A_categories.png"),
       p_kw2, width = 8, height = 5, dpi = 150, bg = "white")
message("Saved: B1_kw_B_by_A_categories.png")


# =============================================================================
# B2. PERT WIDTH — LLM internal uncertainty signal
# This is an INTERNAL PROPERTY of rater A only. It does not compare to rater B.
# Wide distributions = the LLM itself is uncertain about the species.
# The D1 model below tests whether this internal uncertainty predicts
# the magnitude of inter-rater disagreement.
# =============================================================================
message("\n── B2. PERT width (LLM internal uncertainty) ──")

riska_spans <- summary_df %>%
  select(pest,
         span_A   = RISKA_span_A,
         span_B   = RISKA_span_B,
         cat_A, cat_B, cat_A_num, cat_B_num) %>%
  mutate(
    abs_disagreement = abs(cat_A_num - cat_B_num)
  )

span_p75 <- quantile(riska_spans$span_A, 0.75, na.rm = TRUE)
span_p90 <- quantile(riska_spans$span_A, 0.90, na.rm = TRUE)

message(sprintf("  LLM RISKA P5-P95 span: 75th pct = %.4f, 90th pct = %.4f",
                span_p75, span_p90))

# Species above 75th percentile of LLM span — flagged for further attention
# NOT because humans disagreed with them, but because the LLM itself was uncertain
wide_species <- riska_spans %>%
  filter(span_A >= span_p75) %>%
  arrange(desc(span_A))

message(sprintf("  Species at >= 75th pct of LLM uncertainty: %d", nrow(wide_species)))
print(wide_species %>% select(pest, span_A, span_B, cat_A, cat_B, abs_disagreement))

write.csv(wide_species, file.path(OUT_DIR, "B2_wide_distribution_species.csv"),
          row.names = FALSE)
message("Saved: B2_wide_distribution_species.csv")

# Correlation between LLM uncertainty and inter-rater disagreement
span_disagree_cor <- cor.test(riska_spans$span_A, riska_spans$abs_disagreement,
                               method = "spearman", exact = FALSE)
message(sprintf(
  "  Spearman rho (LLM span vs |category disagreement|) = %.3f, p = %.4f",
  span_disagree_cor$estimate, span_disagree_cor$p.value))
message("  A significant positive rho means wide LLM distributions predict larger")
message("  inter-rater disagreement — the LLM's own uncertainty is a useful signal.")

span_cor_df <- data.frame(
  statistic     = "Spearman rho: LLM RISKA span vs abs category disagreement",
  rho           = round(span_disagree_cor$estimate, 4),
  p_value       = round(span_disagree_cor$p.value, 4),
  n             = n,
  interpretation = "LLM uncertainty predicts inter-rater disagreement magnitude"
)
write.csv(span_cor_df, file.path(OUT_DIR, "B2_span_disagreement_cor.csv"),
          row.names = FALSE)
message("Saved: B2_span_disagreement_cor.csv")

# Plot: LLM vs Human span comparison + colour by inter-rater disagreement
p_width <- ggplot(
  riska_spans %>%
    mutate(pest = fct_reorder(pest, span_A, .fun = max)) %>%  # reorder BEFORE pivot
    pivot_longer(c(span_A, span_B), names_to = "source", values_to = "span") %>%
    mutate(
      source = if_else(source == "span_A", LABEL_A, LABEL_B)
    ),
  aes(x = span, y = pest, colour = source)
) +
  geom_line(aes(group = pest), colour = "grey80", linewidth = 0.5) +
  geom_point(size = 2, alpha = 0.85) +
  geom_vline(xintercept = span_p75, linetype = "dashed",
             colour = "#E64B35", linewidth = 0.5) +
  scale_colour_manual(values = palette2) +
  labs(
    title    = sprintf("PERT distribution width: %s vs %s", LABEL_A, LABEL_B),
    subtitle = sprintf(
      "P5-P95 span of RISK-A · dashed = %s 75th pct (%.4f) · width is internal LLM property",
      LABEL_A, span_p75),
    x        = "P5-P95 span (RISK-A)",
    y        = NULL,
    caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
  ) +
  pretty_theme +
  theme(axis.text.y = element_text(face = "italic", size = 7))

ggsave(file.path(OUT_DIR, "B2_pert_width.png"),
       p_width,
       width  = 9,
       height = max(6, n_pests * 0.18 + 2),
       dpi    = 150, bg = "white")
message("Saved: B2_pert_width.png")


# =============================================================================
# C1. ICC STUB — LLM self-consistency (requires replicate pipeline runs)
# This analysis compares the LLM to ITSELF across independent runs.
# No human comparison involved. Purely an internal reliability measure.
# =============================================================================
message("\n── C1. ICC stub (LLM self-consistency — needs replicate runs) ──")

compute_icc <- function(replicate_list, variable = "RISKA_median_A") {
  # replicate_list: list of data.frames each with columns: pest, <variable>
  # Returns ICC(2,1): two-way random, single measures, absolute agreement
  # Appropriate when runs are a random sample from possible pipeline runs.
  stopifnot(length(replicate_list) >= 2)
  mat <- replicate_list %>%
    map(~ select(.x, pest, all_of(variable))) %>%
    reduce(full_join, by = "pest") %>%
    select(-pest) %>%
    as.matrix()
  irr::icc(mat, model = "twoway", type = "agreement", unit = "single")
}

# When data are available:
# rep1 <- read.csv("path/to/run1/species_summary.csv")
# rep2 <- read.csv("path/to/run2/species_summary.csv")
# rep3 <- read.csv("path/to/run3/species_summary.csv")
# icc_result <- compute_icc(list(rep1, rep2, rep3))
# print(icc_result)
# Benchmarks (Koo & Li 2016): < 0.50 poor, 0.50-0.75 moderate,
#                               0.75-0.90 good, > 0.90 excellent

message("  Minimum recommendation: 3-5 independent pipeline runs on 20+ species.")
message("  Variables: RISKA_median_A, cat_A_num, per sub-parameter medians.")
message("  This measures whether the LLM is stable — independent of human scores.")


# =============================================================================
# C2. FLEISS KAPPA STUB — ordinal category self-consistency across runs
# =============================================================================
message("\n── C2. Fleiss kappa stub (LLM self-consistency) ──")

compute_fleiss_kappa <- function(replicate_cat_list) {
  # replicate_cat_list: list of integer vectors, one per run, one value per species
  mat <- do.call(cbind, replicate_cat_list)
  irr::kappam.fleiss(mat)
}

# fk <- compute_fleiss_kappa(list(run1$cat_A_num, run2$cat_A_num, run3$cat_A_num))
# print(fk)

message("  Supply list of integer category vectors (one per run) to compute_fleiss_kappa().")


# =============================================================================
# D1. ORDINAL LOGISTIC REGRESSION
# Outcome: magnitude of inter-rater disagreement (|category shift| = 0, 1, 2...)
# Predictor: LLM internal uncertainty (RISKA span)
# Framing: does the LLM's own uncertainty predict how much the two raters
# disagree? This characterises the two-rater system, not LLM accuracy.
# NOTE: n = 63, exploratory only. No strong inference. Max 2-3 predictors.
# =============================================================================
message("\n── D1. Ordinal logistic regression ──")

if (!requireNamespace("ordinal", quietly = TRUE)) {
  message("  Package 'ordinal' not installed: install.packages('ordinal')")
} else {
  library(ordinal)

  olr_df <- summary_df %>%
    mutate(
      abs_disagreement = factor(abs(cat_A_num - cat_B_num), ordered = TRUE),
      llm_uncertainty  = RISKA_span_A,
      # Direction of disagreement — descriptive only, no "correct" direction
      direction = case_when(
        cat_A_num > cat_B_num ~ sprintf("%s higher", LABEL_A),
        cat_A_num < cat_B_num ~ sprintf("%s higher", LABEL_B),
        TRUE                  ~ "Same category"
      )
    )

  tryCatch({
    m1 <- ordinal::clm(abs_disagreement ~ llm_uncertainty, data = olr_df)
    message("  Model: |inter-rater disagreement| ~ LLM uncertainty (RISKA span)")
    print(summary(m1))
    write.csv(
      as.data.frame(coef(summary(m1))),
      file.path(OUT_DIR, "D1_olr_uncertainty.csv")
    )
    message("  Saved: D1_olr_uncertainty.csv")
    message("  Interpretation: positive slope = wider LLM distributions associated")
    message("  with larger inter-rater disagreements. Consistent with span as a")
    message("  useful signal for species requiring additional scrutiny.")
  }, error = function(e) {
    message(sprintf("  Model failed: %s", conditionMessage(e)))
  })

  # Direction summary — descriptive cross-tab
  dir_summary <- olr_df %>%
    count(direction, abs(cat_A_num - cat_B_num), .drop = FALSE) %>%
    rename(abs_shift = `abs(cat_A_num - cat_B_num)`) %>%
    arrange(direction, abs_shift)

  write.csv(dir_summary, file.path(OUT_DIR, "D1_direction_summary.csv"),
            row.names = FALSE)
  message("  Saved: D1_direction_summary.csv")
  print(dir_summary)
}


# =============================================================================
# E1. INFORMATION ACCESS STRATIFICATION
#
# PURPOSE
#   Classify each FinnPRIO sub-parameter by the PRIMARY information source
#   required to answer it, then ask: does inter-rater disagreement cluster
#   by information access category?
#
#   This is NOT an accuracy analysis. The claim is not that humans are more
#   correct because they have access to Norwegian statistics. The claim is:
#   systematic inter-rater differences are structured by information access,
#   and this structure has implications for where adding data (e.g. via an
#   MCP server connecting to SSB, Tollvesenet, Mattilsynet) would be expected
#   to reduce disagreement.
#
# INFORMATION ACCESS TAXONOMY
#   Three categories based on what knowledge is required to score the question:
#
#   GLOBAL_LIT  — answered primarily from published international literature
#                 (EPPO, CABI, peer-reviewed papers). AI and humans have
#                 broadly equivalent access. Disagreement here = reasoning gap.
#                 Examples: ENT1 (global distribution), EST4 (biological traits),
#                 EST3 (spread rate), IMP3 (ecosystem impact)
#
#   LOCAL_DATA  — requires Norway-specific quantitative data not in public
#                 literature: trade volumes (SSB/Tollvesenet), crop production
#                 areas (SSB), economic loss estimates (SSB sector statistics).
#                 AI currently lacks this. Disagreement here = data gap,
#                 fixable with MCP server access.
#                 Examples: ENT3 (import volume), EST2 (host area in Norway),
#                 IMP1 (economic losses in EUR)
#
#   LOCAL_REG   — requires knowledge of Norwegian/EU regulatory status:
#                 current import bans, Mattilsynet requirements, Europhyt
#                 interception records, TRACES NT data, EU presence.
#                 AI has partial access (some Europhyt data online) but
#                 misses current regulatory decisions and Norwegian specifics.
#                 Fixable with MCP server access to Mattilsynet/EPPO systems.
#                 Examples: ENT2B (with management measures), MAN2 (EU presence),
#                 ENT2A (Europhyt interceptions)
#
#   LOCAL_CTX   — requires Norwegian ecological/cultural context: landscape
#                 structure, host plant distribution in Norway, cultural
#                 importance of specific plants in Norwegian context.
#                 Partially fixable (open data) but requires local expertise.
#                 Examples: EST1 (Norwegian climate suitability), MAN3 (detection
#                 difficulty), MAN4-5 (eradication/survey in Norway), IMP4.3
#                 (cultural plants), IMP4.1-2 (social/aesthetic in Norway)
#
# EXPECTED PATTERN
#   If information access drives disagreement:
#   LOCAL_DATA and LOCAL_REG should show higher |mean_delta| and lower
#   % similar than GLOBAL_LIT.
#   ENT1 (global distribution, GLOBAL_LIT) should serve as a positive control
#   showing near-zero mean_delta.
#   EST4 (biological traits, GLOBAL_LIT) showing HIGH mean_delta indicates
#   reasoning divergence independent of data access — a separate phenomenon.
#
# =============================================================================
message("\n── E1. Information access stratification ──")

# ── Define taxonomy ───────────────────────────────────────────────────────────
info_access <- tribble(
  ~variable,       ~category,     ~label,                            ~fixable_by_mcp,
  # GLOBAL_LIT: full literature access, both raters equivalent
  "ENT1",          "GLOBAL_LIT",  "Global distribution",              FALSE,
  "EST3",          "GLOBAL_LIT",  "Spread rate",                      FALSE,
  "EST4",          "GLOBAL_LIT",  "Biological traits",                FALSE,
  "IMP2",          "GLOBAL_LIT",  "Economic impact mechanisms",       FALSE,
  "IMP3",          "GLOBAL_LIT",  "Ecosystem impact",                 FALSE,
  "IMP4",          "GLOBAL_LIT",  "Soc/aesthetic/cultural impact",    FALSE,
  "MAN1",          "GLOBAL_LIT",  "Natural spread distance",          FALSE,
  # LOCAL_DATA: Norway-specific quantitative stats — AI currently lacks
  "ENT3",          "LOCAL_DATA",  "Import volume (SSB/Tollvesenet)",  TRUE,
  "EST2",          "LOCAL_DATA",  "Host area in Norway (SSB)",        TRUE,
  "IMP1",          "LOCAL_DATA",  "Economic losses EUR (SSB)",        TRUE,
  # LOCAL_REG: Norwegian/EU regulatory knowledge
  "ENT2A",         "LOCAL_REG",   "Transport potential (no measures)",FALSE,
  "ENT2B",         "LOCAL_REG",   "Transport potential (with measures, Mattilsynet)", TRUE,
  "MAN2",          "LOCAL_REG",   "EU presence (EPPO current)",       TRUE,
  # LOCAL_CTX: Norwegian ecological/cultural context
  "EST1",          "LOCAL_CTX",   "Climate suitability Norway",       FALSE,
  "MAN3",          "LOCAL_CTX",   "Detection difficulty Norway",      FALSE,
  "MAN4",          "LOCAL_CTX",   "Eradication difficulty Norway",    FALSE,
  "MAN5",          "LOCAL_CTX",   "Survey difficulty Norway",         FALSE,
  "ENTRYA",        "LOCAL_CTX",   "Combined entry score A",           FALSE,
  "ENTRYB",        "LOCAL_CTX",   "Combined entry score B",           FALSE,
  "ESTABLISHMENT", "LOCAL_CTX",   "Combined establishment score",     FALSE,
  "IMPACT",        "LOCAL_CTX",   "Combined impact score",            FALSE,
  "RISKA",         "LOCAL_CTX",   "Composite risk score A",           FALSE,
  "MANAGEABILITY", "LOCAL_CTX",   "Combined manageability",           FALSE
)

# ── Join with delta profile ───────────────────────────────────────────────────
if (!exists("comp_stats")) {
  stats_csv <- "./scripts/exploration/output/comparison_stats.csv"
  if (file.exists(stats_csv)) {
    comp_stats <- read.csv(stats_csv)
  } else {
    message("  comparison_stats.csv not found — skipping E1.")
    comp_stats <- NULL
  }
}

if (!is.null(comp_stats)) {

  # Core variable delta summary (one row per CORE_VARS variable, all pests pooled)
  core_vars_e1 <- info_access$variable

  delta_core <- comp_stats %>%
    filter(variable %in% core_vars_e1, !is.na(cliffs_delta)) %>%
    group_by(variable) %>%
    summarise(
      n_species      = n(),
      mean_delta     = mean(cliffs_delta,                    na.rm = TRUE),
      median_delta   = median(cliffs_delta,                  na.rm = TRUE),
      sd_delta       = sd(cliffs_delta,                      na.rm = TRUE),
      pct_A_higher   = mean(cliffs_delta >  DELTA_THRESH,    na.rm = TRUE) * 100,
      pct_similar    = mean(abs(cliffs_delta) <= DELTA_THRESH, na.rm = TRUE) * 100,
      pct_B_higher   = mean(cliffs_delta < -DELTA_THRESH,    na.rm = TRUE) * 100,
      mean_abs_delta = mean(abs(cliffs_delta),               na.rm = TRUE),
      .groups = "drop"
    ) %>%
    left_join(info_access, by = "variable") %>%
    arrange(category, desc(mean_abs_delta))

  write.csv(delta_core,
            file.path(OUT_DIR, "E1_information_access_delta.csv"),
            row.names = FALSE)
  message("Saved: E1_information_access_delta.csv")

  # ── Summary by category ───────────────────────────────────────────────────
  category_summary <- delta_core %>%
    group_by(category) %>%
    summarise(
      n_questions      = n(),
      mean_abs_delta   = round(mean(mean_abs_delta,  na.rm = TRUE), 3),
      median_abs_delta = round(median(mean_abs_delta,na.rm = TRUE), 3),
      mean_pct_similar = round(mean(pct_similar,     na.rm = TRUE), 1),
      mean_delta_signed = round(mean(mean_delta,     na.rm = TRUE), 3),
      .groups = "drop"
    ) %>%
    mutate(
      interpretation = case_when(
        category == "GLOBAL_LIT" ~ "Reasoning gap — data access equivalent",
        category == "LOCAL_DATA" ~ "Data gap — fixable with SSB/Tollvesenet MCP",
        category == "LOCAL_REG"  ~ "Regulatory gap — fixable with Mattilsynet/EPPO MCP",
        category == "LOCAL_CTX"  ~ "Context gap — partially fixable"
      )
    )

  write.csv(category_summary,
            file.path(OUT_DIR, "E1_category_summary.csv"),
            row.names = FALSE)
  message("Saved: E1_category_summary.csv")

  message("\n  Information access category summary:")
  print(as.data.frame(category_summary))

  # ── Kruskal-Wallis: do categories differ in |delta|? ─────────────────────
  kw_info <- kruskal.test(mean_abs_delta ~ category, data = delta_core)
  message(sprintf(
    "\n  Kruskal-Wallis: |delta| across info-access categories: H = %.3f, df = %d, p = %.4f",
    kw_info$statistic, kw_info$parameter, kw_info$p.value))
  if (kw_info$p.value < 0.05) {
    message("  Significant: inter-rater disagreement varies by information access category.")
    message("  Pairwise comparisons warranted (see plot).")
  } else {
    message("  Not significant at alpha = 0.05.")
  }

  kw_info_df <- data.frame(
    H_statistic = round(kw_info$statistic, 3),
    df          = kw_info$parameter,
    p_value     = round(kw_info$p.value,   4),
    n_questions = nrow(delta_core),
    interpretation = "Do information access categories differ in inter-rater disagreement?"
  )
  write.csv(kw_info_df, file.path(OUT_DIR, "E1_kruskal_wallis.csv"),
            row.names = FALSE)
  message("Saved: E1_kruskal_wallis.csv")

  # ── Plot 1: dot plot — mean |delta| per question, coloured by category ────
  cat_colours <- c(
    "GLOBAL_LIT" = "#4DBBD5",
    "LOCAL_DATA" = "#E64B35",
    "LOCAL_REG"  = "#F39B7F",
    "LOCAL_CTX"  = "#91D1C2"
  )

  cat_labels <- c(
    "GLOBAL_LIT" = "Global literature\n(reasoning gap)",
    "LOCAL_DATA" = "Local data\n(SSB/Tollvesenet — fixable)",
    "LOCAL_REG"  = "Regulatory knowledge\n(Mattilsynet/EPPO — fixable)",
    "LOCAL_CTX"  = "Local context\n(partially fixable)"
  )

  plot_df <- delta_core %>%
    filter(!is.na(category)) %>%
    mutate(
      var_label = coalesce(label, variable),
      category  = factor(category,
                         levels = c("LOCAL_DATA", "LOCAL_REG",
                                    "LOCAL_CTX",  "GLOBAL_LIT"))
    )

  p_info <- ggplot(plot_df,
                   aes(x = mean_abs_delta,
                       y = reorder(var_label, mean_abs_delta),
                       colour = category,
                       shape  = fixable_by_mcp)) +
    geom_vline(xintercept = DELTA_THRESH, linetype = "dashed",
               colour = "grey60", linewidth = 0.4) +
    geom_point(size = 3.5) +
    scale_colour_manual(values = cat_colours, labels = cat_labels,
                        name = "Information access") +
    scale_shape_manual(values = c("TRUE" = 17, "FALSE" = 16),
                       labels = c("TRUE" = "Fixable with MCP server",
                                  "FALSE" = "Not directly fixable"),
                       name = "") +
    scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    labs(
      title    = "Inter-rater disagreement by information access category",
      subtitle = sprintf(
        "Mean |Cliff's δ| per sub-parameter · n = %d species · dashed = negligible threshold (%.3f)",
        n_pests, DELTA_THRESH),
      x        = "Mean |Cliff's δ| (larger = more inter-rater disagreement)",
      y        = NULL,
      caption  = paste0(
        "Triangle = fixable by adding data via MCP server (SSB, Tollvesenet, Mattilsynet, EPPO)\n",
        format(Sys.time(), "Generated %Y-%m-%d %H:%M")
      )
    ) +
    facet_grid(category ~ ., scales = "free_y", space = "free_y",
               labeller = labeller(category = cat_labels)) +
    pretty_theme +
    theme(
      strip.text.y     = element_text(angle = 0, hjust = 0, size = 8),
      legend.position  = "bottom",
      legend.box       = "vertical",
      axis.text.y      = element_text(size = 9)
    )

  ggsave(file.path(OUT_DIR, "E1_info_access_dotplot.png"),
         p_info, width = 10, height = 8, dpi = 150, bg = "white")
  message("Saved: E1_info_access_dotplot.png")

  # ── Plot 2: direction heatmap — which questions, which direction? ─────────
  # For each question in the taxonomy: show % AI higher / similar / B higher
  # as a horizontal stacked bar, grouped by category
  dir_e1 <- plot_df %>%
    select(var_label, category, pct_A_higher, pct_similar, pct_B_higher,
           fixable_by_mcp) %>%
    pivot_longer(c(pct_A_higher, pct_similar, pct_B_higher),
                 names_to = "direction", values_to = "pct") %>%
    mutate(
      direction = factor(direction,
        levels  = c("pct_A_higher", "pct_similar", "pct_B_higher"),
        labels  = c(
          sprintf("%s scores higher", LABEL_A),
          sprintf("Similar (|δ| ≤ %.3f)", DELTA_THRESH),
          sprintf("%s scores higher", LABEL_B)
        )
      ),
      var_label = reorder(var_label, ifelse(direction == sprintf("%s scores higher", LABEL_A), pct, 0))
    )

  dir_colours2 <- c(
    setNames(c("#E64B35", "#DDDDDD", "#4DBBD5"),
             c(sprintf("%s scores higher", LABEL_A),
               sprintf("Similar (|δ| ≤ %.3f)", DELTA_THRESH),
               sprintf("%s scores higher", LABEL_B)))
  )

  p_dir2 <- ggplot(dir_e1, aes(x = pct, y = var_label, fill = direction)) +
    geom_col(position = "stack", colour = "white", linewidth = 0.2) +
    geom_text(aes(label = ifelse(pct >= 10, sprintf("%.0f%%", pct), "")),
              position = position_stack(vjust = 0.5),
              size = 2.8, colour = "grey15") +
    geom_vline(xintercept = 50, linetype = "dashed",
               colour = "grey40", linewidth = 0.4) +
    scale_fill_manual(values = dir_colours2, name = NULL) +
    scale_x_continuous(labels = scales::percent_format(scale = 1)) +
    facet_grid(category ~ ., scales = "free_y", space = "free_y",
               labeller = labeller(category = cat_labels)) +
    labs(
      title    = "Direction of inter-rater disagreement by information access",
      subtitle = sprintf(
        "n = %d species · neither rater is reference · red = %s scores higher",
        n_pests, LABEL_A),
      x        = "% species",
      y        = NULL,
      caption  = format(Sys.time(), "Generated %Y-%m-%d %H:%M")
    ) +
    pretty_theme +
    theme(
      strip.text.y    = element_text(angle = 0, hjust = 0, size = 8),
      legend.position = "bottom",
      axis.text.y     = element_text(size = 9)
    )

  ggsave(file.path(OUT_DIR, "E1_info_access_direction.png"),
         p_dir2, width = 11, height = 9, dpi = 150, bg = "white")
  message("Saved: E1_info_access_direction.png")

  # ── Highlight: ENT1 as positive control ──────────────────────────────────
  ent1_delta <- delta_core %>% filter(variable == "ENT1") %>% pull(mean_abs_delta)
  ent3_delta <- delta_core %>% filter(variable == "ENT3") %>% pull(mean_abs_delta)
  est4_delta <- delta_core %>% filter(variable == "EST4") %>% pull(mean_abs_delta)
  entr3_dir  <- delta_core %>% filter(variable == "ENT3") %>%
    select(pct_A_higher, pct_B_higher)

  message(sprintf("\n  KEY FINDINGS:"))
  message(sprintf("  ENT1 (global distribution — positive control):  |delta| = %.3f", ent1_delta))
  message(sprintf("  ENT3 (import volume — LOCAL_DATA gap):           |delta| = %.3f", ent3_delta))
  message(sprintf("    %s scores higher: %.0f%% | %s scores higher: %.0f%%",
                  LABEL_B, entr3_dir$pct_B_higher,
                  LABEL_A, entr3_dir$pct_A_higher))
  message(sprintf("  EST4 (biological traits — GLOBAL_LIT but high):  |delta| = %.3f", est4_delta))
  message("  EST4 high despite full literature access indicates a REASONING gap,")
  message("  not a data gap. Adding MCP access to SSB will NOT reduce EST4 disagreement.")

  # ── Save interpretation guide ─────────────────────────────────────────────
  interp <- data.frame(
    category        = c("GLOBAL_LIT", "LOCAL_DATA", "LOCAL_REG", "LOCAL_CTX"),
    what_it_means   = c(
      "Both raters have equivalent literature access. Disagreement = different reasoning from same evidence.",
      "AI lacks Norway-specific quantitative data. Adding SSB/Tollvesenet via MCP server expected to reduce disagreement.",
      "AI lacks current Norwegian/EU regulatory status. Adding Mattilsynet/EPPO live data via MCP expected to reduce disagreement.",
      "AI lacks local ecological/cultural context. Partially reducible with open geodata (N2000, AR5 land cover)."
    ),
    expected_delta_direction = c(
      "Variable — depends on how AI and humans reason from global evidence.",
      "AI scores lower for volume-dependent questions (ENT3); AI scores higher for area-dependent (EST2) using global host range.",
      "AI scores higher for unmanaged transport (ENT2A), higher or similar for managed (ENT2B) where AI misses restrictive legislation.",
      "Mixed — depends on whether Norwegian context is more or less favourable than global average."
    ),
    fixable_with_mcp = c(FALSE, TRUE, TRUE, FALSE)
  )
  write.csv(interp, file.path(OUT_DIR, "E1_interpretation_guide.csv"),
            row.names = FALSE)
  message("Saved: E1_interpretation_guide.csv")

} # end if (!is.null(comp_stats))


# =============================================================================
# FINAL SUMMARY
# =============================================================================
message("\n", strrep("=", 60))
message("ANALYSIS COMPLETE")
message(strrep("=", 60))
message(sprintf("Output directory: %s", normalizePath(OUT_DIR)))
message(sprintf("Species analysed: %d", n))
message("")
message("Files saved:")
list.files(OUT_DIR, full.names = FALSE) %>% sort() %>% walk(~ message("  ", .x))
message("")
message("REMOVED (invalid under inter-rater framing):")
message("  ROC / AUC             — required human = truth as outcome variable")
message("  Sensitivity/specificity — same problem")
message("  False negative rate   — same problem")
message("")
message("NEXT STEPS:")
message("  1. A1_kappa_summary.csv     — report quadratic kappa in Results")
message("  2. A2_bland_altman_stats.csv — report mean difference + LoA + proportional")
message("                                  disagreement slope. Use 'inter-rater difference'")
message("                                  language, not 'bias' or 'overestimation'.")
message("  3. A4_rank_concordance.csv  — report Spearman rho as the key discrimination metric")
message("  4. B1_kruskal_wallis_concordance.csv — report both directions")
message("  5. B2_wide_distribution_species.csv  — name these species in Results")
message("  6. Run 3-5 replicate pipeline runs -> feed to compute_icc() in C1")
message("  7. D1 is exploratory at n=63 — flag as such in text")
message("  8. E1_info_access_dotplot.png + E1_info_access_direction.png:")
message("     Review whether LOCAL_DATA (ENT3, EST2, IMP1) shows higher |delta| than GLOBAL_LIT.")
message("     If yes: this supports the MCP server argument for the Discussion.")
message("     If ENT3 shows AI scoring LOWER (humans cite SSB trade volumes AI cannot access),")
message("     that is the clearest data-gap signal in the dataset.")
message("  9. E1_category_summary.csv: compare mean_abs_delta across categories.")
message("     Expected order: LOCAL_DATA >= LOCAL_REG > LOCAL_CTX > GLOBAL_LIT")
message("     (if information access drives disagreement).")
message("     EST4 breaking this pattern (GLOBAL_LIT but high) is itself a finding:")
message("     biological trait reasoning diverges even with equivalent data access.")
