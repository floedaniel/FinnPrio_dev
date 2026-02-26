"""
FinnPRIO Database Justification Populator 

Key features:
- Copies entire database (preserves complete structure)
- Appends AI justifications to answers table
- Handles pathway questions for EACH selected pathway
- Clean plain text output (no markdown)
- Question-specific instructions
- Domain exclusions
"""

import os
import asyncio
import sqlite3
import shutil
from pathlib import Path
from gpt_researcher import GPTResearcher
from datetime import datetime
from typing import Dict, List, Tuple
import re

# Import instructions loader (auto-generates JSON from Rmd if needed)
from instructions_loader import build_justification_prompt

# =============================================================================
# CONFIGURATION
# =============================================================================

#  IMPORTANT: READ BEFORE RUNNING
#  THIS SCRIPT CREATES A NEW COPY OF YOUR DATABASE EACH TIME IT RUNS!
#  Using original database again will lose all AI work!

# Skip Existing Justifications
#  KEEP THIS AS True - It will only add justifications for NEW pathway questions
SKIP_EXISTING_JUSTIFICATION = False # True

# DATABASE PATH - UPDATE THIS IF YOU ADDED PATHWAYS
# CURRENT SETTING: Using AI-enhanced database (with existing justifications)
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel.db"

# Output directory (new copy will be created here)
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026"

# Filter by EPPO codes (empty list = process all species)
# Example: EPPOCODES_TO_POPULATE = ["XYLEFA", "ANOLGL", "DROSSU"]
EPPOCODES_TO_POPULATE = ["ANOLHO"]

# Filter by question code (None = process all questions)
# Example: QUESTION_FILTER = "EST2"  # Only process EST2
# Pathway questions: "ENT2", "ENT2B", "ENT3", "ENT4"
QUESTION_FILTER = "EST2"

# =============================================================================
# API Keys - Read from files
OPENAI_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\chatgpt_apikey.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\Tavily_key.txt"

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
# =============================================================================

# GPT Researcher Configuration
os.environ.update({
    "TEMPERATURE": "0.1",
    "LLM_MODEL": "gpt-4o-mini",
    "LLM_MAX_TOKENS": "4096",
    "DEEP_RESEARCH_BREADTH": "3",
    "DEEP_RESEARCH_DEPTH": "2",
    "MAX_SEARCH_RESULTS_PER_QUERY": "10",
    "TOTAL_WORDS": "400",
    "MAX_ITERATIONS": "8",
})

# Excluded domains
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# TEXT CLEANING FUNCTIONS
# =============================================================================

