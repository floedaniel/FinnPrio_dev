################################################################################
# Excel Structure Inspector
#
# This script examines the structure of the Excel file to help configure
# the migration script correctly
################################################################################

library(readxl)
library(tidyverse)

# Configuration
EXCEL_FILE <- "FinnPRIO_Daniel_Floe_PCRP.xlsm"

cat("Excel File Structure Inspector\n")
cat("==============================\n\n")

# List all sheets
cat("Available sheets in Excel file:\n")
sheets <- excel_sheets(EXCEL_FILE)
for (i in seq_along(sheets)) {
  cat(sprintf("  %d. %s\n", i, sheets[i]))
}

# Ask which sheet to inspect (or use default)
cat("\nInspecting sheet: 'Assessment database'\n\n")
EXCEL_TAB <- "Assessment database"

# Read the data
excel_data <- read_excel(EXCEL_FILE, sheet = EXCEL_TAB)

cat(sprintf("Number of rows: %d\n", nrow(excel_data)))
cat(sprintf("Number of columns: %d\n\n", ncol(excel_data)))

# Display column names
cat("Column names in Excel file:\n")
cat("---------------------------\n")
for (i in seq_along(names(excel_data))) {
  cat(sprintf("%3d. %s\n", i, names(excel_data)[i]))
}

cat("\n\n")

# Show first row of data
cat("First row of data (as example):\n")
cat("-------------------------------\n")
first_row <- excel_data[1, ]
for (col_name in names(first_row)) {
  value <- first_row[[col_name]]
  if (is.na(value)) {
    value_str <- "<NA>"
  } else if (is.numeric(value) && value > 40000 && value < 50000) {
    # Likely an Excel date number
    date_val <- as.Date(value, origin = "1899-12-30")
    value_str <- sprintf("%s (Excel date: %s)", value, format(date_val, "%Y-%m-%d"))
  } else {
    value_str <- as.character(value)
    if (nchar(value_str) > 50) {
      value_str <- paste0(substr(value_str, 1, 47), "...")
    }
  }
  cat(sprintf("  %-40s : %s\n", col_name, value_str))
}

cat("\n\n")

# Identify question columns
cat("Question columns detected:\n")
cat("--------------------------\n")

question_patterns <- c("min$", "likely$", "max$", "justification$")
for (pattern in question_patterns) {
  matching_cols <- grep(pattern, names(excel_data), value = TRUE, ignore.case = TRUE)
  if (length(matching_cols) > 0) {
    cat(sprintf("\nColumns ending with '%s' (%d found):\n",
                gsub("\\$", "", pattern), length(matching_cols)))
    for (col in matching_cols) {
      cat(sprintf("  - %s\n", col))
    }
  }
}

cat("\n\n")

# Try to identify key columns
cat("Attempting to identify key columns:\n")
cat("-----------------------------------\n")

# Species/date identifier
species_cols <- grep("species|date|assessment.*name", names(excel_data),
                     value = TRUE, ignore.case = TRUE)
if (length(species_cols) > 0) {
  cat("Possible Species/Assessment ID columns:\n")
  for (col in species_cols) {
    cat(sprintf("  - %s\n", col))
  }
} else {
  cat("No obvious species/assessment ID column found\n")
}

cat("\n")

# Assessor
assessor_cols <- grep("assessor", names(excel_data), value = TRUE, ignore.case = TRUE)
if (length(assessor_cols) > 0) {
  cat("Possible Assessor columns:\n")
  for (col in assessor_cols) {
    cat(sprintf("  - %s\n", col))
  }
} else {
  cat("No obvious assessor column found\n")
}

cat("\n")

# Taxonomic group
taxa_cols <- grep("taxonomic|taxon|group", names(excel_data), value = TRUE, ignore.case = TRUE)
if (length(taxa_cols) > 0) {
  cat("Possible Taxonomic group columns:\n")
  for (col in taxa_cols) {
    unique_vals <- unique(excel_data[[col]])
    unique_vals <- unique_vals[!is.na(unique_vals)]
    cat(sprintf("  - %s (unique values: %s)\n", col,
                paste(head(unique_vals, 3), collapse = ", ")))
  }
} else {
  cat("No obvious taxonomic group column found\n")
}

cat("\n")

# Quarantine status
quar_cols <- grep("quarantine|status", names(excel_data), value = TRUE, ignore.case = TRUE)
if (length(quar_cols) > 0) {
  cat("Possible Quarantine status columns:\n")
  for (col in quar_cols) {
    unique_vals <- unique(excel_data[[col]])
    unique_vals <- unique_vals[!is.na(unique_vals)]
    cat(sprintf("  - %s (unique values: %s)\n", col,
                paste(head(unique_vals, 3), collapse = ", ")))
  }
} else {
  cat("No obvious quarantine status column found\n")
}

cat("\n")

# Europe/pathway
europe_cols <- grep("europe|pathway", names(excel_data), value = TRUE, ignore.case = TRUE)
if (length(europe_cols) > 0) {
  cat("Possible Europe/Pathway columns:\n")
  for (col in europe_cols) {
    unique_vals <- unique(excel_data[[col]])
    unique_vals <- unique_vals[!is.na(unique_vals)]
    cat(sprintf("  - %s (unique values: %s)\n", col,
                paste(head(unique_vals, 3), collapse = ", ")))
  }
} else {
  cat("No obvious Europe/pathway column found\n")
}

cat("\n")

# Threatened sectors
sector_cols <- grep("sector|threat", names(excel_data), value = TRUE, ignore.case = TRUE)
if (length(sector_cols) > 0) {
  cat("Possible Threatened sector columns:\n")
  for (col in sector_cols) {
    cat(sprintf("  - %s\n", col))
  }
} else {
  cat("No obvious threatened sector column found\n")
}

cat("\n\n")

# Check for IMP2 and IMP4 questions
cat("Special questions (IMP2 and IMP4):\n")
cat("-----------------------------------\n")
imp_cols <- grep("IMP[24]", names(excel_data), value = TRUE, ignore.case = FALSE)
if (length(imp_cols) > 0) {
  for (col in imp_cols) {
    unique_vals <- unique(excel_data[[col]])
    unique_vals <- unique_vals[!is.na(unique_vals)]
    cat(sprintf("  - %s (unique values: %s)\n", col,
                paste(head(unique_vals, 5), collapse = ", ")))
  }
} else {
  cat("No IMP2 or IMP4 columns found\n")
}

cat("\n\n")

# Save column names to file for reference
writeLines(names(excel_data), "excel_column_names.txt")
cat("✓ Column names saved to: excel_column_names.txt\n\n")

# Create a mapping template
cat("Creating column mapping template...\n")
mapping <- data.frame(
  Expected = c("Species/date", "Assessment date", "Assessor name", "In Europe?",
               "Taxonomic group", "Quarantine status", "Pathway category"),
  Actual = c(
    ifelse(length(species_cols) > 0, species_cols[1], ""),
    "",
    ifelse(length(assessor_cols) > 0, assessor_cols[1], ""),
    "",
    ifelse(length(taxa_cols) > 0, taxa_cols[1], ""),
    ifelse(length(quar_cols) > 0, quar_cols[1], ""),
    ""
  )
)

write.csv(mapping, "column_mapping.csv", row.names = FALSE)
cat("✓ Mapping template saved to: column_mapping.csv\n")
cat("  (Edit this file to define your column mappings)\n\n")

cat("Inspection complete!\n")
