################################################################################
# Create Assessments for Pests and Populate Hosts from EPPO
#
# This script:
# 1. Reads all pests from pests table (or only those without assessments)
# 2. Creates a new assessment for each
# 3. Fetches hosts from EPPO API and populates assessments.hosts
################################################################################

library(DBI)
library(RSQLite)
library(httr2)
library(jsonlite)

# Configuration ----------------------------------------------------------------
# DB_FILE <- "./databases/selam_database_2026/selam_test_species.db"

# -------------------------------------------------------------------------

API_KEY_FILE <- "C:/Users/dafl/Desktop/API keys/EPPO_beta.txt"

# Set to TRUE to only create assessments for pests that don't have one yet
ONLY_MISSING <- TRUE

# Default assessor ID - check your assessors table for valid IDs
DEFAULT_ASSESSOR_ID <- 1L

api_key <- readLines(API_KEY_FILE, warn = FALSE)[1]

# Connect to database
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Show available assessors
cat("Available assessors:\n")
print(dbGetQuery(con, "SELECT idAssessor, firstName, lastName FROM assessors"))
cat("\nUsing assessor ID:", DEFAULT_ASSESSOR_ID, "\n\n")

# Get pests to process ---------------------------------------------------------
if (ONLY_MISSING) {
  # Only pests without any assessment
  pests_df <- dbGetQuery(con, 
                         "SELECT p.idPest, p.scientificName, p.eppoCode 
     FROM pests p
     LEFT JOIN assessments a ON p.idPest = a.idPest
     WHERE a.idAssessment IS NULL
       AND p.eppoCode IS NOT NULL")
  cat("Found", nrow(pests_df), "pests WITHOUT assessments\n\n")
} else {
  # All pests with EPPO codes
  pests_df <- dbGetQuery(con, 
                         "SELECT idPest, scientificName, eppoCode 
     FROM pests 
     WHERE eppoCode IS NOT NULL")
  cat("Found", nrow(pests_df), "pests with EPPO codes\n\n")
}

if (nrow(pests_df) == 0) {
  cat("Nothing to process.\n")
  dbDisconnect(con)
  stop("No pests to process")
}

# Get next assessment ID
max_id <- dbGetQuery(con, "SELECT MAX(idAssessment) as max_id FROM assessments")$max_id
next_assessment_id <- if (is.na(max_id)) 1 else max_id + 1

cat("Starting assessment ID:", next_assessment_id, "\n\n")

# Helper function to extract hosts from EPPO API response ----------------------
extract_hosts <- function(x) {
  if (is.list(x)) {
    if (!is.null(x$prefname)) {
      return(x$prefname)
    } else {
      return(unlist(lapply(x, extract_hosts)))
    }
  }
  return(NULL)
}

# Process each pest ------------------------------------------------------------
created_count <- 0
today <- format(Sys.Date(), "%Y-%m-%d")

for (i in seq_len(nrow(pests_df))) {
  pest <- pests_df[i, ]
  eppocode <- pest$eppoCode
  
  cat("[", i, "/", nrow(pests_df), "] ", pest$scientificName, " (", eppocode, ")\n", sep = "")
  
  # Fetch hosts from EPPO API
  hosts_text <- NA_character_
  
  url_hosts <- paste0("https://api.eppo.int/gd/v2/taxons/taxon/", eppocode, "/hosts")
  resp_hosts <- tryCatch({
    request(url_hosts) |>
      req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
      req_perform()
  }, error = function(e) NULL)
  
  if (!is.null(resp_hosts)) {
    hosts_raw <- resp_body_json(resp_hosts)
    all_hosts <- unique(unlist(lapply(hosts_raw, extract_hosts)))
    
    if (length(all_hosts) > 0) {
      hosts_text <- paste(all_hosts, collapse = ", ")
      cat("  Hosts:", length(all_hosts), "\n")
    } else {
      cat("  No hosts found\n")
    }
  } else {
    cat("  Could not fetch hosts from EPPO\n")
  }
  
  # Create assessment - only required fields
  dbExecute(con,
            "INSERT INTO assessments (idAssessment, idPest, idAssessor, startDate, hosts, version)
     VALUES (?, ?, ?, ?, ?, ?)",
            params = list(
              next_assessment_id,
              pest$idPest,
              DEFAULT_ASSESSOR_ID,
              today,
              hosts_text,
              "1"
            )
  )
  
  cat("  Created assessment ID:", next_assessment_id, "\n\n")
  
  next_assessment_id <- next_assessment_id + 1
  created_count <- created_count + 1
}

# Summary ----------------------------------------------------------------------
cat("================================================================================\n")
cat("DONE!\n")
cat("================================================================================\n\n")

cat("Created", created_count, "new assessments\n\n")

cat("Assessments summary:\n")
summary_df <- dbGetQuery(con, 
                         "SELECT a.idAssessment, p.scientificName, p.eppoCode,
          CASE WHEN a.hosts IS NOT NULL THEN 'Yes' ELSE 'No' END as hasHosts,
          a.finished, a.valid
   FROM assessments a 
   JOIN pests p ON a.idPest = p.idPest
   ORDER BY a.idAssessment DESC
   LIMIT 20")
print(summary_df)

dbDisconnect(con)