################################################################################
# FinnPRIO: Simulation Trace Export
#
# Like 7_batch_simulation.R, but captures every per-iteration Monte Carlo
# vector (every question + every intermediate) and writes the full trace to a
# .rds file as a list(metadata = df, traces = list_keyed_by_A{id}).
# Companion script 'compare_distributions.R' consumes two such files
# (e.g. AI vs. human) and runs statistical comparisons.
#
# This script is self-contained: it copies the simulation math from
# R/simulations.R so that file is not modified.
################################################################################

library(DBI)
library(RSQLite)
library(tidyverse)
library(mc2d)
library(lubridate)
library(glue)
library(jsonlite)

source("R/internal functions.R")   # get_points_as_table()

# =============================================================================
# CONFIGURATION
# =============================================================================
# AI
 DB_PATH     <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/comparison/FinnPrio_fg9_batch_1_2025_v001_2026-04-17T14-33-38.db"
 OUTPUT_RDS <- "./scripts/exploration/output/trace_ai.rds"


# Homan
# DB_PATH     <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/comparison/FinnPrio_fg9_batch_1_2025.db"
# OUTPUT_RDS <- "./scripts/exploration/output/trace_human.rds"

ITERATIONS <- 50000
LAMBDA     <- 1
WEIGHT1    <- 0.5
WEIGHT2    <- 0.5

ONLY_FINISHED       <- FALSE
ONLY_VALID          <- FALSE
SPECIFIC_ASSESSMENT <- NULL

# =============================================================================

rpert_from_tag <- function(answers, tag, iterations, lambda) {
  p <- answers[answers$question == tag, c("min_points", "likely_points", "max_points")] |>
    as.numeric()
  mc2d::rpert(iterations, p[1], p[2], p[3], lambda)
}

inclusion_exclusion <- function(score_matrix) {
  if (is.vector(score_matrix)) return(score_matrix)
  n <- ncol(score_matrix); iters <- nrow(score_matrix)
  out <- numeric(iters)
  for (k in seq_len(n)) {
    sign <- if (k %% 2 == 1) 1 else -1
    for (combo in combn(n, k, simplify = FALSE)) {
      out <- out + sign * apply(score_matrix[, combo, drop = FALSE], 1, prod)
    }
  }
  out
}

