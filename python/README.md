# FinnPRIO AI Enhancement Scripts

Python scripts for automatically generating justifications and populating min/likely/max values for FinnPRIO risk assessments using AI.

## 📁 Scripts

### Unified Script (Recommended)
| Script | Purpose | Cost |
|--------|---------|------|
| `populate_finnprio_justifications_unified.py` | **EPPO + GPT Researcher combined** | ~$0.10-0.50/question |

The unified script combines two complementary data sources:
- **EPPO MCP Server** - Authoritative structured data (distribution, hosts, regulatory status)
- **GPT Researcher MCP** - Scientific literature and web research

### Cloud/Paid Scripts
| Script | Purpose | Cost |
|--------|---------|------|
| `populate_finnprio_justifications.py` | Generate justifications using GPT Researcher | ~$0.10-0.50/question |
| `populate_finnprio_justifications_mcp.py` | MCP server version (caching) | ~$0.10-0.50/question |
| `populate_finnprio_justifications_anthropic.py` | Generate justifications using Claude | ~$0.10-0.50/question |
| `populate_finnprio_justifications_hybrid.py` | Hybrid: web research + local PDF documents from Species/{EPPO_CODE}/ | ~$0.10-0.50/question |
| `populate_finnprio_values.py` | Determine min/likely/max values | ~$0.01/question |

### MCP Servers
| Server | Purpose |
|--------|---------|
| `servers/eppo_mcp_server.py` | EPPO Global Database API with caching and rate limiting |

### Local/FREE Scripts (Ollama)
| Script | Purpose | Cost |
|--------|---------|------|
| `populate_finnprio_justifications_local.py` | Justifications with Ollama + DuckDuckGo | **$0.00** |
| `populate_finnprio_values_local.py` | Values with Ollama | **$0.00** |

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

### Recommended: Unified Script
```
SOURCE DATABASE → Unified Script → VALUES Script → COMPLETE DATABASE
                  (EPPO + GPTR)    (GPT-4o-mini)   (Ready for app)
```

1. **Generate Justifications** - Run `populate_finnprio_justifications_unified.py`
2. **Generate Values** - Run `populate_finnprio_values.py` on the enhanced database
3. **Use in App** - Load the complete database in FinnPRIO Assessor

### Alternative: GPT Researcher Only
```
SOURCE DATABASE → Justifications Script → VALUES Script → COMPLETE DATABASE
                  (GPT Researcher)       (GPT-4o-mini)   (Ready for app)
```

---

## 🌟 Unified Script (Recommended)

### `populate_finnprio_justifications_unified.py`

**"One script to bind them all"** - Combines EPPO and GPT Researcher for comprehensive justifications.

**Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│              Unified Orchestrator                       │
└───────────────────────┬─────────────────────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
┌───────────────────┐         ┌───────────────────────┐
│   EPPO MCP Server │         │   GPT Researcher MCP  │
│                   │         │                       │
│ • Distribution    │         │ • Scientific papers   │
│ • Hosts           │         │ • Recent outbreaks    │
│ • Categorization  │         │ • Management studies  │
│ • Regulatory      │         │ • Climate modeling    │
│                   │         │                       │
│ AUTHORITATIVE     │         │ CONTEXTUAL            │
└───────────────────┘         └───────────────────────┘
```

**Features:**
- Parallel MCP server connections
- EPPO data as reliable foundation (cached 7 days)
- GPT Researcher for broader scientific context
- Smart query building with EPPO context
- Graceful fallback (EPPO down → research only)
- Question-specific EPPO data mapping

**Question → EPPO Data Mapping:**
| Question | EPPO Data Used |
|----------|----------------|
| ENT1 | Distribution, Categorization |
| EST1-3 | Distribution, Hosts |
| EST4 | Hosts, Vectors |
| IMP1-4 | Hosts |
| MAN1-3 | Distribution, Categorization |
| MAN4-5 | Biological Control Agents |

**Usage:**
```bash
# Process specific EPPO codes
python populate_finnprio_justifications_unified.py --eppo-codes XYLEFA ANOLGL

# Process single assessment
python populate_finnprio_justifications_unified.py --assessment-id 1

# Process all assessments
python populate_finnprio_justifications_unified.py
```

**Output:** `original_name_unified_DD_MM_YYYY.db`

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

## 🆓 FREE Local Scripts (Ollama)

### `populate_finnprio_justifications_local.py`
**100% FREE** - Uses Ollama (local LLM) + DuckDuckGo (free search).

**Features:**
- GPT Researcher with Ollama backend
- DuckDuckGo for web search (no API key!)
- Reduced research parameters for laptop performance
- Same output format as paid version

**Requirements:**
```bash
# Install Ollama from https://ollama.com
ollama pull llama3.2
ollama pull phi3:3.8b-mini-128k-instruct
ollama pull nomic-embed-text
ollama serve
```

**Configuration:**
```python
# Models (choose based on RAM)
FAST_LLM = "ollama:phi3:3.8b-mini-128k-instruct"  # 8GB RAM
SMART_LLM = "ollama:llama3.2"                      # 8GB RAM
# SMART_LLM = "ollama:qwen2:7b"                    # 16GB+ RAM
```

**Output:** `original_name_local_DD_MM_YYYY.db`

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

**Last Updated:** February 26, 2026
