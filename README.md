# FinnPRIO Assessor

A Shiny application for conducting plant pest risk assessments using the FinnPRIO model (Heikkilä et al. 2016).

## Overview

FinnPRIO Assessor helps evaluate non-native plant pests across five dimensions:
- **Entry** - Likelihood of pest entering the area
- **Establishment & Spread** - Potential to establish and spread
- **Impact** - Economic, environmental, and social impacts
- **Preventability** - Effectiveness of prevention measures
- **Controllability** - Effectiveness of control measures

The application produces risk assessments for Sweden, adapted from the original Finnish Food Authority model.

## Quick Start

```r
# Install dependencies (first time only)
source("global.R")

# Run the app
shiny::runApp()
```

Select a database file (.db) when prompted.

## Requirements

- R (≥ 4.0)
- Required packages are auto-installed via `global.R`

**Key packages:** shiny, DBI, RSQLite, tidyverse, mc2d, officer, flextable

## Features

- Multi-user database with concurrent access control
- Monte Carlo simulations using PERT distributions
- Word document report generation
- Full CRUD for pests and assessors
- Entry pathway assessment with multiple pathways

## Project Structure

```
FinnPRIO_development/
├── server.R          # Server logic
├── ui.R              # User interface
├── global.R          # Package loading
├── R/                # Helper functions
├── www/              # CSS, templates, images
├── databases/        # SQLite databases
└── scripts/          # Utility scripts
```

## Documentation

- [CHANGELOG.md](CHANGELOG.md) - Version history and bug fixes
- [CLAUDE.md](CLAUDE.md) - Development guidelines

## Reference

Heikkilä, J., Tuomola, J., Pouta, E., & Peltola, J. (2016). FinnPRIO: A model for ranking plant pests. *Journal of Plant Diseases and Protection*, 123(2), 57-67.

## License

Internal use - Folkehelseinstituttet / Swedish Board of Agriculture
