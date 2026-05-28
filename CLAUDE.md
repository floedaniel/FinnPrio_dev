# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FinnPRIO Assessor is a Shiny application for conducting plant pest risk assessments using the FinnPRIO model (Heikkila et al. 2016). The application produces assessments for Sweden, adapted from the original Finnish Food Authority model. It evaluates non-native plant pests across five dimensions: entry likelihood, establishment/spread, impact magnitude, preventability, and controllability.

## Development Principles

These principles guide all code changes in this repository. Follow them strictly when modifying or extending the application.

### 1. Think Before Coding

Explicit reasoning precedes action:
- **Declare assumptions**: State what you assume to be true about the code, data, or requirements
- **Expose ambiguities**: Identify unclear requirements or implementation details before proceeding
- **Consider alternatives**: Evaluate multiple approaches and justify the chosen solution
- **Halt on uncertainty**: Stop and ask for clarification rather than guessing or making assumptions
- **Verify understanding**: Read existing code thoroughly before making changes

### 2. Simplicity First

Only the minimum necessary solution is implemented:
- **No speculative features**: Build only what is explicitly requested or clearly necessary
- **No premature abstractions**: Don't create utilities, helpers, or frameworks for one-time operations
- **No extra configurability**: Avoid adding parameters, options, or settings "just in case"
- **Remove complexity**: Simplify until only essential code remains
- **Trust existing guarantees**: Don't add validation or error handling for scenarios that can't happen with internal code

### 3. Surgical Changes

Edits are strictly limited to what the task requires:
- **Minimal scope**: Change only the code directly related to the task
- **No incidental refactoring**: Don't clean up, reorganize, or improve unrelated code
- **No stylistic changes**: Don't add comments, docstrings, or type annotations to unchanged code
- **Remove only what you create**: Delete artifacts created by your changes, not pre-existing code
- **No backwards-compatibility hacks**: Delete unused code completely rather than leaving markers (e.g., `_unused` variables, `// removed` comments)

### 4. Goal-Driven Execution

Work is defined by verifiable outcomes:
- **Convert tasks to criteria**: Define measurable success conditions before starting
- **Test against criteria**: Verify that each change satisfies its requirements
- **Iterate until satisfied**: Continue refining until all criteria are met
- **Verify in context**: Test changes within the full application workflow
- **Document what changed**: Explain what was modified and why in commit messages

## Technology Stack

- **Language**: R
- **Framework**: Shiny (web application framework)
- **Database**: SQLite (FinnPrio_DB.db)
- **Key Packages**:
  - UI: shiny, shinyjs, shinyFiles, shinythemes, shinyalert, shinyWidgets, DT
  - Data: DBI, RSQLite, tidyverse, lubridate, glue, jsonlite, fs
  - Statistics: mc2d (for PERT distributions in Monte Carlo simulations)
  - Reporting: officer, flextable

**Note**: All packages are loaded via `global.R` with automatic dependency checking and installation.

## Running the Application

To launch the Shiny app:
```r
shiny::runApp()
```

The application expects a SQLite database file to be selected on startup via the file chooser dialog.

## Code Architecture

### Application Structure

The app follows the standard Shiny architecture pattern:

- **global.R**: Package loading and initialization (optimized with automatic dependency management)
- **ui.R**: User interface definition (navbar with tabs for Assessments, Pest-species data, Assessors, Instructions)
- **server.R**: Server-side logic and reactive programming (~2100+ lines)
  - Includes full CRUD operations for Pests and Assessors
  - Automatic stale session unlock (5-minute timeout)
