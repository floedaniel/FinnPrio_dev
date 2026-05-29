# FinnPRIO AI Enhancement Scripts

> For Shiny application documentation, see [../README.md](../README.md).

Python scripts for automatically generating justifications and populating min/likely/max values for FinnPRIO risk assessments using AI.

## 📁 Scripts

### Scripts
| Script | Purpose | Cost |
|--------|---------|------|
| `populate_finnprio_justifications.py` | Generate justifications using GPT Researcher | ~$0.10-0.50/question |
| `populate_finnprio_values.py` | Determine min/likely/max values | ~$0.01/question |
| `populate_finnprio_values_local.py` | Values with Ollama (free, local) | **$0.00** |

### MCP Servers
| Server | Purpose |
|--------|---------|
| `servers/eppo_mcp_server.py` | EPPO Global Database API with caching and rate limiting |

### Utilities
| Script | Purpose |
|--------|---------|
| `view_justifications.py` | View generated justifications |

### Instructions System (v2.0)
| File | Purpose |
|------|---------|
| `parse_rmd_instructions.py` | Parses Rmd instructions to JSON (v2.0 format) |
| `instructions_loader.py` | Loads JSON, builds prompts with options and guidance |
| `instructions_cache/` | Cache directory for generated JSON |

---

## 📋 Instructions System (v2.0)

Question-specific instructions are loaded from an external Rmd file with a clean, consistent format.

**Source File:** `../information/Instructions_FinnPRIO_assessments.Rmd`

**Rmd Format:**
```markdown
## ENT1. How wide is the current global geographical distribution?

### Options

**a. Small** (<2 million km²)
The distribution is smaller than approximately 2 million km².

**b. Medium** (2-20 million km²)
The distribution is approximately 2-20 million km².

### Guidance

- Estimate the total area of the pest's known global distribution
- Include both native and introduced ranges
```

**Key Thresholds (now explicit in prompts):**
| Question | Thresholds |
|----------|------------|
| ENT1 | Small (<2M km²), Medium (2-20M km²), Large (>20M km²) |
| ENT3 | Small (<1M kg/pc), Medium (1-10M kg/pc), Large (>10M kg/pc) |
| EST2 | Very small (<100 ha), Small (100-1000 ha), Medium (1000-10000 ha), Large (>10000 ha) |

**How it works:**
1. Edit the Rmd file to customize instructions
2. JSON is auto-generated when scripts run (if Rmd is newer)
3. Scripts use JSON for prompts with explicit thresholds and guidance

**Benefits:**
- Explicit quantitative thresholds (km², ha, kg) in AI prompts
- More accurate value selection
- No code changes needed to modify instructions
- Consistent across justification and values scripts

**Test the parser:**
```bash
python parse_rmd_instructions.py --force
python instructions_loader.py
```

---

## 🔄 Workflow

### Standard Workflow
```
SOURCE DATABASE → Justifications Script → VALUES Script → COMPLETE DATABASE
                  (GPT Researcher)       (GPT-4o-mini)   (Ready for app)
```

---

## 🔧 MCP Servers

### `servers/eppo_mcp_server.py`

MCP server providing access to EPPO Global Database API v2.

**Features:**
- SQLite caching (7-day TTL)
- Rate limiting (60 requests / 10 seconds)
- Async HTTP client
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

**Standalone Usage:**
```bash
# Run as MCP server
python servers/eppo_mcp_server.py
```

**Requirements:**
```bash
pip install mcp httpx aiosqlite
```

**API Key:** `C:\Users\dafl\Desktop\API keys\EPPO_beta.txt`

---

## 📜 Script Details

### `populate_finnprio_justifications.py`
Main script for generating AI-powered scientific justifications.

**Features:**
- Web research using GPT Researcher + Tavily API
- Creates database copy with timestamp
- Processes all assessments or single assessment
- Handles pathway questions for each selected pathway
- Clean plain text output (removes markdown formatting)
- Domain exclusion (skips unreliable sources)
- Skip existing justifications option

**Output:** `original_name_ai_enhanced_DD_MM_YYYY.db`

---

### `populate_finnprio_values_local.py`
**100% FREE** - Uses Ollama for value determination.

**Features:**
- Direct Ollama API (OpenAI-compatible)
- No web search needed
- Fast inference with small models
- Same features as paid version

**Recommended Models:**
| Model | RAM | Speed | Quality |
|-------|-----|-------|---------|
| `phi3:3.8b-mini-128k-instruct` | 4GB | Fast | Good |
| `llama3.2` | 4GB | Fast | Good |
| `qwen2:7b` | 6GB | Medium | Better |

**Usage:**
```bash
python populate_finnprio_values_local.py --eppo-codes XYLEFA
python populate_finnprio_values_local.py --model llama3.2
```

---

### `populate_finnprio_values.py`
Determines min/likely/max values based on existing justifications.

