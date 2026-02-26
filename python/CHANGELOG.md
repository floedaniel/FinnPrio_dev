# Changelog - FinnPRIO AI Enhancement Scripts

All notable changes to the Python AI enhancement scripts.

---

## [2026-02-26] - Hybrid Research Script

### Added
- `populate_finnprio_justifications_hybrid.py`: New script combining web search with local PDF documents
  - Uses GPT Researcher's hybrid mode for enhanced research quality
  - Automatically loads documents from `Species/{EPPO_CODE}/` folder
  - Recursively finds all .pdf, .txt, .docx, .doc files
  - Falls back to web-only if no local documents exist for a species
  - Copies docs to temp `my-docs` folder, cleans up after processing

---

## [2026-02-25] - Rmd Restructuring and Parser v2.0

### Major: Clean Rmd Format with Explicit Thresholds

Complete restructuring of the instructions system for better parsing and clearer AI prompts.

**Rmd File Changes (`Instructions_FinnPRIO_assessments.Rmd`):**
- New consistent format with `### Options` and `### Guidance` sections
- Options now include descriptions inline (e.g., `**a. Small** (<2 million km²)`)
- Explicit km² thresholds for geographic questions:
  - **ENT1**: Small (<2M km²), Medium (2-20M km²), Large (>20M km²)
  - **ENT3**: Small (<1M kg/pc), Medium (1-10M kg/pc), Large (>10M kg/pc)
  - **EST2**: Very small (<100 ha), Small (100-1000 ha), Medium (1000-10000 ha), Large (>10000 ha)
- Removed old "red circle" references
- All 18 questions converted to new format

**Parser Changes (`parse_rmd_instructions.py`):**
- Version 2.0 for new clean format
- Parses `### Options` section with descriptions
- Parses `### Guidance` section as bullet points
- Filters out `---` separator lines
- Handles EST4 scoring characteristics
- Handles IMP2/IMP4 boolean sub-questions

**Loader Changes (`instructions_loader.py`):**
- Works with new JSON format (`guidance` instead of old `sections`)
- Builds prompts with option descriptions inline
- Cleaner prompt output

**Benefits:**
- AI now sees explicit thresholds (km², ha, kg) in prompts
- More accurate value selection based on quantitative criteria
- Easier to maintain - edit Rmd, parser auto-updates JSON
- Both justification and values scripts use the new instructions

**Testing:**
```bash
# Regenerate JSON from new Rmd
python parse_rmd_instructions.py --force

# Test loader
python instructions_loader.py
```

---

## [2026-02-24] - Rmd-to-JSON Instructions System

### New: External Instructions Source

Question-specific instructions now loaded from `Instructions_FinnPRIO_assessments.Rmd` instead of hardcoded Python.

**Benefits:**
- Edit Rmd file to customize instructions (no code changes needed)
- Richer prompts with examples, thresholds, and guidance sections
- Consistent instructions across justification and value scripts
- Auto-regenerates JSON when Rmd is modified

**New Files:**
| File | Purpose |
|------|---------|
| `parse_rmd_instructions.py` | Parses Rmd to structured JSON |
| `instructions_loader.py` | Loads JSON, builds prompts |
| `instructions_cache/` | Cache directory for generated JSON |

**Modified Files:**
- `populate_finnprio_justifications.py` - Uses `instructions_loader` with fallback
- `populate_finnprio_values.py` - Enhanced prompts with Rmd examples

**Workflow:**
```
Instructions_FinnPRIO_assessments.Rmd
         ↓ (auto-parse on change)
finnprio_instructions.json (cache)
         ↓ (load at runtime)
populate_*.py scripts
```

**Testing:**
```bash
# Test parser standalone
python parse_rmd_instructions.py --force

# Test loader
python instructions_loader.py
```

---

## [2026-02-24] - Unified EPPO + GPT Researcher Integration

### ✅ New: EPPO MCP Server (`servers/eppo_mcp_server.py`)

Custom MCP server providing access to EPPO Global Database API v2.

**Features:**
- SQLite caching (7-day TTL) - reduces API calls
- Rate limiting (60 requests / 10 seconds) - respects EPPO limits
- Async HTTP client (httpx)
- MCP protocol compliance

