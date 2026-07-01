"""
FinnPRIO Database Justification Populator 16.04.26

Key features:
- Copies entire database (preserves complete structure)
- Appends AI justifications to answers table
- Handles pathway questions for EACH selected pathway
- Clean plain text output (no markdown)
- Question-specific instructions
- Domain exclusions
- DAG context injection: prior findings from dependency questions are
  injected into each query to reduce contradictions and repetition
"""

import os
import sys
import asyncio
import logging
import sqlite3
import shutil
from pathlib import Path
from gpt_researcher import GPTResearcher

# Register the EPPO Global Database retriever with gpt-researcher's factory.
# Must run before any GPTResearcher() instance is created.
from eppo_gd_retriever import register as _register_eppo_gd
_register_eppo_gd()
from datetime import datetime
from typing import Dict, List
import re
from collections import deque

# Ensure UTF-8 console output. Windows defaults stdout to a legacy code page
# (cp1252) whenever it is not a UTF-8 console (e.g. a redirected pipe), which
# raises UnicodeEncodeError on the first emoji print. Reconfigure defensively.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except (AttributeError, ValueError):
    pass

# DAG configuration: question dependencies and sibling constraints
from dag_config import QUESTION_DEPENDENCIES, PATHWAY_DEPENDENCIES, SIBLING_CONSTRAINTS

from module_loader import load_module, strip_light, normalize_code


class MissingDependencyError(Exception):
    """Raised when a filtered question has dependencies not yet in the DB."""
    pass


# =============================================================================
# CONFIGURATION — edit this before running
# =============================================================================

#  IMPORTANT: READ BEFORE RUNNING
#  THIS SCRIPT CREATES A NEW COPY OF YOUR DATABASE EACH TIME IT RUNS!
#  Using original database again will lose all AI work!

# Skip Existing Justifications
#  KEEP THIS AS True - It will only add justifications for NEW pathway questions
SKIP_EXISTING_JUSTIFICATION = False # True

# DATABASE PATH - UPDATE THIS IF YOU ADDED PATHWAYS
# CURRENT SETTING: Using AI-enhanced database (with existing justifications)
DEFAULT_DB_PATH = r"C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/test databases/ai_test_db/ai_test.db"

# Output directory (new copy will be created here)
DEFAULT_OUTPUT_DIR = r"C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/test databases/ai_test_db"

# Filter by EPPO codes (empty list = process all species)
# Example: EPPOCODES_TO_POPULATE = ["XYLEFA", "ANOLGL", "DROSSU"]
EPPOCODES_TO_POPULATE = [ "DENCPO" ]

# Filter by question codes (empty list = process all questions)
# Example: QUESTION_FILTER = ["EST2"]  # Only process EST2
# Multiple: QUESTION_FILTER = ["IMP4.1", "IMP4.2", "IMP4.3"]
# Pathway questions: "ENT2A", "ENT2B", "ENT3", "ENT4"
QUESTION_FILTER = [ ] # Full-pipeline run: process every question (IMP2.x + IMP4.x pipeline now validated)
# "IMP2.1", "IMP2.2", "IMP2.3"
# =============================================================================
# API Keys - Read from files
OPENAI_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\tore_vkm_openai.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\Tavily_key.txt"
NCBI_API_KEY_FILE   = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\NCBI_api_key.txt"

# Load API keys from files
def load_api_key(file_path: str) -> str:
    """Load API key from file, stripping whitespace"""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"⚠️  Warning: API key file not found: {file_path}")
        return ""

os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)
os.environ['NCBI_API_KEY']   = load_api_key(NCBI_API_KEY_FILE)
# =============================================================================

# GPT Researcher Configuration (research phase; all questions use report_type="custom_report")
# Optimized for scientific pest risk assessment:
# - Multi-retriever: Tavily (general) + arXiv + Semantic Scholar + PubMed Central
# - APA citation format, source curation, low-temp factual output
# - Ref: https://docs.gptr.dev/docs/gpt-researcher/gptr/config
os.environ.update({
    # LLM roles
    "FAST_LLM": "openai:gpt-5.4-mini",   # Quick tasks: summarization, sub-queries
    "SMART_LLM": "openai:gpt-5.4",      # Complex reasoning: report writing (long response support)
    "STRATEGIC_LLM": "openai:gpt-5.4",  # Planning: agent/query selection

    "TEMPERATURE": "0.1",
    "REASONING_EFFORT": "medium",

    # Embeddings (for context compression / similarity filtering)
    "EMBEDDING": "openai:text-embedding-3-small",
    "SIMILARITY_THRESHOLD": "0.42",

    # Retrievers — scientific sources first, Tavily as broad fallback
    # (names verified in gpt_researcher/actions/retriever.py)
    "RETRIEVER": "tavily, semantic_scholar,pubmed_central,eppo_gd",
    "SCRAPER": "bs",

    # Research depth
    "MAX_SEARCH_RESULTS_PER_QUERY": "100",
    "TOTAL_WORDS": "1000",

    # Output: APA for scientific traceability, curate sources for quality
    "REPORT_FORMAT": "apa",
    "CURATE_SOURCES": "true",
    "LANGUAGE": "english",
})

