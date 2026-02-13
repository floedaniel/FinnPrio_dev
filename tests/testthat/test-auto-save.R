# Test: Auto-save functionality for FinnPRIO Assessor
#
# These tests verify the auto-save draft system works correctly.
# Run with: shinytest2::test_app(".")

library(shinytest2)
library(testthat)

# Configure browser for shinytest2 (use Edge if Chrome not available)
if (Sys.getenv("CHROMOTE_CHROME") == "") {
  edge_path <- "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  chrome_path <- "C:/Program Files/Google/Chrome/Application/chrome.exe"
  if (file.exists(chrome_path)) {
    Sys.setenv(CHROMOTE_CHROME = chrome_path)
  } else if (file.exists(edge_path)) {
    Sys.setenv(CHROMOTE_CHROME = edge_path)
  }
}

# Test database path - find app root and construct path
get_app_root <- function() {
  # Try to find app root by looking for server.R
  candidates <- c(
    getwd(),
    dirname(getwd()),
    dirname(dirname(getwd())),
    Sys.getenv("FINNPRIO_APP_ROOT", unset = NA)
  )

  for (dir in candidates) {
    if (!is.na(dir) && file.exists(file.path(dir, "server.R"))) {
      return(normalizePath(dir))
    }
  }

  # Fallback: assume we're in tests/testthat
  return(normalizePath(file.path(getwd(), "..", "..")))
}

APP_ROOT <- get_app_root()
TEST_DB <- file.path(APP_ROOT, "databases", "test databases", "ai_test_db", "ai_test.db")

# =============================================================================
# Helper Functions
# =============================================================================

# Wait for app to be ready (database loaded)
wait_for_app_ready <- function(app, timeout = 10000) {
  app$wait_for_idle(timeout = timeout)
}

# Select database file via JavaScript (workaround for shinyFiles)
select_database <- function(app, db_path) {
  # Get absolute path
  abs_path <- normalizePath(db_path, winslash = "/")

  # Trigger the file selection via Shiny's internal mechanism
  # This simulates what happens after file selection
  app$run_js(sprintf('
    Shiny.setInputValue("db_file", {
      files: {"0": ["%s"]},
      roots: "wd"
    }, {priority: "event"});
  ', abs_path))

  app$wait_for_idle(timeout = 15000)
}

# Check if draft indicator is visible
is_draft_indicator_visible <- function(app) {
  result <- app$get_js("document.querySelector('.draft-indicator') !== null")
  return(isTRUE(result))
}

# Check JavaScript dirty flag
get_js_dirty_flag <- function(app) {
  result <- app$get_js("window.finnprioHasUnsavedChanges")
  return(isTRUE(result))
}

# Get count of drafts in database
get_draft_count <- function(db_path, assessment_id) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  on.exit(DBI::dbDisconnect(con))

  count <- DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*) as n FROM answerDrafts WHERE idAssessment = %d",
    assessment_id
  ))$n

  return(count)
}

# Clear all drafts from test database
clear_test_drafts <- function(db_path) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  on.exit(DBI::dbDisconnect(con))

  DBI::dbExecute(con, "DELETE FROM answerDrafts")
  DBI::dbExecute(con, "DELETE FROM pathwayAnswerDrafts")
}

# =============================================================================
# Database Tests (no app needed)
# =============================================================================

test_that("Draft tables exist in test database", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")

  con <- DBI::dbConnect(RSQLite::SQLite(), TEST_DB)
  on.exit(DBI::dbDisconnect(con))

  tables <- DBI::dbListTables(con)


  expect_true("answerDrafts" %in% tables,
              info = "answerDrafts table should exist")
  expect_true("pathwayAnswerDrafts" %in% tables,
              info = "pathwayAnswerDrafts table should exist")
})

test_that("Draft tables have correct schema", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")

  con <- DBI::dbConnect(RSQLite::SQLite(), TEST_DB)
  on.exit(DBI::dbDisconnect(con))

  # Check answerDrafts columns
  answer_schema <- DBI::dbGetQuery(con, "PRAGMA table_info(answerDrafts)")
  expected_cols <- c("idAssessment", "idQuestion", "minimum", "likely",
                     "maximum", "justification", "savedAt")
  expect_true(all(expected_cols %in% answer_schema$name),
              info = "answerDrafts should have all required columns")

  # Check pathwayAnswerDrafts columns
  pathway_schema <- DBI::dbGetQuery(con, "PRAGMA table_info(pathwayAnswerDrafts)")
  expected_cols <- c("idAssessment", "idPathway", "idQuestion", "minimum",
                     "likely", "maximum", "justification", "savedAt")
  expect_true(all(expected_cols %in% pathway_schema$name),
              info = "pathwayAnswerDrafts should have all required columns")
})