- **R/**: Helper functions organized by purpose
  - `constants.R`: System volume paths and default simulation parameters
  - `internal functions.R`: UI rendering helpers and utility functions
  - `simulations.R`: Monte Carlo simulation logic for risk assessment
  - `sqlite queries.R`: SQL query templates for data export

### Data Management (CRUD Operations)

The application provides full CRUD (Create, Read, Update, Delete) functionality for key data entities:

**Pest-Species Data Tab:**
- **Create**: `+ Add Pest` button opens modal for new pest entry with validation
- **Read**: Interactive DataTable with search, sort, and single-row selection
- **Update**: `Edit Selected Pest` button pre-populates modal with existing data
- **Delete**: `Delete Selected Pest` with cascade deletion of associated assessments, answers, and simulations
- **Validation**: Prevents duplicate scientific names, EPPO codes, and GBIF taxon keys
- **Data Integrity**: Warns before deleting pests with existing assessments

**Assessors Tab:**
- **Create**: `+ Add Assessor` button for new assessor entry
- **Read**: Interactive DataTable showing firstName, lastName, email
- **Update**: `Edit Selected Assessor` button for modifications
- **Delete**: `Delete Selected Assessor` with protection (blocks deletion if assessments exist)
- **Validation**: Requires firstName and lastName; email is optional
- **Data Integrity**: Prevents deletion of assessors with existing assessments

**Implementation Pattern:**
- Row selection: `input$[table_name]_rows_selected`
- Edit modals: Pre-populated with `value =` parameter in input fields
- Validation: Check required fields and duplicates before DB operations
- Confirmation: `shinyalert()` with callbacks for destructive operations
- Refresh: Reload reactive data and update dropdowns after changes

### Database Schema

The SQLite database (FinnPrio_DB.db) follows this structure:

**Core Tables:**
- `assessments`: Main assessment records linking pests, assessors, dates, validity status
- `pests`: Pest species information (scientific name, EPPO code, GBIF key, taxonomic group, quarantine status)
- `assessors`: Assessor information (name, email)
- `questions`: Main questionnaire items organized by group (ENT, EST, IMP, MAN)
- `pathwayQuestions`: Entry pathway-specific questions (ENT2A, ENT2B, ENT3, ENT4)

**Answer Tables:**
- `answers`: Responses to main questions (stores min/likely/max values and justification)
- `pathwayAnswers`: Responses to pathway-specific questions

**Relationship Tables:**
- `entryPathways`: Links assessments to selected entry pathways
- `threatXassessment`: Links assessments to threatened sectors
- `pathways`: Entry pathway definitions with grouping (group 1/2/3 affects calculation)
- `threatenedSectors`: Sectors that could be impacted

**Simulation Tables:**
- `simulations`: Simulation run metadata (iterations, lambda, weights, date)
- `simulationSummaries`: Statistical summaries of simulation results (min, q5, q25, median, q75, q95, max, mean)

**System Table:**
- `dbStatus`: Concurrent access control (tracks inUse flag and timestamp)

### Data Flow

1. **Database Loading**: User selects .db file → Connection established → All reference data loaded into reactiveValues
2. **Assessment Workflow**:
   - Create assessment → Select pest & assessor → Choose entry pathways
   - Answer questions (ENT, EST, IMP, MAN groups + pathway-specific)
   - Mark as finished (triggers completeness validation)
   - Mark as valid (ensures only one valid assessment per species)
3. **Simulation Workflow**:
   - Assessment must be finished → Run Monte Carlo simulation → Save results → Generate statistics
4. **Export**: Wide table format joins all assessment data, answers, and simulation results

### Key Reactive Patterns

**Concurrent Access Control**:
- `dbStatus` table prevents simultaneous database writes
- **Automatic stale lock release**: Checks timestamp using `difftime(now(), as_datetime(timestamp))`
- If lock is stale (>5 minutes), automatically resets `inUse = 0` and updates timestamp
- Prevents permanent locks from crashed/abandoned sessions
- Disables save buttons when another user actively has the database locked
- Implementation in server.R uses lubridate functions: `now()`, `as_datetime()`

**Assessment Selection**:
- Selecting a row in assessments table triggers loading of all related data (entry pathways, threats, answers)
- `assessments$selected` drives the entire questionnaire rendering

**Dynamic UI Generation**:
- `render_quest_tab()` generates interactive checkbox tables for min/likely/max selections
- Questions stored as JSON in database, parsed dynamically
- JavaScript callbacks enforce single-selection-per-column constraint

**Answer Validation**:
- Before marking finished: checks all required questions answered, all min/likely/max selections complete
- Entry pathway answers validated separately if pathways selected

## Monte Carlo Simulations

The core risk calculation uses PERT distributions fitted to min/likely/max answers:

**Entry Score Calculation**:
- Each pathway scored separately using ENT questions
- Scenario A (no current management): ENT1 × ENT2A × ENT3A × ENT4
- Scenario B (with management): ENT1 × ENT2B × ENT3B × ENT4
- Multiple pathways combined using inclusion-exclusion principle
- Pathway group (1/2/3) determines divisor (81/27/9)

**Establishment Score**:
- Uses EST questions with conditional logic
- SPR1 (spread) derived from EST2 × EST3 matrix lookup
- Final: (EST1 + SPR1 + EST4) / 21, with edge case handling

**Impact Score**:
- Weighted combination: (w1 × (IMP1 + IMP2) + w2 × (IMP3 + IMP4)) / 9
- w1 typically for economic impacts, w2 for environmental/social
- IMP2 and IMP4 are boolean question groups that get summed

**Risk Score**:
- RISK = IMPACT × INVASION (where INVASION = ENTRY × ESTABLISHMENT)

**Manageability Score**:
- PREVENTABILITY = max(MAN1, MAN2, MAN3) / 4
- CONTROLLABILITY = max(MAN4, MAN5) / 4
- MANAGEABILITY = min(PREVENTABILITY, CONTROLLABILITY)

Default simulation parameters: 50,000 iterations, lambda=1, weights=0.5/0.5

## Important Development Notes

### Database Transactions

Always wrap multi-step database operations in transaction logic (though not explicitly implemented in current code). When modifying entry pathways via `save_general`, the cascade deletion of pathwayAnswers is automatic due to schema constraints.

### Question Types

Two question types in the system:
- `"minmax"`: Standard three-column selection (minimum/likely/maximum)
- `"boolean"`: Yes/no questions (IMP2.x, IMP4.x) that still use three-column format but get summed together

### Entry Pathway Groups

Pathways have a `group` field (1, 2, or 3) that determines the calculation formula:
- Group 1: Uses full formula with ENT3 (transfer/survival)
- Group 2: Omits ENT3
- Group 3: Omits both ENT1 and ENT3

This is hardcoded in `simulations.R` case_when logic.

### Answer Storage

Answers store option identifiers (e.g., "a", "b", "c") not point values. Points are joined at simulation time using the points lookup tables generated from questions$list JSON.

### Validation Edge Cases

- IMP2 and IMP4 are composite questions (IMP2.1, IMP2.2, IMP2.3) that get summed. If none selected, create zero-value rows before simulation.
- ENT3A/ENT3B apply conditional overrides based on ENT2/ENT3 combinations (see lines 85-90, 113-118 in simulations.R)

## File Locations and System Configuration

**Project Structure**:
- **Root Files**: `global.R`, `ui.R`, `server.R`, `0_clean_session.R`
- **R/**: Helper functions and utilities
- **www/**: Web assets (templates, CSS, instructions, images)
- **databases/**: Database files organized by project/purpose
- **information/**: Documentation (README files, database diagrams)
- **scripts/**: Utility scripts organized by function (see Script Files section below)
- **python/**: AI enhancement scripts for generating justifications and values

**Database Selection**:
- Selected at runtime via shinyFiles dialog
- File chooser includes quick access volumes (defined in `R/constants.R`):
  - **Working Directory**: `getwd()` - Project root folder
  - **Home**: `fs::path_home()` - User home directory
  - **Named Paths**: Dynamically detected drive letters (Windows)
  - **My Computer**: Root filesystem access

**Application Assets**:
- **Templates**: www/template.docx (for Word report generation)
- **CSS**: www/styles.css (custom styling)
- **Instructions**: www/instructions.html (user documentation displayed in Instructions tab)
- **Images**: www/img/ (application images)

**Configuration Files**:
- `R/constants.R`: System volume paths, default simulation parameters (50000 iterations, lambda=1, weights=0.5/0.5)
- `global.R`: Package loading with automatic dependency management (17 packages total)

## Common Modification Patterns

**Adding a Question**:
1. Insert into `questions` or `pathwayQuestions` table with JSON list format
2. Update points calculation if needed
3. Modify simulation.R if question affects risk calculation

**Adding a Pathway**:
1. Insert into `pathways` table with appropriate group (1/2/3)
2. No code changes needed, dynamic UI will pick it up

**Modifying Simulation Logic**:
- Edit `simulation()` function in R/simulations.R
- Maintain consistency with FinnPRIO model specification
- Test with known assessment data to verify statistical output

**Export Format Changes**:
- Modify SQL in `sqlite queries.R` for structure
- Update `export_wide_table()` function for post-processing

## Script Files

Utility scripts are organized in the `scripts/` folder by function. These are administrative tools, not part of the main application runtime.

### Database Management Scripts (`scripts/database management scripts/`)

Scripts for managing database operations:
- `1_db_delete_database.R`: Database deletion utility
- `2_db_delete_selected_by_eppocode.R`: Remove pest by EPPO code (case-insensitive with `UPPER(eppoCode)`)
- `3_db_change_assesors.R`: Modify assessor assignments
- `4_db_inspect_database.R`: Database exploration and inspection
- `5_db_merge_multiple_db.R`: Combine multiple database files
- `6_db_check_assessor_pest.R`: Verify assessor-pest relationships

### Migration Scripts (`scripts/migration scripts/`)

Scripts for data migration and database repairs:
- `1_excel_to_db_migration.R`: Import assessments from Excel templates
- `2_fix_null_pest_fields.R`: Repair script to fix NULL values in pests table (idTaxa, idQuarantineStatus, inEurope)

**Important**: Script 2 ensures required pest fields are never NULL, preventing app crashes when loading assessments.

### Populate Database Scripts (`scripts/populate database scripts/`)

Scripts for bulk data population with EPPO data and master database management:
- `0_batch_populate_eppo.R`: Batch EPPO data population across multiple databases
- `1_populate_eppo_pests_table_db.R`: Bulk pest data import (sets default values for required fields)
- `2_populate_eppo_assesment_host.R`: Assessment-host relationship setup
- `3_populate_eppo_notes_datasheet.R`: Notes field population
- `4_populate_eppo_pathwayshosts.R`: Pathway-host relationships
- `5_populate_eppo_distribution.R`: Geographic distribution data
- `6_sdm_populator.R`: Populates EST1 justification with Maxent SDM model results for Norway/Sweden (reads `model_summary.json` from SDMtune folders)
- `7_populate_database.R`: Merges all assessor `4_master` databases under a base directory into a single master database; backs up existing master with timestamp before overwriting; deduplicates assessors by name and pests by EPPO code
- `8_batch_simulation.R`: Batch runs Monte Carlo simulations for all assessments in a FinnPRIO database
- `9_populate_plot.R`: Extracts simulation summaries from master database and produces risk matrix plots (invasion vs impact, establishment vs impact, total risk score lollipop); groups species by taxonomy (Arthropoda, Fungi, Viruses, etc.); includes diagnosis section for missing/unplotted species
- `10_populate_master_database.R`: Merges yearly databases (`yearly copies/`) into the cumulative `master_finnprio.db` in `databases/master_database/`; deduplicates by EPPO code at **master pest ID level** — if two source pests share the same EPPO code (e.g. capitalisation variants), only the assessment with the newest simulation date is inserted (falls back to `endDate` when neither has a simulation); assessors deduplicated by firstName+lastName; after merging, safely deletes assessments with no justifications, no values, AND no simulations (all related rows removed in FK order); backs up master to `databases/master_database/backups/` before any changes

### Support Scripts (`scripts/div support scripts/`)

Diagnostic and troubleshooting utilities:
- `check_excel_columns.R`: Validate Excel file structure
- `check_questions_schema.R`: Verify questions table schema
- `check_schema.R`: Database schema validation
- `compare_assessors.R`: Compare assessor data
- `compare_schemas.R`: Compare database schemas
- `diagnose_assessment_8.R`: Specific assessment diagnostics
- `final_diagnosis.R`: Comprehensive diagnostics
- `inspect_excel_structure.R`: Detailed Excel structure analysis
- `investigate_error.R`: Error investigation tools
- `investigate_latest_assessment.R`: Latest assessment analysis

### Root Level Scripts

- `0_clean_session.R`: Clear R environment (quick reset during development)

### Python AI Enhancement Scripts (`python/`)

Python scripts for automatically generating justifications and populating min/likely/max values using AI:

**Main Scripts:**
- `populate_finnprio_justifications.py`: Main script using GPT Researcher for web research; ENT3 attaches the SSB MCP server for trade-volume data (trade pathways only: Seeds, Plants for planting, Wood, Food/fodder, Other living plant parts — Hitchhiking/Natural spread/Intentional introduction skip SSB); IMP1, EST2, and IMP2.2 attach the NIBIO MCP server for Norwegian agricultural production statistics
- `populate_finnprio_justifications_mcp.py`: MCP server version with caching and persistent connection
- `populate_finnprio_justifications_anthropic.py`: Claude (Anthropic) version with optimized prompts
- `populate_finnprio_values.py`: Determines min/likely/max values from justifications
- `view_justifications.py`: Utility to view generated justifications
- `inspect_prompts.py`: Renders all LLM prompts without API calls — use for prompt review and debugging

**SSB Statistics Norway integration (ENT3):**
- `ssb_query_lib.py`: Pure SSB PxWebApi v2 helper functions (no AI SDK). Five functions: `ssb_search_tables`, `ssb_get_metadata`, `ssb_search_codes`, `ssb_query_data`, `toll_search_hs_codes`. Used by both `ssb_mcp_server.py` and `standalone_ssb_MPC.py`. Includes 8 MB response cap and 120 s wall-clock timeout.
- `ssb_mcp_server.py`: FastMCP 3.x server exposing five tools (four SSB + `search_tariff_codes`). Launched as stdio subprocess for ENT3 on trade pathways only (`pathway_uses_ssb()` gate in `populate_finnprio_justifications.py`).
- `standalone_ssb_MPC.py`: CLI agent for ad-hoc SSB queries (imports from `ssb_query_lib.py`).
- `customstariffstructure.xml`: Norwegian customs tariff (English) cached locally on first use — downloaded from data.toll.no; 4.2 MB, 7 436 8-digit commodity codes. Used by `toll_search_hs_codes()` to resolve host plant keywords to exact SSB `Varekoder` before querying table 08801.

**NIBIO Totalkalkylen integration (IMP1, EST2, IMP2.2):**
- `nibio_query_lib.py`: Pure NIBIO Totalkalkylen API helper functions (no AI SDK). Three functions: `nibio_list_groups`, `nibio_list_posts`, `nibio_get_data`. Returns 68-year production time series (1959–2026) with kvantum (Tonn), pris (Kr/100 kg), verdi (1000 kr).
- `nibio_mcp_server.py`: FastMCP 3.x server exposing three tools (`list_groups`, `list_posts`, `get_data`). Launched as stdio subprocess for IMP1, EST2, and IMP2.2 regular questions. Key groups: 2606=Korn, 2607=Poteter, 2608=Hagebruksprodukter, 2641=Jordbruksareal (daa by crop type).

**Instructions System (v2.0):**
- `parse_rmd_instructions.py`: Parses Rmd to structured JSON with options and guidance
- `instructions_loader.py`: Loads JSON, builds prompts for AI scripts
- `instructions_cache/`: Cache directory for generated JSON

The instructions system loads question-specific guidance from `information/Instructions_FinnPRIO_assessments.Rmd` with explicit thresholds (km², ha, kg) for accurate AI value selection.

**Workflow:**
1. Run `populate_finnprio_justifications.py` to generate scientific justifications
2. Run `populate_finnprio_values.py` to determine values from justifications
3. Load enhanced database in FinnPRIO Assessor

**Configuration:** API keys read from external files at `C:\Users\dafl\Desktop\API keys\`

See `python/README.md` for detailed documentation and `python/CHANGELOG.md` for version history.

**SSB MCP gotchas** (relevant to ENT3 in `populate_finnprio_justifications.py`):
- `build_ent3_mcp_configs()` uses `sys.executable` (not `"python"`) so the subprocess inherits the venv — do NOT pass `env: {}` (strips subprocess environment, wrong FastMCP version)
- `RETRIEVER` is temporarily set to `"tavily,mcp"` for MCP questions only, restored in `finally`; `MCP_AUTO_TOOL_SELECTION=true` enables tool discovery
- `mcp_strategy="fast"` runs MCP once for the main query; suits both ENT3 (single-shot trade lookup) and NIBIO (chained group→post→data calls within the same session)
- SSB `query_data` caps at 8 MB / 120 s wall clock / 500 non-zero rows — if SSB returns an error JSON the pipeline logs a warning and continues
- `SSB_PATHWAYS` set in `populate_finnprio_justifications.py` gates SSB activation: keywords `"seeds"`, `"plants for planting"`, `"wood"`, `"food"`, `"fodder"`, `"living plant"` — Hitchhiking, Natural spread, Intentional introduction never trigger SSB
- `toll_search_hs_codes()` downloads `customstariffstructure.xml` on first call and caches it in `python/`; subsequent calls use the in-memory index — no re-download during a pipeline run

**`gpt_researcher` API gotchas** (relevant to `Populate_finprio_justifications_deep.py`):
- `Tone` enum: `from gpt_researcher.utils.enum import Tone`
- `report_source` takes a string literal: `"web"` / `"local"` / `"hybrid"`
- `conduct_research(on_progress=cb)`: callback is called **synchronously** — must be `def`, not `async def`
- `ResearchProgress` attrs: `current_depth`, `total_depth`, `current_breadth`, `total_breadth`, `current_query`, `completed_queries`, `total_queries`
- Deep research requires `report_type="deep"` + reasoning `STRATEGIC_LLM` (e.g. `openai:o4-mini`); tune via `DEEP_RESEARCH_BREADTH/DEPTH/CONCURRENCY` + `TOTAL_WORDS`
- `FAST_/SMART_/STRATEGIC_TOKEN_LIMIT` are per-role output caps (not a shared budget); `LLM_MAX_TOKENS` is NOT a recognized env var
- No native domain-exclusion API; exclusions rely on prompt text + post-hoc regex scrubbing

## Recent Updates

For detailed changelog of all updates, features, bug fixes, and improvements, see **CHANGELOG.md**.

**Latest major updates:**
- **May 2026**: Pathway tab save bug fixed — `Save Answers` no longer jumps the pathway tabset to the first tab, and answers for off-screen pathway tabs are no longer silently dropped. Six commits on `fix/pathway-tab-save-bug` (`3f54591..55464a5`): added `id = "pathway_tabset"` and `tabPanel(value = x)` (so the active tab is reachable via `input$pathway_tabset` and `updateTabsetPanel`); switched seed reads of `answers$main` and `answers$entry` inside `output$questionarie` / `output$questionariePath` to `isolate()` snapshots (Mastering Shiny Ch. 10 pattern); dropped redundant `assessments$selected` slot mutations from `save_answers` / `save_general`; restructured `save_general`'s pathway add/remove so DELETEs precede the re-query and `answers$entry` refreshes in lockstep with `assessments$entry`; `ass_finish` and `ass_valid` capture/restore the active pathway tab around their unavoidable slot mutations (incl. the `shinyalert` conflict callback). `server.R` only, +135 / -61 lines. Spec: `docs/superpowers/specs/2026-05-28-pathway-save-bug-design.md`; plan: `docs/superpowers/plans/2026-05-28-pathway-save-bug.md`.
- **May 2026**: Master DB pipeline hardened — `databases/master database/` renamed to `databases/master_database/` (underscore), output renamed to `master_finnprio.db`, backups routed to `backups/` subfolder; dedup fix in `10_populate_master_database.R` now groups by master pest ID (not source pest ID) to prevent EPPO-code capitalisation variants from inserting duplicate assessments; FinnPRIO Explorer defaults updated — all filter checkboxes pre-ticked, default colour = taxonomic group, risk rank plot height dynamic; Explorer `global.R` switched to relative DB path; deployment script uses explicit `appFiles`
- **May 2026**: NIBIO Totalkalkylen MCP integration — IMP1, EST2, IMP2.2 now query Norwegian agricultural production statistics (kvantum/pris/verdi, 1959–2026) via `nibio_mcp_server.py`; Norwegian customs tariff search added to `ssb_query_lib.py` (`toll_search_hs_codes`) and `ssb_mcp_server.py` (`search_tariff_codes`) — AI resolves host plant keywords to exact 8-digit SSB Varekoder before querying table 08801; SSB activation gated to trade pathways only (Seeds, Plants for planting, Wood, Food/fodder, Other living plant parts)
- **May 2026**: SSB MCP integration — ENT3 now queries real Statistics Norway trade data via `ssb_mcp_server.py` (FastMCP 3.x stdio); `ssb_query_lib.py` extracted as shared pure-function library; `dag_validation_stub.py` schema corrected to actual `answers`/`pathwayAnswers` tables; IMP2.x boolean parser fix, boolean value-selection fix for IMP2.2/2.3/IMP4.2/4.3 (opt codes `'b'`/`'c'` — not always `'a'`), MAN1 Rmd corrected to 3 options (a/b/c) matching DB (was erroneously 5), hallucination retry in value selection, new `inspect_prompts.py` for dry-run prompt review, prompt boilerplate refactored into named constants with unified `create_research_query()` structure
- **February 2026**: Instructions System v2.0 - Restructured Rmd file with `### Options` and `### Guidance` sections, explicit km²/ha/kg thresholds, updated parser and loader for cleaner AI prompts
- **February 2026**: Python folder cleanup - renamed scripts (`populate_finnprio_justifications.py`, `populate_finnprio_justifications_mcp.py`), removed 22 unnecessary files, added MCP server version with caching
- **February 2026**: Complete UI/UX overhaul with CSS rebuild (v36.0 → v37.3), color-coded sections, enhanced typography, prominent justification boxes, and 8-color pathway tabs
- **February 2026**: Project restructuring with organized folder structure and cross-platform compatibility
- **January 2026**: Full CRUD operations for Pests and Assessors, data validation, database locking improvements, and code quality enhancements
