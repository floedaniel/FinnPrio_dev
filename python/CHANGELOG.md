# Changelog - FinnPRIO AI Enhancement Scripts

> Covers Python pipeline technical detail.
> For R/Shiny and project-level changes see [../CHANGELOG.md](../CHANGELOG.md).

All notable changes to the Python AI enhancement scripts.

---

## [2026-06-18] - Model upgrade: gpt-5.x series across both scripts

### Changed

**`populate_finnprio_justifications.py`**
- **`FAST_LLM`** upgraded from `openai:gpt-4o-mini` to `openai:gpt-5.4-mini` — quick tasks (summarization, sub-queries).
- **`SMART_LLM`** upgraded from `openai:gpt-4.1` to `openai:gpt-5.4` — complex reasoning and report writing.
- **`STRATEGIC_LLM`** upgraded from `openai:o3` to `openai:gpt-5.5` — planning (agent/query selection).

**`populate_finnprio_values.py`**
- **`LLM_MODEL`** and **`LLM_MODEL_FAST`** added to the configuration section via `os.environ.setdefault()` — defaults to `gpt-5.4` (PERT scoring) and `gpt-5.4-mini` (boolean classification) respectively; overridable via environment variable.
- **`_call_gpt_for_values`**: model fallback updated from `gpt-4o` to `gpt-5.4`; `max_tokens` replaced with `max_completion_tokens` (required by gpt-5.x).
- **`_call_gpt_boolean`**: switched from `LLM_MODEL` to `LLM_MODEL_FAST`; `max_tokens` replaced with `max_completion_tokens`.
- **`populate_values`**: prints active `LLM_MODEL` and `LLM_MODEL_FAST` on startup.

---

## [2026-06-16] - Deep research routing + eppo_gd validator fix

### Added

- **`DEEP_RESEARCH_QUESTIONS`** constant in `populate_finnprio_justifications.py` — set of question codes that use `report_type="deep"` (recursive tree-like exploration) instead of `"research_report"`. Current members: `ENT2A`, `ENT2B`, `EST1`, `EST2`, `IMP1`. ENT2 appears as pathway questions in the DB (not plain ENT2), so both A/B variants are included.
- **Per-question `report_type` routing** in `research_justification()`: normalises the question code (strips trailing dot) and selects `"deep"` or `"research_report"` before constructing the `GPTResearcher` instance.
- **`logging.info` line** before the `GPTResearcher` constructor — logs `[species] question_code: report_type=<type>` for every research call.

### Fixed

- **`eppo_gd_retriever.register()`** now patches both the retriever factory (`get_retriever`) **and** the validator (`get_all_retriever_names`). Previously, deep research mode validated retrievers against a filesystem directory scan and rejected `eppo_gd` (falling back silently to `tavily`), while standard mode worked fine. The validator patch appends `"eppo_gd"` to the allowed list so it is accepted in all modes — including `report_type="deep"`.

---

## [2026-06-01] - DAG enforcement layer for populate_finnprio_values.py

### Added

- **`dag_values.py`** — stateless DAG enforcement module. Exposes:
  `get_zero_option`, `topological_sort_answers`, `check_zero_forcing`,
  `check_sibling_clamp`, `build_scored_prior_context`, `append_dag_correction`,
  `PATHWAY_VALUES_DEPENDENCIES`.
- **Four enforcement rules** (Heikkila et al. 2016):
  - EST1 = "a" → IMP1/IMP2.1/IMP2.3/IMP3/IMP4.1–4.3 forced to zero per parameter (p. 1832)
  - EST2 = "a" → same targets (p. 1832)
  - ENT2A = "a" → ENT3 forced to zero within same pathway (Table 2, p. 1830)
  - ENT2B ≤ ENT2A — post-GPT sibling clamp by points value
- **Topological sort** applied before both the regular-questions and pathway loops
  so upstream scores are always written before downstream checks read them.
- **`scored_context` seeding**: `load_scored_context()` / `load_scored_context_pathway()`
  read already-scored DB values before each loop — partial re-runs stay consistent.
- **Parameter-wise enforcement**: each of min/likely/max is checked and forced
  independently; partial forcing still calls GPT for unforced parameters.
- **JSONL audit trail**: `dag_corrections_<db_stem>.jsonl` written alongside the
  database — one line per parameter per event, fields:
  `{assessment_id, question_code, parameter, rule_fired, original_option, forced_option, timestamp}`.
