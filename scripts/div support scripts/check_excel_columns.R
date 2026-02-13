library(readxl)
library(tidyverse)

EXCEL_FILE <- "FinnPRIO_Daniel_Floe_PCRP.xlsm"
EXCEL_TAB <- "Assessment database"

cat("Reading Excel file...\n")
excel_data <- read_excel(EXCEL_FILE, sheet = EXCEL_TAB)

cat(sprintf("\nRows: %d\n", nrow(excel_data)))
cat(sprintf("Columns: %d\n\n", ncol(excel_data)))

cat("First 50 column names:\n")
cat("=====================\n")
for (i in 1:min(50, ncol(excel_data))) {
  cat(sprintf("%3d. %s\n", i, names(excel_data)[i]))
}

cat("\n\nFirst row of data:\n")
cat("==================\n")
print(as.data.frame(excel_data[1, 1:20]))

cat("\n\nColumn names containing 'Species' or 'date':\n")
cat("============================================\n")
species_cols <- grep("species|date|assessment", names(excel_data), ignore.case = TRUE, value = TRUE)
print(species_cols)

cat("\n\nColumn names containing 'Assessor':\n")
cat("===================================\n")
assessor_cols <- grep("assessor", names(excel_data), ignore.case = TRUE, value = TRUE)
print(assessor_cols)

cat("\n\nColumn names containing 'ENT1':\n")
cat("===============================\n")
ent1_cols <- grep("ENT1", names(excel_data), ignore.case = FALSE, value = TRUE)
print(ent1_cols)

cat("\n\nSample of column names 100-120:\n")
cat("===============================\n")
if (ncol(excel_data) >= 100) {
  for (i in 100:min(120, ncol(excel_data))) {
    cat(sprintf("%3d. %s\n", i, names(excel_data)[i]))
  }
}