**Available Tools:**
| Tool | Description |
|------|-------------|
| `eppo_get_pest_info` | Comprehensive pest data (distribution, hosts, regulatory) |
| `eppo_get_distribution` | Geographic distribution by country |
| `eppo_get_hosts` | Host plants (major/minor classification) |
| `eppo_get_categorization` | Regulatory status (A1/A2 lists) |
| `eppo_get_taxonomy` | Taxonomic classification |
| `eppo_get_vectors` | Vector organisms |
| `eppo_get_bca` | Biological control agents |
| `eppo_search` | Search EPPO code by name |

**Requirements:**
```bash
pip install mcp httpx aiosqlite
```

---

### ✅ New: Unified Orchestrator (`populate_finnprio_justifications_unified.py`)

**"One script to bind them all"** - Combines EPPO and GPT Researcher.

**Architecture:**
```
Unified Script
    ├── EPPO MCP Server (authoritative data)
    │   └── Distribution, Hosts, Categorization, Vectors, BCA
    └── GPT Researcher MCP (scientific literature)
        └── Papers, Studies, Outbreak reports
```

**Workflow per question:**
1. Query EPPO for structured, authoritative data (cached)
2. Build context-aware research query using EPPO data
3. Call GPT Researcher for broader scientific context
4. Synthesize both into comprehensive justification

**Question → EPPO Data Mapping:**
| Question | EPPO Data Used |
|----------|----------------|
| ENT1 | Distribution, Categorization |
| EST1-3 | Distribution, Hosts |
| EST4 | Hosts, Vectors |
| IMP1-4 | Hosts |
| MAN1-3 | Distribution, Categorization |
| MAN4-5 | Biological Control Agents |

**Benefits over separate scripts:**
- EPPO data as reliable foundation (instant, cached)
- Smarter research queries (GPT Researcher searches with EPPO context)
- Reduced costs (EPPO data is free after fetch; reduces research scope)
- Better citations (EPPO official sources + literature)
- Graceful fallback (EPPO down → research only)

**Usage:**
```bash
python populate_finnprio_justifications_unified.py --eppo-codes XYLEFA
python populate_finnprio_justifications_unified.py --assessment-id 1
python populate_finnprio_justifications_unified.py  # All assessments
```

**Output:** `original_name_unified_DD_MM_YYYY.db`

---

### 📁 New File Structure

```
python/
├── servers/
│   ├── __init__.py
│   └── eppo_mcp_server.py          # NEW: EPPO API MCP server
├── cache/
│   └── eppo_cache.db               # Auto-created: EPPO cache
├── populate_finnprio_justifications_unified.py  # NEW: Combined script
├── populate_finnprio_justifications.py
├── populate_finnprio_justifications_mcp.py
├── populate_finnprio_justifications_anthropic.py
├── populate_finnprio_values.py
└── ...
```

---

## [2026-02-16] - Performance Fixes for Local Values Script

### 🔧 Fixed: `populate_finnprio_values_local.py` Extreme Slowness

Fixed critical performance issues causing 10+ minutes per question:

**Root Causes:**
1. Model was `phi4-reasoning:14b` (11GB) - too slow for laptops
2. No `max_tokens` limit - model could generate excessive responses
3. No justification truncation - long texts slowed inference
4. Verbose prompts - unnecessary tokens in input

**Fixes Applied:**
- Changed default model to `mistral:7b-instruct` (4.4GB, much faster)
- Added `MAX_TOKENS = 150` limit (only need short JSON response)
- Added `MAX_JUSTIFICATION_LENGTH = 2000` truncation
- Simplified prompts (reduced ~300 tokens to ~80 tokens)

**Expected Performance:**
- Before: 10+ minutes per question
- After: 5-15 seconds per question (depending on model/hardware)

---

## [2026-02-16] - EPPO Code Filtering, Database Fixes, and FREE Local Scripts

### ✅ New: FREE Local LLM Scripts (Zero Cost!)

Created two new scripts that use **Ollama (local LLM) + DuckDuckGo (free search)** for 100% free operation:

**`populate_finnprio_justifications_local.py`**
- Uses GPT Researcher with Ollama backend
- DuckDuckGo for web search (no API key needed)
- Recommended models: phi3:3.8b (fast), llama3.2 (balanced), qwen2:7b (quality)
- Reduced research parameters for laptop performance
- Output files named `*_local_*.db`

**`populate_finnprio_values_local.py`**
- Direct Ollama API (OpenAI-compatible endpoint)
- No web search needed (analyzes existing justifications)
- Fast inference with small models
- Same features as paid version

