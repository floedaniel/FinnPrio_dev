load_required_packages <- function(pkgs) {

  installed <- rownames(installed.packages())
  missing <- setdiff(pkgs, installed)

  if (length(missing) > 0) {
    message("Installing missing packages: ", paste(missing, collapse = ", "))
    install.packages(missing, dependencies = TRUE)
  }

  invisible(
    lapply(pkgs, function(pkg) {
      suppressPackageStartupMessages(
        library(pkg, character.only = TRUE)
      )
    })
  )
}

required_packages <- c(
  # Data manipulation
  "tidyverse",    # Includes dplyr, tidyr, stringr, etc.
  "lubridate",    # Date/time operations (now(), as_datetime())
  "glue",
  "jsonlite",
  
  "shiny",
  "shinyjs",
  "shinyFiles",
  "shinyalert",
  "shinyWidgets",
  "DT",
  
  "DBI",
  "RSQLite",

  "fs",           # For fs::path_home() in constants.R

  "mc2d",         # PERT distributions for Monte Carlo simulations

  "officer",      # Word document generation
  "flextable"     # Formatted tables
)

load_required_packages(required_packages)

# Source R/ files explicitly (Shiny auto-sourcing may fail on some systems)
for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) {
  source(f, local = FALSE)
}

## Set options

op <- options(digits.secs = 0)