- **`python/tests/test_dag_values.py`**: 32 unit tests covering all public functions.

### Changed

- **`populate_finnprio_values.py`**: regular-answers and pathway loops now use
  topological ordering, zero-forcing, sibling clamping, and JSONL logging.
  Pathway loop groups answers by `id_entry_pathway` with a fresh `scored_context_pathway`
  per group.
- **Model upgraded**: default scoring model changed from `gpt-4o-mini` to `gpt-4o`
  (overridable via `LLM_MODEL` env var).

---

## [2026-05-29b] - EPPO Global Database retriever + model upgrade

### Added

- **`eppo_gd_retriever.py`** — Custom GPT Researcher retriever (`EPPOGDSearch`) scraping `gd.eppo.int` for the species set in `os.environ["EPPO_CODE"]`. Returns up to 20 newest EPPO Reporting Service articles (full body text) plus all EPPO PRA Platform document links as synthetic title+URL bodies. In-process cache per EPPO code (~12 s first call, ~0 ms subsequent). All HTTP/parse errors soft-fail to `[]`. `register()` monkey-patches `gpt_researcher.actions.retriever.get_retriever` — no edits to the pip package needed.
- **`populate_finnprio_justifications.py`** integration: `eppo_gd` added to default `RETRIEVER` env; `EPPO_CODE` set per assessment and cleared on exit via `try/finally`.

### Changed

- **`STRATEGIC_LLM`** upgraded from `openai:o4-mini` to `openai:o3` in `populate_finnprio_justifications.py`.

---

## [2026-05-29] - Codebase housekeeping: legacy quarantine, DAG audit, SSB Ch 44 fix

### Changed

- **Legacy scripts quarantined to `python/legacy/`** — Nine scripts and the
  vendored `gptr-mcp-master/` folder moved out of the active `python/` namespace.
  No file contents changed; no active script imports from any of them. Canonical
  production scripts remain at the root: `populate_finnprio_justifications.py`
  and `populate_finnprio_values.py`.
  Moved: `populate_finnprio_justifications_anthropic.py`,
  `populate_finnprio_justifications_hybrid.py`,
  `populate_finnprio_justifications_local.py`,
  `populate_finnprio_justifications_local_fast.py`,
  `populate_finnprio_justifications_mcp.py`,
  `populate_finnprio_justifications_unified.py`,
  `Populate_finprio_justifications_deep.py`, `Simple_run.py`,
  `populate_finnprio_values_local.py`, `gptr-mcp-master/`.

- **`README.md` rewritten** — Replaced the 416-line outdated document with a
  100-line focused reference covering workflow, active scripts, quick-start
  commands, configuration variable names, and a troubleshooting table. All legacy
  script references and stale content removed.

### Fixed

- **`dag_config.py` — six Rmd-traced dependency corrections** (audit against
  `information/Instructions_FinnPRIO_assessments.Rmd`):
  - `QUESTION_DEPENDENCIES["EST1"]`: removed `"ENT1"` — EST1 assesses Norwegian
    climate suitability; global range is not a stated factor in the Rmd.
  - `QUESTION_DEPENDENCIES["ENT4"]`: removed `"ENT3"` — Rmd ENT4 guidance
    references season and destination/use of commodity, not trade volume.
  - `QUESTION_DEPENDENCIES["MAN1"]`: kept `["ENT1"]`; added comment that ENT1 is
    weak ordering context and that the stronger prior (ENT2A natural spread
    pathway) would require cross-table wiring not currently supported.
  - `QUESTION_DEPENDENCIES["MAN4"]`: kept `[]`; added uncertainty flag comment
    (possible EST1 connection not explicit in Rmd).
  - `QUESTION_DEPENDENCIES["MAN5"]`: added `"EST2"` — Rmd MAN5 guidance
    explicitly lists "Abundance and distribution of host plants" = EST2.
  - `PATHWAY_DEPENDENCIES["ENT4"]`: removed `"ENT3"` — same rationale as
    `QUESTION_DEPENDENCIES["ENT4"]`; volume of imports does not determine
    habitat transfer probability.