# Excluded domains (applied to all questions)
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# DATABASE FUNCTIONS - GENERAL
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy source database to a versioned, timestamped destination.

    Names follow `{base}_v{NNN}_{ISO8601}.db`, e.g.
        daniel_v002_2026-04-14T15-42-31.db

    Version is auto-incremented based on existing `{base}_v*_*.db` files in
    `output_dir`. Timestamp uses ISO 8601 with ':' replaced by '-' so the
    filename is valid on Windows. Both parts together guarantee every run
    produces a unique, chronologically sortable, reproducible identifier.
    """
    source_file = Path(source_path)
    original_name = source_file.stem

    # Strip any existing versioned suffix first, then the legacy
    # `_ai_enhanced_...` suffix, to recover a clean base name.
    base_name = re.sub(r'_v\d+_\d{4}-\d{2}-\d{2}T.*$', '', original_name)
    base_name = re.sub(r'_ai_enhanced_.*$', '', base_name)

    output_dir_path = Path(output_dir)
    output_dir_path.mkdir(parents=True, exist_ok=True)

    # Next version: max existing + 1, or 1 if no prior versions exist.
    existing_versions = []
    for f in output_dir_path.glob(f"{base_name}_v*_*.db"):
        m = re.match(rf'{re.escape(base_name)}_v(\d+)_', f.stem)
        if m:
            existing_versions.append(int(m.group(1)))
    next_version = (max(existing_versions) + 1) if existing_versions else 1

    # ISO 8601 timestamp, filesystem-safe (colons → hyphens).
    timestamp = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")

    output_name = f"{base_name}_v{next_version:03d}_{timestamp}.db"
    output_path = output_dir_path / output_name

    # Safety guard: copying a file onto itself corrupts it. With seconds-level
    # timestamps this is virtually impossible, but keep the check.
    if source_file.resolve() == output_path.resolve():
        print(f"\n📋 Source and destination resolve to the same file; reusing it.")
        print(f"   Path: {output_path}")
        return str(output_path)

    print(f"\n📋 Copying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)

    if output_path.exists():
        print(f"✅ Database copied ({output_path.stat().st_size / 1024:.1f} KB)")
    else:
        raise FileNotFoundError(f"Failed to copy database to {output_path}")

    return str(output_path)

def get_all_assessment_ids(db_path: str, eppo_codes: List[str] = None) -> List[int]:
    """Get all assessment IDs, optionally filtered by EPPO codes."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    if eppo_codes:
        # Filter by EPPO codes (case-insensitive)
        placeholders = ','.join(['?' for _ in eppo_codes])
        cursor.execute(f"""
            SELECT a.idAssessment
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE UPPER(p.eppoCode) IN ({placeholders})
            ORDER BY a.idAssessment
        """, [code.upper() for code in eppo_codes])

        ids = [row[0] for row in cursor.fetchall()]

        # Warn about EPPO codes with no matching pest/assessment rows (silently skipped otherwise).
        cursor.execute(f"""
            SELECT DISTINCT UPPER(p.eppoCode)
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE UPPER(p.eppoCode) IN ({placeholders})
        """, [code.upper() for code in eppo_codes])
        matched = {row[0] for row in cursor.fetchall()}
        unmatched = [c for c in eppo_codes if c.upper() not in matched]
        if unmatched:
            logging.warning(
                "EPPO codes not found in pests/assessments (skipped): %s",
                ", ".join(unmatched),
            )
    else:
        cursor.execute("""
            SELECT idAssessment
            FROM assessments
            ORDER BY idAssessment
        """)
        ids = [row[0] for row in cursor.fetchall()]

    conn.close()
    return ids


def get_eppo_codes_for_assessments(db_path: str, assessment_ids: List[int]) -> List[str]:
    """Get EPPO codes for a list of assessment IDs."""
    if not assessment_ids:
        return []
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    placeholders = ','.join(['?' for _ in assessment_ids])
    cursor.execute(f"""
        SELECT DISTINCT p.eppoCode
        FROM assessments a
        JOIN pests p ON a.idPest = p.idPest
        WHERE a.idAssessment IN ({placeholders})
    """, assessment_ids)
    codes = [row[0] for row in cursor.fetchall() if row[0]]
    conn.close()
    return codes