**Requirements:**
```bash
# Install Ollama models
ollama pull phi3:3.8b-mini-128k-instruct
ollama pull llama3.2
ollama pull nomic-embed-text

# Start Ollama server
ollama serve
```

**Usage:**
```bash
python populate_finnprio_justifications_local.py --eppo-codes XYLEFA
python populate_finnprio_values_local.py --eppo-codes XYLEFA
```

### ✅ New: EPPO Code Filtering

Added ability to filter species by EPPO codes in all 4 Python population scripts. Previously, scripts processed ALL assessments in the database.

**Files Modified:**
- `populate_finnprio_justifications.py`
- `populate_finnprio_justifications_mcp.py`
- `populate_finnprio_justifications_anthropic.py`
- `populate_finnprio_values.py`

**New Configuration Variable:**
```python
# Filter by EPPO codes (empty list = process all species)
EPPOCODES_TO_POPULATE = []  # e.g., ["XYLEFA", "ANOLGL", "DROSSU"]
```

**New Command-Line Argument:**
```bash
python populate_finnprio_justifications.py --eppo-codes XYLEFA ANOLGL DROSSU
```

**Features:**
- Case-insensitive matching (uses `UPPER()` in SQL)
- Command-line `--eppo-codes` overrides config `EPPOCODES_TO_POPULATE`
- Warns about missing EPPO codes not found in the database
- Empty list = process all species (default behavior)

### ✅ Fixed: Database Naming Accumulation

**Issue:** Running the script multiple times would append `_ai_enhanced_` repeatedly, creating very long filenames like `db_ai_enhanced_15_02_2026_ai_enhanced_16_02_2026.db`

**Solution:** Extract base name before the enhancement suffix when source already contains it:
- `selam_2026.db` → `selam_2026_ai_enhanced_16_02_2026.db`
- `selam_2026_ai_enhanced_15_02_2026.db` → `selam_2026_ai_enhanced_16_02_2026.db` (replaces, not appends)

### ✅ Fixed: Same-Day Re-run Error

**Issue:** Running the script on the same database on the same day caused `SameFileError` because source and destination paths were identical.

**Solution:** Detect when source and destination are the same file and work directly on the existing file:
```
📋 Using existing database (same-day re-run)...
   Path: C:\...\daniel_ai_enhanced_16_02_2026.db
✅ Working on existing file (XXX KB)
```

---

## [2026-02-10] - Major Cleanup, MCP Version, and Anthropic Version

### ✅ New: Anthropic Version (`populate_finnprio_justifications_anthropic.py`)
- GPT Researcher with Claude (Anthropic) as the LLM backend
- Best of both worlds: comprehensive web research + Claude's superior reasoning
- Claude Sonnet 4 for final reports and strategic planning
- Claude 3.5 Haiku for fast intermediate tasks (summaries)
- Same proven GPT Researcher workflow, but powered by Claude
- Tavily API for web search (same as OpenAI version)

### 🧹 Folder Cleanup
Removed 22 unnecessary files (tests, debug scripts, old documentation).

### 📁 File Renames
- `populate_finnprio_justifications_v3.py` → `populate_finnprio_justifications.py`
- `populate_finnprio_justifications_v4.py` → `populate_finnprio_justifications_mcp.py`

### ✅ New: MCP Version (`populate_finnprio_justifications_mcp.py`)
- Uses GPT Researcher MCP Server for research
- Benefits: caching, persistent connection, multiple tools
- Requires `gptr-mcp-master/` server
- Fixed markdown cleaning that was stripping all content

### 🗑️ Deleted Files
- `populate_finnprio_justifications_v2.py` (empty)
- `populate_sdm_establishment.py` (R version is better)
- All test files (`test_v2*.py`, `test_v3*.py`, etc.)
- All debug/check scripts (`check_*.py`, `debug_*.py`)
- Old documentation (`V2_APPROACH.md`, `V3_WHATS_NEW.md`, etc.)

### 📦 Current Python Scripts
```
python/
├── populate_finnprio_justifications.py           # Main (GPT Researcher direct)
├── populate_finnprio_justifications_mcp.py       # MCP server version
├── populate_finnprio_justifications_anthropic.py # Claude/Anthropic version
├── populate_finnprio_values.py                   # Values populator
├── view_justifications.py                        # Utility
├── README.md
├── CHANGELOG.md
└── requirements.txt
```

