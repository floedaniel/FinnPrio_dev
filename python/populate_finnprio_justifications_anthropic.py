"""
FinnPRIO Database Justification Populator - Anthropic Version

Uses GPT Researcher with Claude (Anthropic) as the LLM backend.
Combines comprehensive web research with Claude's superior reasoning.

Key features:
- GPT Researcher for thorough web research (multiple iterations, source synthesis)
- Claude 3.5 Sonnet as the reasoning/writing LLM
- Tavily API for web search
- Question-specific research instructions
- Clean plain text output
"""

import os
import asyncio
import sqlite3
import shutil
from pathlib import Path
from datetime import datetime
from typing import Optional
import re

# =============================================================================
# CONFIGURATION
# =============================================================================

# Skip Existing Justifications
SKIP_EXISTING_JUSTIFICATION = False

# Database paths
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\selam_database_2026\selam_2026_antrophic.db"

DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\selam_database_2026"

# API Key files
ANTHROPIC_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\anthropic_key.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\Tavily_key.txt"
OPENAI_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\chatgpt_apikey.txt"  # For embeddings

# Excluded domains
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# API KEY LOADING
# =============================================================================

def load_api_key(file_path: str) -> str:
    """Load API key from file."""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"Warning: API key file not found: {file_path}")
        return ""


# Load and set API keys
ANTHROPIC_API_KEY = load_api_key(ANTHROPIC_API_KEY_FILE)
TAVILY_API_KEY = load_api_key(TAVILY_API_KEY_FILE)
OPENAI_API_KEY = load_api_key(OPENAI_API_KEY_FILE)

# Configure GPT Researcher to use Claude
os.environ['ANTHROPIC_API_KEY'] = ANTHROPIC_API_KEY
os.environ['TAVILY_API_KEY'] = TAVILY_API_KEY
os.environ['OPENAI_API_KEY'] = OPENAI_API_KEY  # For embeddings

# GPT Researcher with Anthropic configuration (using new config format)
os.environ.update({
    # LLM settings - new format (no LLM_PROVIDER needed)
    "FAST_LLM": "anthropic:claude-3-5-haiku-20241022",  # Fast model for summaries
    "SMART_LLM": "anthropic:claude-sonnet-4-20250514",   # Smart model for final report
    "STRATEGIC_LLM": "anthropic:claude-sonnet-4-20250514",  # Strategic planning

    # Generation settings
    "TEMPERATURE": "0.1",
    "LLM_MAX_TOKENS": "4096",

    # Research settings
    "DEEP_RESEARCH_BREADTH": "3",
    "DEEP_RESEARCH_DEPTH": "2",
    "MAX_SEARCH_RESULTS_PER_QUERY": "10",
    "TOTAL_WORDS": "400",
    "MAX_ITERATIONS": "8",

    # Embedding - new format
    "EMBEDDING": "openai:text-embedding-3-small",
    "SIMILARITY_THRESHOLD": "0.42",
})

# Import GPT Researcher after setting environment
from gpt_researcher import GPTResearcher

# =============================================================================
# TEXT CLEANING
# =============================================================================

def clean_markdown_formatting(text: str) -> str:
    """Remove markdown formatting and clean up text."""

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
        r'AI-Generated Supplementary Information.*?\n',
        r'\(GPT Researcher\)',
    ]
    for pattern in separators:
        text = re.sub(pattern, '', text, flags=re.MULTILINE | re.DOTALL)

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = text.strip()

    return text


# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy source database to new timestamped location."""
    source_file = Path(source_path)
    timestamp = datetime.now().strftime("%d_%m_%Y")
    output_name = f"{source_file.stem}_anthropic_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    print(f"\nCopying database...")
    print(f"  From: {source_path}")
    print(f"  To:   {output_path}")

    shutil.copy2(source_path, output_path)
    print(f"  Done ({output_path.stat().st_size / 1024:.1f} KB)")

    return str(output_path)


