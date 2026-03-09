################################################################################
# EPPO Batch Population Script
################################################################################
#
# Description:
#   Runs all EPPO populate scripts (1-5) in sequence with a single database path
#
# Usage:
#   1. Set DB_PATH and other configuration below
#   2. Run: source("scripts/populate database scripts/0_batch_populate_eppo.R")
#
################################################################################

# =============================================================================
# CONFIGURATION - EDIT THESE SETTINGS
# =============================================================================

# Database Path - THIS WILL BE USED FOR ALL POPULATE SCRIPTS
DB_PATH <- "./databases/daniel_database_2026/test_sdm.db"

# EPPO API Key File
API_KEY_FILE <- "C:/Users/dafl/Desktop/API keys/EPPO_beta.txt"

# EPPO Codes to Populate (for script 1)
EPPO_CODES <- c("ANOLHO", "ARGPLE", "CERTCA", "CHRBFE", "CHRBMA", "DACUDO", "DENDSU", "EPIXCU", "EPIXSU", "EPIXTU", "LAPHFR", "MALADI", "PHECPI", "RHYCFE", "XYLOCH")

# Default Assessor ID (for script 2)
DEFAULT_ASSESSOR_ID <- 1L

# Only process missing data (for script 2)
ONLY_MISSING <- TRUE

# =============================================================================
# END CONFIGURATION
# =============================================================================

# Scripts to run in order
SCRIPTS <- c(
  "1_populate_eppo_pests_table_db.R",
  "2_populate_eppo_assesment_host.R",
  "3_populate_eppo_notes_datasheet.R",
  "4_populate_eppo_pathwayshosts.R",
  "5_populate_eppo_distribution.R"
)

# Helper function to source a script with variable overrides
source_with_config <- function(script_name, config_vars) {
  script_path <- file.path("scripts/populate database scripts", script_name)

  if (!file.exists(script_path)) {
    stop("Script not found: ", script_path)
  }

  cat("\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat(sprintf("RUNNING: %s\n", script_name))
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")

  # Read script content
  script_content <- readLines(script_path, warn = FALSE)

  # Replace configuration variables
  for (var_name in names(config_vars)) {
    # Find lines that define this variable
    pattern <- paste0("^\\s*", var_name, "\\s*<-")
    matching_lines <- grep(pattern, script_content)

    if (length(matching_lines) > 0) {
      # Get the new value
      new_value <- config_vars[[var_name]]

      # Format the replacement based on type
      if (is.character(new_value)) {
        if (length(new_value) > 1) {
          # Vector of strings
          formatted_value <- sprintf('c(%s)', paste0('"', new_value, '"', collapse = ", "))
        } else {
          # Single string
          formatted_value <- sprintf('"%s"', new_value)
        }
      } else if (is.numeric(new_value)) {
        formatted_value <- as.character(new_value)
        if (grepl("L$", deparse(substitute(new_value)))) {
          formatted_value <- paste0(formatted_value, "L")
        }
      } else if (is.logical(new_value)) {
        formatted_value <- as.character(new_value)
      } else {
        formatted_value <- deparse(new_value)
      }

      # Replace the line
      replacement <- paste0(var_name, " <- ", formatted_value)
      script_content[matching_lines[1]] <- replacement

      cat(sprintf("  ✓ Override: %s\n", replacement))
    }
  }

  # Execute the modified script
  tryCatch({
    # Parse and evaluate the script
    parsed_script <- parse(text = script_content)
    eval(parsed_script, envir = .GlobalEnv)

    cat(sprintf("\n✅ COMPLETED: %s\n", script_name))
    return(TRUE)

  }, error = function(e) {
    cat(sprintf("\n❌ FAILED: %s\n", script_name))
    cat(sprintf("Error: %s\n", conditionMessage(e)))
    return(FALSE)
  })
}

# Main Execution ---------------------------------------------------------------

main <- function() {

  cat("\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat("EPPO BATCH POPULATION\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat(sprintf("\nDatabase: %s\n", DB_PATH))
  cat(sprintf("Scripts to run: %d\n", length(SCRIPTS)))

  # Check database exists
  if (!file.exists(DB_PATH)) {
    cat(sprintf("\n❌ Database not found: %s\n", DB_PATH))
    cat("Please create the database first or update DB_PATH.\n\n")
    return()
  }

  # Check API key file exists
  if (!file.exists(API_KEY_FILE)) {
    cat(sprintf("\n❌ API key file not found: %s\n", API_KEY_FILE))
    cat("Please update API_KEY_FILE path.\n\n")
    return()
  }

  # Configuration to pass to scripts
  config <- list(
    DB_FILE = DB_PATH,
    API_KEY_FILE = API_KEY_FILE,
    input = EPPO_CODES,
    DEFAULT_ASSESSOR_ID = DEFAULT_ASSESSOR_ID,
    ONLY_MISSING = ONLY_MISSING
  )

  cat("\nConfiguration:\n")
  cat(sprintf("  Database: %s\n", DB_PATH))
  cat(sprintf("  API Key: %s\n", API_KEY_FILE))
  cat(sprintf("  EPPO Codes: %s\n", paste(EPPO_CODES, collapse = ", ")))
  cat(sprintf("  Assessor ID: %d\n", DEFAULT_ASSESSOR_ID))
  cat(sprintf("  Only Missing: %s\n", ONLY_MISSING))

  # Ask for confirmation
  cat("\nPress [Enter] to continue or [Ctrl+C] to cancel...")
  readline()

  # Track results
  success_count <- 0
  failed_count <- 0
  failed_scripts <- c()

  # Run each script
  for (script in SCRIPTS) {
    success <- source_with_config(script, config)

    if (success) {
      success_count <- success_count + 1
    } else {
      failed_count <- failed_count + 1
      failed_scripts <- c(failed_scripts, script)
    }
  }

  # Summary
  cat("\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat("BATCH POPULATION COMPLETE\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat(sprintf("\nTotal scripts: %d\n", length(SCRIPTS)))
  cat(sprintf("  ✅ Success: %d\n", success_count))
  cat(sprintf("  ❌ Failed:  %d\n", failed_count))

  if (failed_count > 0) {
    cat("\nFailed scripts:\n")
    for (script in failed_scripts) {
      cat(sprintf("  - %s\n", script))
    }
  }

  cat("\n")
}

# Run the script ---------------------------------------------------------------
main()
