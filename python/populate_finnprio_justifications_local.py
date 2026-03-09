"""
FinnPRIO Database Justification Populator - LOCAL VERSION

Uses Ollama (local LLM) + DuckDuckGo (free search) for ZERO COST operation.

Key features:
- GPT Researcher with Ollama backend (local, free)
- DuckDuckGo for web search (no API key needed)
- Copies entire database (preserves complete structure)
- Appends AI justifications to answers table
- Handles pathway questions for EACH selected pathway
- Clean plain text output (no markdown)

Requirements:
    pip install gpt-researcher duckduckgo-search
    ollama pull llama3.2
    ollama pull nomic-embed-text

Usage:
    python populate_finnprio_justifications_local.py
    python populate_finnprio_justifications_local.py --eppo-codes XYLEFA ANOLGL
"""

import os
import asyncio
import sqlite3
import shutil
from pathlib import Path
from datetime import datetime
from typing import Dict, List
import re

# =============================================================================
# CONFIGURATION
# =============================================================================

# Skip Existing Justifications
SKIP_EXISTING_JUSTIFICATION = True

# Database paths
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel.db"
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\test databases"

# Filter by EPPO codes (empty list = process all species)
EPPOCODES_TO_POPULATE = ["ANOLHO"]

# =============================================================================
# OLLAMA CONFIGURATION
# =============================================================================

# Ollama server URL
OLLAMA_BASE_URL = "http://localhost:11434"

# Models - Using your installed models
# Note: mistral:7b-instruct is used for all roles because instruction-tuned
# models are better at outputting the JSON format GPT Researcher requires internally.
# phi4-reasoning is great at reasoning but struggles with strict JSON formatting.
FAST_LLM = "ollama:mistral:7b-instruct"       # Fast tasks (summaries)
SMART_LLM = "ollama:mistral:7b-instruct"      # Smart tasks (final reports)
STRATEGIC_LLM = "ollama:mistral:7b-instruct"  # Strategic planning

# Embedding model
EMBEDDING_MODEL = "nomic-embed-text"

# =============================================================================
# SET ENVIRONMENT FOR GPT RESEARCHER
# =============================================================================

# Configure GPT Researcher to use Ollama + DuckDuckGo
os.environ.update({
    # Use DuckDuckGo for FREE web search (no API key needed!)
    "RETRIEVER": "duckduckgo",

    # Ollama configuration
    "OLLAMA_BASE_URL": OLLAMA_BASE_URL,
    "FAST_LLM": FAST_LLM,
    "SMART_LLM": SMART_LLM,
    "STRATEGIC_LLM": STRATEGIC_LLM,

    # Embedding configuration (new format - not deprecated)
    "EMBEDDING": f"ollama:{EMBEDDING_MODEL}",

    # Research settings (reduced for laptop performance)
    "TEMPERATURE": "0.1",
    "DEEP_RESEARCH_BREADTH": "2",  # Reduced from 3
    "DEEP_RESEARCH_DEPTH": "1",    # Reduced from 2
    "MAX_SEARCH_RESULTS_PER_QUERY": "5",  # Reduced from 10
    "TOTAL_WORDS": "300",  # Reduced from 400
    "MAX_ITERATIONS": "4",  # Reduced from 8

    # Dummy API key (required by GPT Researcher but not used with Ollama)
    "OPENAI_API_KEY": "not-needed-for-ollama",
})

# Import GPT Researcher AFTER setting environment
from gpt_researcher import GPTResearcher

# =============================================================================
# TEXT CLEANING FUNCTIONS
# =============================================================================

def clean_markdown_formatting(text: str) -> str:
    """Remove markdown formatting and clean up AI-generated text."""
    if not text:
        return ""

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

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = text.strip()

    return text

# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy entire source database to new location."""
    source_file = Path(source_path)
    original_name = source_file.stem
    timestamp = datetime.now().strftime("%d_%m_%Y")

    # Check if source already has pattern - extract base name
    if "_local_" in original_name:
        base_name = original_name.split("_local_")[0]
    elif "_ai_enhanced_" in original_name:
        base_name = original_name.split("_ai_enhanced_")[0]
    else:
        base_name = original_name

    output_name = f"{base_name}_local_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # Check if source and destination are the same (same-day re-run)
    if source_file.resolve() == output_path.resolve():
        print(f"\nUsing existing database (same-day re-run)...")
        print(f"   Path: {source_path}")
        print(f"   Working on existing file ({output_path.stat().st_size / 1024:.1f} KB)")
        return str(output_path)

    print(f"\nCopying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)

    if output_path.exists():
        print(f"   Database copied ({output_path.stat().st_size / 1024:.1f} KB)")
    else:
        raise FileNotFoundError(f"Failed to copy database to {output_path}")

    return str(output_path)


def get_all_assessment_ids(db_path: str, eppo_codes: List[str] = None) -> List[int]:
    """Get all assessment IDs, optionally filtered by EPPO codes."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    if eppo_codes:
        placeholders = ','.join(['?' for _ in eppo_codes])
        cursor.execute(f"""
            SELECT a.idAssessment
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE UPPER(p.eppoCode) IN ({placeholders})
            ORDER BY a.idAssessment
        """, [code.upper() for code in eppo_codes])
    else:
        cursor.execute("SELECT idAssessment FROM assessments ORDER BY idAssessment")

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

    cursor.execute("""
        SELECT a.idAssessment, a.idPest, p.scientificName, p.eppoCode
        FROM assessments a
        JOIN pests p ON a.idPest = p.idPest
        WHERE a.idAssessment = ?
    """, (assessment_id,))

    result = cursor.fetchone()

    if not result:
        conn.close()
        return None

    assessment_id, pest_id, pest_name, eppo_code = result

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
        'answers': answers
    }


def update_answer_justification(db_path: str, id_answer: int, justification: str):
    """Update justification in answers table."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("UPDATE answers SET justification = ? WHERE idAnswer = ?",
                  (justification, id_answer))
    conn.commit()
    conn.close()


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
    """Get all pathway questions."""
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
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

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

# =============================================================================
# RESEARCH FUNCTIONS
# =============================================================================

def create_research_query(pest_name: str, question_code: str, question_text: str,
                          question_info: str = "", pathway_name: str = None) -> str:
    """Create targeted research query."""

    pathway_text = f' via the pathway "{pathway_name}"' if pathway_name else ""

    query = f"""
Research the following question about {pest_name}{pathway_text}:

QUESTION ({question_code}): {question_text}

RESEARCH REQUIREMENTS:
- Focus on peer-reviewed literature, official risk assessments (EPPO, EFSA, CABI)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (200-300 words)

INSUFFICIENT INFORMATION:
- If information is insufficient, state: "Insufficient information available."
- Provide what relevant context IS available

{f'ADDITIONAL GUIDANCE: {question_info}' if question_info else ''}

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown
- Answer the question DIRECTLY
- Use paragraph format
- Citations in parentheses: (Author, Year)
"""

    return query


