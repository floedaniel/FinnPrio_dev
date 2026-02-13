# Manage Assessors Table in FinnPrio Database
library(DBI)
library(RSQLite)
library(dplyr)

# Database connection
DB_FILE <- "./selam/selam_2026.db"
con <- dbConnect(SQLite(), DB_FILE)

# View current assessors
assessors_df <- dbReadTable(con, "assessors")
print(as_tibble(assessors_df))

# =============================================================================
# FUNCTIONS
# =============================================================================

# 1. Delete ALL assessors (use with caution!)
delete_all_assessors <- function(con) {
  cat("WARNING: This will delete ALL assessors!\n")
  response <- readline("Are you sure? (yes/no): ")
  if (tolower(response) == "yes") {
    dbExecute(con, "DELETE FROM assessors")
    cat("All assessors deleted.\n")
  } else {
    cat("Cancelled.\n")
  }
}

# 2. Add a new assessor
add_assessor <- function(con, firstName, lastName, email = NA) {
  dbExecute(con, 
            "INSERT INTO assessors (firstName, lastName, email) VALUES (?, ?, ?)",
            params = list(firstName, lastName, email)
  )
  cat("Added:", firstName, lastName, "\n")
}

# 3. Delete a specific assessor by ID
delete_assessor <- function(con, idAssessor) {
  # Check if assessor exists
  exists <- dbGetQuery(con, "SELECT * FROM assessors WHERE idAssessor = ?", 
                       params = list(idAssessor))
  if (nrow(exists) == 0) {
    cat("Assessor ID", idAssessor, "not found.\n")
    return()
  }
  
  cat("Deleting:", exists$firstName, exists$lastName, "\n")
  dbExecute(con, "DELETE FROM assessors WHERE idAssessor = ?", 
            params = list(idAssessor))
  cat("Deleted assessor ID:", idAssessor, "\n")
}

# 4. Update an assessor
update_assessor <- function(con, idAssessor, firstName = NULL, lastName = NULL, email = NULL) {
  if (!is.null(firstName)) {
    dbExecute(con, "UPDATE assessors SET firstName = ? WHERE idAssessor = ?",
              params = list(firstName, idAssessor))
  }
  if (!is.null(lastName)) {
    dbExecute(con, "UPDATE assessors SET lastName = ? WHERE idAssessor = ?",
              params = list(lastName, idAssessor))
  }
  if (!is.null(email)) {
    dbExecute(con, "UPDATE assessors SET email = ? WHERE idAssessor = ?",
              params = list(email, idAssessor))
  }
  cat("Updated assessor ID:", idAssessor, "\n")
}

# 5. View assessors
view_assessors <- function(con) {
  assessors_df <- dbReadTable(con, "assessors")
  print(as_tibble(assessors_df))
  return(assessors_df)
}

# Add a new assessor (with optional ID)
add_assessor <- function(con, firstName, lastName, email = NA, idAssessor = NULL) {
  if (!is.null(idAssessor)) {
    dbExecute(con, 
              "INSERT INTO assessors (idAssessor, firstName, lastName, email) VALUES (?, ?, ?, ?)",
              params = list(idAssessor, firstName, lastName, email)
    )
  } else {
    dbExecute(con, 
              "INSERT INTO assessors (firstName, lastName, email) VALUES (?, ?, ?)",
              params = list(firstName, lastName, email)
    )
  }
  cat("Added:", firstName, lastName, "\n")
}

# =============================================================================
# EXAMPLES - Uncomment and modify as needed
# =============================================================================

# View current assessors
view_assessors(con)

# Delete specific assessors (by ID)
delete_assessor(con, 1)  # Deletes "Selamawit"


# Add new assessors
add_assessor(con, "Selamawit", "Gobena", "Dselamawit.tekle.gobena@vkm.no")

# Add new assessors with idAssessor
add_assessor(con, "Selamawit Tekle", "Gobena", "selamawit.tekle.gobena@vkm.no", idAssessor = 1)

# Update an assessor
# update_assessor(con, 2, lastName = "Björklund")  # Fix encoding

# Delete ALL assessors (careful!)
delete_all_assessors(con)



# =============================================================================
# CLOSE CONNECTION when done
# =============================================================================
dbDisconnect(con)