def get_assessment_info(db_path: str, assessment_id: int) -> Dict:
    """Get assessment details including pest and regular questions."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Get assessment with hosts (hosts is in assessments table)
    cursor.execute("""
        SELECT a.idAssessment, a.idPest, p.scientificName, p.eppoCode, a.hosts
        FROM assessments a
        JOIN pests p ON a.idPest = p.idPest
        WHERE a.idAssessment = ?
    """, (assessment_id,))

    result = cursor.fetchone()

    if not result:
        conn.close()
        return None

    assessment_id, pest_id, pest_name, eppo_code, hosts = result

    # Get regular questions
    cursor.execute("""
        SELECT a.idAnswer, q.idQuestion, q."group", q.number, q.subgroup,
               q.question, q.info, a.justification
        FROM answers a
        JOIN questions q ON a.idQuestion = q.idQuestion
        WHERE a.idAssessment = ?
        ORDER BY q.idQuestion
    """, (assessment_id,))

    answers = []
    for row in cursor.fetchall():
        id_answer, id_question, grp, num, subgrp, text, info, justification = row
        # Canonical code = group + number (e.g. ENT1, IMP2.1, MAN5). This matches
        # the module filenames and the DAG keys. The `subgrp` column is a category
        # label (MAN → Preventability/Controllability), NOT part of the code —
        # appending it produced e.g. "MAN5.Controllability", which normalize_code
        # turned into "MAN5.CONTROLLABILITY" and broke both load_module (no
        # MAN5.CONTROLLABILITY.md) and DAG lookups (key is "MAN5").
        code = f"{grp}{num}"
        answers.append({
            'idAnswer': id_answer,
            'code': code,
            'text': text,
            'info': info or "",
            'existing_justification': justification or ""
        })

    conn.close()

    return {
        'idAssessment': assessment_id,
        'idPest': pest_id,
        'scientificName': pest_name,
        'eppoCode': eppo_code,
        'hosts': hosts or "",
        'answers': answers
    }

def update_answer_justification(db_path: str, id_answer: int, justification: str):
    """Update justification in answers table."""
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # Verify table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='answers'")
        if not cursor.fetchone():
            raise Exception(f"Table 'answers' not found in database: {db_path}")

        cursor.execute("UPDATE answers SET justification = ? WHERE idAnswer = ?",
                      (justification, id_answer))
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"  ⚠️  Database error in update_answer_justification:")
        print(f"     Database: {db_path}")
        print(f"     Answer ID: {id_answer}")
        print(f"     Error: {e}")
        raise

# =============================================================================
# DATABASE FUNCTIONS - PATHWAYS
# =============================================================================

def get_assessment_pathways(db_path: str, assessment_id: int) -> List[Dict]:
    """Get all selected pathways for an assessment."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT ep.idEntryPathway, ep.idPathway, p.name, p."group", ep.specification
        FROM entryPathways ep
        JOIN pathways p ON ep.idPathway = p.idPathway
        WHERE ep.idAssessment = ?
        ORDER BY p.idPathway
    """, (assessment_id,))

    pathways = []
    for row in cursor.fetchall():
        id_entry, id_pathway, name, group, spec = row
        pathways.append({
            'idEntryPathway': id_entry,
            'idPathway': id_pathway,
            'name': name,
            'group': group,
            'specification': spec or ""
        })

    conn.close()
    return pathways

def get_pathway_questions(db_path: str) -> List[Dict]:
    """Get all pathway questions (ENT2A, ENT2B, ENT3, ENT4)."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT idPathQuestion, "group", number, question, info
        FROM pathwayQuestions
        ORDER BY idPathQuestion
    """)

    questions = []
    for row in cursor.fetchall():
        id_q, grp, num, text, info = row
        code = f"{grp}{num}"
        questions.append({
            'idPathQuestion': id_q,
            'code': code,
            'text': text,
            'info': info or ""
        })

    conn.close()
    return questions

def get_existing_pathway_justification(db_path: str, id_entry_pathway: int,
                                       id_path_question: int) -> str:
    """Get existing pathway justification."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT justification FROM pathwayAnswers
        WHERE idEntryPathway = ? AND idPathQuestion = ?
    """, (id_entry_pathway, id_path_question))
    result = cursor.fetchone()
    conn.close()
    return result[0] if result and result[0] else ""

def update_pathway_justification(db_path: str, id_entry_pathway: int,
                                 id_path_question: int, justification: str):
    """Update or insert pathway justification."""
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # Verify table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='pathwayAnswers'")
        if not cursor.fetchone():
            raise Exception(f"Table 'pathwayAnswers' not found in database: {db_path}")

        # Check if exists
        cursor.execute("""
            SELECT idPathAnswer FROM pathwayAnswers
            WHERE idEntryPathway = ? AND idPathQuestion = ?
        """, (id_entry_pathway, id_path_question))

        result = cursor.fetchone()

        if result:
            cursor.execute("""
                UPDATE pathwayAnswers SET justification = ?
                WHERE idPathAnswer = ?
            """, (justification, result[0]))
        else:
            cursor.execute("""
                INSERT INTO pathwayAnswers (idEntryPathway, idPathQuestion, justification)
                VALUES (?, ?, ?)
            """, (id_entry_pathway, id_path_question, justification))

        conn.commit()
        conn.close()
    except Exception as e:
        print(f"  ⚠️  Database error in update_pathway_justification:")
        print(f"     Database: {db_path}")
        print(f"     EntryPathway ID: {id_entry_pathway}, PathQuestion ID: {id_path_question}")
        print(f"     Error: {e}")
        raise

# =============================================================================
# DAG CONTEXT FUNCTIONS
# =============================================================================

# normalize_code is imported from module_loader (single canonical definition):
# uppercase, no trailing dot — "EST2." → "EST2", "IMP2.1" → "IMP2.1", "ENT2A" → "ENT2A".
# All DAG dict keys and filter comparisons use this form.


def _first_n_sentences(text: str, n: int = 3) -> str:
    """Return the first n sentences of text."""
    sentences = re.split(r'(?<=[.!?])\s+', text.strip())
    return ' '.join(sentences[:n])


def get_regular_prior_answers(db_path: str, assessment_id: int,
                               dep_codes: List[str]) -> Dict[str, str]:
    """Fetch justifications for regular question dependencies (answers + questions tables).

    Returns {normalized_code: justification_excerpt} for each dep that has a
    non-empty justification in the DB.
    """
    if not dep_codes:
        return {}

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT q."group" || q.number ||
               CASE WHEN q.subgroup IS NOT NULL THEN '.' || q.subgroup ELSE '.' END AS code_raw,
               a.justification
        FROM answers a
        JOIN questions q ON a.idQuestion = q.idQuestion
        WHERE a.idAssessment = ?
          AND a.justification IS NOT NULL
          AND a.justification != ''
    """, (assessment_id,))
    rows = cursor.fetchall()
    conn.close()

    result = {}
    dep_set = set(dep_codes)
    for code_raw, justification in rows:
        code = normalize_code(code_raw)
        if code in dep_set:
            result[code] = justification
    return result


