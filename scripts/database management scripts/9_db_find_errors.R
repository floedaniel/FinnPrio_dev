# 9_db_find_errors.R
# Quick diagnostic: prints ONLY erroneous answer entries, grouped by species,
# and writes a distributable Excel file with the same information.
# Standard questions: error if missing justification or any of min/likely/max.
# Boolean questions: error if partially filled, or fully filled with no justification.

library(DBI)
library(RSQLite)
library(dplyr)
if (!requireNamespace("openxlsx", quietly = TRUE)) install.packages("openxlsx")
library(openxlsx)

# ── Configuration ─────────────────────────────────────────────────────────────
DB_PATH  <- "C:/Dev/FinnPrio/FinnPRIO_development/databases/finnprio_2026/jorunn_database_2026/4_master/jorunn.db"
OUT_XLSX <- sub("\\.db$", "_errors.xlsx", DB_PATH)

# ── Connect ───────────────────────────────────────────────────────────────────
con <- dbConnect(SQLite(), DB_PATH)
on.exit(dbDisconnect(con), add = TRUE)
cat("Connected:", DB_PATH, "\n\n")

# ── Helpers ───────────────────────────────────────────────────────────────────
CORRUPT_STRINGS <- c("[object Object]", "[object object]",
                     "ERROR: 'list' object has no attribute 'split'",
                     "undefined", "null")

is_blank   <- function(x) is.na(x) | trimws(x) == ""
is_corrupt <- function(x) !is.na(x) & trimws(x) %in% CORRUPT_STRINGS
just_ok    <- function(x) !is_blank(x) & !is_corrupt(x)
fmt_val    <- function(x) if (is_blank(x)) "(empty)" else substr(trimws(x), 1, 10)

# ── Question lookup ───────────────────────────────────────────────────────────
q_lookup <- dbGetQuery(con, 'SELECT idQuestion, "group", number, type FROM questions') %>%
  mutate(
    code       = paste0(group, number),
    is_boolean = !is.na(type) & type == "boolean"
  ) %>%
  select(idQuestion, code, is_boolean)

pq_lookup <- dbGetQuery(con, 'SELECT idPathQuestion, "group", number FROM pathwayQuestions') %>%
  mutate(code = paste0(group, number), is_boolean = FALSE) %>%
  select(idPathQuestion, code, is_boolean)

