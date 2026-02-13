# Populate ENT 1 answers from EPPO distribution
library(httr2)
library(jsonlite)
library(dplyr)
library(stringr)
library(countrycode)
library(DBI)
library(RSQLite)


# -------------------------------------------------------------------------

# Database connection
# DB_FILE <- "./databases/selam_database_2026/selam_test_species.db"

# -------------------------------------------------------------------------
con <- dbConnect(SQLite(), DB_FILE)

# Read API key
api_key <- readLines("C:/Users/dafl/Desktop/API keys/EPPO_beta.txt", warn = FALSE)[1]

# Get pests from database WITH their assessment IDs
pests_df <- dbGetQuery(con, 
                       "SELECT p.idPest, p.scientificName, p.eppoCode, a.idAssessment 
   FROM pests p
   JOIN assessments a ON p.idPest = a.idPest
   WHERE p.eppoCode IS NOT NULL")

# Debug: show column names
cat("Columns in pests query:", paste(names(pests_df), collapse = ", "), "\n")
cat("First few rows:\n")
print(head(pests_df))

# Functions (same as before)
get_eppo_distribution <- function(eppocode, api_key) {
  url <- paste0("https://api.eppo.int/gd/v2/taxons/taxon/", eppocode, "/distribution")
  resp <- request(url) |>
    req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
    req_perform()
  data <- resp |> resp_body_json(simplifyVector = TRUE)
  return(data)
}

get_eppo_countries <- function(api_key) {
  url <- "https://api.eppo.int/gd/v2/references/countriesStates"
  resp <- request(url) |>
    req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
    req_perform()
  data <- resp |> resp_body_json(simplifyVector = TRUE)
  return(data)
}

get_eppo_dist_status <- function(api_key) {
  url <- "https://api.eppo.int/gd/v2/references/distributionStatus"
  resp <- request(url) |>
    req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
    req_perform()
  data <- resp |> resp_body_json(simplifyVector = TRUE)
  return(data)
}

# Get reference tables (do this once)
countries_ref <- get_eppo_countries(api_key)
status_ref <- get_eppo_dist_status(api_key)

countries_flat <- bind_rows(
  lapply(names(countries_ref), function(iso) {
    df <- countries_ref[[iso]]
    df$country_iso <- iso
    return(df)
  })
)

# Function to create justification text from distribution
create_ent1_justification <- function(eppocode, api_key, countries_flat, status_ref) {
  
  tryCatch({
    dist_data <- get_eppo_distribution(eppocode, api_key)
    
    if (is.null(dist_data) || nrow(dist_data) == 0) {
      return("No distribution data available in EPPO Global Database.")
    }
    
    # Translate codes
    dist_translated <- dist_data |>
      left_join(countries_flat, by = c("country_iso" = "country_iso", "state_id" = "state_code")) |>
      left_join(status_ref, by = "peststatus") |>
      mutate(country_name = countrycode(country_iso, origin = "iso2c", destination = "country.name"))
    
    # Filter only "Present" records
    present <- dist_translated |>
      filter(str_detect(peststatus_label, "Present"))
    
    if (nrow(present) == 0) {
      return("No confirmed presence records in EPPO Global Database.")
    }
    
    # Get unique countries where present
    countries_present <- present |>
      distinct(country_name) |>
      pull(country_name) |>
      sort()
    
    n_countries <- length(countries_present)
    
    # Create justification text
    justification <- paste0(
      "According to EPPO Global Database, the pest is present in ",
      n_countries, " countries: ",
      paste(countries_present, collapse = ", "), "."
    )
    
    return(justification)
    
  }, error = function(e) {
    return(paste("Error fetching distribution:", e$message))
  })
}

# Loop over pests and populate answers
# First, clear ALL existing answers
dbExecute(con, "DELETE FROM answers")
cat("Cleared all existing answers\n")

cat("Processing", nrow(pests_df), "pests...\n")

for (i in seq_len(nrow(pests_df))) {
  pest <- pests_df[i, ]
  eppocode <- pest$eppoCode
  idAssessment <- pest$idAssessment  # from assessments table, NOT idPest!
  
  if (i %% 1 == 0 || i == nrow(pests_df)) {
    cat(sprintf("  %d/%d: %s (Assessment %d)\n", i, nrow(pests_df), eppocode, idAssessment))
  }
  
  # Get ENT 1 justification from EPPO
  justification_ent1 <- create_ent1_justification(eppocode, api_key, countries_flat, status_ref)
  
  # Insert answers for ALL 18 questions
  for (q in 1:18) {
    if (q == 1) {
      justification <- justification_ent1
    } else {
      justification <- ""
    }
    
    dbExecute(con, 
              "INSERT INTO answers (idAssessment, idQuestion, min, likely, max, justification) 
       VALUES (?, ?, ?, ?, ?, ?)",
              params = list(idAssessment, q, "", "", "", justification)
    )
  }
  
  Sys.sleep(0.3)  # Rate limiting
}

cat("Done!\n")

# Verify
answers_df <- dbReadTable(con, "answers")
print(answers_df)

# Close connection
dbDisconnect(con)