**Features:**
- Reads justifications and determines appropriate values
- Handles standard questions (3-18 options)
- Handles boolean questions (IMP2, IMP4)
- Skips boolean "NO" answers (doesn't store null values)
- Processes all assessments or single assessment
- Skip existing values option

**Output:** Updates database in place (no new file)

---

## ⚙️ Configuration

### API Keys

Both scripts read API keys from external text files:

```
C:\Users\dafl\Desktop\API keys\
├── chatgpt_apikey.txt    (OpenAI API key)
└── Tavily_key.txt        (Tavily API key)
```

**To change location:** Edit `OPENAI_API_KEY_FILE` and `TAVILY_API_KEY_FILE` in script headers.

---

### Configuration Options

#### `populate_finnprio_justifications.py`

```python
# SKIP EXISTING JUSTIFICATIONS
SKIP_EXISTING_JUSTIFICATION = True  # True = skip, False = append

# DATABASE PATHS
DEFAULT_DB_PATH = r"path/to/source/database.db"
DEFAULT_OUTPUT_DIR = r"path/to/outputs"

# EXCLUDED DOMAINS
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# GPT RESEARCHER SETTINGS
os.environ.update({
    "TEMPERATURE": "0.1",
    "LLM_MODEL": "gpt-4o-mini",
    "LLM_MAX_TOKENS": "4096",
    "TOTAL_WORDS": "400",
})
```

---

#### `populate_finnprio_values.py`

```python
# SKIP EXISTING VALUES
SKIP_EXISTING_VALUES = True  # True = skip, False = overwrite

# DATABASE PATH
INPUT_DATABASE = r"outputs/enhanced_backup.db"

# MODEL SETTINGS
os.environ.update({
    "LLM_MODEL": "gpt-4o-mini",
    "TEMPERATURE": "0.1",
    "LLM_MAX_TOKENS": "500",
})
```

---

## 🚀 Usage

### Basic Usage (All Assessments)

```bash
cd python

# Step 1: Generate justifications for all assessments
python populate_finnprio_justifications.py

# Step 2: Generate values for all assessments
python populate_finnprio_values.py --db outputs/ai_test_ai_enhanced_03_02_2026.db
```

---

### Single Assessment

```bash
# Process only assessment ID 2
python populate_finnprio_justifications.py --assessment-id 2
python populate_finnprio_values.py --assessment-id 2
```

---

### Command Line Options

#### `populate_finnprio_justifications.py`
```bash
--db PATH                    # Source database path
--output PATH                # Output directory
--assessment-id N            # Process single assessment
--limit-questions N          # Limit to N questions (testing)
--no-pathways                # Skip pathway questions
--overwrite                  # Overwrite existing justifications
--exclude-domains D1 D2      # Additional domains to exclude
--no-default-exclusions      # Don't use default exclusions
```

#### `populate_finnprio_values.py`
```bash
--db PATH                    # Database path
--assessment-id N            # Process single assessment
--overwrite                  # Overwrite existing values
```

---

### Configuration Overrides

**Skip existing data:**
```python
# In script header
SKIP_EXISTING_JUSTIFICATION = False  # Append to existing
SKIP_EXISTING_VALUES = False         # Overwrite existing
```

**Or via command line:**
```bash
python populate_finnprio_justifications.py --overwrite
python populate_finnprio_values.py --overwrite
```

---

## 🔧 Troubleshooting

### "Database is locked" Error
- Close the database in DB Browser or any other SQLite client that has it open
- Restart the script

### "No such table: answers" Error
- Check database has correct schema
- Verify database path is correct

### Pathway Answers Not Created
- Ensure pathways are selected in the `entryPathways` table in the source database
- Verify pathway answers exist by inspecting `pathwayAnswers` directly

### No Values Being Populated
- Justifications must exist first — run `populate_finnprio_justifications.py` before `populate_finnprio_values.py`

---

## 📊 Output Files

### Justifications Script
Creates new database with timestamp:
```
outputs/
└── ai_test_ai_enhanced_03_02_2026.db
```

### Values Script
Updates database in place (no new file created).

---

## 🔍 Checking Progress

### View justifications status:
```bash
# Check regular answers
python -c "
import sqlite3
conn = sqlite3.connect('outputs/ai_test_ai_enhanced_03_02_2026.db')
cursor = conn.cursor()
cursor.execute('SELECT COUNT(*) FROM answers WHERE justification IS NOT NULL')
print(f'Answers with justifications: {cursor.fetchone()[0]}')
"
```

### View values status:
```bash
# Check values populated
python -c "
import sqlite3
conn = sqlite3.connect('outputs/ai_test_ai_enhanced_03_02_2026.db')
cursor = conn.cursor()
cursor.execute('SELECT COUNT(*) FROM answers WHERE min IS NOT NULL')
print(f'Answers with values: {cursor.fetchone()[0]}')
"
```

---

## 📝 Important Notes

### Processing Order
1. **Always run justifications script FIRST**
2. **Then run values script**
3. Scripts must be run in this order!

### Boolean Questions (IMP2, IMP4)
- Boolean "NO" answers return `null` for all values
- These are automatically skipped (not stored)
- Boolean "YES" answers store the option code (a, b, or c)

### Pathway Questions
- Justifications script creates pathway answers if they don't exist
- Must have pathways selected in `entryPathways` table first
- Each pathway gets separate ENT2A, ENT2B, ENT3, ENT4 answers

### API Costs
- Justifications: ~$0.10-0.50 per question (web research)
- Values: ~$0.01 per question (GPT-4o-mini)
- Use `SKIP_EXISTING_*` to minimize costs

---

## 🆘 Support

For issues or questions, refer to:
- Main project documentation: `../CLAUDE.md`
- Changelog: `CHANGELOG.md`
- Script comments and docstrings

---

**Last Updated:** May 19, 2026
