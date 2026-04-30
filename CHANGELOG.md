# Changelog

All notable changes to the FinnPRIO Assessor project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added - April 2026

#### New populate database scripts (`scripts/populate database scripts/`)
- `7_populate_masterdatabase.R`: Scans all `4_master` subfolders under a base directory, merges every `.db` file found into a single master database with timestamped backup; deduplicates assessors by name and pests by EPPO code
- `8_batch_simulation.R`: Batch runs Monte Carlo simulations for all assessments in a FinnPRIO database (renamed from previous numbering)

### Changed - April 2026

#### IMP4 sub-questions restructured to match IMP2 pattern (`information/Instructions_FinnPRIO_assessments.Rmd`, `python/`)
- **IMP4.1, IMP4.2, IMP4.3 now have their own `##` headings** with dedicated `### Options` and `### Guidance` sections, matching the structure used by IMP2.1, IMP2.2, IMP2.3
- Previously nested under a single `## IMP4.` with a `### Sub-questions` section — sub-question descriptions were too thin for AI prompts (no individual guidance)
- Each sub-question now carries its own context (what counts as social/aesthetic/cultural impact) directly in the guidance
- Updated `parse_rmd_instructions.py` validation list: `IMP4` → `IMP4.1`
- Updated `instructions_loader.py` host-related check: exact list match → prefix match so `IMP4.1`/`IMP4.2`/`IMP4.3` receive host plant context in AI prompts

#### QUESTION_FILTER now accepts multiple codes (`python/populate_finnprio_justifications.py`)
- Changed from single string (`"EST2"`) to list (`["EST2", "IMP4.1", "IMP4.2"]`)
- CLI `--question` flag now accepts multiple space-separated codes (e.g., `--question EST2 IMP4.1 IMP4.2`)
- Empty list `[]` processes all questions (same as previous `None` behavior)

#### QUESTION_FILTER set to `[]` for full-pipeline runs (`python/populate_finnprio_justifications.py`) — 2026-04-17
- Changed default from `["IMP4.2", "IMP4.3"]` (IMP4 trial) to `[]` (all questions).
- The IMP2.x / IMP4.x sub-question pipeline is now validated end-to-end (Rmd → JSON → prompt construction → DB write), so subsequent runs can populate every question in one pass rather than targeting a single group at a time.

### Fixed - April 2026

#### Three simulation bugs producing warnings and corrupt summary statistics (`R/simulations.R`, `scripts/populate database scripts/8_batch_simulation.R`) — 2026-04-30

##### Bug 1 — `rpert_from_tag`: invalid PERT parameters produce NaN for entire assessment (`R/simulations.R` line 7–13)

- **Symptom**: `Warning: Some values of mode < min or mode > max` and `Warning: NaN in rpert` during batch simulation. Affected assessments produced NaN for every one of the 50 000 iterations, making their simulation summaries meaningless (all statistics stored as `Inf`/`-Inf` or `NaN`).
- **Root cause**: `rpert_from_tag()` passed the raw `min_points`, `likely_points`, `max_points` values directly to `rpert()` without validating that `min ≤ mode ≤ max`. The PERT distribution requires this ordering; violating it returns NaN for every draw. The Shiny UI enforces this ordering for human-entered answers, so the violation can only originate from data written directly to the database programmatically — specifically by the Python AI populator (`populate_finnprio_values.py`) or by Excel-migration scripts, both of which bypass the UI's column-ordering constraint.
- **Fix**: Sort `min`/`max` before use (swap if `min > max`), then clamp `mode` to `[min, max]`:
  ```r
  if (points[1] > points[3]) points[c(1, 3)] <- points[c(3, 1)]
  points[2] <- pmin(pmax(points[2], points[1]), points[3])
  ```
- **Why this fix**: Programmatically-inserted data can contain ordering violations that the UI would have prevented. Rather than crashing or silently discarding the assessment, the simulation corrects the parameter ordering and proceeds — preserving the assessor's intended spread and preventing NaN propagation.

##### Bug 2 — `scorePathway` assignment: deprecated `case_when()` with scalar condition and vector RHS (`R/simulations.R` lines 105–112, 133–140)