test_that("Draft INSERT OR REPLACE works correctly", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")

  con <- DBI::dbConnect(RSQLite::SQLite(), TEST_DB)
  on.exit({
    # Cleanup test data
    DBI::dbExecute(con, "DELETE FROM answerDrafts WHERE idAssessment = -999")
    DBI::dbDisconnect(con)
  })

  # Insert a test draft
  DBI::dbExecute(con, "
    INSERT OR REPLACE INTO answerDrafts
    (idAssessment, idQuestion, minimum, likely, maximum, justification)
    VALUES (-999, 1, 'a', 'b', 'c', 'test justification')
  ")

  # Verify it exists
  result <- DBI::dbGetQuery(con,
    "SELECT * FROM answerDrafts WHERE idAssessment = -999")
  expect_equal(nrow(result), 1)
  expect_equal(result$minimum, "a")
  expect_equal(result$likely, "b")
  expect_equal(result$maximum, "c")

  # Update via INSERT OR REPLACE
 DBI::dbExecute(con, "
    INSERT OR REPLACE INTO answerDrafts
    (idAssessment, idQuestion, minimum, likely, maximum, justification)
    VALUES (-999, 1, 'x', 'y', 'z', 'updated justification')
  ")

  # Verify update (still only 1 row)
  result <- DBI::dbGetQuery(con,
    "SELECT * FROM answerDrafts WHERE idAssessment = -999")
  expect_equal(nrow(result), 1)
  expect_equal(result$minimum, "x")
  expect_equal(result$justification, "updated justification")
})

test_that("Draft cascade delete works", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")
  skip("Cascade delete test requires assessment creation - run manually")

  # This test would require creating a test assessment, adding drafts,
 # then deleting the assessment and verifying drafts are also deleted.
  # Skipped for now as it modifies production tables.
})

# =============================================================================
# App Integration Tests
# =============================================================================

test_that("App starts without errors", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")
  skip_if(Sys.getenv("CI") != "", "Skipping on CI - requires browser")
  skip_if_not(interactive(), "Run interactively for app tests")

  app <- AppDriver$new(
    app_dir = ".",
    name = "finnprio-startup",
    height = 800,
    width = 1200
  )
  on.exit(app$stop())

  # App should start
  app$wait_for_idle(timeout = 10000)

  # Check that the file chooser button exists
  expect_true(
    app$get_js("document.getElementById('db_file') !== null"),
    info = "Database file chooser should be present"
  )
})

test_that("JavaScript dirty flag initializes to false", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")
  skip_if(Sys.getenv("CI") != "", "Skipping on CI - requires browser")
  skip_if_not(interactive(), "Run interactively for app tests")

  app <- AppDriver$new(
    app_dir = ".",
    name = "finnprio-dirty-init",
    height = 800,
    width = 1200
  )
  on.exit(app$stop())

  app$wait_for_idle(timeout = 10000)

  # Check initial dirty flag is false
  dirty_flag <- app$get_js("window.finnprioHasUnsavedChanges")
  expect_false(isTRUE(dirty_flag),
               info = "Dirty flag should initialize to false")
})

test_that("beforeunload handler is registered", {
  skip_if_not(file.exists(TEST_DB), "Test database not found")
  skip_if(Sys.getenv("CI") != "", "Skipping on CI - requires browser")
  skip_if_not(interactive(), "Run interactively for app tests")

  app <- AppDriver$new(
    app_dir = ".",
    name = "finnprio-beforeunload",
    height = 800,
    width = 1200
  )
  on.exit(app$stop())

  app$wait_for_idle(timeout = 10000)

  # Check that onbeforeunload is set
  has_handler <- app$get_js("typeof window.onbeforeunload === 'function'")
  expect_true(isTRUE(has_handler),
              info = "beforeunload handler should be registered")
})

# =============================================================================
# Manual Integration Test Guide
# =============================================================================
#
# Since the file picker (shinyFilesButton) is complex to automate,
# run these steps manually after starting the app:
#
# 1. Run the app: shiny::runApp()
# 2. Click "Choose File" and select: databases/test databases/ai_test_db/ai_test.db
# 3. Select any assessment from the table
# 4. Go to a question tab and change an answer (click a checkbox)
# 5. VERIFY: Orange "Unsaved changes" indicator appears
# 6. VERIFY: In browser console, run: window.finnprioHasUnsavedChanges
#            Should return: true
# 7. Wait 60+ seconds
# 8. VERIFY: R console shows "Auto-saved drafts at [timestamp]"
# 9. VERIFY: Indicator disappears
# 10. Make another change
# 11. Try to close the browser tab
# 12. VERIFY: Browser shows "Leave site?" warning
# 13. Stay on page, click "Save Answers"
# 14. VERIFY: Success message appears
# 15. VERIFY: In database, answerDrafts table is empty for this assessment
# 16. Close browser without warning (no unsaved changes now)
# 17. Reopen app, load same database and assessment
# 18. VERIFY: Your saved answers are loaded correctly
#
# =============================================================================
