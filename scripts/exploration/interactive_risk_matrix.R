
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
  scale_colour_manual(values = shift_colours, name = NULL, drop = FALSE) +
  scale_x_continuous(breaks = c(1, 2), labels = c(LABEL_B, LABEL_A),
                     limits = c(0.6, 3.2),
                     expand = expansion(0)) +
  scale_y_continuous(breaks = 1:5, labels = RISK_LEVELS,
                     limits = c(0.5, 5.5)) +
  labs(title = "Risk category shifts between assessors",
       subtitle = sprintf(
         "%d pests · %d shift category · %d remain in same category",
         nrow(cat_df),
         sum(cat_df$shift != 0),
         sum(cat_df$shift == 0)),
       x = NULL, y = "Risk category",
       caption = format(Sys.time(), "Generated %Y-%m-%d %H:%M")) +
  pretty_theme +
  theme(panel.grid.major.x = element_blank(),
        panel.grid.minor   = element_blank(),
        axis.text.x = element_text(face = "bold", size = 13))

ggsave(file.path(PLOTS_DIR, "11_risk_category_shifts.png"), p11,
       width = 11, height = 9, dpi = 150, bg = "white")
message("  Saved slope graph.")
