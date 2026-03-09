"""
FinnPRIO Database Justification Populator - LOCAL FAST VERSION

Simple and FAST approach using Ollama + DuckDuckGo.
NO GPT Researcher - just direct search + summarize.

Expected speed: ~1-2 minutes per question (vs 15+ min with GPT Researcher)

How it works:
1. DuckDuckGo search for the question
2. Scrape top 3 results
3. ONE Ollama call to generate justification

Requirements:
    pip install duckduckgo-search httpx
    ollama pull mistral:7b-instruct

Usage:
    python populate_finnprio_justifications_local_fast.py
    python populate_finnprio_justifications_local_fast.py --eppo-codes XYLEFA
"""

import os
import asyncio
import sqlite3
import shutil
import httpx
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional
import re
from ddgs import DDGS
from bs4 import BeautifulSoup

# =============================================================================
# CONFIGURATION
# =============================================================================

# Skip Existing Justifications
SKIP_EXISTING_JUSTIFICATION = False

# Database paths
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel.db"
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\test databases"

# Filter by EPPO codes (empty list = process all species)
EPPOCODES_TO_POPULATE = ["ANOLHO"]

# =============================================================================
# OLLAMA CONFIGURATION
# =============================================================================

OLLAMA_BASE_URL = "http://localhost:11434"
OLLAMA_MODEL = "qwen2.5:7b"  # No thinking mode = FAST, 100% GPU
#  qwen3:14b
#  ollama pull qwen3:8b
# ollama serve

# Search settings
MAX_SEARCH_RESULTS = 25  # Number of web pages to fetch
MAX_CONTENT_LENGTH = 10000  # Max chars per page

# Quality settings (MAXED OUT for best output)
NUM_CTX = 32768  # Context window - qwen2.5 supports up to 128k
NUM_PREDICT = 1500  # Max output tokens (detailed justifications)
MAX_CONTEXT_TO_LLM = 18000  # Use most of the research context
OLLAMA_TIMEOUT = 600  # Seconds - thinking models (qwen3) need more time

# =============================================================================
# WEB SEARCH AND SCRAPING
# =============================================================================

def search_duckduckgo(query: str, max_results: int = 3) -> List[Dict]:
    """Search DuckDuckGo and return results."""
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=max_results))
            return results
    except Exception as e:
        print(f"    Search error: {e}")
        return []


async def fetch_page_content(url: str, timeout: float = 10.0) -> str:
    """Fetch and extract text content from a URL."""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                url,
                timeout=timeout,
                follow_redirects=True,
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
            )

            if response.status_code != 200:
                return ""

            # Parse HTML
            soup = BeautifulSoup(response.text, 'html.parser')

            # Remove script and style elements
            for element in soup(['script', 'style', 'nav', 'header', 'footer', 'aside']):
                element.decompose()

            # Get text
            text = soup.get_text(separator=' ', strip=True)

            # Clean up whitespace
            text = re.sub(r'\s+', ' ', text)

            # Truncate to max length
            if len(text) > MAX_CONTENT_LENGTH:
                text = text[:MAX_CONTENT_LENGTH] + "..."

            return text

    except Exception as e:
        print(f"    Fetch error for {url[:50]}...: {e}")
        return ""