- **SSB Ch 44 exclusion list** (`ssb_query_lib.py`, `ssb_mcp_server.py`,
  `standalone_ssb_MPC.py`) — highly processed wood products with no viable plant
  pest pathway are now filtered out of all SSB trade queries. Excluded headings:
  4402 (charcoal), 4405 (wood wool/flour), 4406 (railway sleepers —
  typically heat-treated/preserved), 4408 (veneer sheets ≤6 mm), 4409
  (continuously shaped/parquet), 4410 (particleboard/OSB), 4411 (fibreboard/MDF),
  4412 (plywood/laminated), 4413 (densified wood), 4416–4421 (finished articles).
  Implementation: `_EXCLUDED_WOOD_HEADINGS` frozenset in `ssb_query_lib.py`
  hard-filters these from `toll_search_hs_codes()` results; docstrings in all
  three files updated to document the exclusion. Retained for plant health queries:
  4401 (fuel wood), 4403 (roundwood), 4404 (split poles), 4407 (sawnwood),
  4415 (packaging wood — ISPM 15 regulated).

---

## [2026-05-19] - SSB MCP Integration for ENT3 + DAG Validation Schema Fix

### Added
- **`ssb_query_lib.py`** — Pure SSB PxWebApi v2 helper library (no Anthropic/OpenAI SDK). Exposes four functions used by both the MCP server and the standalone CLI:
  - `ssb_search_tables` — search tables by keyword
  - `ssb_get_metadata` — variable codes and labels (first 30 per variable)
  - `ssb_search_codes` — filter codes within a variable by search term
  - `ssb_query_data` — POST query, returns flattened rows
  - **Safety limits**: 8 MB response cap (Content-Length pre-check + chunked streaming cap), 120 s wall-clock deadline via `time.monotonic()` (guards slow-trickle responses that bypass the 60 s per-read socket timeout), early exit at 500 non-zero rows to keep LLM context manageable
- **`ssb_mcp_server.py`** — FastMCP 3.x server wrapping the four SSB functions as `@mcp.tool` endpoints with domain-aware docstrings (HS chapter mappings, genus-level codes for chapter 44). Launched as a stdio subprocess by GPT Researcher for ENT3 only; no service to manage.
- **ENT3 SSB MCP integration** (`populate_finnprio_justifications.py`):
  - `build_ent3_mcp_configs()` — returns the `mcp_configs` list for the SSB subprocess. Uses `sys.executable` (inherits venv) — no `env:{}` which would strip the subprocess environment.
  - `build_ent3_ssb_context()` — builds a context block injected into the ENT3 research query: pathway name, years (last 5), HS chapter list, host genera extracted from `assessments.hosts`, ENT1 and EST1 excerpts from prior DAG answers.
  - `RETRIEVER` temporarily set to `"tavily,mcp"` and `MCP_AUTO_TOOL_SELECTION=true` while processing ENT3; both restored in `finally`.
  - `mcp_strategy="fast"` — GPT Researcher runs MCP once for the main query (suits single-shot trade-volume lookup).

### Changed
- **`standalone_ssb_MPC.py`** — Removed the inline definitions of the four SSB API functions (~120 lines) and replaced with a single import from `ssb_query_lib`. CLI behaviour (`run()`, `main()`, `TOOLS`, `TOOL_DISPATCH`, `SYSTEM_PROMPT`) is unchanged.

### Fixed
- **`dag_validation_stub.py`** — Replaced placeholder table names (`answerValues`, `pathwayValues`) and columns (`val_min`, `val_likely`, `val_max`) with the actual FinnPRIO schema:
  - Regular answers: `answers a JOIN questions q ON a.idQuestion = q.idQuestion` — columns `a.min`, `a.likely`, `a.max`
  - Pathway answers: `pathwayAnswers pa JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion` — same column names
  - Added None-value guard before `c_likely > s_likely` numeric comparison (boolean NO answers have NULL option codes in all three columns)

---

## [2026-05-15] - IMP2.x Parser Fix, inspect_prompts.py, Prompt Refactor

### Fixed
- **IMP2.x boolean options not parsed** (`parse_rmd_instructions.py`): `_extract_options()` was discarding
  all options for `IMP2.x` and `IMP4.x` questions with an early return. Added `_extract_boolean_options()`
  that reads `**Yes**` / `**No**` Rmd option blocks and returns `[{opt: 'yes', points: 1}, {opt: 'no', points: 0}]`.
  IMP 2.2 ("Is the pest a vector for other pests?") was the confirmed broken case.