def get_all_assessment_ids(db_path: str) -> list[int]:
    """Get all assessment IDs."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("SELECT idAssessment FROM assessments ORDER BY idAssessment")
    ids = [row[0] for row in cursor.fetchall()]
    conn.close()
    return ids


def get_assessment_info(db_path: str, assessment_id: int) -> Optional[dict]:
    """Get assessment details."""
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
        id_answer, id_q, grp, num, subgrp, text, info, justification = row
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
        'scientificName': pest_name,
        'eppoCode': eppo_code,
        'answers': answers
    }


def get_assessment_pathways(db_path: str, assessment_id: int) -> list[dict]:
    """Get selected pathways for assessment."""
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


def get_pathway_questions(db_path: str) -> list[dict]:
    """Get pathway questions."""
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
        questions.append({
            'idPathQuestion': id_q,
            'code': f"{grp}{num}",
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


def update_answer_justification(db_path: str, id_answer: int, justification: str):
    """Update answer justification."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("UPDATE answers SET justification = ? WHERE idAnswer = ?",
                   (justification, id_answer))
    conn.commit()
    conn.close()


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
# QUESTION-SPECIFIC INSTRUCTIONS
# =============================================================================

def get_question_specific_instructions(question_code: str, pest_name: str,
                                       pathway_name: str = None) -> str:
    """Get specific research instructions for each question."""

    if pathway_name:
        return f"""
Answer ONLY about {pest_name} transport/survival via the pathway "{pathway_name}".

INCLUDE:
- Association with this specific pathway
- Survival during transport via this pathway
- Life stages that can be transported
- Relevant evidence for THIS pathway only

DO NOT include:
- Overall distribution
- Other pathways
- Transfer to habitat (that's ENT4)
- General pest characteristics
"""

    instructions = {
        'ENT1.': f"""
Answer ONLY about geographical distribution of {pest_name}.

INCLUDE:
- Current native range (countries, regions)
- Introduced/invaded regions
- Climate zones where found

DO NOT include pathways, transport, or management.""",

        'EST1.': f"""
Answer ONLY about reproduction and overwintering of {pest_name} in Norway.

INCLUDE:
- Temperature requirements
- Cold tolerance and winter survival
- Norwegian climate suitability

DO NOT include hosts (EST2), spread rates (EST3), or characteristics (EST4).""",

        'EST2.': f"""
Answer ONLY about host plant distribution in Norway for {pest_name}.

INCLUDE:
- Which plants are hosts
- Distribution of hosts in Norway
- Abundance of hosts

DO NOT include climate (EST1), spread (EST3), or characteristics (EST4).""",

        'EST3.': f"""
Answer ONLY about spread rate of {pest_name}.

INCLUDE:
- Natural dispersal speed
- Documented spread rates
- Factors affecting spread

DO NOT include establishment (EST1), hosts (EST2), or characteristics (EST4).""",

        'EST4.': f"""
Answer ONLY about characteristics helping {pest_name} establish.

INCLUDE:
- Reproductive capacity
- Dispersal mechanisms
- Adaptability traits

DO NOT include climate (EST1), hosts (EST2), or spread rates (EST3).""",

        'IMP1.': f"""
Answer ONLY about direct economic losses from {pest_name}.

INCLUDE:
- Yield/production losses
- Crop damage severity
- Economic value affected

DO NOT include control costs, indirect impacts, or environmental impacts.""",

        'IMP3.': f"""
Answer ONLY about environmental impacts of {pest_name}.

INCLUDE:
- Effects on native species
- Ecosystem changes
- Biodiversity impacts

DO NOT include economic or social impacts.""",

        'MAN1.Preventability': f"""
Answer ONLY about natural spread potential of {pest_name} to Norway.

INCLUDE:
- Current proximity to Norway
- Natural dispersal range
- Likelihood of natural arrival

DO NOT include trade pathways or control methods.""",

        'MAN3.Preventability': f"""
Answer ONLY about detection difficulty of {pest_name} during inspections.

INCLUDE:
- Symptom visibility
- Diagnostic methods
- Inspection feasibility

DO NOT include spread, EU presence, or eradication.""",

        'MAN4.Controllability': f"""
Answer ONLY about eradication difficulty of {pest_name}.

INCLUDE:
- Eradication methods
- Success rates
- Technical feasibility

DO NOT include detection or surveillance.""",

        'MAN5.Controllability': f"""
Answer ONLY about surveillance difficulty for {pest_name}.

INCLUDE:
- Monitoring methods
- Survey feasibility
- Sampling requirements

DO NOT include eradication or import detection.""",
    }

    return instructions.get(question_code, "")


# =============================================================================
# RESEARCH FUNCTION
# =============================================================================