async def research_justification(pest_name: str, question_code: str, question_text: str,
                                 question_info: str = "", pathway_name: str = None) -> str:
    """Research a single justification using GPT Researcher with Ollama."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 70}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"Using: Ollama ({SMART_LLM.split(':')[1]}) + DuckDuckGo (FREE)")
    print(f"{'=' * 70}\n")

    query = create_research_query(pest_name, question_code, question_text,
                                  question_info, pathway_name)

    researcher = GPTResearcher(
        query=query,
        report_type="research_report",
        tone="formal",
        report_source="web",
    )

    try:
        print("  Conducting research...")
        await researcher.conduct_research()
        print("  Writing report...")
        report = await researcher.write_report()

        # Clean markdown
        report = clean_markdown_formatting(report)

        print(f"  Generated {len(report)} chars")
        return report

    except Exception as e:
        print(f"  ERROR: {str(e)}")
        return f"ERROR: {str(e)}"

# =============================================================================
# MAIN WORKFLOW
# =============================================================================

async def process_assessment(db_path: str, assessment_id: int,
                             limit_questions: int = None,
                             process_pathways: bool = True,
                             skip_existing: bool = True):
    """Process assessment: regular questions + pathway questions."""

    print("\nLoading assessment data...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        print("No assessment found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']
    assessment_id = assessment_info['idAssessment']

    if limit_questions:
        answers = answers[:limit_questions]
        print(f"Limited to {limit_questions} questions")

    print(f"\nAssessment: {pest_name} ({eppo_code})")
    print(f"Regular questions: {len(answers)}")

    # Process regular questions
    print("\n" + "=" * 70)
    print("PROCESSING REGULAR QUESTIONS")
    print("=" * 70)

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        existing = answer['existing_justification']
        if existing:
            print(f"  Found existing ({len(existing)} chars)")
            if skip_existing:
                print(f"  Skipped (existing justification)")
                continue

        try:
            ai_text = await research_justification(
                pest_name=pest_name,
                question_code=answer['code'],
                question_text=answer['text'],
                question_info=answer['info']
            )

            combined = f"{existing}\n\n{ai_text}" if existing else ai_text
            update_answer_justification(db_path, answer['idAnswer'], combined)

            print(f"  Updated ({len(combined)} chars)")
        except Exception as e:
            print(f"  Error: {str(e)}")

    # Process pathway questions
    if process_pathways:
        pathways = get_assessment_pathways(db_path, assessment_id)

        if pathways:
            print(f"\n{'=' * 70}")
            print(f"PROCESSING PATHWAY QUESTIONS ({len(pathways)} pathways)")
            print(f"{'=' * 70}")

            pathway_questions = get_pathway_questions(db_path)
            total = len(pathways) * len(pathway_questions)
            count = 0

            for pathway in pathways:
                pathway_name = pathway['name']
                print(f"\nPathway: {pathway_name}")

                for pq in pathway_questions:
                    count += 1
                    print(f"\n[{count}/{total}] {pq['code']} for {pathway_name}")

                    existing = get_existing_pathway_justification(
                        db_path, pathway['idEntryPathway'], pq['idPathQuestion'])

                    if existing:
                        print(f"  Found existing ({len(existing)} chars)")
                        if skip_existing:
                            print(f"  Skipped (existing justification)")
                            continue

                    try:
                        ai_text = await research_justification(
                            pest_name=pest_name,
                            question_code=pq['code'],
                            question_text=pq['text'],
                            question_info=pq['info'],
                            pathway_name=pathway_name
                        )

                        combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                        update_pathway_justification(
                            db_path, pathway['idEntryPathway'],
                            pq['idPathQuestion'], combined)

                        print(f"  Updated ({len(combined)} chars)")
                    except Exception as e:
                        print(f"  Error: {str(e)}")
        else:
            print("\nNo pathways selected for this assessment")


async def main(source_db: str = DEFAULT_DB_PATH,
               output_dir: str = DEFAULT_OUTPUT_DIR,
               assessment_id: int = None,
               limit_questions: int = None,
               process_pathways: bool = True,
               skip_existing: bool = None,
               eppo_codes: List[str] = None):
    """Main workflow."""

    if skip_existing is None:
        skip_existing = SKIP_EXISTING_JUSTIFICATION

    print("\n" + "=" * 70)
    print("FinnPRIO JUSTIFICATION POPULATOR - LOCAL VERSION")
    print("Ollama + DuckDuckGo (100% FREE)")
    print("=" * 70)

    print(f"\nSource Database: {source_db}")
    print(f"Skip existing: {skip_existing}")
    print(f"\nLLM Configuration:")
    print(f"  Fast LLM: {FAST_LLM}")
    print(f"  Smart LLM: {SMART_LLM}")
    print(f"  Embeddings: {EMBEDDING_MODEL}")
    print(f"  Search: DuckDuckGo (FREE)")
    print(f"\nCost: $0.00")

    # Test Ollama connection
    print("\nTesting Ollama connection...")
    try:
        import httpx
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=5.0)
            if response.status_code == 200:
                models = response.json().get('models', [])
                model_names = [m['name'] for m in models]
                print(f"  Ollama connected! Available models: {len(models)}")

                # Check if required models are available
                required_model = SMART_LLM.split(':')[1] if ':' in SMART_LLM else SMART_LLM.replace('ollama:', '')
                if not any(required_model in m for m in model_names):
                    print(f"\n  Warning: Model '{required_model}' not found!")
                    print(f"  Run: ollama pull {required_model}")
            else:
                raise Exception(f"Status {response.status_code}")
    except Exception as e:
        print(f"\n  Ollama connection failed: {e}")
        print("\n  Make sure Ollama is running:")
        print("    1. Start Ollama: ollama serve")
        print(f"    2. Pull models: ollama pull {SMART_LLM.split(':')[1] if ':' in SMART_LLM else 'llama3.2'}")
        print(f"                    ollama pull {EMBEDDING_MODEL}")
        return

    # Copy database
    working_db = copy_database(source_db, output_dir)

    print(f"\nWorking database: {working_db}")

    # Confirm
    if limit_questions is None or limit_questions > 3:
        response = input("\nThis will take time (local LLM is slower). Continue? (yes/no): ")
        if response.lower() not in ['yes', 'y']:
            print("Cancelled.")
            return

    print("\n" + "=" * 70)
    print("STARTING RESEARCH")
    print("=" * 70)

    # Determine EPPO codes
    effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

    # Get assessments
    if assessment_id:
        assessment_ids = [assessment_id]
        print(f"\nProcessing single assessment: {assessment_id}")
    elif effective_eppo_codes:
        assessment_ids = get_all_assessment_ids(working_db, effective_eppo_codes)
        print(f"\nFiltering by EPPO codes: {effective_eppo_codes}")
        print(f"Found {len(assessment_ids)} matching assessment(s)")
        if assessment_ids:
            found_codes = get_eppo_codes_for_assessments(working_db, assessment_ids)
            missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
            if missing:
                print(f"Warning: No assessments found for EPPO codes: {missing}")
    else:
        assessment_ids = get_all_assessment_ids(working_db)
        print(f"\nProcessing all assessments: {len(assessment_ids)} total")

    # Process each assessment
    for idx, aid in enumerate(assessment_ids, 1):
        if len(assessment_ids) > 1:
            print("\n" + "=" * 70)
            print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
            print("=" * 70)

        await process_assessment(
            db_path=working_db,
            assessment_id=aid,
            limit_questions=limit_questions,
            process_pathways=process_pathways,
            skip_existing=skip_existing
        )

    print("\n" + "=" * 70)
    print("COMPLETED")
    print("=" * 70)
    print(f"\nDatabase: {working_db}")
    print("Cost: $0.00 (100% local)")
    print("\nReady to use in FinnPRIO app!")

# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="FinnPRIO Justification Populator - LOCAL VERSION (Ollama + DuckDuckGo)"
    )
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH)
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument('--assessment-id', type=int, default=None)
    parser.add_argument('--limit-questions', type=int, default=None)
    parser.add_argument('--no-pathways', action='store_true', help='Skip pathway questions')
    parser.add_argument('--eppo-codes', type=str, nargs='+', default=None,
                       help='Filter by EPPO codes')
    parser.add_argument('--overwrite', action='store_true',
                       help='Overwrite existing justifications')

    args = parser.parse_args()

    skip_existing = False if args.overwrite else None

    asyncio.run(main(
        source_db=args.db,
        output_dir=args.output,
        assessment_id=args.assessment_id,
        limit_questions=args.limit_questions,
        process_pathways=not args.no_pathways,
        skip_existing=skip_existing,
        eppo_codes=args.eppo_codes
    ))