def clean_markdown_formatting(text: str) -> str:
    """Remove markdown formatting and clean up AI-generated text."""

    # Remove markdown headings
    text = re.sub(r'^#+\s+.*$', '', text, flags=re.MULTILINE)

    # Remove bold/italic
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    text = re.sub(r'\*([^*]+)\*', r'\1', text)
    text = re.sub(r'__([^_]+)__', r'\1', text)
    text = re.sub(r'_([^_]+)_', r'\1', text)

    # Remove markdown links
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)

    # Remove markdown tables
    text = re.sub(r'^\s*\|[^\n]+\|\s*$', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\|[\s\-:|]+\|\s*$', '', text, flags=re.MULTILINE)

    # Remove bullet points
    text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\d+\.\s+', '', text, flags=re.MULTILINE)

    # Remove code blocks
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`([^`]+)`', r'\1', text)

    # Remove horizontal rules
    text = re.sub(r'^[-*_]{3,}$', '', text, flags=re.MULTILINE)

    # Remove separator phrases
    separators = [
        r'---\s*\*\*AI-Generated.*?\*\*\s*---',
        r'\*\*AI-Generated.*?\*\*',
        r'---\s*AI-Generated.*?---',
        r'AI-Generated Supplementary Information.*?\n',
        r'\(GPT Researcher\)',
    ]
    for pattern in separators:
        text = re.sub(pattern, '', text, flags=re.MULTILINE | re.DOTALL)

    # Remove common AI introduction phrases
    intro_patterns = [
        r'^.*?[Ii]ntroduction.*?$',
        r'^.*?[Ss]ummary.*?$',
        r'^.*?[Oo]verview.*?$',
        r'^This report.*?$',
    ]
    for pattern in intro_patterns:
        text = re.sub(pattern, '', text, flags=re.MULTILINE)

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = re.sub(r'\n ', '\n', text)
    text = re.sub(r' \n', '\n', text)
    text = text.strip()

    return text

# =============================================================================
# DATABASE FUNCTIONS - GENERAL
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy entire source database to new location."""
    # Get original database name without extension
    source_file = Path(source_path)
    original_name = source_file.stem  # filename without .db

    # Create timestamp in DD_MM_YYYY format
    timestamp = datetime.now().strftime("%d_%m_%Y")

    # Check if source already has _ai_enhanced_ pattern - extract base name
    if "_ai_enhanced_" in original_name:
        base_name = original_name.split("_ai_enhanced_")[0]
    else:
        base_name = original_name

    # New name: base_name_ai_enhanced_DD_MM_YYYY.db
    output_name = f"{base_name}_ai_enhanced_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # Check if source and destination are the same file (re-run on same day)
    if source_file.resolve() == output_path.resolve():
        print(f"\n📋 Using existing database (same-day re-run)...")
        print(f"   Path: {source_path}")
        print(f"✅ Working on existing file ({output_path.stat().st_size / 1024:.1f} KB)")
        return str(output_path)

    print(f"\n📋 Copying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)

    if output_path.exists():
        print(f"✅ Database copied successfully ({output_path.stat().st_size / 1024:.1f} KB)")
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
        code = f"{grp}{num}.{subgrp}" if subgrp else f"{grp}{num}."
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
# QUESTION-SPECIFIC INSTRUCTIONS
# =============================================================================

def get_question_specific_instructions(question_code: str, pest_name: str,
                                       pathway_name: str = None, hosts: str = None) -> str:
    """Get research instructions from Rmd-derived JSON. Fails if unavailable."""
    return build_justification_prompt(question_code, pest_name, pathway_name, hosts)

# =============================================================================
# GPT RESEARCHER FUNCTIONS
# =============================================================================

def create_research_query(pest_name: str, question_code: str, question_text: str,
                          question_info: str = "", pathway_name: str = None,
                          hosts: str = None) -> str:
    """Create targeted research query.

    Note: question_info from database is IGNORED when Rmd instructions are available,
    as the Rmd provides more accurate and up-to-date guidance.
    """

    # Get specific instructions from Rmd (preferred) or hardcoded fallback
    specific = get_question_specific_instructions(question_code, pest_name, pathway_name, hosts)

    # Check if we got Rmd instructions (they include "QUESTION" header)
    using_rmd_instructions = specific and "QUESTION" in specific

    # Build query
    pathway_text = f' via the pathway "{pathway_name}"' if pathway_name else ""

    # If using Rmd instructions, the 'specific' prompt already contains everything needed
    if using_rmd_instructions:
        query = f"""
Research the following pest for a risk assessment:

PEST: {pest_name}{pathway_text}

{specific}

CRITICAL: Answer ONLY this specific question. Do NOT include information about other topics.

SCOPE LIMITATION:
- Answer based on documented information for THIS EXACT SPECIES only
- Do NOT extrapolate from related species, congeners, or sister taxa
- Do NOT assume biology, hosts, or behavior based on similar species
- If information is limited for this species, acknowledge it clearly
- "Unknown" or "insufficient data for this species" is a valid answer

RESEARCH REQUIREMENTS:
- Base on peer-reviewed literature, official risk assessments (VKM, Fera, EPPO, EFSA, CABI, USDA, and others)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (300-400 words)

INSUFFICIENT INFORMATION:
- If the provided context contains insufficient information to answer the question, explicitly state: "The provided context contains insufficient information to answer the question."
- After stating this, you may provide relevant context that IS available, but clearly note the information gaps

ASSUMPTIONS:
- If making any assumptions, clearly indicate them with phrases like:
  * "Assuming that..."
  * "Based on the assumption that..."
  * "It is assumed that..."
- Clearly distinguish between evidence-based statements and assumptions

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown (#, ##, **, *, -)
- DO NOT use tables - they are unreadable in plain text
- DO NOT include "Introduction" sections
- Answer the question DIRECTLY
- Use paragraph format with proper punctuation
- Citations in parentheses: (Author, Year)
- Write as continuous text, not lists
- If multiple items, write in sentence form

Provide a clear, evidence-based justification.
"""
    else:
        # Fallback: use old format with database question_info
        query = f"""
Research the following question about {pest_name}{pathway_text}:

QUESTION ({question_code}): {question_text}

{specific if specific else "Focus on answering this specific question."}

CRITICAL: Answer ONLY this specific question. Do NOT include information about other topics.

SCOPE LIMITATION:
- Answer based on documented information for THIS EXACT SPECIES only
- Do NOT extrapolate from related species, congeners, or sister taxa
- Do NOT assume biology, hosts, or behavior based on similar species
- If information is limited for this species, acknowledge it clearly
- "Unknown" or "insufficient data for this species" is a valid answer

RESEARCH REQUIREMENTS:
- Base on peer-reviewed literature, official risk assessments (VKM, Fera, EPPO, EFSA, CABI, USDA, and others)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (300-400 words)

INSUFFICIENT INFORMATION:
- If the provided context contains insufficient information to answer the question, explicitly state: "The provided context contains insufficient information to answer the question."
- After stating this, you may provide relevant context that IS available, but clearly note the information gaps

ASSUMPTIONS:
- If making any assumptions, clearly indicate them with phrases like:
  * "Assuming that..."
  * "Based on the assumption that..."
  * "It is assumed that..."
- Clearly distinguish between evidence-based statements and assumptions

{f'ADDITIONAL GUIDANCE: {question_info}' if question_info else ''}

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown (#, ##, **, *, -)
- DO NOT use tables - they are unreadable in plain text
- DO NOT include "Introduction" sections
- Answer the question DIRECTLY
- Use paragraph format with proper punctuation
- Write as continuous text, not lists
- If multiple items, write in sentence form

Provide a clear, evidence-based justification.
"""

    return query

async def research_justification(pest_name: str, question_code: str, question_text: str,
                                 question_info: str = "", pathway_name: str = None,
                                 exclude_domains: List[str] = None,
                                 hosts: str = None) -> str:
    """Research a single justification using GPT Researcher."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 80}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"{'=' * 80}\n")

    if exclude_domains:
        print(f"⛔ Excluding: {', '.join(exclude_domains)}")

    if hosts:
        print(f"🌱 Hosts: {hosts[:100]}{'...' if len(hosts) > 100 else ''}")

    query = create_research_query(pest_name, question_code, question_text,
                                  question_info, pathway_name, hosts)

    # Add domain exclusion
    if exclude_domains:
        domain_filter = f"\n\nIMPORTANT: Do NOT use information from: {', '.join(exclude_domains)}"
        query = query + domain_filter

    researcher = GPTResearcher(
        query=query,
        report_type="research_report", # research_report or detailed_report
        tone="formal",
        report_source="web",
    )

    try:
        await researcher.conduct_research()
        report = await researcher.write_report()

        # Remove excluded domain references
        if exclude_domains:
            for domain in exclude_domains:
                report = re.sub(rf'\[([^\]]+)\]\([^)]*{re.escape(domain)}[^)]*\)', '', report)
                report = re.sub(rf'https?://[^\s]*{re.escape(domain)}[^\s]*', '', report)

        # Clean markdown
        report = clean_markdown_formatting(report)

        return report
    except Exception as e:
        print(f"ERROR: {str(e)}")
        return f"ERROR: {str(e)}"

# =============================================================================
# MAIN WORKFLOW
# =============================================================================

async def process_assessment(db_path: str, assessment_id: int = None,
                             exclude_domains: List[str] = None,
                             limit_questions: int = None,
                             process_pathways: bool = True,
                             skip_existing: bool = True,
                             question_filter: str = None):
    """Process assessment: regular questions + pathway questions."""

    print("\n📚 Loading assessment data...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        print("❌ No assessment found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']
    assessment_id = assessment_info['idAssessment']
    hosts = assessment_info.get('hosts', '')

    if question_filter:
        # Filter to specific question code (e.g., EST2, ENT2A)
        # Strip trailing dots for comparison (codes stored as "EST2." but user enters "EST2")
        filter_code = question_filter.upper().rstrip('.')
        answers = [a for a in answers if a['code'].upper().rstrip('.') == filter_code]
        print(f"🔍 Filtering to question: {filter_code}")
        if not answers:
            print(f"⚠️  No matching regular question found for {filter_code}")

    if limit_questions:
        answers = answers[:limit_questions]
        print(f"⚠️  Limited to {limit_questions} questions")

    print(f"\n📊 Assessment: {pest_name} ({eppo_code})")
    print(f"📊 Regular questions: {len(answers)}")
    if hosts:
        print(f"🌱 Hosts: {hosts[:100]}{'...' if len(hosts) > 100 else ''}")

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

        try:
            ai_text = await research_justification(
                pest_name=pest_name,
                question_code=answer['code'],
                question_text=answer['text'],
                question_info=answer['info'],
                exclude_domains=exclude_domains or [],
                hosts=hosts
            )

            combined = f"{existing}\n\n{ai_text}" if existing else ai_text
            update_answer_justification(db_path, answer['idAnswer'], combined)

            print(f"✅ Updated ({len(combined)} chars)")
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
                filter_code = question_filter.upper().rstrip('.')
                pathway_questions = [pq for pq in pathway_questions
                                    if pq['code'].upper().rstrip('.') == filter_code]
                if not pathway_questions:
                    print(f"⚠️  No matching pathway question found for {filter_code}")

            total = len(pathways) * len(pathway_questions)
            count = 0

            for pathway in pathways:
                pathway_name = pathway['name']
                print(f"\n📍 Pathway: {pathway_name}")

                for pq in pathway_questions:
                    count += 1
                    print(f"\n[{count}/{total}] {pq['code']} for {pathway_name}")

                    existing = get_existing_pathway_justification(
                        db_path, pathway['idEntryPathway'], pq['idPathQuestion'])

                    if existing:
                        print(f"📄 Found existing ({len(existing)} chars)")
                        if skip_existing:
                            print(f"⏭️  Skipped (existing justification)")
                            continue

                    try:
                        ai_text = await research_justification(
                            pest_name=pest_name,
                            question_code=pq['code'],
                            question_text=pq['text'],
                            question_info=pq['info'],
                            pathway_name=pathway_name,
                            exclude_domains=exclude_domains or [],
                            hosts=hosts
                        )

                        combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                        update_pathway_justification(
                            db_path, pathway['idEntryPathway'],
                            pq['idPathQuestion'], combined)

                        print(f"✅ Updated ({len(combined)} chars)")
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
               question_filter: str = None):
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
    effective_question_filter = question_filter if question_filter else QUESTION_FILTER

    # Copy database
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

    # Determine EPPO codes to use (command-line overrides config)
    effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

    if effective_question_filter:
        print(f"🔍 Question filter: {effective_question_filter.upper()} only")

    # Get list of assessments to process
    if assessment_id:
        assessment_ids = [assessment_id]
        print(f"\nℹ️  Processing single assessment: {assessment_id}")
    elif effective_eppo_codes:
        assessment_ids = get_all_assessment_ids(working_db, effective_eppo_codes)
        print(f"\nℹ️  Filtering by EPPO codes: {effective_eppo_codes}")
        print(f"    Found {len(assessment_ids)} matching assessment(s)")
        # Verify all requested codes were found
        if assessment_ids:
            found_codes = get_eppo_codes_for_assessments(working_db, assessment_ids)
            missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
            if missing:
                print(f"⚠️  Warning: No assessments found for EPPO codes: {missing}")
    else:
        assessment_ids = get_all_assessment_ids(working_db)
        print(f"\nℹ️  Processing all assessments: {len(assessment_ids)} total")

    # Process each assessment
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
    parser.add_argument('--question', type=str, default=None,
                       help='Process only specific question code (e.g., --question EST2)')
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
        question_filter=args.question
    ))