# ── Fetch answers ─────────────────────────────────────────────────────────────
answers_raw <- dbGetQuery(con, "
  SELECT a.idAssessment, a.idQuestion,
         a.min, a.likely, a.max, a.justification,
         p.eppoCode, p.scientificName
  FROM answers a
  LEFT JOIN assessments ass ON a.idAssessment = ass.idAssessment
  LEFT JOIN pests p ON ass.idPest = p.idPest
") %>%
  left_join(q_lookup, by = "idQuestion") %>%
  mutate(pathway_label = NA_character_) %>%
  select(idAssessment, code, is_boolean, pathway_label,
         min, likely, max, justification, eppoCode, scientificName)

pathway_answers_raw <- dbGetQuery(con, "
  SELECT ep.idAssessment, pa.idPathQuestion,
         pw.name AS pathway_label,
         pa.min, pa.likely, pa.max, pa.justification,
         p.eppoCode, p.scientificName
  FROM pathwayAnswers pa
  LEFT JOIN entryPathways ep  ON pa.idEntryPathway = ep.idEntryPathway
  LEFT JOIN pathways      pw  ON ep.idPathway      = pw.idPathway
  LEFT JOIN assessments   ass ON ep.idAssessment   = ass.idAssessment
  LEFT JOIN pests         p   ON ass.idPest        = p.idPest
") %>%
  left_join(pq_lookup, by = "idPathQuestion") %>%
  select(idAssessment, code, is_boolean, pathway_label,
         min, likely, max, justification, eppoCode, scientificName)

all_answers <- bind_rows(answers_raw, pathway_answers_raw)

# ── Detect errors ─────────────────────────────────────────────────────────────
check_problems <- function(min, likely, max, justification, is_boolean) {
  n_filled <- sum(!is_blank(c(min, likely, max)))
  probs <- character(0)
  if (isTRUE(is_boolean)) {
    if (n_filled > 0 && n_filled < 3) {
      probs <- c(probs, sprintf("partial fill (%d/3 PERT fields set)", n_filled))
    } else if (n_filled == 3 && !just_ok(justification)) {
      probs <- c(probs, "missing justification (answer is yes)")
    }
  } else {
    if (is_blank(min))           probs <- c(probs, "missing minimum")
    if (is_blank(likely))        probs <- c(probs, "missing most_likely")
    if (is_blank(max))           probs <- c(probs, "missing maximum")
    if (!just_ok(justification)) probs <- c(probs, "missing justification")
  }
  paste(probs, collapse = "; ")
}

all_answers$problems <- mapply(
  check_problems,
  all_answers$min, all_answers$likely, all_answers$max,
  all_answers$justification, all_answers$is_boolean,
  SIMPLIFY = TRUE
)

errors <- all_answers %>%
  filter(nchar(problems) > 0) %>%
  mutate(
    species_key = paste0(
      ifelse(is.na(eppoCode),       "(unknown)", eppoCode),      " | ",
      ifelse(is.na(scientificName), "(unknown)", scientificName)
    ),
    q_label = ifelse(
      !is.na(pathway_label),
      paste0(ifelse(is.na(code), "?", code), " [", pathway_label, "]"),
      ifelse(is.na(code), "?", code)
    )
  ) %>%
  arrange(species_key, idAssessment, q_label)

# ── Print results ─────────────────────────────────────────────────────────────
species_list <- unique(errors$species_key)
total_issues <- nrow(errors)

if (length(species_list) == 0) {
  cat("No errors found.\n")
} else {
  BAR <- strrep("-", 74)
  for (sp in species_list) {
    sp_err <- errors[errors$species_key == sp, ]
    cat(sprintf("\n%s\n  %s\n%s\n", BAR, sp, BAR))
    for (i in seq_len(nrow(sp_err))) {
      r <- sp_err[i, ]
      just_display <-
        if      (is_blank(r$justification))   "(empty)"
        else if (is_corrupt(r$justification)) paste0("[CORRUPT: ", trimws(r$justification), "]")
        else paste0('"', substr(trimws(r$justification), 1, 60),
                    if (nchar(trimws(r$justification)) > 60) '..."' else '"')
      cat(sprintf(
        "  [#%-3d]  %-35s  %s\n          min=%-10s  likely=%-10s  max=%-10s\n          just: %s\n",
        r$idAssessment, r$q_label, r$problems,
        fmt_val(r$min), fmt_val(r$likely), fmt_val(r$max),
        just_display
      ))
    }
  }
  cat(sprintf(
    "\n%s\n  %d species with errors, %d total issues\n%s\n",
    strrep("=", 74), length(species_list), total_issues, strrep("=", 74)
  ))
}

# ── Excel output ──────────────────────────────────────────────────────────────
if (total_issues == 0) {
  cat("No errors — Excel file not written.\n")
} else {

  # ── Styles ─────────────────────────────────────────────────────────────────
  sty_header <- createStyle(
    fontColour = "#FFFFFF", fgFill = "#1F4E79",
    textDecoration = "Bold", halign = "LEFT",
    border = "Bottom", borderColour = "#AAAAAA"
  )
  sty_warn    <- createStyle(fgFill = "#FFF3CD")  # amber  — problem cell
  sty_missing <- createStyle(fgFill = "#FFCDD2")  # pink   — empty value
  sty_corrupt <- createStyle(fgFill = "#EF9A9A")  # red    — corrupt value
  sty_wrap    <- createStyle(wrapText = TRUE, valign = "top")

  wb <- createWorkbook()

  # ── Sheet 1: Errors (one row per flagged answer) ───────────────────────────
  xl_errors <- errors %>%
    transmute(
      `EPPO Code`       = ifelse(is.na(eppoCode),       "(unknown)", eppoCode),
      `Scientific Name` = ifelse(is.na(scientificName), "(unknown)", scientificName),
      `Assessment #`    = idAssessment,
      `Question`        = ifelse(is.na(code), "?", code),
      `Pathway`         = ifelse(is.na(pathway_label), "", pathway_label),
      `Minimum`         = ifelse(is_blank(min),    "MISSING!", min),
      `Most Likely`     = ifelse(is_blank(likely), "MISSING!", likely),
      `Maximum`         = ifelse(is_blank(max),    "MISSING!", max),
      `Justification`   = ifelse(is_blank(justification), "MISSING!", justification)
    )

  addWorksheet(wb, "Errors")
  writeDataTable(wb, "Errors", xl_errors,
                 tableStyle = "TableStyleLight1", withFilter = TRUE)
  freezePane(wb, "Errors", firstRow = TRUE)
  addStyle(wb, "Errors", sty_header,
           rows = 1, cols = 1:9, gridExpand = TRUE, stack = FALSE)

  setColWidths(wb, "Errors", cols = 1,   widths = 12)   # EPPO Code
  setColWidths(wb, "Errors", cols = 2,   widths = 28)   # Scientific Name
  setColWidths(wb, "Errors", cols = 3,   widths = 13)   # Assessment #
  setColWidths(wb, "Errors", cols = 4,   widths = 14)   # Question
  setColWidths(wb, "Errors", cols = 5,   widths = 32)   # Pathway
  setColWidths(wb, "Errors", cols = 6:8, widths = 12)   # min / likely / max
  setColWidths(wb, "Errors", cols = 9,   widths = 70)   # Justification

  addStyle(wb, "Errors", sty_wrap,
           rows = seq_len(nrow(xl_errors)) + 1L, cols = 9,
           gridExpand = TRUE, stack = TRUE)

  # Excel data rows are offset by 1 (row 1 = header)
  row_miss_min     <- which(grepl("missing minimum",     errors$problems)) + 1L
  row_miss_likely  <- which(grepl("missing most_likely", errors$problems)) + 1L
  row_miss_max     <- which(grepl("missing maximum",     errors$problems)) + 1L
  row_miss_just    <- which(grepl("missing justification|partial fill",
                                   errors$problems)) + 1L
  row_partial      <- which(grepl("partial fill",        errors$problems)) + 1L
  row_corrupt_just <- which(is_corrupt(errors$justification)) + 1L

  # Pink on empty PERT cells
  if (length(row_miss_min))    addStyle(wb, "Errors", sty_missing, rows = row_miss_min,    cols = 6, stack = TRUE)
  if (length(row_miss_likely)) addStyle(wb, "Errors", sty_missing, rows = row_miss_likely, cols = 7, stack = TRUE)
  if (length(row_miss_max))    addStyle(wb, "Errors", sty_missing, rows = row_miss_max,    cols = 8, stack = TRUE)
  # Pink on missing justification, red on corrupt
  if (length(row_miss_just))    addStyle(wb, "Errors", sty_missing, rows = row_miss_just,    cols = 9, stack = TRUE)
  if (length(row_corrupt_just)) addStyle(wb, "Errors", sty_corrupt, rows = row_corrupt_just, cols = 9, stack = TRUE)
  # Amber on all three PERT cells for partial-fill booleans (some filled, some not)
  if (length(row_partial)) {
    addStyle(wb, "Errors", sty_warn, rows = row_partial, cols = 6, stack = TRUE)
    addStyle(wb, "Errors", sty_warn, rows = row_partial, cols = 7, stack = TRUE)
    addStyle(wb, "Errors", sty_warn, rows = row_partial, cols = 8, stack = TRUE)
  }

  # ── Sheet 2: Summary (one row per species, sorted by issue count) ──────────
  xl_summary <- errors %>%
    group_by(
      `EPPO Code`       = ifelse(is.na(eppoCode),       "(unknown)", eppoCode),
      `Scientific Name` = ifelse(is.na(scientificName), "(unknown)", scientificName)
    ) %>%
    summarise(`Issues` = n(), .groups = "drop") %>%
    arrange(desc(Issues))

  addWorksheet(wb, "Summary")
  writeDataTable(wb, "Summary", xl_summary,
                 tableStyle = "TableStyleLight1", withFilter = TRUE)
  freezePane(wb, "Summary", firstRow = TRUE)
  addStyle(wb, "Summary", sty_header,
           rows = 1, cols = 1:3, gridExpand = TRUE, stack = FALSE)
  setColWidths(wb, "Summary", cols = 1, widths = 12)
  setColWidths(wb, "Summary", cols = 2, widths = 30)
  setColWidths(wb, "Summary", cols = 3, widths = 10)
  # Amber on the Issues count column so it draws the eye
  addStyle(wb, "Summary", sty_warn,
           rows = seq_len(nrow(xl_summary)) + 1L, cols = 3,
           gridExpand = TRUE, stack = TRUE)

  saveWorkbook(wb, OUT_XLSX, overwrite = TRUE)
  cat(sprintf("\nExcel saved to:\n  %s\n", OUT_XLSX))
}
