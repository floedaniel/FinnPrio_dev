# 9_db_find_errors.R
# Diagnose errors in a FinnPRIO database and write results to Excel.
# Each sheet covers one entity type; flag_* columns mark specific problems
# (1 = problem, 0 = ok). flag_any = 1 means at least one problem on that row.
# Run when the app shows "[object Object]", crashes, or assessments look wrong.

library(DBI)
library(RSQLite)
library(dplyr)

if (!requireNamespace("openxlsx", quietly = TRUE)) install.packages("openxlsx")
library(openxlsx)

# ── Configuration ─────────────────────────────────────────────────────────────

DB_PATH <- "C:/Users/dafl/Downloads/andrea_db_2026.db"

# Justifications shorter than this (non-empty, non-error) are flagged as too short
MIN_JUSTIFICATION_CHARS <- 20

# Excel output file (written next to the database file)
OUT_XLSX <- sub("\\.db$", "_diagnostics.xlsx", DB_PATH)

# ── Helpers ───────────────────────────────────────────────────────────────────

KNOWN_ERROR_STRINGS <- c(
  "[object Object]", "[object object]",
  "ERROR: 'list' object has no attribute 'split'",
  "undefined", "null"
)

is_error_str  <- function(x) !is.na(x) & trimws(x) %in% KNOWN_ERROR_STRINGS
is_blank      <- function(x) is.na(x) | trimws(x) == ""
is_short_just <- function(x) !is_blank(x) & !is_error_str(x) & nchar(trimws(x)) < MIN_JUSTIFICATION_CHARS

VALID_OPTS <- c("a", "b", "c", "d", "e", "f", "g")
is_bad_opt  <- function(x) !is.na(x) & trimws(x) != "" & !(trimws(x) %in% VALID_OPTS)

fl <- function(x) as.integer(x)   # coerce logical flag to 0/1

add_flag_any <- function(df) {
  flag_cols <- grep("^flag_", names(df), value = TRUE)
  df$flag_any <- as.integer(rowSums(df[, flag_cols, drop = FALSE]) > 0)
  df
}

# ── Connect ───────────────────────────────────────────────────────────────────

con <- dbConnect(SQLite(), DB_PATH)
on.exit(dbDisconnect(con), add = TRUE)

existing <- dbListTables(con)
cat("Connected to:", DB_PATH, "\n")
cat("Tables found:", paste(sort(existing), collapse = ", "), "\n\n")

# ── Sheet: answers ────────────────────────────────────────────────────────────

# Detect the question identifier column (varies across DB versions)
q_cols  <- dbGetQuery(con, "PRAGMA table_info(questions)")$name
q_id_col <- intersect(c("tag", "questionCode", "code", "name", "group"), q_cols)[1]
q_select <- if (!is.na(q_id_col)) sprintf('q."%s" AS question_tag', q_id_col) else "NULL AS question_tag"
q_join   <- if (!is.na(q_id_col)) "LEFT JOIN questions q ON a.idQuestion = q.idQuestion" else ""

cat(sprintf("questions identifier column: %s\n", if (!is.na(q_id_col)) q_id_col else "(none found)"))