- **Wrong answer code for boolean YES** (`instructions_loader.py`, `build_value_selection_prompt()`):
  The boolean branch was deriving the YES code from parsed `opt` values (`'yes'`) instead of the database
  code (`'a'`). Hardcoded `option_code = 'a'` for the boolean branch to match database expectations.
- **Boolean value selection failing for IMP2.2/IMP2.3/IMP4.2/IMP4.3** (`populate_finnprio_values.py`,
  `instructions_loader.py`): The database YES opt code varies per sub-question (`'a'` for IMP2.1/IMP4.1,
  `'b'` for IMP2.2/IMP4.2, `'c'` for IMP2.3/IMP4.3). `build_value_selection_prompt()` hardcoded
  `option_code = 'a'`, so the LLM returned `'a'` but `valid_opts` was `{'b'}` or `{'c'}` — a ValueError
  on every call for four of the six sub-questions. Fixed in two places:
  - `instructions_loader.py`: derive `option_code` from `options_override[0]['opt']` instead of `'a'`
  - `populate_finnprio_values.py`: added `_call_gpt_boolean()` that routes boolean questions through a
    dedicated yes/no prompt (temperature=0, returns `{"answer":"YES/NO"}`), maps YES → correct opt code,
    NO → all-null; `determine_values_with_gpt()` routes `question_type == 'boolean'` here, bypassing the
    min/likely/max path entirely

### Added
- **`inspect_prompts.py`**: New utility script that renders all LLM prompts without making any API calls.
  - Iterates all questions in canonical assessment order (ENT → EST → IMP → MAN)
  - Per question: metadata (group, type, options), Instructions Fragment (`build_justification_prompt`),
    and Full Research Query (`create_research_query`) in fenced code blocks
  - Graceful fallback when `gpt_researcher` is unavailable (shows fragment only, explains what is missing)
  - Flags host-related questions where `DOCUMENTED HOST PLANTS` block is absent without a DB connection
  - GPT Researcher config section at the top (env vars + constructor args + excluded domains)
  - Usage: `python inspect_prompts.py --output prompt_inspection.md [--species "Name"]`

### Changed
- **Prompt boilerplate deduplication** (`populate_finnprio_justifications.py`): Extracted three module-level
  constants — `_ANSWERING_RULES`, `_SOURCES`, `_FORMAT_RULES` — replacing ~80 lines duplicated across two
  `create_research_query()` branches.
- **`create_research_query()` restructured**: Single code path regardless of Rmd vs. fallback instructions.
  New section order: metadata header → question block → ANSWERING RULES → SOURCES → FORMAT → EXCLUDED DOMAINS.
  Species and pathway stated once in the header; removed from `build_justification_prompt()` prefix.
  Added `exclude_domains` parameter so callers pass the list directly instead of appending manually.
- **`_SOURCES` constant**: Added SSB (Statistics Norway) and Eurostat as explicit trade/production data sources.
- **`_FORMAT_RULES` constant**: Added "Answer the question directly in the first sentence" as first rule.
- **`build_justification_prompt()`** (`instructions_loader.py`): Removed species/pathway prefix — species
  now appears only once, in the outer query header assembled by `create_research_query()`.

### Fixed (continued)
- **MAN1 Rmd/DB sync resolved** (`Instructions_FinnPRIO_assessments.Rmd`, `populate_finnprio_values.py`):
  Rmd v2.0 had inadvertently given MAN1 five options (a–e) while the DB `questions.list` retained three
  (a–c), causing LLM-returned codes `'d'`/`'e'` to fail DB validation. The intermediate `effective_options`
  workaround (Rmd-preferred validation) introduced in the same session has been reverted: MAN1 in the
  Rmd has been corrected to three options (a/b/c) matching the DB, so `_call_gpt_for_values` now
  validates against DB options as originally intended. Stale JSON cache deleted and regenerated.
- **LLM hallucination retry** (`populate_finnprio_values.py`): Added one-shot retry to
  `_call_gpt_for_values` when an invalid option code is returned. On first failure the prompt is
  re-sent with an explicit `"Use ONLY: 'a', 'b', 'c'"` correction; on second failure the error is
  raised as before. Fixes MAN2 returning `'d'` (and any similar hallucinations).

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
