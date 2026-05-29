# FinnPRIO AI Enhancement Scripts

> For Shiny application documentation see [../README.md](../README.md).
> For detailed changelog see [CHANGELOG.md](CHANGELOG.md).

Python scripts for automatically generating scientific justifications and min/likely/max values for FinnPRIO risk assessments.

---

## Workflow

```
SOURCE DATABASE  →  populate_finnprio_justifications.py  →  populate_finnprio_values.py  →  COMPLETE DATABASE
                     (GPT Researcher, ~$0.10-0.50/question)  (GPT-4.1, ~$0.01/question)
```

Always run the justifications script **before** the values script.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `populate_finnprio_justifications.py` | Generate justifications via GPT Researcher web research |
| `populate_finnprio_values.py` | Determine min/likely/max values from justifications |
| `standalone_ssb_MPC.py` | CLI tool for ad-hoc SSB Statistics Norway trade queries |
| `view_justifications.py` | Inspect generated justifications in the DB |
| `servers/eppo_mcp_server.py` | MCP server for EPPO Global Database API (used by legacy unified script) |

Legacy variants (no longer the canonical scripts) are in `python/legacy/`.

---

## Quick Start

```bash
cd python

# Step 1 — generate justifications (creates a timestamped copy of the DB)
python populate_finnprio_justifications.py --db path/to/source.db

# Step 2 — populate values from those justifications
python populate_finnprio_values.py --db outputs/source_ai_enhanced_DD_MM_YYYY.db
```

### Common options

```bash
# Process a single assessment
python populate_finnprio_justifications.py --db source.db --assessment-id 3

# Re-run and overwrite existing data
python populate_finnprio_justifications.py --db source.db --overwrite
python populate_finnprio_values.py --db enhanced.db --overwrite

# Limit to specific EPPO codes
python populate_finnprio_justifications.py --db source.db --eppo-codes XYLEFA ANOLGL

# Limit to specific questions (useful for testing)
python populate_finnprio_justifications.py --db source.db --question ENT1 EST2
```

---

## Configuration

Key settings are at the top of each script:

**`populate_finnprio_justifications.py`**
- `SKIP_EXISTING_JUSTIFICATION` — skip questions that already have a justification (default `True`)
- `DEFAULT_DB_PATH` / `DEFAULT_OUTPUT_DIR` — fallback paths when `--db` is not passed on CLI

**`populate_finnprio_values.py`**
- `SKIP_EXISTING_VALUES` — skip questions that already have min/likely/max (default `True`)

**API keys** are read from text files. Paths are set near the top of each script. Default locations:
```
C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\
├── tore_vkm_openai.txt    (OpenAI)
└── Tavily_key.txt         (Tavily)
```

---

## Instructions System

Question-specific guidance is loaded at runtime from:

```
../information/Instructions_FinnPRIO_assessments.Rmd
```

The Rmd is parsed to JSON (`instructions_cache/finnprio_instructions.json`) on first run and whenever the Rmd is newer. To force a regeneration:

```bash
python parse_rmd_instructions.py --force
```

---

## Output

- **Justifications script** creates a timestamped database copy: `source_ai_enhanced_DD_MM_YYYY.db`
- **Values script** updates the database in place (no new file)

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Database is locked" | Close the DB in DB Browser or any other SQLite client, then retry |
| "No such table: answers" | Wrong database path, or DB does not have the FinnPRIO schema |
| Pathway answers missing | Check that pathways are selected in `entryPathways` before running |
| No values populated | Justifications must exist first — run step 1 before step 2 |