def get_pathway_prior_answers(db_path: str, id_entry_pathway: int,
                               dep_codes: List[str]) -> Dict[str, str]:
    """Fetch justifications for same-pathway question dependencies (pathwayAnswers table).

    Returns {normalized_code: justification} for each dep that has a non-empty
    justification for this specific pathway instance.
    """
    if not dep_codes:
        return {}

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT pq."group" || pq.number AS code_raw,
               pa.justification
        FROM pathwayAnswers pa
        JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
        WHERE pa.idEntryPathway = ?
          AND pa.justification IS NOT NULL
          AND pa.justification != ''
    """, (id_entry_pathway,))
    rows = cursor.fetchall()
    conn.close()

    result = {}
    dep_set = set(dep_codes)
    for code_raw, justification in rows:
        code = normalize_code(code_raw)
        if code in dep_set:
            result[code] = justification
    return result


def format_prior_context(prior_answers: Dict[str, str],
                          sibling_rule: str = None) -> str:
    """Format prior answers + optional sibling constraint as an injectable context block.

    Each prior answer is truncated to the first 3 sentences to keep prompts focused.
    Returns empty string if there is nothing to inject.
    """
    if not prior_answers and not sibling_rule:
        return ""

    lines = ["PRIOR FINDINGS (established by earlier questions in this assessment):"]
    for code, justification in prior_answers.items():
        excerpt = _first_n_sentences(justification, 3)
        lines.append(f"\n{code}: {excerpt}")
    lines.append("\nDo not re-derive facts already stated above — build on them.")

    if sibling_rule:
        lines.append(f"\nCONSTRAINT: {sibling_rule}")

    return '\n'.join(lines)


def topological_sort_questions(questions: List[Dict],
                                dependencies: Dict[str, List[str]]) -> List[Dict]:
    """Sort questions in topological order using Kahn's algorithm.

    Only dependencies between questions present in `questions` are considered —
    cross-set deps (e.g. ENT1 as a dep when only EST2 is being processed) are
    ignored; those should be caught by check_missing_dependencies() first.

    Questions whose codes are not in `dependencies` are treated as having no
    deps and are placed first.
    """
    code_to_q = {normalize_code(q['code']): q for q in questions}
    codes = sorted(code_to_q.keys())  # deterministic base order

    in_degree = {c: 0 for c in codes}
    adj: Dict[str, List[str]] = {c: [] for c in codes}

    for code in codes:
        for dep in dependencies.get(code, []):
            if dep in code_to_q:   # dep is present in this filtered set
                in_degree[code] += 1
                adj[dep].append(code)

    queue = deque(sorted(c for c in codes if in_degree[c] == 0))
    result = []

    while queue:
        node = queue.popleft()
        result.append(code_to_q[node])
        for dependent in sorted(adj[node]):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)

    # Append any remaining nodes (shouldn't happen with a valid DAG)
    processed = {normalize_code(q['code']) for q in result}
    result.extend(code_to_q[c] for c in codes if c not in processed)

    return result


def check_missing_dependencies(db_path: str, assessment_id: int,
                                question_filter: List[str]) -> None:
    """Raise MissingDependencyError if any filtered question has unmet dependencies.

    A dependency is satisfied when it is either:
    - Also in question_filter (will be run before it in this session), or
    - Already has a non-empty justification in the database.

    Must be called with the SOURCE database before copy_database() so that a
    versioned copy is not created for a run that is guaranteed to fail.
    """
    if not question_filter:
        return

    filter_norm = {normalize_code(c) for c in question_filter}

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Existing regular justifications
    cursor.execute("""
        SELECT q."group" || q.number ||
               CASE WHEN q.subgroup IS NOT NULL THEN '.' || q.subgroup ELSE '.' END AS code_raw
        FROM answers a
        JOIN questions q ON a.idQuestion = q.idQuestion
        WHERE a.idAssessment = ?
          AND a.justification IS NOT NULL
          AND a.justification != ''
    """, (assessment_id,))
    existing = {normalize_code(r[0]) for r in cursor.fetchall()}

    # Existing pathway justifications (any pathway for this assessment)
    cursor.execute("""
        SELECT pq."group" || pq.number AS code_raw
        FROM pathwayAnswers pa
        JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
        JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
        WHERE ep.idAssessment = ?
          AND pa.justification IS NOT NULL
          AND pa.justification != ''
    """, (assessment_id,))
    existing |= {normalize_code(r[0]) for r in cursor.fetchall()}
    conn.close()

    available = filter_norm | existing

    missing_per_question = {}
    for code in filter_norm:
        deps = (QUESTION_DEPENDENCIES.get(code, []) +
                PATHWAY_DEPENDENCIES.get(code, []))
        missing = [d for d in deps if d not in available]
        if missing:
            missing_per_question[code] = missing

    if missing_per_question:
        lines = [
            "MissingDependencyError: Cannot process with question_filter — "
            "required dependencies are not in the DB:"
        ]
        for q_code, missing_deps in sorted(missing_per_question.items()):
            lines.append(f"  {q_code} requires: {', '.join(missing_deps)}")
        lines.append(
            "\nRun without question_filter first, or add the missing codes to question_filter."
        )
        raise MissingDependencyError('\n'.join(lines))


def build_prior_context(db_path: str, assessment_id: int, question_code: str,
                         id_entry_pathway: int = None) -> str:
    """Assemble the prior-context string to inject into a research query.

    Fetches dependency justifications from the correct table(s) and applies
    any sibling constraint rule from SIBLING_CONSTRAINTS.
    """
    code = normalize_code(question_code)
    is_pathway_q = (code in PATHWAY_DEPENDENCIES and
                    code not in QUESTION_DEPENDENCIES)

    if is_pathway_q and id_entry_pathway is not None:
        all_deps = PATHWAY_DEPENDENCIES.get(code, [])
        regular_deps  = [d for d in all_deps if d in QUESTION_DEPENDENCIES]
        pathway_deps  = [d for d in all_deps if d in PATHWAY_DEPENDENCIES]
        prior = {}
        prior.update(get_regular_prior_answers(db_path, assessment_id, regular_deps))
        prior.update(get_pathway_prior_answers(db_path, id_entry_pathway, pathway_deps))
    else:
        deps = QUESTION_DEPENDENCIES.get(code, [])
        prior = get_regular_prior_answers(db_path, assessment_id, deps)

    sibling_rule = None
    if code in SIBLING_CONSTRAINTS:
        sc = SIBLING_CONSTRAINTS[code]
        sib = sc['sibling']
        if id_entry_pathway is not None and sib in PATHWAY_DEPENDENCIES:
            sib_ans = get_pathway_prior_answers(db_path, id_entry_pathway, [sib])
        else:
            sib_ans = get_regular_prior_answers(db_path, assessment_id, [sib])
        prior.update(sib_ans)
        sibling_rule = sc['rule']

    return format_prior_context(prior, sibling_rule)


# =============================================================================
# NIBIO MCP INTEGRATION (IMP1, EST2, IMP2.2)
# =============================================================================

NIBIO_QUESTIONS = {'IMP1', 'EST2', 'IMP2.2'}


def build_nibio_mcp_configs() -> list:
    """Return mcp_configs for the NIBIO Totalkalkylen server (stdio subprocess)."""
    server_path = Path(__file__).parent / "nibio_mcp_server.py"
    return [{
        "name": "nibio_totalkalkylen",
        "command": sys.executable,
        "args": [str(server_path)],
    }]


def build_nibio_context(db_path: str, assessment_id: int, question_code: str,
                         hosts: str = "") -> str:
    """Build NIBIO-specific prior context for IMP1, EST2, IMP2.2 queries.

    Fetches EST1 justification (host plant context) already written to the DB.
    """
    prior = get_regular_prior_answers(db_path, assessment_id, ["EST1"])

    lines = [
        "NORWEGIAN AGRICULTURAL STATISTICS CONTEXT (NIBIO Totalkalkylen):",
        f"Question: {question_code}",
        "",
        "Use the NIBIO Totalkalkylen MCP tools to find Norwegian production statistics",
        "for the host crop(s) of this pest. Workflow:",
        "  1. list_groups(search=<crop keyword>) — find the relevant product group",
        "  2. list_posts(group_id) — list line items (prefer 'Produksjon' or 'Salg' posts)",
        "  3. get_data(post_id, years_back=10) — retrieve price, quantity, and value series",
        "",
    ]

    if question_code == 'IMP1':
        lines += [
            "For IMP1: report verdi (total production value, unit: 1000 kr) for the relevant",
            "crop(s). Use the most recent 5-year average as the baseline value at risk.",
            "Key groups: 2606=Korn/cereals, 2607=Poteter, 2608=Hagebruksprodukter (fruit/veg),",
            "            2609=Andre planteprodukter.",
        ]
    elif question_code == 'EST2':
        lines += [
            "For EST2: report kvantum (production quantity, unit: Tonn) and, if available,",
            "area from group 2641 (Jordbruksareal fordelt på vekster, 1000 daa).",
            "Key groups: 2641=crop area by type, 2606=Korn, 2607=Poteter, 2608=Hagebruk.",
        ]
    elif question_code == 'IMP2.2':
        lines += [
            "For IMP2.2 (food security): report kvantum (production quantity, unit: Tonn)",
            "to assess Norwegian self-sufficiency for the affected crop.",
            "Compare domestic production volume against known consumption patterns to gauge",
            "how dependent Norway is on domestic supply for this commodity.",
        ]

    if hosts:
        lines += ["", f"Host species (for group/post identification): {hosts[:500]}"]

    if "EST1" in prior:
        excerpt = _first_n_sentences(prior["EST1"], 3)
        lines += ["", f"Host plant context (from EST1): {excerpt}"]

    return "\n".join(lines)


# =============================================================================
# SSB MCP INTEGRATION (ENT3 only)
# =============================================================================

# Pathways where trade volume data from SSB is meaningful.
# Hitchhiking, Natural spread, and Intentional introduction have no
# commodity trade stream to query.
SSB_PATHWAYS = {
    "seeds",
    "plants for planting",
    "wood",
    "food",
    "fodder",
    "living plant",
}


def pathway_uses_ssb(pathway_name: str) -> bool:
    """Return True if this pathway has a relevant trade stream in SSB."""
    name_lower = pathway_name.lower()
    return any(kw in name_lower for kw in SSB_PATHWAYS)


def build_ent3_mcp_configs() -> list:
    """Return mcp_configs for the SSB trade data server (stdio subprocess)."""
    server_path = Path(__file__).parent / "ssb_mcp_server.py"
    return [{
        "name": "ssb_trade",
        "command": sys.executable,
        "args": [str(server_path)],
    }]


def build_ent3_ssb_context(db_path: str, assessment_id: int,
                            pathway_name: str, hosts: str = "") -> str:
    """Build SSB-specific prior context for ENT3 trade data queries.

    Fetches ENT1 (pest distribution → source regions) and EST1 (host plants
    → HS codes) justifications already written to the DB by the DAG pipeline.
    Falls back gracefully if either has not been written yet.
    """
    prior = get_regular_prior_answers(db_path, assessment_id, ["ENT1", "EST1"])

    lines = [
        "TRADE DATA CONTEXT (for SSB Statistics Norway query):",
        f"Pathway: {pathway_name}",
        "Years: last 5",
        "",
        "DATA SOURCE REQUIREMENT: Use ONLY SSB Statistics Norway table 08801 for",
        "import volume data. Do NOT cite or use WITS, UN Comtrade, CEIC, Statbase,",
        "TradeMap, OEC, or any other trade database. SSB table 08801 is the authoritative",
        "Norwegian trade statistics source and must be the sole source for import figures.",
        "",
        "Workflow:",
        "  1. Call search_tariff_codes(<host crop keyword>) to find the exact 8-digit",
        "     Varekoder for the relevant commodity.",
        "  2. Call query_data('08801', ...) with those Varekoder to retrieve annual",
        "     import volumes (tonnes) and values (NOK) for the last 5 years.",
        "",
        "HS chapters: 06 (live plants/cuttings), 07 (vegetables), 08 (fruit/nuts),",
        "10 (cereals), 12 (oil seeds), 44 (wood: 4403=roundwood, 4407=sawnwood, 4415=packaging).",
        "Wood genera: 4403.91=oak, .92=beech, .95/.96=birch, .97=poplar, .99=other non-coniferous;",
        "4407 mirrors the same subcode structure for sawnwood.",
    ]

    if hosts:
        lines += ["", f"Host species (for HS code identification): {hosts[:500]}"]

    if "ENT1" in prior:
        excerpt = _first_n_sentences(prior["ENT1"], 3)
        lines += ["", f"Pest native distribution (from ENT1, for source-region filter): {excerpt}"]

    if "EST1" in prior:
        excerpt = _first_n_sentences(prior["EST1"], 3)
        lines += ["", f"Host plant context (from EST1, for HS code selection): {excerpt}"]

    lines += [
        "",
        "Report aggregate total imports first (all HS codes combined, by year),",
        "then per-HS-code breakdown for genera that have genus-specific codes.",
        "All figures must come from SSB table 08801 only.",
    ]

    return "\n".join(lines)


# =============================================================================
# SHARED QUERY BOILERPLATE
# =============================================================================

_ANSWERING_RULES = """\
ANSWERING RULES:
- Answer for THIS EXACT SPECIES only — do not extrapolate from related species, congeners, or sister taxa
- If species-specific data is unavailable, state "Insufficient species-specific information" and describe what is known
- Flag all assumptions explicitly ("Assuming...", "Based on the assumption that...", "It is assumed that...")
- Distinguish evidence-based statements from assumptions throughout
- If prior findings are provided above, build on them rather than re-deriving the same facts"""

_SOURCES = """\
SOURCES:
- Peer-reviewed literature and official risk assessments (EPPO, EFSA, CABI, USDA, VKM, SLU, Ruokavirasto, Fera, and others)
- Trade and production data: SSB (Statistics Norway), NIBIO Totalkalkylen, and Eurostat where relevant
- Acknowledge uncertainty when evidence is limited; keep the response focused and concise (300–400 words)"""

_FORMAT_RULES = """\
FORMAT:
- Answer the question directly in the first sentence
- Organize the report under the section headings listed in the module's "Headings" section, in that order
- End with the recommended option
- Write in clear paragraphs under each heading"""

# custom_report uses this query verbatim as the report-writing prompt, so GPT
# Researcher's built-in citation/reference instructions do NOT apply — they must
# be stated here explicitly or the report comes back with no references.
_REFERENCE_RULES = """\
REFERENCES:
- Cite sources inline where claims are made (author or organisation and year where available).
- End the report with a "References" section listing every source you actually used.
- Give each reference's full source URL exactly as retrieved — complete and raw. Do NOT shorten, trim, truncate, rewrite, or omit any URL, and do not wrap URLs in markdown link syntax.
- List one entry per source; do not duplicate sources."""

# =============================================================================
# GPT RESEARCHER FUNCTIONS
# =============================================================================

def create_research_query(pest_name: str, question_code: str,
                          pathway_name: str = None, hosts: str = None,
                          exclude_domains: List[str] = None,
                          prior_context: str = "") -> str:
    """Build the custom_report query.

    Layout: header -> prior DAG context -> verbatim question module -> answering
    rules -> sources -> format rules -> reference rules -> excluded domains. The
    module text (from finnprio_question_modules/) is used verbatim; custom_report
    uses this query as the report-writing instruction.
    """
    module_text = load_module(question_code)

    header_lines = [
        "PEST RISK ASSESSMENT QUERY",
        f"Species: {pest_name}",
        f"Pathway: {pathway_name or 'N/A'}",
        "PRA area: Norway (temperate to boreal climate, cold winters)",
    ]
    if hosts:
        header_lines.append(f"Documented hosts for this pest: {hosts}")
    header = "\n".join(header_lines)

    parts = [header]
    if prior_context:
        parts.append(prior_context)
    parts.append(module_text)
    parts.extend([_ANSWERING_RULES, _SOURCES, _FORMAT_RULES, _REFERENCE_RULES])

    if exclude_domains:
        parts.append(f"EXCLUDED DOMAINS: {', '.join(exclude_domains)}")

    return "\n\n".join(parts)

async def research_justification(pest_name: str, question_code: str,
                                 pathway_name: str = None,
                                 exclude_domains: List[str] = None,
                                 hosts: str = None,
                                 prior_context: str = "",
                                 mcp_configs: list = None) -> str:
    """Research a single justification using GPT Researcher (custom_report)."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 80}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"{'=' * 80}\n")

    if exclude_domains:
        print(f"⛔ Excluding: {', '.join(exclude_domains)}")
    if hosts:
        print(f"🌱 Hosts: {hosts[:100]}{'...' if len(hosts) > 100 else ''}")
    if prior_context:
        print(f"🔗 Injecting prior context ({len(prior_context)} chars)")
    if mcp_configs:
        print(f"🔌 Starting MCP server (stdio)...")

    query = create_research_query(pest_name, question_code, pathway_name, hosts,
                                  exclude_domains=exclude_domains,
                                  prior_context=prior_context)

    # For MCP-backed questions (NIBIO/SSB): switch to hybrid Tavily+MCP retriever,
    # restore afterward.
    original_retriever = os.environ.get("RETRIEVER", "")
    if mcp_configs:
        os.environ["RETRIEVER"] = "tavily,mcp"
        os.environ["MCP_AUTO_TOOL_SELECTION"] = "true"

    try:
        researcher_kwargs = dict(
            query=query,
            report_type="custom_report",
            # tone=Tone.Formal,   # inert for custom_report — disabled
            report_source="web",
        )
        if mcp_configs:
            researcher_kwargs["mcp_configs"] = mcp_configs
            researcher_kwargs["mcp_strategy"] = "fast"

        researcher = GPTResearcher(**researcher_kwargs)

        await researcher.conduct_research()
        report = await researcher.write_report()

        if mcp_configs:
            print(f"✅ MCP context injected")

        return strip_light(report)
    except Exception as e:
        if mcp_configs:
            logging.warning("MCP research failed for %s %s: %s",
                            pest_name, question_code, e)
        print(f"ERROR: {str(e)}")
        # Return None (not an "ERROR: ..." string) so the caller skips the DB
        # write and leaves the existing answer untouched — a transient
        # OpenAI/Tavily failure must not overwrite a justification with error text.
        return None
    finally:
        if mcp_configs:
            os.environ["RETRIEVER"] = original_retriever
            os.environ.pop("MCP_AUTO_TOOL_SELECTION", None)

