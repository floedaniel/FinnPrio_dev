# FinnPRIO AI Enhancement Scripts

Python scripts for automatically generating justifications and populating min/likely/max values for FinnPRIO risk assessments using AI.

## 📁 Scripts

| Script | Purpose |
|--------|---------|
| `populate_finnprio_justifications.py` | Generate justifications using GPT Researcher |
| `populate_finnprio_justifications_mcp.py` | MCP server version (caching, persistent connection) |
| `populate_finnprio_justifications_anthropic.py` | Generate justifications using Claude (Anthropic) |
| `populate_finnprio_values.py` | Determine min/likely/max values from justifications |
| `view_justifications.py` | Utility to view generated justifications |

---

## 🔄 Workflow

```
SOURCE DATABASE → Justifications Script → VALUES Script → COMPLETE DATABASE
                  (GPT Researcher)       (GPT-4o-mini)   (Ready for app)
```

1. **Generate Justifications** - Run `populate_finnprio_justifications.py`
2. **Generate Values** - Run `populate_finnprio_values.py` on the enhanced database
3. **Use in App** - Load the complete database in FinnPRIO Assessor

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

### `populate_finnprio_justifications_mcp.py`
MCP server version with additional benefits.

**Benefits over standard version:**
- Caching of research results
- Persistent server connection
- Multiple tools (deep_research, quick_search)

**Requires:** `gptr-mcp-master/` server and `fastmcp` package

---

### `populate_finnprio_justifications_anthropic.py`
Best of both worlds: GPT Researcher + Claude (Anthropic).

**Features:**
- GPT Researcher for comprehensive web research (multiple iterations, source synthesis)
- Claude 3.5 Sonnet as the reasoning/writing LLM (superior scientific synthesis)
- Claude 3.5 Haiku for fast intermediate tasks
- Tavily API for web search
- Same proven workflow as the OpenAI version, but with Claude's reasoning

**Configuration:**
```python
# GPT Researcher uses these Claude models:
"SMART_LLM": "anthropic:claude-sonnet-4-20250514"   # Final reports
"FAST_LLM": "anthropic:claude-3-5-haiku-20241022"   # Summaries
"STRATEGIC_LLM": "anthropic:claude-sonnet-4-20250514"  # Planning
```

**API Keys:** Requires `anthropic_key.txt` and `Tavily_key.txt`

**Output:** `original_name_anthropic_DD_MM_YYYY.db`

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

### Utility Scripts

#### `close_all_connections.py`
Closes all database connections and clears locks.

**Use when:**
- Getting "database is locked" errors
- Need to reset database connections
- Cleaning up after interrupted scripts

---

#### `check_missing_values.py`
Checks which questions have justifications but missing values.

**Output:** Lists questions needing value population by type.

---

#### `check_pathway_values.py`
Detailed check of pathway answers status.

**Output:** Shows pathway answers with/without justifications and values.

---

#### `check_selected_pathways.py`
Shows which pathways are selected in each assessment.

**Output:** Lists assessments and their entry pathways.

---

#### `check_wood_pathway.py`
Specific check for wood and wood products pathway.

**Output:** Status of wood pathway answers across assessments.

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

#### `populate_finnprio_justifications_v3.py`

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
python populate_finnprio_justifications_v3.py

# Step 2: Generate values for all assessments
python populate_finnprio_values.py --db outputs/ai_test_ai_enhanced_03_02_2026.db
```

---

### Single Assessment

```bash
# Process only assessment ID 2
python populate_finnprio_justifications_v3.py --assessment-id 2
python populate_finnprio_values.py --assessment-id 2
```

---

### Command Line Options

#### `populate_finnprio_justifications_v3.py`
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
python populate_finnprio_justifications_v3.py --overwrite
python populate_finnprio_values.py --overwrite
```

---

## 🔧 Troubleshooting

### "Database is locked" Error
```bash
# Close all connections
python close_all_connections.py
```

### "No such table: answers" Error
- Check database has correct schema
- Verify database path is correct
- Close all connections and retry

### Pathway Answers Not Created
```bash
# Check if pathways are selected
python check_selected_pathways.py

# Verify pathway answers exist
python check_pathway_values.py
```

### No Values Being Populated
```bash
# Check what's missing
python check_missing_values.py

# Justifications must exist first!
# Run populate_finnprio_justifications_v3.py before populate_finnprio_values.py
```

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

**Last Updated:** February 3, 2026