### 🐛 Bug Fixes
- Fixed overly strict database warning (now just confirms before proceeding)
- Fixed MCP markdown cleaner that was removing all content

---

## [2026-02-03] - Major Refactoring and Feature Additions

### 🎯 Overview
Complete overhaul of both main scripts to support multiple assessments, improved error handling, and better configuration management.

---

## [2026-02-03 - Final Update] - Batch Simulation Script

### ✅ New R Script: Batch Simulation

**Purpose:** Automate Monte Carlo simulations for all assessments in a database

**Location:** `scripts/populate database scripts/6_batch_simulation.R`

**Features:**
- Sources `R/simulations.R` for simulation functions
- Configurable simulation settings (iterations, lambda, weights)
- Batch processes all assessments or single assessment
- Skip existing simulations option
- Filter by finished/valid assessments
- Detailed progress reporting
- Error handling per assessment
- Saves to `simulations` and `simulationSummaries` tables

**Configuration Options:**
```r
ITERATIONS <- 50000  # Monte Carlo iterations
LAMBDA <- 1          # PERT shape parameter
WEIGHT1 <- 0.5       # Economic impact weight
WEIGHT2 <- 0.5       # Environmental/social weight
SKIP_EXISTING <- TRUE        # Skip assessments with simulations
ONLY_FINISHED <- TRUE        # Only process finished assessments
ONLY_VALID <- FALSE          # Only process valid assessments
SPECIFIC_ASSESSMENT <- NULL  # Or set ID for single assessment
```

**Usage:**
```r
# Edit configuration in script, then run:
source("scripts/populate database scripts/6_batch_simulation.R")
```

**Impact:** Enables automated simulation runs for entire databases, completing the AI-assisted assessment pipeline.

---

## [2026-02-03 - Late Update] - Research Guidance Enhancement

### ✅ Improved Research Quality Instructions

**Issue:** AI justifications didn't always clearly indicate when information was insufficient or when assumptions were made
**Solution:** Added explicit guidance to research query prompts

**Changes:**
- `populate_finnprio_justifications_v3.py` (lines 539-548):
  - **INSUFFICIENT INFORMATION section:** Instructs AI to explicitly state "The provided context contains insufficient information to answer the question." when data is lacking
  - **ASSUMPTIONS section:** Requires clear indication of assumptions with phrases like "Assuming that...", "Based on the assumption that...", etc.
  - Distinguishes between evidence-based statements and assumptions

**Impact:**
- More transparent justifications
- Clearer indication of data quality and limitations
- Better assessment of confidence levels
- Easier to identify questions needing additional research

---

## Added Features

### ✅ Multi-Assessment Processing
**Issue:** Scripts only processed one assessment at a time (the most recent valid one)
**Solution:** Refactored both scripts to loop through all assessments

**Changes:**
- `populate_finnprio_justifications_v3.py`:
  - Added `get_all_assessment_ids()` function
  - Modified `get_assessment_info()` to require assessment_id parameter
  - Updated `main()` to loop through all assessments when no ID specified
  - Shows progress: "ASSESSMENT 1/2 (ID: 1)"

- `populate_finnprio_values.py`:
  - Added `get_all_assessment_ids()` method
  - Created `populate_values_for_assessment()` method for single assessment
  - Refactored `populate_values()` to loop through assessments
  - Shows progress per assessment with totals

**Impact:** Users can now process entire databases in one run instead of manually specifying each assessment ID.

---

### ✅ Skip Existing Configuration

**Issue:** No easy way to skip already-processed data, leading to duplicate work and API costs
**Solution:** Added top-level configuration flags with command-line overrides

**Changes:**
- `populate_finnprio_justifications_v3.py`:
  ```python
  SKIP_EXISTING_JUSTIFICATION = True  # Line 27
  ```
  - Added `--overwrite` command-line flag
  - Properly skips answers/pathway answers with existing justifications
  - Clear console output: "⏭️ Skipped (existing justification)"

- `populate_finnprio_values.py`:
  ```python
  SKIP_EXISTING_VALUES = True  # Line 32
  ```
  - Added `--overwrite` command-line flag
  - Skips answers with existing min/likely/max values
  - Prevents unnecessary API calls

**Impact:** Significant cost savings and faster re-runs when adding new assessments to database.

---

### ✅ External API Key Management

**Issue:** API keys were hardcoded in scripts
**Solution:** Read API keys from external text files