- **Symptom**: `Warning: Calling case_when() with size 1 LHS inputs and size >1 RHS inputs was deprecated in dplyr 1.2.0. This can result in subtle silent bugs and is very inefficient.`
- **Root cause**: `g` (the pathway group, 1/2/3) is fetched with `pull(group)` — a scalar integer of length 1. The four `scorePathway` assignments used `case_when(g == 1 ~ vector_of_50000_values, ...)`. The LHS condition `g == 1` is a length-1 logical; the RHS expressions are length-`iterations` vectors. dplyr 1.2.0 deprecated this pattern because it is ambiguous and inefficient — dplyr must silently recycle the scalar condition across all RHS rows, which is not the intended semantics of `case_when` (designed for element-wise dispatch over equal-length inputs). The warning is displayed only once per session, masking how frequently it fires (it fires for every pathway in every assessment).
- **Fix**: Replaced all four `case_when()` blocks with `if/else if` — the correct R construct for scalar dispatch:
  ```r
  scorePathway[, paste0("path", p), "A"] <- if (g == 1) {
    (ENT1 * ENT2A * ENT3A * ENT4) / 81
  } else if (g == 2) {
    (ENT1 * ENT2A * ENT4) / 27
  } else if (g == 3) {
    (ENT2A * ENT4) / 9
  } else {
    rep(NA_real_, iterations)
  }
  ```
- **Why this fix**: `if/else if` on a scalar condition is unambiguous, eliminates the deprecation warning, and is significantly faster — dplyr does not need to evaluate all three RHS expressions before selecting one; R's `if` short-circuits immediately.

##### Bug 3 — Summary statistics: `min()`/`max()` return `Inf`/`-Inf` on all-NaN columns (`scripts/populate database scripts/8_batch_simulation.R` lines 249–260)

- **Symptom**: `Warning in reframe(): min() returning Inf` and `max() returning -Inf` — six warnings per affected assessment. These values were written to `simulationSummaries`, meaning the stored `min` and `max` statistics for affected variables were `Inf`/`-Inf` rather than `NA`, corrupting the database.
- **Root cause**: NaN values from Bug 1 propagate through all downstream calculations (`IMPACT = NaN`, `RISK = NaN`, etc.). When an entire column of the 50 000-row results matrix is NaN, `min(x, na.rm = TRUE)` and `max(x, na.rm = TRUE)` have no non-missing values to operate on and return `Inf`/`-Inf` with a warning. These sentinel values were then written to `simulationSummaries` as if they were real statistics.
- **Fix**: Added `safe_min`/`safe_max` wrappers that convert `Inf`/`-Inf` to `NA_real_`:
  ```r
  safe_min <- function(x) { r <- min(x, na.rm = TRUE); if (is.infinite(r)) NA_real_ else round(r, 3) }
  safe_max <- function(x) { r <- max(x, na.rm = TRUE); if (is.infinite(r)) NA_real_ else round(r, 3) }
  ```
- **Why this fix**: Bug 1's fix prevents all-NaN columns in normal use, but the defensive wrappers guard against any future edge case (e.g., an assessment with a pathway group value outside 1/2/3, or future data that creates other invalid PERT inputs). Storing `NA` for a statistic is correct and interpretable; storing `Inf` is a corrupt value that would cause errors in downstream analysis or app rendering.
- **Note on existing data**: Any simulation summaries already written to a database while Bug 1 was active may contain `Inf`/`-Inf` values. Re-running `8_batch_simulation.R` with `SKIP_EXISTING <- FALSE` on the affected database will overwrite those rows with corrected values.