ans_raw <- dbGetQuery(con, sprintf("
  SELECT
    a.idAnswer, a.idAssessment, a.idQuestion,
    %s,
    a.min, a.likely, a.max,
    a.justification,
    p.scientificName
  FROM answers a
  LEFT JOIN assessments ass ON a.idAssessment = ass.idAssessment
  LEFT JOIN pests p         ON ass.idPest     = p.idPest
  %s
  ORDER BY a.idAssessment, a.idQuestion
", q_select, q_join))

dup_ans <- paste(ans_raw$idAssessment, ans_raw$idQuestion)

ans_out <- ans_raw %>%
  mutate(
    flag_missing_min           = fl(is_blank(min)),
    flag_missing_likely        = fl(is_blank(likely)),
    flag_missing_max           = fl(is_blank(max)),
    flag_invalid_min           = fl(is_bad_opt(min)),
    flag_invalid_likely        = fl(is_bad_opt(likely)),
    flag_invalid_max           = fl(is_bad_opt(max)),
    flag_empty_justification   = fl(is_blank(justification)),
    flag_short_justification   = fl(is_short_just(justification)),
    flag_error_str_in_just     = fl(is_error_str(justification)),
    flag_orphan_assessment     = fl(is.na(scientificName)),
    flag_orphan_question       = fl(is.na(question_tag)),
    flag_duplicate             = fl(duplicated(dup_ans) | duplicated(dup_ans, fromLast = TRUE))
  ) %>%
  add_flag_any()

# ── Sheet: pathway_answers ────────────────────────────────────────────────────

pq_cols   <- dbGetQuery(con, "PRAGMA table_info(pathwayQuestions)")$name
pq_id_col <- intersect(c("tag", "questionCode", "code", "name", "group"), pq_cols)[1]
pq_select <- if (!is.na(pq_id_col)) sprintf('pq."%s" AS question_tag', pq_id_col) else "NULL AS question_tag"
pq_join   <- if (!is.na(pq_id_col)) "LEFT JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion" else ""

cat(sprintf("pathwayQuestions identifier column: %s\n\n", if (!is.na(pq_id_col)) pq_id_col else "(none found)"))

pans_raw <- dbGetQuery(con, sprintf("
  SELECT
    pa.idPathAnswer, pa.idEntryPathway, pa.idPathQuestion,
    %s,
    ep.idAssessment,
    pw.name              AS pathway_name,
    pa.min, pa.likely, pa.max,
    pa.justification,
    p.scientificName
  FROM pathwayAnswers pa
  LEFT JOIN entryPathways   ep  ON pa.idEntryPathway  = ep.idEntryPathway
  LEFT JOIN assessments     ass ON ep.idAssessment     = ass.idAssessment
  LEFT JOIN pests           p   ON ass.idPest          = p.idPest
  LEFT JOIN pathways        pw  ON ep.idPathway        = pw.idPathway
  %s
  ORDER BY ep.idAssessment, pa.idEntryPathway, pa.idPathQuestion
", pq_select, pq_join))

dup_pans <- paste(pans_raw$idEntryPathway, pans_raw$idPathQuestion)

pans_out <- pans_raw %>%
  mutate(
    flag_missing_min           = fl(is_blank(min)),
    flag_missing_likely        = fl(is_blank(likely)),
    flag_missing_max           = fl(is_blank(max)),
    flag_invalid_min           = fl(is_bad_opt(min)),
    flag_invalid_likely        = fl(is_bad_opt(likely)),
    flag_invalid_max           = fl(is_bad_opt(max)),
    flag_empty_justification   = fl(is_blank(justification)),
    flag_short_justification   = fl(is_short_just(justification)),
    flag_error_str_in_just     = fl(is_error_str(justification)),
    flag_orphan_entry_pathway  = fl(is.na(scientificName)),
    flag_orphan_question       = fl(is.na(question_tag)),
    flag_duplicate             = fl(duplicated(dup_pans) | duplicated(dup_pans, fromLast = TRUE))
  ) %>%
  add_flag_any()

# ── Sheet: pests ──────────────────────────────────────────────────────────────

pests_raw <- dbGetQuery(con, "SELECT * FROM pests ORDER BY idPest")

pests_out <- pests_raw %>%
  mutate(
    flag_null_scientific_name   = fl(is_blank(scientificName)),
    flag_null_eppo_code         = fl(is_blank(eppoCode)),
    flag_null_taxa              = fl(is.na(idTaxa)),
    flag_null_quarantine_status = fl(is.na(idQuarantineStatus))
  ) %>%
  add_flag_any()

# ── Sheet: assessors ──────────────────────────────────────────────────────────

assessors_raw <- dbGetQuery(con, "SELECT * FROM assessors ORDER BY idAssessor")

# Handle both old schema (assessorName) and new schema (firstName / lastName)
has_split_name <- all(c("firstName", "lastName") %in% names(assessors_raw))

if (has_split_name) {
  assessors_out <- assessors_raw %>%
    mutate(
      flag_null_first_name = fl(is_blank(firstName)),
      flag_null_last_name  = fl(is_blank(lastName))
    ) %>%
    add_flag_any()
} else {
  assessors_out <- assessors_raw %>%
    mutate(
      flag_null_assessor_name = fl(is_blank(assessorName))
    ) %>%
    add_flag_any()
}

# ── Sheet: assessments ────────────────────────────────────────────────────────

ass_raw <- dbGetQuery(con, "
  SELECT
    a.*,
    p.scientificName,
    ass.firstName, ass.lastName
  FROM assessments a
  LEFT JOIN pests     p   ON a.idPest     = p.idPest
  LEFT JOIN assessors ass ON a.idAssessor = ass.idAssessor
  ORDER BY a.idAssessment
")

ass_out <- ass_raw %>%
  mutate(
    flag_missing_pest     = fl(is.na(scientificName)),
    flag_missing_assessor = fl(is.na(firstName) & is.na(lastName))
  ) %>%
  add_flag_any()

# ── Sheet: summary ────────────────────────────────────────────────────────────

count_sheet_flags <- function(sheet_name, df) {
  flag_cols <- setdiff(grep("^flag_", names(df), value = TRUE), "flag_any")
  n_rows <- nrow(df)
  data.frame(
    sheet      = sheet_name,
    flag       = flag_cols,
    n_flagged  = sapply(flag_cols, function(c) sum(df[[c]], na.rm = TRUE)),
    total_rows = n_rows,
    stringsAsFactors = FALSE
  )
}

summary_df <- bind_rows(
  count_sheet_flags("answers",         ans_out),
  count_sheet_flags("pathway_answers", pans_out),
  count_sheet_flags("pests",           pests_out),
  count_sheet_flags("assessors",       assessors_out),
  count_sheet_flags("assessments",     ass_out)
) %>%
  filter(n_flagged > 0) %>%
  mutate(pct_flagged = round(100 * n_flagged / total_rows, 1)) %>%
  arrange(desc(n_flagged))

cat(sprintf("Total problem flags: %d\n\n", sum(summary_df$n_flagged)))
if (nrow(summary_df) > 0) print(summary_df) else cat("No problems found.\n")

# ── Write Excel ───────────────────────────────────────────────────────────────

wb <- createWorkbook()

style_header  <- createStyle(fontColour = "#FFFFFF", fgFill = "#2C3E50",
                              textDecoration = "Bold", halign = "CENTER",
                              border = "Bottom", borderColour = "#FFFFFF")
style_flag1   <- createStyle(fgFill = "#FFCCCC", halign = "CENTER")  # problem
style_flag0   <- createStyle(fgFill = "#CCFFCC", halign = "CENTER")  # ok
style_flag_any1 <- createStyle(fgFill = "#FF6666", halign = "CENTER", textDecoration = "Bold")

write_sheet <- function(wb, name, df) {
  addWorksheet(wb, name)
  writeDataTable(wb, name, df, tableStyle = "TableStyleMedium9", withFilter = TRUE)
  freezePane(wb, name, firstRow = TRUE)
  addStyle(wb, name, style_header, rows = 1, cols = seq_len(ncol(df)), gridExpand = TRUE)
  setColWidths(wb, name, cols = seq_len(ncol(df)), widths = "auto")

  flag_cols <- grep("^flag_", names(df))
  if (length(flag_cols) == 0 || nrow(df) == 0) return(invisible())

  any_col <- which(names(df) == "flag_any")

  for (ci in flag_cols) {
    rows1 <- which(df[[ci]] == 1) + 1L
    rows0 <- which(df[[ci]] == 0) + 1L
    sty   <- if (ci == any_col) style_flag_any1 else style_flag1
    if (length(rows1)) addStyle(wb, name, sty,        rows = rows1, cols = ci, gridExpand = TRUE)
    if (length(rows0)) addStyle(wb, name, style_flag0, rows = rows0, cols = ci, gridExpand = TRUE)
  }
}

# Summary sheet first
addWorksheet(wb, "summary")
writeDataTable(wb, "summary", summary_df, tableStyle = "TableStyleMedium2", withFilter = TRUE)
freezePane(wb, "summary", firstRow = TRUE)
addStyle(wb, "summary", style_header, rows = 1, cols = seq_len(ncol(summary_df)), gridExpand = TRUE)
setColWidths(wb, "summary", cols = seq_len(ncol(summary_df)), widths = "auto")

write_sheet(wb, "answers",         ans_out)
write_sheet(wb, "pathway_answers", pans_out)
write_sheet(wb, "pests",           pests_out)
write_sheet(wb, "assessors",       assessors_out)
write_sheet(wb, "assessments",     ass_out)

saveWorkbook(wb, OUT_XLSX, overwrite = TRUE)
cat(sprintf("\nDiagnostics saved to:\n  %s\n", OUT_XLSX))