async def gather_research_context(pest_name: str, question_text: str,
                                   question_code: str = "",
                                   pathway_name: str = None) -> str:
    """Search web and gather context for the question."""

    # Build SHORT search query (long queries return no results!)
    # Map question codes to search topics
    topic_map = {
        'ENT1': 'native invasive geographic distribution range',
        'EST1': 'climatic suitability cold tolerance overwintering',
        'EST2': 'host range host plants',
        'EST3': 'spread potential dispersal rate',
        'EST4': 'establishment potential characteristics',
        'IMP1': 'economic impact crop yield loss',
        'IMP3': 'environmental impact biodiversity ecosystem',
        'MAN1': 'natural spread import pathway',
        'MAN2': 'trade pathway commodities EU',
        'MAN3': 'detection identification inspection',
        'MAN4': 'eradication containment control measures',
        'MAN5': 'surveillance monitoring survey',
    }

    # Get topic from code (e.g., "EST1." -> "EST1")
    code_prefix = question_code.rstrip('.').split('.')[0] if question_code else ""
    topic = topic_map.get(code_prefix, "pest risk")

    if pathway_name:
        search_query = f"{pest_name} {pathway_name} transport"
    else:
        search_query = f"{pest_name} {topic}"

    print(f"    Searching: {search_query}")

    # Search DuckDuckGo
    results = search_duckduckgo(search_query, MAX_SEARCH_RESULTS)

    if not results:
        print("    No search results found")
        return "No web search results available."

    print(f"    Found {len(results)} results, fetching content...")

    # Fetch content from each result
    context_parts = []
    for i, result in enumerate(results, 1):
        url = result.get('href', result.get('link', ''))
        title = result.get('title', 'Unknown')
        snippet = result.get('body', result.get('snippet', ''))

        print(f"    [{i}/{len(results)}] {title[:50]}...")

        # Fetch full page content
        content = await fetch_page_content(url)

        if content:
            context_parts.append(f"SOURCE {i}: {title}\nURL: {url}\nContent: {content}\n")
        elif snippet:
            context_parts.append(f"SOURCE {i}: {title}\nURL: {url}\nSnippet: {snippet}\n")

    if not context_parts:
        return "Could not fetch content from search results."

    return "\n".join(context_parts)

# =============================================================================
# OLLAMA FUNCTIONS
# =============================================================================

async def generate_with_ollama(prompt: str, system_prompt: str = None) -> str:
    """Generate text using Ollama API."""

    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": messages,
                    "stream": False,
                    "options": {
                        "temperature": 0.1,
                        "num_predict": NUM_PREDICT,  # Max output tokens
                        "num_ctx": NUM_CTX,  # Context window size
                        "num_thread": 18,  # Use more CPU threads (you have 22)
                        "num_gpu": 99,  # Use all GPU layers possible
                    }
                },
                timeout=OLLAMA_TIMEOUT
            )

            if response.status_code == 200:
                result = response.json()
                return result.get("message", {}).get("content", "")
            else:
                # Try to get error message
                try:
                    error_detail = response.json().get("error", "Unknown error")
                except:
                    error_detail = response.text[:200] if response.text else "No details"
                print(f"    Ollama error {response.status_code}: {error_detail}")
                return f"ERROR: Ollama returned status {response.status_code}"

    except httpx.TimeoutException:
        print(f"    Ollama timeout (model may be loading)")
        return "ERROR: Ollama timeout - try again"
    except Exception as e:
        print(f"    Ollama error: {e}")
        return f"ERROR: {str(e)}"