#### Empty-string answers silently discarded → IMP4.2/IMP4.3 AI justifications not visible in app (`server.R`) — 2026-04-17
- **Symptom**: After running `populate_finnprio_justifications.py` with `QUESTION_FILTER = ["IMP4.2", "IMP4.3"]`, the DB correctly held the new justifications (verified in DB Browser) but they did not appear in the Shiny app for the affected species (TYLCV0, TOBRFV, PEPMV0).
- **Root cause**: The DB convention across the project is that missing min/likely/max are stored as `""` (TEXT empty string), not SQL `NULL` — see `scripts/migration scripts/1_excel_to_db_migration.R`'s `safe_str()` and the Feb 2026 "justification-only rows" fix. However, `answers_2_logical()` in `R/internal functions.R` computed `options <- unique(c(row$min, row$likely, row$max)) |> na.omit()`, which kept `""` as a valid option. This produced a row with `ques_tag_opt = "IMP4.2_"` (trailing underscore), a downstream `filter(ques_tag_opt == "IMP4.2_b")` that matched zero rows, an empty `as.logical()` result, and a broken `tagList()` that prevented the `textAreaInput(justIMP4.2, ...)` from rendering.
- **Fix — Fix B (normalize at the DB-read boundary)**: Apply `|> mutate(across(c(min, likely, max), ~ if_else(.x == "", NA_character_, .x)))` immediately after every `dbGetQuery()` that loads the `answers` / `pathwayAnswers` tables in `server.R` (4 call sites: lines ~443, ~444, ~1562, ~1625). `answers_2_logical()` now receives proper `NA` and `na.omit()` strips them as intended.
- **Why normalize at read-time (not inside `answers_2_logical`)**: The DB's `""` sentinel is load-bearing (used by the save path, export, migration scripts). Fixing the single reader keeps every downstream consumer honest and protects against future readers with the same bug.
- **Verification (read-only, `mogens_v004_2026-04-17T09-03-11.db`)**:
  | Assessment | Code | After mutate | justification_len |
  |---|---|---|---|
  | TYLCV0 | IMP4.2 | min=NA, likely=NA, max=NA | 17,170 |
  | TYLCV0 | IMP4.3 | min=NA, likely=NA, max=NA | 13,944 |
  | TOBRFV | IMP4.2 | min=NA, likely=NA, max=NA | 14,781 |
  | TOBRFV | IMP4.3 | min='c', likely='c', max='c' | 15,871 |
  | PEPMV0 | IMP4.2 | min=NA, likely=NA, max=NA | 16,183 |
  | PEPMV0 | IMP4.3 | min='c', likely='c', max='c' | 14,859 |

#### Parser validation list + dead `IMP2`/`IMP4` bare-code branches (`python/parse_rmd_instructions.py`) — 2026-04-17
- **Context**: After the April 2026 restructure, `IMP2.1/.2/.3` and `IMP4.1/.2/.3` became top-level `##` entries; bare `IMP2` / `IMP4` headings no longer exist in the Rmd. Several code paths still checked for them.
- **Changes**:
  - `_validate()` `required_codes`: replaced `'IMP2'`, `'IMP4'` with the six actual sub-codes (`'IMP2.1'`, `'IMP2.2'`, `'IMP2.3'`, `'IMP4.1'`, `'IMP4.2'`, `'IMP4.3'`) so missing sub-questions are now flagged.
  - `_parse_question()` sub-questions branch (`if code in ['IMP2', 'IMP4']: question['sub_questions'] = ...`): removed (dead).
  - `_determine_type()` and `_extract_options()`: dropped the `code in ['IMP2', 'IMP4']` check; kept the `startswith('IMP2.') / startswith('IMP4.')` checks that actually fire.
  - `_validate()` boolean-options check: replaced `boolean_codes = {'IMP2', 'IMP4'}` set with an inline `startswith` check.
- Each removal carries an inline comment: `# IMP2/IMP4 restructured 2026-04-17: IMP2.1/.2/.3 and IMP4.1/.2/.3 are top-level entries (not sub-questions under a parent IMP2/IMP4 heading)`.