**Changes:**
Both scripts now use:
```python
OPENAI_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\chatgpt_apikey.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\Tavily_key.txt"

def load_api_key(file_path: str) -> str:
    """Load API key from file, stripping whitespace"""
    with open(file_path, 'r') as f:
        return f.read().strip()
```

**Impact:**
- Easier API key rotation
- No accidental key exposure in git
- Better security practices

---

### ✅ Enhanced Error Handling

**Issue:** Generic error messages made debugging difficult
**Solution:** Added detailed error reporting with database path verification

**Changes:**
- `populate_finnprio_justifications_v3.py`:
  ```python
  def update_answer_justification(db_path, id_answer, justification):
      # Verify table exists
      cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='answers'")
      if not cursor.fetchone():
          raise Exception(f"Table 'answers' not found in database: {db_path}")
      # ... detailed error messages
  ```
  - Same for `update_pathway_justification()`
  - Shows database path, answer ID, and specific error

**Impact:** Faster troubleshooting of database connection issues.

---

### ✅ Boolean Question Handling

**Issue:** Boolean questions (IMP2, IMP4) were failing with "Invalid option code 'no'" error
**Solution:** Improved prompt and validation for boolean questions

**Changes:**
- `populate_finnprio_values.py`:
  - Updated boolean question prompt to clarify single-option structure
  - Explained that option "a" = YES, null = NO
  - Added null value validation
  - Skips boolean NO answers (doesn't store null values)
  - Lines 191-222: New boolean prompt
  - Lines 258-260: Allow null in validation
  - Lines 443-446, 490-493: Skip null value answers

**Impact:** Boolean questions now process correctly without errors.

---

## Utility Scripts Created

### ✅ `close_all_connections.py`
**Purpose:** Close all database connections and clear locks

**Features:**
- Finds all .db files in project (excludes .venv)
- Checks and clears dbStatus locks
- Removes stale journal/WAL files
- Shows lock status and timestamps

**Use Case:** Resolving "database is locked" errors

---

### ✅ `check_missing_values.py`
**Purpose:** List questions with justifications but missing values

**Output:**
```
Questions with justifications but missing values:
ENT1    (minmax  ) -  12 answers missing
IMP2.1  (boolean ) -   8 answers missing
```

---

### ✅ `check_pathway_values.py`
**Purpose:** Detailed status of pathway answers

**Output:**
- Lists all pathway answers
- Shows justification status (✅/❌)
- Shows values status (✅/❌)
- Groups by pathway name

---

### ✅ `check_selected_pathways.py`
**Purpose:** Show which pathways are selected in assessments

**Output:**
```
Assessment 1: Fusarium euwallaceae
  ✅ Plants for planting

Assessment 2: Dendroctonus ponderosae
  ✅ Plants for planting
  ✅ Wood and wood products
```

---

### ✅ `check_wood_pathway.py`
**Purpose:** Specific check for wood pathway status

**Output:** Shows wood pathway answers across all assessments with justification/value status.

---

## Bug Fixes

### 🐛 Fixed: Pathway Answers Not Being Created
**Issue:** pathwayAnswers table was empty even though pathways were selected
**Root Cause:** Justifications script needs to run first to create pathway answers
**Solution:**
- Verified justifications script creates pathway answers via INSERT
- Added documentation explaining workflow order
- Created check scripts to diagnose the issue

---

### 🐛 Fixed: Database Path Configuration
**Issue:** Script used hardcoded database paths
**Root Cause:** No clear configuration section at top of files
**Solution:**
- Moved all configuration to top of scripts
- Added comments explaining each option
- Documented in README.md

---

### 🐛 Fixed: Case-Insensitive EPPO Code Matching
**Issue:** Delete by EPPO code failed for lowercase codes
**Note:** This was in R script `2_db_delete_selected_by_eppocode.R`
**Solution:** Used `UPPER(eppoCode)` in SQL query

---

## Documentation

### ✅ Created `README.md`
Comprehensive documentation including:
- Overview and workflow diagram
- All scripts with features and usage
- Configuration options
- Command-line arguments
- Troubleshooting guide
- Important notes about processing order

### ✅ Created `CHANGELOG.md`
This file documenting all changes made today.

---

## Configuration Changes

### Default Values Updated

#### `populate_finnprio_justifications_v3.py`
```python
SKIP_EXISTING_JUSTIFICATION = True  # NEW
DEFAULT_DB_PATH = "outputs/old_test.db"  # Updated by user
EXCLUDED_DOMAINS = ["grokipedia.com", "wikipedia.org"]
```

#### `populate_finnprio_values.py`
```python
SKIP_EXISTING_VALUES = True  # NEW
INPUT_DATABASE = "outputs/ai_test_ai_enhanced_03_02_2026.db"  # Updated by user
LLM_MODEL = "gpt-4o-mini"  # Updated from "gpt-4o"
```

---

## Performance Improvements

### ✅ Skip Existing Data
- Avoids redundant API calls
- Saves ~$0.10-0.50 per question for justifications
- Saves ~$0.01 per question for values
- Processes only new/missing data

### ✅ Parallel-Ready Structure
- Each assessment processed independently
- Future: Could parallelize assessment processing
- Current: Sequential but well-organized

---

## Breaking Changes

### ⚠️ `get_assessment_info()` Parameter Change
**Old:** `get_assessment_info(db_path, assessment_id=None)`
**New:** `get_assessment_info(db_path, assessment_id)` - assessment_id now required

**Impact:** Internal function only, no external API impact

### ⚠️ Default Behavior Change
**Old:** Process only most recent valid assessment
**New:** Process ALL assessments when no --assessment-id specified

**Impact:** Users need to be aware that running without parameters processes everything

---

## Known Issues

### 🔍 Investigating: "no such table: answers" Error
**Status:** Enhanced error handling added to diagnose
**Workaround:**
1. Run `close_all_connections.py`
2. Verify database schema
3. Check detailed error output

**Next Steps:** Waiting for detailed error logs from user

---

### 🔍 Empty pathwayAnswers Table
**Status:** Workflow order issue
**Root Cause:** Justifications script must run before values script
**Solution:** Documented in README.md, added check scripts

---

## Migration Guide

### From Previous Version

If you have existing scripts, update:

1. **Add configuration at top:**
```python
SKIP_EXISTING_JUSTIFICATION = True  # or False
SKIP_EXISTING_VALUES = True  # or False
```

2. **Update API key loading:**
```python
# OLD
os.environ['OPENAI_API_KEY'] = 'sk-...'

# NEW
OPENAI_API_KEY_FILE = r"path/to/key.txt"
os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
```

3. **Update command-line usage:**
```bash
# OLD - only processed one assessment
python script.py

# NEW - processes all assessments
python script.py

# NEW - single assessment (same as before)
python script.py --assessment-id 2
```

---

## Testing

### ✅ Tested Scenarios

1. **Multi-assessment processing:** ✅ Verified with 2 assessments
2. **Skip existing justifications:** ✅ Confirmed skips correctly
3. **Skip existing values:** ✅ Confirmed skips correctly
4. **Boolean questions:** ✅ Fixed and verified
5. **Pathway questions:** ✅ Verified creation and updates
6. **Database locking:** ✅ Close connections script works
7. **Error handling:** ✅ Enhanced error messages added

### ⏳ Pending Tests

1. **Large database (10+ assessments):** Not yet tested
2. **Concurrent script execution:** Not tested (should fail gracefully)
3. **Network interruption during research:** Not tested
4. **Corrupted database recovery:** Not tested

---

## Future Enhancements

### Planned Features

1. **Progress Bar:** Add tqdm for better progress visualization
2. **Resume Capability:** Save state to resume interrupted runs
3. **Parallel Processing:** Process multiple assessments simultaneously
4. **Dry Run Mode:** Preview what would be processed without making changes
5. **Validation Mode:** Verify justifications and values for quality
6. **Export Reports:** Generate summary reports of processing results
7. **Database Backup:** Automatic backup before processing
8. **Cost Estimation:** Show estimated API costs before running

### Under Consideration

1. **Web UI:** Simple web interface for script configuration
2. **Batch Processing:** Queue multiple databases for processing
3. **Integration Tests:** Automated testing framework
4. **Docker Container:** Containerized deployment option

---

## Contributors

- **Initial Development:** AI assistance (Claude Code)
- **Testing & Feedback:** User (dafl)
- **Date:** February 3, 2026

---

## Version History

### v3.0.0 (2026-02-03)
- Multi-assessment processing
- Skip existing configuration
- External API key management
- Enhanced error handling
- Boolean question fixes
- Comprehensive documentation

### v2.x (Previous)
- Single assessment processing
- Hardcoded API keys
- Basic error handling
- Limited documentation

---

**For questions or issues, refer to README.md or contact the development team.**