async def generate_justification(pest_name: str, question_code: str,
                                  question_text: str, question_info: str = "",
                                  pathway_name: str = None) -> str:
    """Generate a justification for a question using web search + Ollama."""

    pathway_text = f" for pathway '{pathway_name}'" if pathway_name else ""

    print(f"\n{'=' * 60}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"Model: {OLLAMA_MODEL} (LOCAL - FREE)")
    print(f"{'=' * 60}")

    # Gather web context
    context = await gather_research_context(pest_name, question_text, question_code, pathway_name)

    # Truncate context if too long (to avoid Ollama issues)
    if len(context) > MAX_CONTEXT_TO_LLM:
        context = context[:MAX_CONTEXT_TO_LLM] + "\n[Content truncated]"

    # Build focused prompt - emphasize answering ONLY the specific question
    prompt = f"""You must answer ONLY this specific question about {pest_name}:

═══════════════════════════════════════════════════════════════
QUESTION: {question_text}
═══════════════════════════════════════════════════════════════
{f'(Context: Entry pathway "{pathway_name}")' if pathway_name else ''}

RESEARCH SOURCES (use only information relevant to the question above):
{context}

CRITICAL INSTRUCTIONS:
- Answer ONLY the specific question above - nothing else
- Ignore any source information that does not directly relate to this question
- Focus on Norway/Nordic conditions (cold climate, short growing season)
- Include specific data: numbers, temperatures, percentages, geographic ranges, years

CITATION REQUIREMENTS (MANDATORY):
- You MUST cite sources for every factual claim
- Use inline citations like: "According to EPPO..." or "CABI reports that..." or "(Source: USDA)"
- If a source has no name, cite the URL domain (e.g., "according to efsa.europa.eu")
- End with a "Sources:" line listing the main references used

OTHER REQUIREMENTS:
- Discuss uncertainty and confidence levels where appropriate
- Write 300-500 words in plain text only (no markdown, no bullets)
- If sources don't contain relevant information for this question, state that clearly

YOUR ANSWER TO THE QUESTION "{question_text[:80]}...":"""

    system_prompt = f"""You are answering ONE specific pest risk assessment question about {pest_name}.
Stay strictly on topic. Do not provide general information about the pest - only answer what is asked.
The question is: {question_text[:100]}"""

    print("    Generating justification...")

    response = await generate_with_ollama(prompt, system_prompt)

    # Clean up response - handle thinking models (qwen3, deepseek-r1)
    response = response.strip()

    # Remove qwen3 thinking blocks: "Thinking...\n...\n...done thinking.\n"
    if "...done thinking" in response.lower():
        parts = response.split("...done thinking")
        if len(parts) > 1:
            response = parts[-1].strip()
            # Also clean up any remaining "." from "...done thinking."
            if response.startswith("."):
                response = response[1:].strip()

    # Remove deepseek-r1 thinking blocks: <think>...</think>
    if "</think>" in response:
        response = response.split("</think>")[-1].strip()

    # Remove any "Thinking..." prefix that might remain
    if response.lower().startswith("thinking"):
        lines = response.split("\n")
        # Find where actual content starts (after thinking section)
        for i, line in enumerate(lines):
            if line.strip() and not line.lower().startswith("thinking") and len(line.strip()) > 20:
                response = "\n".join(lines[i:]).strip()
                break

    print(f"    Generated {len(response)} chars")

    return response

# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy entire source database to new location."""
    source_file = Path(source_path)
    original_name = source_file.stem
    timestamp = datetime.now().strftime("%d_%m_%Y")

    # Extract base name
    if "_local_fast_" in original_name:
        base_name = original_name.split("_local_fast_")[0]
    elif "_local_" in original_name:
        base_name = original_name.split("_local_")[0]
    elif "_ai_enhanced_" in original_name:
        base_name = original_name.split("_ai_enhanced_")[0]
    else:
        base_name = original_name

    output_name = f"{base_name}_local_fast_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # Check if same file (re-run)
    if source_file.resolve() == output_path.resolve():
        print(f"\nUsing existing database (same-day re-run)")
        print(f"   Path: {source_path}")
        return str(output_path)

    print(f"\nCopying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)
    print(f"   Done ({output_path.stat().st_size / 1024:.1f} KB)")

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


def get_assessment_info(db_path: str, assessment_id: int) -> Optional[Dict]:
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

    if limit_questions:
        answers = answers[:limit_questions]

    print(f"\nAssessment: {pest_name} ({eppo_code})")
    print(f"Questions: {len(answers)}")

    # Process regular questions
    print("\n" + "=" * 60)
    print("PROCESSING REGULAR QUESTIONS")
    print("=" * 60)

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        existing = answer['existing_justification']
        if existing and skip_existing:
            print(f"  Skipped (existing: {len(existing)} chars)")
            continue

        try:
            ai_text = await generate_justification(
                pest_name=pest_name,
                question_code=answer['code'],
                question_text=answer['text'],
                question_info=answer['info']
            )

            if ai_text and not ai_text.startswith("ERROR"):
                combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                update_answer_justification(db_path, answer['idAnswer'], combined)
                print(f"  Saved ({len(combined)} chars)")
            else:
                print(f"  Error: {ai_text}")

        except Exception as e:
            print(f"  Error: {str(e)}")

    # Process pathway questions
    if process_pathways:
        pathways = get_assessment_pathways(db_path, assessment_id)

        if pathways:
            print(f"\n{'=' * 60}")
            print(f"PROCESSING PATHWAY QUESTIONS ({len(pathways)} pathways)")
            print(f"{'=' * 60}")

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

                    if existing and skip_existing:
                        print(f"  Skipped (existing: {len(existing)} chars)")
                        continue

                    try:
                        ai_text = await generate_justification(
                            pest_name=pest_name,
                            question_code=pq['code'],
                            question_text=pq['text'],
                            question_info=pq['info'],
                            pathway_name=pathway_name
                        )

                        if ai_text and not ai_text.startswith("ERROR"):
                            combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                            update_pathway_justification(
                                db_path, pathway['idEntryPathway'],
                                pq['idPathQuestion'], combined)
                            print(f"  Saved ({len(combined)} chars)")
                        else:
                            print(f"  Error: {ai_text}")

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

    print("\n" + "=" * 60)
    print("FinnPRIO JUSTIFICATION POPULATOR - LOCAL FAST VERSION")
    print("DuckDuckGo + Ollama (100% FREE)")
    print("=" * 60)

    print(f"\nSource: {source_db}")
    print(f"Model: {OLLAMA_MODEL}")
    print(f"Context window: {NUM_CTX} tokens")
    print(f"Max output: {NUM_PREDICT} tokens")
    print(f"Search results: {MAX_SEARCH_RESULTS} pages")
    print(f"Context to LLM: {MAX_CONTEXT_TO_LLM} chars")
    print(f"Skip existing: {skip_existing}")
    print(f"Cost: $0.00")

    # Test Ollama connection
    print("\nTesting Ollama connection...")
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=5.0)
            if response.status_code == 200:
                models = response.json().get('models', [])
                model_names = [m['name'] for m in models]
                print(f"  Ollama connected! Models: {len(models)}")

                if not any(OLLAMA_MODEL.replace(':latest', '') in m['name'] for m in models):
                    print(f"\n  Warning: Model '{OLLAMA_MODEL}' may not be available")
                    print(f"  Run: ollama pull {OLLAMA_MODEL}")
            else:
                raise Exception(f"Status {response.status_code}")
    except Exception as e:
        print(f"\n  Ollama connection failed: {e}")
        print("\n  Make sure Ollama is running: ollama serve")
        return

    # Copy database
    working_db = copy_database(source_db, output_dir)
    print(f"\nWorking database: {working_db}")

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

    if not assessment_ids:
        print("No assessments to process!")
        return

    # Process each assessment
    for idx, aid in enumerate(assessment_ids, 1):
        if len(assessment_ids) > 1:
            print(f"\n{'=' * 60}")
            print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
            print(f"{'=' * 60}")

        await process_assessment(
            db_path=working_db,
            assessment_id=aid,
            limit_questions=limit_questions,
            process_pathways=process_pathways,
            skip_existing=skip_existing
        )

    print("\n" + "=" * 60)
    print("COMPLETED")
    print("=" * 60)
    print(f"\nDatabase: {working_db}")
    print("Cost: $0.00 (100% local)")
    print("\nReady to use in FinnPRIO app!")

# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="FinnPRIO Justification Populator - LOCAL FAST (DuckDuckGo + Ollama)"
    )
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH)
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument('--assessment-id', type=int, default=None)
    parser.add_argument('--limit-questions', type=int, default=None)
    parser.add_argument('--no-pathways', action='store_true')
    parser.add_argument('--eppo-codes', type=str, nargs='+', default=None)
    parser.add_argument('--overwrite', action='store_true')
    parser.add_argument('--model', type=str, default=None, help='Ollama model to use')

    args = parser.parse_args()

    if args.model:
        OLLAMA_MODEL = args.model

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