#### Sub-question rows carried old parent text after IMP2/IMP4 restructure (DB `questions` table) — 2026-04-17
- **Symptom**: In the Shiny app, IMP2.1 / IMP2.2 / IMP2.3 all rendered with the identical generic label "Would the pest cause the following indirect economic impacts in the PRA area?" (and IMP4.1 / IMP4.2 / IMP4.3 all showed the generic environmental/social label). Same-text appearance raised a concern that the AI populator was researching the wrong question.
- **Root cause**: The IMP2 / IMP4 restructure renamed the old parent rows (`idQuestion=7` `number='2'` → `'2.1'`; `idQuestion=9` `number='4'` → `'4.1'`) and inserted new sibling rows (`idQuestion=15,16,17,18`) for the remaining sub-questions. The `questions.question` column was not updated, so every sub-question row inherited the parent-level text. The Rmd and its generated JSON cache held the correct sub-question text all along.
- **Impact on the Python populator**: Not blocking. `create_research_query()` in `populate_finnprio_justifications.py` calls `build_justification_prompt(code, …)` which reads text from the JSON cache, not the DB — so AI prompts used the correct sub-question text. The DB's stale text only affected the Shiny UI label and any path that fell back on `answer['text']` (currently only console logging).
- **Fix**: New replayable migration script `scripts/migration scripts/4_sync_subquestion_text.py` (slot 3 was already used). Generic over any dotted sub-question code in `python/instructions_cache/finnprio_instructions.json`; updates `questions.question` for every dotted code where DB text ≠ JSON text. `argparse` CLI with `--dry-run` and `-v/--verbose` flags; uses `logging` (not `print`); idempotent (re-running produces `updated=0, already-in-sync=N`).
- **Applied to**: `databases/mogens_database_2026/mogens_v006_2026-04-17T10-45-45.db` — 6 rows updated (IMP2.1, IMP2.2, IMP2.3, IMP4.1, IMP4.2, IMP4.3). Re-run this script against every database that went through the IMP2/IMP4 restructure.

#### Surfaced previously-silent skips in justification populator (`python/populate_finnprio_justifications.py`) — 2026-04-17
- `get_all_assessment_ids()` now runs a second query to identify EPPO codes in `EPPOCODES_TO_POPULATE` that have no matching pest/assessment rows, and emits `logging.warning("EPPO codes not found in pests/assessments (skipped): %s", ...)`. Previously these were silently dropped (e.g. `TOLCND` in the mogens database has no matching pest record).
- Added a TODO comment in `get_assessment_info()` near the `code = f"{grp}{num}.{subgrp}" if subgrp else f"{grp}{num}."` line documenting that this trailing-dot convention diverges from `populate_finnprio_values.py` (`f"{group}{number}"`, no trailing dot). Both scripts currently interoperate only because `instructions_loader.py` strips trailing dots via `rstrip('.')`; the two should be unified on one form in a follow-up.

#### Crash when opening assessments with empty min/likely/max values (`R/internal functions.R`)
- **"ERROR [object Object]" / `ques_tag_opt` not found** when selecting species whose answers had justifications but no min/likely/max values (e.g. AI-populated assessments before value assignment)
- Root cause: `answers_2_logical()` initialized `result <- data.frame()` (zero columns), and when all answer values were NULL/NA, the loop never added rows — returning a column-less dataframe instead of `NULL`
- `render_quest_tab()` checked `!is.null(answers)` (TRUE for empty dataframe) then crashed on `filter(ques_tag_opt == ...)` since the column didn't exist
- Fix: added `if (nrow(result) == 0) result <- NULL` after the loop in both `answers_2_logical` and `answers_path_2_logical`

### Changed - March 2026

#### SDM Populator (`scripts/populate database scripts/6_sdm_populator.R`)
- Now looks for `SDMtune_updated_2` subfolder within each species folder instead of the species folder directly
- Replaced HTML parser with JSON reader (`model_summary/model_summary.json`) for richer, structured model metrics
- TIFF lookup now targets `rasters/current_clamped_{EPPOCODE}.tif` specifically
- Uses model's own `optimal_threshold` from JSON (maxTSS) instead of fixed 0.1 fallback
- Norway is primary focus; Sweden reported as supplementary only
- BioCLIM variable codes expanded to full human-readable names in justification text
- Justification restructured: establishment potential first, then future projections, then model performance details
- Removed boilerplate section headers and source tags from justification output

### Fixed - February 2026

#### Critical Save Handling Fixes
- **Justifications disappearing on save** - Fixed `grep()` bug in `get_inputs_as_df()`:
  - `grep("_", x)` returns `integer(0)` when no matches found
  - `x[-integer(0)]` removes ALL elements in R (unexpected behavior)
  - Changed to `grepl()` which returns logical vector and handles empty case correctly
  - Affected assessments without entry pathways where all justifications were lost

- **Justification-only rows not saved** - Fixed filter logic in `get_inputs_as_df()`:
  - Rows with justification text but no checkbox selections were being filtered out
  - Rewrote filter to explicitly keep rows with checkboxes OR justification content
  - Added `trimws()` to handle whitespace-only input
  - Same fix applied to `get_inputs_path_as_df()` for pathway answers