def create_research_query(pest_name: str, question_code: str, question_text: str,
                          question_info: str = "", pathway_name: str = None) -> str:
    """Create targeted research query for GPT Researcher."""

    specific = get_question_specific_instructions(question_code, pest_name, pathway_name)
    pathway_text = f' via the pathway "{pathway_name}"' if pathway_name else ""

    query = f"""
Research the following question about {pest_name}{pathway_text}:

QUESTION ({question_code}): {question_text}

{specific if specific else "Focus on answering this specific question."}

CRITICAL: Answer ONLY this specific question. Do NOT include information about other topics.

RESEARCH REQUIREMENTS:
- Base on peer-reviewed literature, official risk assessments (EPPO, EFSA, CABI)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (300-400 words)

INSUFFICIENT INFORMATION:
- If information is insufficient, explicitly state: "The provided context contains insufficient information to answer the question."
- After stating this, provide what relevant context IS available

ASSUMPTIONS:
- If making assumptions, clearly indicate with "Assuming that..." or similar
- Distinguish between evidence-based statements and assumptions

{f'ADDITIONAL GUIDANCE: {question_info}' if question_info else ''}

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown (#, ##, **, *, -)
- DO NOT use tables
- Answer the question DIRECTLY
- Use paragraph format
- Citations in parentheses: (Author, Year)
- Write as continuous text, not lists
"""

    return query