# =============================================================================
# MAIN WORKFLOW
# =============================================================================

async def process_assessment(db_path: str, assessment_id: int = None,
                             exclude_domains: List[str] = None,
                             limit_questions: int = None,
                             process_pathways: bool = True,
                             skip_existing: bool = True,
                             question_filter: List[str] = None):
    """Process assessment: regular questions + pathway questions."""

    print("\n📚 Loading assessment data...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        os.environ.pop("EPPO_CODE", None)
        print("❌ No assessment found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']

    # Expose EPPO code to the EPPOGDSearch retriever for this assessment.
    os.environ["EPPO_CODE"] = eppo_code or ""
    assessment_id = assessment_info['idAssessment']
    hosts = assessment_info.get('hosts', '')

    if question_filter:
        filter_codes = {normalize_code(c) for c in question_filter}
        answers = [a for a in answers if normalize_code(a['code']) in filter_codes]
        print(f"🔍 Filtering to questions: {', '.join(sorted(filter_codes))}")
        if not answers:
            print(f"⚠️  No matching regular questions found for {filter_codes}")

    if limit_questions:
        answers = answers[:limit_questions]
        print(f"⚠️  Limited to {limit_questions} questions")

    print(f"\n📊 Assessment: {pest_name} ({eppo_code})")
    print(f"📊 Regular questions: {len(answers)}")
    if hosts:
        print(f"🌱 Hosts: {hosts[:100]}{'...' if len(hosts) > 100 else ''}")

    # Topological sort: process questions in dependency order so prior context
    # is always written to the DB before it is needed by dependent questions.
    answers = topological_sort_questions(answers, QUESTION_DEPENDENCIES)

    # Process regular questions
    print("\n" + "=" * 80)
    print("PROCESSING REGULAR QUESTIONS")
    print("=" * 80)

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        existing = answer['existing_justification']
        if existing:
            print(f"📄 Found existing ({len(existing)} chars)")
            if skip_existing:
                print(f"⏭️  Skipped (existing justification)")
                continue

        prior_context = build_prior_context(db_path, assessment_id, answer['code'])

        # IMP1, EST2, IMP2.2: inject NIBIO agricultural statistics context
        q_mcp_configs = None
        norm_code = normalize_code(answer['code'])
        if norm_code in NIBIO_QUESTIONS:
            nibio_ctx = build_nibio_context(
                db_path, assessment_id, norm_code, hosts=hosts)
            prior_context = (
                (prior_context + '\n\n' + nibio_ctx).strip()
                if prior_context else nibio_ctx
            )
            q_mcp_configs = build_nibio_mcp_configs()

        try:
            ai_text = await research_justification(
                pest_name=pest_name,
                question_code=answer['code'],
                exclude_domains=exclude_domains or [],
                hosts=hosts,
                prior_context=prior_context,
                mcp_configs=q_mcp_configs,
            )

            if ai_text:
                update_answer_justification(db_path, answer['idAnswer'], ai_text)
                print(f"✅ Updated ({len(ai_text)} chars)")
            else:
                print("⏭️  Research failed — DB left unchanged for this question")
        except Exception as e:
            print(f"❌ Error: {str(e)}")

    # Process pathway questions
    if process_pathways:
        try:
            pathways = get_assessment_pathways(db_path, assessment_id)
        except Exception as e:
            print(f"\n⚠️  Error getting pathways: {e}")
            pathways = []

        if pathways:
            print(f"\n{'=' * 80}")
            print(f"PROCESSING PATHWAY QUESTIONS ({len(pathways)} pathways)")
            print(f"{'=' * 80}")

            try:
                pathway_questions = get_pathway_questions(db_path)
            except Exception as e:
                print(f"\n⚠️  Error getting pathway questions: {e}")
                return

            # Filter pathway questions if question_filter is set
            if question_filter:
                filter_codes = {normalize_code(c) for c in question_filter}
                pathway_questions = [pq for pq in pathway_questions
                                    if normalize_code(pq['code']) in filter_codes]
                if not pathway_questions:
                    print(f"⚠️  No matching pathway questions found for {filter_codes}")

            # Sort pathway questions in dependency order (re-used per pathway)
            sorted_pqs = topological_sort_questions(pathway_questions, PATHWAY_DEPENDENCIES)

            total = len(pathways) * len(sorted_pqs)
            count = 0

            for pathway in pathways:
                pathway_name = pathway['name']
                id_entry_pathway = pathway['idEntryPathway']
                print(f"\n📍 Pathway: {pathway_name}")

                for pq in sorted_pqs:
                    count += 1
                    print(f"\n[{count}/{total}] {pq['code']} for {pathway_name}")

                    existing = get_existing_pathway_justification(
                        db_path, id_entry_pathway, pq['idPathQuestion'])

                    if existing:
                        print(f"📄 Found existing ({len(existing)} chars)")
                        if skip_existing:
                            print(f"⏭️  Skipped (existing justification)")
                            continue

                    prior_context = build_prior_context(
                        db_path, assessment_id, pq['code'],
                        id_entry_pathway=id_entry_pathway)

                    # ENT3: inject SSB trade context and enable MCP retriever
                    # Only for pathways with a real commodity trade stream.
                    pq_mcp_configs = None
                    if (normalize_code(pq['code']) == 'ENT3'
                            and pathway_uses_ssb(pathway_name)):
                        ssb_ctx = build_ent3_ssb_context(
                            db_path, assessment_id, pathway_name, hosts=hosts)
                        prior_context = (
                            (prior_context + '\n\n' + ssb_ctx).strip()
                            if prior_context else ssb_ctx
                        )
                        pq_mcp_configs = build_ent3_mcp_configs()

                    try:
                        ai_text = await research_justification(
                            pest_name=pest_name,
                            question_code=pq['code'],
                            pathway_name=pathway_name,
                            exclude_domains=exclude_domains or [],
                            hosts=hosts,
                            prior_context=prior_context,
                            mcp_configs=pq_mcp_configs,
                        )

                        if ai_text:
                            update_pathway_justification(
                                db_path, id_entry_pathway,
                                pq['idPathQuestion'], ai_text)
                            print(f"✅ Updated ({len(ai_text)} chars)")
                        else:
                            print("⏭️  Research failed — DB left unchanged for this pathway question")
                    except Exception as e:
                        print(f"❌ Error: {str(e)}")
        else:
            print("\nℹ️  No pathways selected for this assessment")

async def main(source_db: str = DEFAULT_DB_PATH,
               output_dir: str = DEFAULT_OUTPUT_DIR,
               assessment_id: int = None,
               limit_questions: int = None,
               exclude_domains: List[str] = None,
               process_pathways: bool = True,
               skip_existing: bool = None,
               eppo_codes: List[str] = None,
               question_filter: List[str] = None):
    """Main workflow."""

    # Use configuration value if not explicitly set via command line
    if skip_existing is None:
        skip_existing = SKIP_EXISTING_JUSTIFICATION

    print("\n" + "=" * 80)
    print("FinnPRIO JUSTIFICATION POPULATOR")
    print("=" * 80)

    print(f"\n📂 Source Database: {source_db}")
    print(f"📂 Skip existing justifications: {skip_existing}")

    if exclude_domains is None:
        exclude_domains = EXCLUDED_DOMAINS

    if exclude_domains:
        print(f"\n⛔ Excluded: {', '.join(exclude_domains)}")

    # Determine question filter to use (command-line overrides config)
    effective_question_filter = question_filter if question_filter else (QUESTION_FILTER if QUESTION_FILTER else None)

    # Determine EPPO codes to use (command-line overrides config)
    effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

    # --- Determine assessment IDs from SOURCE DB before copying ---
    # This allows dependency validation to fail before a versioned copy is created.
    if assessment_id:
        assessment_ids = [assessment_id]
        print(f"\nℹ️  Processing single assessment: {assessment_id}")
    elif effective_eppo_codes:
        assessment_ids = get_all_assessment_ids(source_db, effective_eppo_codes)
        print(f"\nℹ️  Filtering by EPPO codes: {effective_eppo_codes}")
        print(f"    Found {len(assessment_ids)} matching assessment(s)")
        if assessment_ids:
            found_codes = get_eppo_codes_for_assessments(source_db, assessment_ids)
            missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
            if missing:
                print(f"⚠️  Warning: No assessments found for EPPO codes: {missing}")
    else:
        assessment_ids = get_all_assessment_ids(source_db)
        print(f"\nℹ️  Processing all assessments: {len(assessment_ids)} total")

    # --- Validate dependencies BEFORE copying (fail fast, no wasted DB version) ---
    if effective_question_filter:
        print(f"🔍 Question filter: {', '.join(c.upper() for c in effective_question_filter)} only")
        print("🔎 Checking dependencies...")
        for aid in assessment_ids:
            check_missing_dependencies(source_db, aid, effective_question_filter)
        print("✅ Dependencies satisfied")

    # --- Copy database (only after validation passes) ---
    working_db = copy_database(source_db, output_dir)

    print(f"\n✅ Working with: {working_db}")
    print(f"✅ Complete structure preserved")

    # Confirm (skip if filtering to single question or limited questions)
    if not effective_question_filter and (limit_questions is None or limit_questions > 5):
        response = input("\nThis will make many API calls. Continue? (yes/no): ")
        if response.lower() not in ['yes', 'y']:
            print("Cancelled.")
            return

    # Process
    print("\n" + "=" * 80)
    print("STARTING RESEARCH")
    print("=" * 80)
    if skip_existing:
        print("ℹ️  Skip existing justifications: Enabled")
    else:
        print("ℹ️  Existing justifications preserved, AI text appended")
    if process_pathways:
        print("ℹ️  Will process pathway questions for each selected pathway")

    # Process each assessment
    try:
        for idx, aid in enumerate(assessment_ids, 1):
            if len(assessment_ids) > 1:
                print("\n" + "=" * 80)
                print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
                print("=" * 80)

            await process_assessment(
                db_path=working_db,
                assessment_id=aid,
                exclude_domains=exclude_domains,
                limit_questions=limit_questions,
                process_pathways=process_pathways,
                skip_existing=skip_existing,
                question_filter=effective_question_filter
            )
    finally:
        os.environ.pop("EPPO_CODE", None)

    print("\n" + "=" * 80)
    print("✅ COMPLETED")
    print("=" * 80)
    print(f"\n📁 Database: {working_db}")
    print("\n✅ Regular questions: AI text appended to answers table")
    if process_pathways:
        print("✅ Pathway questions: AI text appended to pathwayAnswers table")
    print("\n🚀 Ready to use in FinnPRIO app!")

# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="FinnPRIO Justification Populator v3")
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH)
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument('--assessment-id', type=int, default=None)
    parser.add_argument('--limit-questions', type=int, default=None)
    parser.add_argument('--no-pathways', action='store_true',
                       help='Skip pathway questions')
    parser.add_argument('--question', type=str, nargs='+', default=None,
                       help='Process only specific question codes (e.g., --question EST2 IMP4.1 IMP4.2)')
    parser.add_argument('--eppo-codes', type=str, nargs='+', default=None,
                       help='Filter by EPPO codes (e.g., --eppo-codes XYLEFA ANOLGL)')
    parser.add_argument('--overwrite', action='store_true',
                       help=f'Overwrite existing justifications (default behavior: SKIP_EXISTING_JUSTIFICATION={SKIP_EXISTING_JUSTIFICATION})')
    parser.add_argument('--exclude-domains', type=str, nargs='+', default=None)
    parser.add_argument('--no-default-exclusions', action='store_true')

    args = parser.parse_args()

    # Build exclusion list
    exclude_domains = None
    if not args.no_default_exclusions:
        exclude_domains = EXCLUDED_DOMAINS.copy()
        if args.exclude_domains:
            exclude_domains.extend(args.exclude_domains)
    elif args.exclude_domains:
        exclude_domains = args.exclude_domains

    # Determine skip_existing based on command line flag or use config default
    skip_existing = False if args.overwrite else None  # None means use config default

    asyncio.run(main(
        source_db=args.db,
        output_dir=args.output,
        assessment_id=args.assessment_id,
        limit_questions=args.limit_questions,
        exclude_domains=exclude_domains,
        process_pathways=not args.no_pathways,
        skip_existing=skip_existing,
        eppo_codes=args.eppo_codes,
        question_filter=args.question,
    ))