- **Stale data on save** - Fixed timing issue in save handler:
  - Save was using cached `frominput$main` which could be outdated
  - Now extracts fresh data directly from `input` at save time
  - Matches pattern already used for pathway answers

- **Report generation crash** - Fixed vector length mismatch in `add_answers_to_report()`:
  - `opt` and `text` vectors weren't aligned with `answers_quest` rows
  - Created lookup table and joins by option code
  - Same fix applied to `add_answers_path_to_report()`

- **Error handling** - Added try-catch around entire save operation:
  - Shows clear error message if database write fails
  - Prevents silent failures

#### Download Report Fix
- **Report saving to wrong location** - Changed from browser download to direct file save:
  - Reports now save directly to working directory
  - Shows confirmation with full file path
  - Changed `downloadHandler` to `observeEvent` with `actionButton`

### Changed - February 2026

#### UI Refinement (CSS v38.0)
- **Complete visual overhaul** - Replaced busy, colorful design with calm, professional aesthetic
- **Monochromatic color palette** - Single blue hue with neutral grays (removed green gradients and 8-color pathway tabs)
- **Reduced typography scale** - Base 16px (was 20px), proportional headings
- **Subtle visual elements** - Light borders (1-3px), soft shadows, no gradients
- **Unified section headings** - Consistent light gray/blue backgrounds with subtle left border accent
- **Clean pathway tabs** - Simple pill-style tabs with single accent color for active state
- **Refined justification boxes** - Minimal styling with focus states instead of heavy borders
- **Professional button hierarchy** - Muted edit buttons, outlined delete buttons
- **Improved readability** - Better contrast ratios, appropriate font sizes for context

**Design principles applied:**
- Visual hierarchy through typography weight and spacing, not competing colors
- Reduced cognitive load by minimizing decorative elements
- Consistent, predictable interface patterns
- Focus on content, not chrome

### Added - February 2026

#### Project Restructuring
- **Folder organization** - Created organized folder structure for better code management:
  - `databases/`: Centralized database storage with project-specific subfolders
  - `information/`: Documentation and diagrams
  - `scripts/`: All utility scripts organized by function
- **Script categorization** - Organized scripts into functional categories:
  - Database management scripts: `db_` prefix (delete, inspect, merge, check operations)
  - Migration scripts: Data migration and repair utilities
  - Populate scripts: `populate_eppo_` prefix for bulk EPPO data imports
  - Support scripts: Diagnostic and troubleshooting utilities
- **Cross-platform compatibility** - Fixed constants.R for Mac/Linux support:
  - Platform detection using `.Platform$OS.type`
  - Windows: Dynamic drive letter detection via `wmic logicaldisk get name`
  - Mac/Linux: Simplified approach with Home and Root paths
  - Resolves app crashes on Mac caused by Windows-specific system commands

  **Implementation** (R/constants.R):
  ```r
  if (.Platform$OS.type == "windows") {
    sysdrive <- system("wmic logicaldisk get name", intern = TRUE)
    drives <- substr(sysdrive[-c(1, length(sysdrive))], 1, 1)
    named_paths <- setNames(paste0(drives, ":/"), paste0(drives, ":"))
  } else {
    named_paths <- c(Home = fs::path_home(), Root = "/")
  }

  volumes <- c("Working Directory" = getwd(),
               Home = fs::path_home(),
               named_paths,
               "My Computer" = "/")

  # Default simulation parameters
  limits <- list(Minimum = 1, Likely = 1, Maximum = 1)
  default_sim <- list(n_sim = 50000, seed = 1234, lambda = 1, w1 = 0.5, w2 = 0.5)
  ```

