# FinnPRIO Auto-Save Test Runner
#
# Run this script to execute automated tests for the auto-save feature.
#
# Usage:
#   source("tests/run_tests.R")
#   run_all_tests()        # Run all tests
#   run_database_tests()   # Run only database tests (fast, no browser)
#   run_app_tests()        # Run only app integration tests (requires browser)

library(testthat)
library(shinytest2)
library(DBI)
library(RSQLite)

# Configure chromote to use Edge (if Chrome not found)
configure_browser <- function() {
  edge_path <- "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  chrome_path <- "C:/Program Files/Google/Chrome/Application/chrome.exe"

  if (file.exists(chrome_path)) {
    Sys.setenv(CHROMOTE_CHROME = chrome_path)
    cat("Using Chrome for browser tests\n")
  } else if (file.exists(edge_path)) {
    Sys.setenv(CHROMOTE_CHROME = edge_path)
    cat("Using Edge for browser tests\n")
  } else {
    cat("Warning: No supported browser found. App tests may fail.\n")
  }
}

# Auto-configure browser on load
configure_browser()

# Set working directory to app root
if (!file.exists("server.R")) {
  stop("Please run this script from the app root directory")
}

#' Run all tests
run_all_tests <- function() {
  cat("\n========================================\n")
  cat("Running FinnPRIO Auto-Save Tests\n")
  cat("========================================\n\n")

  test_dir("tests/testthat", reporter = "summary")
}

#' Run only database tests (no browser needed)
run_database_tests <- function() {
  cat("\n========================================\n")
  cat("Running Database Tests Only\n")
  cat("========================================\n\n")

  test_file("tests/testthat/test-auto-save.R", reporter = "summary")
}

#' Run app integration tests interactively (requires browser)
#' This launches a browser-based test - run from RStudio console
run_app_tests <- function() {
  cat("\n========================================\n")
  cat("Running App Integration Tests\n")
  cat("========================================\n\n")

  if (!interactive()) {
    cat("App tests must be run interactively (e.g., from RStudio console)\n")
    return(invisible(FALSE))
  }

  shinytest2::test_app(".", name = "auto-save-test")
}

#' Quick database sanity check
check_database <- function(db_path = "databases/test databases/ai_test_db/ai_test.db") {
  cat("\n========================================\n")
  cat("Database Sanity Check\n")
  cat("========================================\n\n")

  if (!file.exists(db_path)) {
    cat("ERROR: Database not found at:", db_path, "\n")
    return(invisible(FALSE))
  }

  con <- dbConnect(SQLite(), db_path)
  on.exit(dbDisconnect(con))

  tables <- dbListTables(con)
  cat("Tables found:", length(tables), "\n")

  # Check draft tables
  if ("answerDrafts" %in% tables) {
    cat("  [OK] answerDrafts table exists\n")
    count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM answerDrafts")$n
    cat("       Current draft count:", count, "\n")
  } else {
    cat("  [MISSING] answerDrafts table\n")
    cat("  Run: source('scripts/migration scripts/3_add_draft_tables.R')\n")
    cat("       add_draft_tables('", db_path, "')\n", sep = "")
  }

  if ("pathwayAnswerDrafts" %in% tables) {
    cat("  [OK] pathwayAnswerDrafts table exists\n")
    count <- dbGetQuery(con, "SELECT COUNT(*) as n FROM pathwayAnswerDrafts")$n
    cat("       Current draft count:", count, "\n")
  } else {
    cat("  [MISSING] pathwayAnswerDrafts table\n")
  }

  cat("\nDatabase check complete.\n")
  return(invisible(TRUE))
}

#' Clear all drafts (for testing)
clear_drafts <- function(db_path = "databases/test databases/ai_test_db/ai_test.db") {
  if (!file.exists(db_path)) {
    stop("Database not found: ", db_path)
  }

  con <- dbConnect(SQLite(), db_path)
  on.exit(dbDisconnect(con))

  n1 <- dbExecute(con, "DELETE FROM answerDrafts")
  n2 <- dbExecute(con, "DELETE FROM pathwayAnswerDrafts")

 cat("Cleared", n1, "answer drafts and", n2, "pathway drafts\n")
}

# Print instructions
cat("\n")
cat("FinnPRIO Auto-Save Test Suite\n")
cat("=============================\n\n")
cat("Available functions:\n")
cat("  run_all_tests()      - Run all automated tests\n")
cat("  run_database_tests() - Run database tests only (fast)\n")
cat("  run_app_tests()      - Run app tests (requires browser)\n")
cat("  check_database()     - Quick database sanity check\n")
cat("  clear_drafts()       - Clear all draft data (for testing)\n")
cat("\n")