prepare_answers_data <- function(con, id_assessment, points_main) {
  ans <- dbGetQuery(con, "
    SELECT a.idAnswer, a.idAssessment, a.idQuestion, q.[group], q.number,
           q.subgroup, a.min, a.likely, a.max
    FROM answers a JOIN questions q ON a.idQuestion = q.idQuestion
    WHERE a.idAssessment = ?", params = list(id_assessment))
  if (nrow(ans) == 0) return(NULL)

  df <- ans |> rename_with(tolower) |>
    mutate(question = paste0(group, number)) |>
    left_join(points_main, by = c("question" = "Question", "min" = "Option"))    |> rename(min_points = Points) |>
    left_join(points_main, by = c("question" = "Question", "likely" = "Option")) |> rename(likely_points = Points) |>
    left_join(points_main, by = c("question" = "Question", "max" = "Option"))    |> rename(max_points = Points) |>
    mutate(across(c(min_points, likely_points, max_points), ~ ifelse(is.na(.x), 0, .x))) |>
    mutate(question = case_when(
      question %in% c("IMP2.1", "IMP2.2", "IMP2.3") ~ "IMP2",
      question %in% c("IMP4.1", "IMP4.2", "IMP4.3") ~ "IMP4",
      TRUE ~ question)) |>
    group_by(question) |>
    summarise(min_points    = sum(as.numeric(min_points),    na.rm = TRUE),
              likely_points = sum(as.numeric(likely_points), na.rm = TRUE),
              max_points    = sum(as.numeric(max_points),    na.rm = TRUE),
              .groups = "drop") |>
    as.data.frame()

  for (q in c("IMP2", "IMP4")) {
    if (!q %in% df$question)
      df <- rbind(df, data.frame(question = q, min_points = 0, likely_points = 0, max_points = 0))
  }
  df
}

prepare_pathway_answers_data <- function(con, id_assessment, points_entry) {
  raw <- dbGetQuery(con, "
    SELECT pa.idPathAnswer, ep.idAssessment, ep.idPathway as idpathway,
           pq.[group], pq.number, pa.min, pa.likely, pa.max
    FROM pathwayAnswers pa
    JOIN entryPathways    ep ON pa.idEntryPathway = ep.idEntryPathway
    JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
    WHERE ep.idAssessment = ?", params = list(id_assessment))
  if (nrow(raw) == 0) return(NULL)

  raw |> rename_with(tolower) |>
    mutate(question = paste0(group, number)) |>
    left_join(points_entry, by = c("question" = "Question", "min" = "Option"))    |> rename(min_points = Points) |>
    left_join(points_entry, by = c("question" = "Question", "likely" = "Option")) |> rename(likely_points = Points) |>
    left_join(points_entry, by = c("question" = "Question", "max" = "Option"))    |> rename(max_points = Points) |>
    mutate(across(c(min_points, likely_points, max_points), ~ ifelse(is.na(.x), 0, .x)))
}

# PERT validity: returns rows where min/likely/max violate min <= likely <= max.
check_pert_validity <- function(df) {
  df |>
    filter(likely_points < min_points |
           likely_points > max_points |
           min_points    > max_points)
}

# Clamp likely_points into [min, max] (after re-ordering min/max if swapped).
fix_pert_bounds <- function(df) {
  df |>
    mutate(.lo = pmin(min_points, max_points),
           .hi = pmax(min_points, max_points),
           likely_points = pmin(pmax(likely_points, .lo), .hi),
           min_points    = .lo,
           max_points    = .hi) |>
    select(-.lo, -.hi)
}

# Mirror of R/simulations.R::simulation() that also returns every per-iteration
# vector (per-question PERT draws + intermediates), not just aggregates.
simulation_trace <- function(answers, answers_entry, pathways,
                             iterations, lambda, w1, w2) {
  used <- unique(answers_entry$idpathway)
  out  <- list(iteration = seq_len(iterations))

  ENT1 <- rpert_from_tag(answers, "ENT1", iterations, lambda)
  out$ENT1 <- ENT1

  scoreA <- matrix(0, iterations, length(used))
  scoreB <- matrix(0, iterations, length(used))

  for (up in seq_along(used)) {
    p  <- used[up]
    g  <- pathways |> filter(idPathway == p) |> pull(group)
    ae <- answers_entry |> filter(idpathway == p)

    ENT2A <- rpert_from_tag(ae, "ENT2A", iterations, lambda)
    ENT2B <- rpert_from_tag(ae, "ENT2B", iterations, lambda)
    ENT3  <- rpert_from_tag(ae, "ENT3",  iterations, lambda)
    ENT4  <- rpert_from_tag(ae, "ENT4",  iterations, lambda)

    ENT3A <- case_when(
      ENT2A > 2.5 & ENT3 > 0.5                       ~ 3,
      ENT2A < 2.5 & ENT2A > 1.5 & ENT3 > 1.5         ~ 3,
      ENT2A < 0.25                                   ~ 0,
      TRUE                                           ~ ENT3)
    ENT3B <- case_when(
      ENT2B > 2.5 & ENT3 > 0.5                       ~ 3,
      ENT2B < 2.5 & ENT2B > 1.5 & ENT3 > 1.5         ~ 3,
      ENT2B < 0.25                                   ~ 0,
      TRUE                                           ~ ENT3)

    sA <- if (g == 1) (ENT1 * ENT2A * ENT3A * ENT4) / 81
          else if (g == 2) (ENT1 * ENT2A * ENT4) / 27
          else if (g == 3) (ENT2A * ENT4) / 9
          else rep(NA_real_, iterations)
    sB <- if (g == 1) (ENT1 * ENT2B * ENT3B * ENT4) / 81
          else if (g == 2) (ENT1 * ENT2B * ENT4) / 27
          else if (g == 3) (ENT2B * ENT4) / 9
          else rep(NA_real_, iterations)

    tag <- paste0("path", p)
    out[[paste0("ENT2A_",  tag)]] <- ENT2A
    out[[paste0("ENT2B_",  tag)]] <- ENT2B
    out[[paste0("ENT3_",   tag)]] <- ENT3
    out[[paste0("ENT3A_",  tag)]] <- ENT3A
    out[[paste0("ENT3B_",  tag)]] <- ENT3B
    out[[paste0("ENT4_",   tag)]] <- ENT4
    out[[paste0("scoreA_", tag)]] <- sA
    out[[paste0("scoreB_", tag)]] <- sB

    scoreA[, up] <- sA
    scoreB[, up] <- sB
  }

  out$ENTRYA <- inclusion_exclusion(scoreA)
  out$ENTRYB <- inclusion_exclusion(scoreB)

  EST1 <- rpert_from_tag(answers, "EST1", iterations, lambda)
  EST2 <- rpert_from_tag(answers, "EST2", iterations, lambda)
  EST3 <- rpert_from_tag(answers, "EST3", iterations, lambda)
  EST4 <- rpert_from_tag(answers, "EST4", iterations, lambda)

  SPR1 <- case_when(
    EST3 > 2.5                 & EST2 > 3.5                  ~ 6,
    EST3 > 2.5                 & EST2 > 2.5 & EST2 < 3.5     ~ 7,
    EST3 > 2.5                 & EST2 > 1.5 & EST2 < 2.5     ~ 8,
    EST3 > 2.5                 & EST2 > 0.5 & EST2 < 1.5     ~ 9,
    EST3 < 2.5 & EST3 > 1.5    & EST2 > 3.5                  ~ 4,
    EST3 < 2.5 & EST3 > 1.5    & EST2 > 2.5 & EST2 < 3.5     ~ 5,
    EST3 < 2.5 & EST3 > 1.5    & EST2 > 1.5 & EST2 < 2.5     ~ 6,
    EST3 < 2.5 & EST3 > 1.5    & EST2 > 0.5 & EST2 < 1.5     ~ 7,
    EST3 < 1.5 & EST3 > 0.5    & EST2 > 3.5                  ~ 2,
    EST3 < 1.5 & EST3 > 0.5    & EST2 > 2.5 & EST2 < 3.5     ~ 3,
    EST3 < 1.5 & EST3 > 0.5    & EST2 > 1.5 & EST2 < 2.5     ~ 4,
    EST3 < 1.5 & EST3 > 0.5    & EST2 > 0.5 & EST2 < 1.5     ~ 5,
    EST3 < 0.5                 & EST2 > 2.5                  ~ 1,
    EST3 < 0.5                 & EST2 > 1.5 & EST2 < 2.5     ~ 2,
    EST3 < 0.5                 & EST2 > 0.5 & EST2 < 1.5     ~ 3,
    EST2 < 0.5                                               ~ 0,
    TRUE                                                     ~ NA_real_)

  ESTABLISHMENT <- case_when(
    EST1 < 0.75 ~ 0,
    EST2 < 0.5  ~ 0,
    TRUE ~ (EST1 + SPR1 + EST4) / 21)

  out$EST1 <- EST1; out$EST2 <- EST2; out$EST3 <- EST3; out$EST4 <- EST4
  out$SPR1 <- SPR1; out$ESTABLISHMENT <- ESTABLISHMENT
  out$INVASIONA <- out$ENTRYA * ESTABLISHMENT
  out$INVASIONB <- out$ENTRYB * ESTABLISHMENT

  IMP1 <- rpert_from_tag(answers, "IMP1", iterations, lambda)
  IMP2 <- rpert_from_tag(answers, "IMP2", iterations, lambda)
  IMP3 <- rpert_from_tag(answers, "IMP3", iterations, lambda)
  IMP4 <- rpert_from_tag(answers, "IMP4", iterations, lambda)
  IMPACT <- ((w1 * (IMP1 + IMP2)) + (w2 * (IMP3 + IMP4))) / 9
  out$IMP1 <- IMP1; out$IMP2 <- IMP2; out$IMP3 <- IMP3; out$IMP4 <- IMP4
  out$IMPACT <- IMPACT
  out$RISKA  <- IMPACT * out$INVASIONA
  out$RISKB  <- IMPACT * out$INVASIONB

  MAN1 <- rpert_from_tag(answers, "MAN1", iterations, lambda)
  MAN2 <- rpert_from_tag(answers, "MAN2", iterations, lambda)
  MAN3 <- rpert_from_tag(answers, "MAN3", iterations, lambda)
  MAN4 <- rpert_from_tag(answers, "MAN4", iterations, lambda)
  MAN5 <- rpert_from_tag(answers, "MAN5", iterations, lambda)
  out$MAN1 <- MAN1; out$MAN2 <- MAN2; out$MAN3 <- MAN3
  out$MAN4 <- MAN4; out$MAN5 <- MAN5
  out$PREVENTABILITY  <- pmax(MAN1, MAN2, MAN3) / 4
  out$CONTROLLABILITY <- pmax(MAN4, MAN5) / 4
  out$MANAGEABILITY   <- pmin(out$PREVENTABILITY, out$CONTROLLABILITY)

  as.data.frame(out)
}

get_assessments <- function(con, only_finished, only_valid, specific) {
  if (!is.null(specific)) {
    return(dbGetQuery(con,
      "SELECT idAssessment, idPest FROM assessments WHERE idAssessment = ?",
      params = list(specific)))
  }
  q <- "SELECT idAssessment, idPest FROM assessments WHERE 1=1"
  if (only_finished) q <- paste(q, "AND finished = 1")
  if (only_valid)    q <- paste(q, "AND valid = 1")
  dbGetQuery(con, paste(q, "ORDER BY idAssessment"))
}

get_pest_name <- function(con, id_pest) {
  r <- dbGetQuery(con, "SELECT scientificName FROM pests WHERE idPest = ?",
                  params = list(id_pest))
  if (nrow(r) == 0) "Unknown" else r$scientificName
}

main <- function() {
  stopifnot(file.exists(DB_PATH))
  dir.create(dirname(OUTPUT_RDS), recursive = TRUE, showWarnings = FALSE)

  con <- dbConnect(RSQLite::SQLite(), DB_PATH)
  on.exit(dbDisconnect(con))

  questions_main  <- dbGetQuery(con, "SELECT * FROM questions")
  questions_entry <- dbGetQuery(con, "SELECT * FROM pathwayQuestions")
  points_main     <- get_points_as_table(questions_main)
  points_entry    <- get_points_as_table(questions_entry)
  pathways_df     <- dbReadTable(con, "pathways")

  assessments <- get_assessments(con, ONLY_FINISHED, ONLY_VALID, SPECIFIC_ASSESSMENT)
  if (nrow(assessments) == 0) { cat("No assessments.\n"); return(invisible()) }

  traces  <- list()
  bad_log <- data.frame()
  meta    <- data.frame()
  for (i in seq_len(nrow(assessments))) {
    id   <- assessments$idAssessment[i]
    idp  <- assessments$idPest[i]
    pest <- get_pest_name(con, idp)
    cat(sprintf("[%d/%d] A%d  %s ... ", i, nrow(assessments), id, pest))

    ans   <- prepare_answers_data(con, id, points_main)
    ans_e <- prepare_pathway_answers_data(con, id, points_entry)
    if (is.null(ans) || is.null(ans_e)) { cat("skip (no data)\n"); next }

    bad_main <- check_pert_validity(ans)
    bad_path <- check_pert_validity(ans_e)
    if (nrow(bad_main) + nrow(bad_path) > 0) {
      cat("\n")
      for (rr in seq_len(nrow(bad_main))) {
        cat(sprintf("    PERT bad: %s  min=%.3f likely=%.3f max=%.3f\n",
                    bad_main$question[rr], bad_main$min_points[rr],
                    bad_main$likely_points[rr], bad_main$max_points[rr]))
      }
      for (rr in seq_len(nrow(bad_path))) {
        cat(sprintf("    PERT bad: %s (path %s)  min=%.3f likely=%.3f max=%.3f\n",
                    bad_path$question[rr], bad_path$idpathway[rr],
                    bad_path$min_points[rr], bad_path$likely_points[rr],
                    bad_path$max_points[rr]))
      }
      if (nrow(bad_main) > 0)
        bad_log <- rbind(bad_log, data.frame(
          idAssessment = id, scientificName = pest, idPathway = NA_integer_,
          question = bad_main$question, min = bad_main$min_points,
          likely = bad_main$likely_points, max = bad_main$max_points))
      if (nrow(bad_path) > 0)
        bad_log <- rbind(bad_log, data.frame(
          idAssessment = id, scientificName = pest,
          idPathway = bad_path$idpathway, question = bad_path$question,
          min = bad_path$min_points, likely = bad_path$likely_points,
          max = bad_path$max_points))
      ans   <- fix_pert_bounds(ans)
      ans_e <- fix_pert_bounds(ans_e)
      cat(sprintf("  [A%d %s] clamped, continuing ... ", id, pest))
    }

    trace <- tryCatch(
      simulation_trace(ans, ans_e, pathways_df,
                       iterations = ITERATIONS, lambda = LAMBDA,
                       w1 = WEIGHT1, w2 = WEIGHT2),
      error = function(e) { cat("ERROR: ", conditionMessage(e), "\n"); NULL })
    if (is.null(trace)) next

    sh <- paste0("A", id)
    traces[[sh]] <- trace

    paths_used <- unique(ans_e$idpathway)
    path_names <- pathways_df |>
      filter(idPathway %in% paths_used) |>
      arrange(match(idPathway, paths_used)) |>
      mutate(lbl = paste0(idPathway, ":", name)) |>
      pull(lbl) |> paste(collapse = "; ")

    meta <- rbind(meta, data.frame(
      sheet          = sh,
      idAssessment   = id,
      idPest         = idp,
      scientificName = pest,
      iterations     = ITERATIONS,
      lambda         = LAMBDA,
      weight1        = WEIGHT1,
      weight2        = WEIGHT2,
      pathways       = path_names,
      generated_at   = format(now("UTC"), "%Y-%m-%d %H:%M:%S")
    ))
    cat("ok\n")
  }

  if (nrow(bad_log) > 0) {
    bad_csv <- sub("\\.rds$", "_bad_pert_inputs.csv", OUTPUT_RDS)
    write.csv(bad_log, bad_csv, row.names = FALSE)
    cat(sprintf("\n%d PERT-input violation(s) clamped across %d assessment(s).\n",
                nrow(bad_log), length(unique(bad_log$idAssessment))))
    cat(sprintf("  Details: %s\n", bad_csv))
  } else {
    cat("\nAll PERT inputs valid.\n")
  }

  cat(sprintf("\nWriting rds to disk: %s\n", OUTPUT_RDS))
  cat(sprintf("  %d traces x %d iterations...\n", length(traces), ITERATIONS))
  t0 <- Sys.time()
  saveRDS(list(metadata = meta, traces = traces), OUTPUT_RDS)
  dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  sz <- file.info(OUTPUT_RDS)$size / 1024^2
  cat(sprintf("  done in %.1f s (%.1f MB)\n", dt, sz))
  cat(sprintf("Saved: %s  (%d assessments)\n", OUTPUT_RDS, nrow(meta)))
}

main()