#### Major UI/UX Overhaul (CSS v36.0 - v37.3)
- **Complete CSS Rebuild** - Rebuilt entire stylesheet from scratch with clean, maintainable architecture
  - Organized into 15 logical sections with clear documentation
  - Established CSS variables for all design tokens (colors, spacing, typography)
  - Removed all fragile selectors and excessive !important rules
  - Implemented Coolors blue palette (#03045e through #caf0f8) consistently

#### Color-Coded Section Headings
- **Green Gradient Headings** for General Information section:
  - General Information (main heading) - Dark green gradient
  - Assessment Details - Light green
  - Pest Species Information - Light-medium green
  - Hosts - Medium green
  - Threatened Sectors - Medium-dark green
  - Entry Pathways - Dark green
- **Blue Gradient Headings** for Assessment Questions:
  - Notes - Lightest blue
  - Entry - Light-medium blue
  - Establishment and Spread - Medium blue
  - Impact - Medium-dark blue (white text)
  - Management - Dark blue (white text)
  - References - Light blue
- Creates clear visual separation between setup (green) and assessment (blue) sections

#### Enhanced Typography
- Increased base font size from 16px to 20px for better readability
- Question headings: 36px (bold, prominent)
- Table cells: 24px
- Justification textarea: 30px (extra large for comfortable writing)
- Pathway banners: 44px (bold, highly visible)

#### Button Improvements
- **Color-coded buttons** for clear visual hierarchy:
  - Green: Save actions (save_general, save_answers)
  - Orange/Amber: Edit actions (change_assessor, edit_pest, edit_assessor)
  - Red: Delete actions (delete_pest, delete_assessor)
  - Blue: Default actions
- **Relocated action buttons** - Moved Download/Save/Change buttons from Assessment Details card to centered position below General Information section for better workflow
- **Floating Save Answers button** - Fixed positioning with JavaScript-controlled delayed appearance (shows after scrolling 800px past Notes section)

#### Justification Box Enhancements
- **Prominent styling** that really "pops":
  - Bold 4px borders with 8px left accent in dark blue
  - Strong double-layered shadows for depth
  - 64px padding for generous space
  - Smooth hover effects with lift and shadow intensification
- **Milder label backgrounds** - Changed from dark blue to light blue with dark text
- **Side-by-side layout** - Questions tables (55%) and justification boxes (45%) display side-by-side in main assessment sections

#### Pathway Tab Colors (8 Pathways)
- **Bold, highly visible tabs** with full colored backgrounds:
  - Pathway 1: Hot Pink (#e91e63)
  - Pathway 2: Deep Purple (#9c27b0)
  - Pathway 3: Bright Orange (#ff9800)
  - Pathway 4: Vibrant Green (#4caf50)
  - Pathway 5: Bright Cyan (#00bcd4)
  - Pathway 6: Bold Red (#f44336)
  - Pathway 7: Deep Indigo (#3f51b5)
  - Pathway 8: Rich Teal (#009688)
- Thick 3px borders, 5-6px bottom borders
- Large bold text (24px) for easy identification
- Active state intensifies with darker colors

#### Table Improvements
- **Removed double blue lines** - Clean single header with no extra borders
- Explicit border removal on tables, DataTables wrappers, and containers
- Maintained alternating row colors and hover effects

### Fixed - February 2026

#### Critical Fixes
- **Save buttons functionality** - Both save_general and save_answers buttons now properly visible and functional
  - Removed CSS !important rules that blocked JavaScript control
  - Added debugging logging to both R console and browser console
  - Fixed floating button positioning and z-index issues
- **Pathway layout** - Fixed horizontal cramming issue where all pathway questions displayed in one row
  - Reverted to clean vertical layout for pathway questions
  - Maintained prominent justification box styling
- **CSS cache issues** - Implemented version-based cache busting (v=37.3)

#### Layout Fixes
- Removed inline styles from server.R (replaced with semantic classes)
- Fixed button container structure with proper `button-container` classes
- Ensured proper spacing and alignment throughout application

### Changed - February 2026

#### Structural Changes
- **Button organization** - Consolidated action buttons into logical groups
- **Section hierarchy** - Clear visual flow from General Information (green) to Assessment (blue)
- **Responsive design** - Improved mobile/tablet layout with proper breakpoints

### Technical Details

#### CSS Architecture
- **Variables**: 86 lines of design tokens (colors, spacing, typography, shadows, radius)
- **Sections**: 15 organized sections totaling 560 clean lines (reduced from 800+ messy lines)
- **Performance**: Minimal !important usage, efficient selectors, smooth transitions

#### Files Modified
- `www/styles.css` - Complete rewrite (v36.0 → v37.3)
- `ui.R` - CSS version updates, JavaScript debugging
- `server.R` - Button relocation, heading IDs, inline style removal

#### Browser Compatibility
- Tested with modern browsers (Chrome, Firefox, Edge, Safari)
- Uses standard CSS properties for maximum compatibility
- Graceful degradation for older browsers

### Added - January 2026

#### Data Management Enhancements
- **Pest-species tab** - Full CRUD operations:
  - Added Edit and Delete buttons (previously only had Create)
  - Edit Selected Pest: Pre-populates modal with existing data
  - Delete Selected Pest: Cascade deletion of associated assessments, answers, and simulations
  - Validation: Prevents duplicate scientific names, EPPO codes, and GBIF taxon keys
  - Data integrity warnings before deleting pests with existing assessments
- **Assessors tab** - Complete table display and CRUD operations:
  - Added interactive DataTable showing firstName, lastName, email
  - Edit Selected Assessor: Modify existing assessor information
  - Delete Selected Assessor: Protected deletion (blocks if assessments exist)
  - Validation: Requires firstName and lastName; email optional
  - Data integrity: Prevents deletion of assessors with existing assessments

#### CRUD Implementation Patterns
All CRUD operations follow consistent, reliable patterns:
- **Row selection**: Via DataTable `_rows_selected` input
- **Edit modals**: Pre-populated with `value =` parameter in input fields
- **Validation**: Check required fields and duplicates before DB operations
- **Confirmation**: `shinyalert()` with callbacks for destructive operations
- **Refresh**: Reload reactive data and update dropdowns after changes
- **NULL handling**: Proper handling of NULL/NA values in optional fields

### Fixed - January 2026

#### Critical Bug Fixes
- **Delete by EPPO code** - Fixed case-insensitive matching:
  - Uses `UPPER(eppoCode)` in SQL query for reliable matching
  - Script: `2_db_delete_selected_by_eppocode.R`
- **NULL field repair** - Created repair tool for pests table:
  - Fixes NULL values in idTaxa, idQuarantineStatus, inEurope
  - Prevents app crashes when loading assessments
  - Script: `2_fix_null_pest_fields.R`
- **Database locking** - Implemented automatic stale session unlock:
  - 5-minute timeout using `difftime(now(), as_datetime(timestamp))`
  - Prevents permanent locks from crashed/abandoned sessions
  - Uses lubridate functions: `now()`, `as_datetime()`
  - Disables save buttons when another user actively has the database locked

  **Implementation** (server.R):
  ```r
  if (dbStatus$data$inUse == 1) {
    # Check if lock is stale
    since <- difftime(now(),
                      as_datetime(dbStatus$data$timeStamp),
                      units = "mins")
    if(since > 5) { # 5 minutes - auto-unlock stale sessions
      # Reset stale lock
      dbExecute(con(), "UPDATE dbStatus
                    SET inUse = 0,
                        timeStamp = CURRENT_TIMESTAMP
                    WHERE rowid = (SELECT MAX(rowid) FROM dbStatus);")
      dbStatus$data <- dbReadTable(con(), "dbStatus")
      dbStatus$dibs <- TRUE
    } else {
      dbStatus$dibs <- FALSE
    }
  } else {
    dbStatus$dibs <- TRUE
  }
  ```
- **File navigation** - Added Working Directory to file chooser volumes:
  - Easier database selection via shinyFiles dialog
  - Quick access to project root folder

### Changed - January 2026

#### Code Quality Improvements
- **global.R optimization**:
  - Removed duplicate mc2d loading
  - Added missing packages: lubridate (for date/time operations), fs (for filesystem paths)
  - Organized package comments by purpose (Shiny, Database, Data, File system, Statistics, Reporting)
  - Removed `force=T` parameter from install.packages() for safer installation
- **Documentation**:
  - Comprehensive README.rmd with all features and recent changes
  - Organized package documentation with clear grouping

## [Previous Versions]

For historical changes before January 2026, see git commit history and project documentation.

---

**Note**: This changelog focuses on UI/UX improvements from February 2026. For database schema changes, feature additions, and bug fixes from earlier releases, see the project documentation and CLAUDE.md file.