async def research_justification(pest_name: str, question_code: str, question_text: str,
                                 question_info: str = "", pathway_name: str = None,
                                 exclude_domains: list[str] = None) -> str:
    """Research a justification using GPT Researcher with Claude."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 70}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"  LLM: Claude (Anthropic)")
    print(f"{'=' * 70}")

    if exclude_domains:
        print(f"  Excluding: {', '.join(exclude_domains)}")

    query = create_research_query(pest_name, question_code, question_text,
                                  question_info, pathway_name)

    if exclude_domains:
        query += f"\n\nIMPORTANT: Do NOT use information from: {', '.join(exclude_domains)}"

    researcher = GPTResearcher(
        query=query,
        report_type="research_report",
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

        print(f"  Generated {len(report)} chars")
        return report

    except Exception as e:
        print(f"  ERROR: {e}")
        return f"ERROR: {str(e)}"


# =============================================================================
# MAIN WORKFLOW
# =============================================================================

async def process_assessment(
    db_path: str,
    assessment_id: int,
    skip_existing: bool = True,
    process_pathways: bool = True,
    limit_questions: Optional[int] = None,
    exclude_domains: list[str] = None
):
    """Process a single assessment."""

    print(f"\nLoading assessment {assessment_id}...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        print(f"Assessment {assessment_id} not found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']

    if limit_questions:
        answers = answers[:limit_questions]

    print(f"\nAssessment: {pest_name} ({eppo_code})")
    print(f"Questions: {len(answers)}")

    # Process regular questions
    print(f"\n{'=' * 70}")
    print("REGULAR QUESTIONS")
    print(f"{'=' * 70}")

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        existing = answer['existing_justification']
        if existing and skip_existing:
            print(f"  Skipped (existing: {len(existing)} chars)")
            continue

        try:
            ai_text = await research_justification(
                pest_name=pest_name,
                question_code=answer['code'],
                question_text=answer['text'],
                question_info=answer['info'],
                exclude_domains=exclude_domains or EXCLUDED_DOMAINS
            )

            combined = f"{existing}\n\n{ai_text}" if existing else ai_text
            update_answer_justification(db_path, answer['idAnswer'], combined)
            print(f"  Saved ({len(combined)} chars)")

        except Exception as e:
            print(f"  Error: {e}")

    # Process pathway questions
    if process_pathways:
        pathways = get_assessment_pathways(db_path, assessment_id)

        if pathways:
            print(f"\n{'=' * 70}")
            print(f"PATHWAY QUESTIONS ({len(pathways)} pathways)")
            print(f"{'=' * 70}")

            pathway_questions = get_pathway_questions(db_path)
            total = len(pathways) * len(pathway_questions)
            count = 0

            for pathway in pathways:
                pathway_name = pathway['name']
                print(f"\nPathway: {pathway_name}")

                for pq in pathway_questions:
                    count += 1
                    print(f"\n[{count}/{total}] {pq['code']} - {pathway_name}")

                    existing = get_existing_pathway_justification(
                        db_path, pathway['idEntryPathway'], pq['idPathQuestion'])

                    if existing and skip_existing:
                        print(f"  Skipped (existing: {len(existing)} chars)")
                        continue

                    try:
                        ai_text = await research_justification(
                            pest_name=pest_name,
                            question_code=pq['code'],
                            question_text=pq['text'],
                            question_info=pq['info'],
                            pathway_name=pathway_name,
                            exclude_domains=exclude_domains or EXCLUDED_DOMAINS
                        )

                        combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                        update_pathway_justification(
                            db_path, pathway['idEntryPathway'],
                            pq['idPathQuestion'], combined)
                        print(f"  Saved ({len(combined)} chars)")

                    except Exception as e:
                        print(f"  Error: {e}")
        else:
            print("\nNo pathways selected for this assessment")


async def main(
    source_db: str = DEFAULT_DB_PATH,
    output_dir: str = DEFAULT_OUTPUT_DIR,
    assessment_id: Optional[int] = None,
    skip_existing: Optional[bool] = None,
    process_pathways: bool = True,
    limit_questions: Optional[int] = None,
    exclude_domains: list[str] = None
):
    """Main entry point."""

    if skip_existing is None:
        skip_existing = SKIP_EXISTING_JUSTIFICATION

    print("\n" + "=" * 70)
    print("FinnPRIO JUSTIFICATION POPULATOR")
    print("GPT Researcher + Claude (Anthropic)")
    print("=" * 70)

    # Validate API keys
    if not ANTHROPIC_API_KEY:
        print("\nERROR: Anthropic API key not found!")
        print(f"Expected at: {ANTHROPIC_API_KEY_FILE}")
        return

    if not TAVILY_API_KEY:
        print("\nERROR: Tavily API key not found!")
        print(f"Expected at: {TAVILY_API_KEY_FILE}")
        return

    if not OPENAI_API_KEY:
        print("\nERROR: OpenAI API key not found (needed for embeddings)!")
        print(f"Expected at: {OPENAI_API_KEY_FILE}")
        return

    print(f"\nLLM: Claude (via GPT Researcher)")
    print(f"Smart model: claude-sonnet-4-20250514")
    print(f"Fast model: claude-3-5-haiku-20241022")
    print(f"Embeddings: OpenAI text-embedding-3-small")
    print(f"Skip existing: {skip_existing}")
    print(f"Source: {source_db}")

    # Copy database
    working_db = copy_database(source_db, output_dir)
    print(f"\nWorking database: {working_db}")

    # Confirm before proceeding
    if limit_questions is None or limit_questions > 5:
        response = input("\nThis will make API calls. Continue? (yes/no): ")
        if response.lower() not in ['yes', 'y']:
            print("Cancelled.")
            return

    # Get assessments to process
    if assessment_id:
        assessment_ids = [assessment_id]
    else:
        assessment_ids = get_all_assessment_ids(working_db)

    print(f"\nProcessing {len(assessment_ids)} assessment(s)")

    # Process each assessment
    for idx, aid in enumerate(assessment_ids, 1):
        if len(assessment_ids) > 1:
            print(f"\n{'=' * 70}")
            print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
            print(f"{'=' * 70}")

        await process_assessment(
            db_path=working_db,
            assessment_id=aid,
            skip_existing=skip_existing,
            process_pathways=process_pathways,
            limit_questions=limit_questions,
            exclude_domains=exclude_domains
        )

    print(f"\n{'=' * 70}")
    print("COMPLETED")
    print(f"{'=' * 70}")
    print(f"\nDatabase: {working_db}")
    print("Ready to use in FinnPRIO app!")


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="FinnPRIO Justification Populator (GPT Researcher + Claude)"
    )
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH,
                        help='Source database path')
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR,
                        help='Output directory')
    parser.add_argument('--assessment-id', type=int, default=None,
                        help='Process single assessment')
    parser.add_argument('--limit-questions', type=int, default=None,
                        help='Limit questions (for testing)')
    parser.add_argument('--no-pathways', action='store_true',
                        help='Skip pathway questions')
    parser.add_argument('--overwrite', action='store_true',
                        help='Overwrite existing justifications')
    parser.add_argument('--exclude-domains', type=str, nargs='+', default=None,
                        help='Additional domains to exclude')

    args = parser.parse_args()

    # Build exclusion list
    exclude_domains = EXCLUDED_DOMAINS.copy()
    if args.exclude_domains:
        exclude_domains.extend(args.exclude_domains)

    asyncio.run(main(
        source_db=args.db,
        output_dir=args.output,
        assessment_id=args.assessment_id,
        skip_existing=False if args.overwrite else None,
        process_pathways=not args.no_pathways,
        limit_questions=args.limit_questions,
        exclude_domains=exclude_domains
    ))
