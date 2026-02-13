# Changelog

All notable changes to the FinnPRIO Assessor project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
