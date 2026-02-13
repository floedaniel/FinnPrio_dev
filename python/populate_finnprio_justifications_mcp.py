"""
FinnPRIO Database Justification Populator v4 - MCP Edition

Key features:
- Uses GPT Researcher MCP Server instead of direct library
- Connects via Python MCP SDK (official protocol implementation)
- Deep research capabilities through MCP tools
- Copies entire database (preserves complete structure)
- Appends AI justifications to answers table
- Handles pathway questions for EACH selected pathway
- Clean plain text output (no markdown)
- Question-specific instructions
- Domain exclusions

Requirements:
- pip install mcp
- GPT Researcher MCP server running (python server.py from gptr-mcp repo)
"""

import os
import asyncio
import sqlite3
import shutil
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple
import re
from contextlib import AsyncExitStack

# MCP imports
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# =============================================================================
# CONFIGURATION
# =============================================================================

# Skip Existing Justifications
SKIP_EXISTING_JUSTIFICATION = True

# Database paths
#  CURRENT SETTING: Using AI-enhanced database (with existing justifications)
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\VKM Data\26.08.2024_lopende_oppdrag_plantehelse\FinnPrio databaser\Selamavit\selam_2026.db"

# Output directory (new copy will be created here)
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\VKM Data\26.08.2024_lopende_oppdrag_plantehelse\FinnPrio databaser\Selamavit"

# GPT Researcher MCP Server Path
# Download from: https://github.com/assafelovic/gptr-mcp
GPTR_MCP_SERVER_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\python\gptr-mcp-master\server.py"

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

# Set environment variables for MCP server
os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)

# Excluded domains
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# MCP CLIENT CLASS
# =============================================================================

class GPTResearcherMCPClient:
    """Client for GPT Researcher MCP Server"""

    def __init__(self, server_path: str):
        self.server_path = server_path
        self.exit_stack = AsyncExitStack()
        self.session = None
        self.stdio = None
        self.write = None

    async def connect(self):
        """Connect to GPT Researcher MCP server"""
        print("\n🔌 Connecting to GPT Researcher MCP server...")
        print(f"   Server: {self.server_path}")

        # Create server parameters for stdio connection
        server_params = StdioServerParameters(
            command="python",
            args=[self.server_path],
            env={
                'OPENAI_API_KEY': os.environ.get('OPENAI_API_KEY', ''),
                'TAVILY_API_KEY': os.environ.get('TAVILY_API_KEY', ''),
            }
        )

        try:
            # Establish connection
            stdio_transport = await self.exit_stack.enter_async_context(
                stdio_client(server_params)
            )
            self.stdio, self.write = stdio_transport

            # Create session
            self.session = await self.exit_stack.enter_async_context(
                ClientSession(self.stdio, self.write)
            )

            # Initialize
            await self.session.initialize()

            # List available tools
            response = await self.session.list_tools()
            tools = [tool.name for tool in response.tools]

            print(f"✅ Connected! Available tools: {', '.join(tools)}")

            return True

        except Exception as e:
            print(f"❌ Connection failed: {str(e)}")
            print("\n💡 Make sure GPT Researcher MCP server is accessible:")
            print(f"   1. Clone: git clone https://github.com/assafelovic/gptr-mcp.git")
            print(f"   2. Install: pip install -r requirements.txt")
            print(f"   3. Update GPTR_MCP_SERVER_PATH in this script")
            return False

    async def deep_research(self, query: str) -> str:
        """Perform deep research using MCP server"""
        if not self.session:
            raise RuntimeError("Not connected to MCP server. Call connect() first.")

        try:
            # Call deep_research tool
            result = await self.session.call_tool(
                "deep_research",
                arguments={"query": query}
            )

            # Extract text from result
            if result.content:
                text_parts = []
                for item in result.content:
                    if hasattr(item, 'text'):
                        text_parts.append(item.text)
                    elif isinstance(item, dict):
                        if 'text' in item:
                            text_parts.append(item['text'])
                        elif 'context' in item:
                            text_parts.append(item['context'])
                    elif isinstance(item, str):
                        text_parts.append(item)

                return '\n'.join(text_parts)

            return ""

        except Exception as e:
            print(f"❌ Research failed: {str(e)}")
            return f"ERROR: {str(e)}"

    async def close(self):
        """Close MCP connection"""
        await self.exit_stack.aclose()
        print("\n🔌 Disconnected from MCP server")

# =============================================================================
# TEXT CLEANING FUNCTIONS
# =============================================================================

def clean_markdown_formatting(text: str) -> str:
    """Remove markdown formatting and clean up AI-generated text."""

    if not text:
        return ""

    # Remove markdown headings (keep the text, just remove #)
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)

    # Remove bold/italic (keep the text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    text = re.sub(r'\*([^*]+)\*', r'\1', text)
    text = re.sub(r'__([^_]+)__', r'\1', text)
    text = re.sub(r'_([^_]+)_', r'\1', text)

    # Remove markdown links (keep link text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)

    # Remove markdown table formatting (keep content)
    text = re.sub(r'^\s*\|[\s\-:|]+\|\s*$', '', text, flags=re.MULTILINE)
    text = re.sub(r'\|', ' ', text)

    # Remove bullet markers (keep text)
    text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\d+\.\s+', '', text, flags=re.MULTILINE)

    # Remove code block markers (keep content)
    text = re.sub(r'```\w*\n?', '', text)
    text = re.sub(r'`([^`]+)`', r'\1', text)

    # Remove horizontal rules
    text = re.sub(r'^[-*_]{3,}\s*$', '', text, flags=re.MULTILINE)

    # Remove GPT Researcher specific phrases
    text = re.sub(r'\(GPT Researcher\)', '', text)
    text = re.sub(r'AI-Generated.*?Information', '', text, flags=re.IGNORECASE)

    # Skip intro pattern removal - too aggressive

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = re.sub(r'\n ', '\n', text)
    text = re.sub(r' \n', '\n', text)
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
    output_name = f"{original_name}_ai_enhanced_mcp_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    print(f"\n📋 Copying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)

    if output_path.exists():
        print(f"✅ Database copied successfully ({output_path.stat().st_size / 1024:.1f} KB)")
    else:
        raise FileNotFoundError(f"Failed to copy database to {output_path}")

    return str(output_path)

def get_all_assessment_ids(db_path: str) -> List[int]:
    """Get all assessment IDs."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT idAssessment
        FROM assessments
        ORDER BY idAssessment
    """)
    ids = [row[0] for row in cursor.fetchall()]
    conn.close()
    return ids

def get_assessment_info(db_path: str, assessment_id: int) -> Dict:
    """Get assessment details including pest and regular questions."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Get assessment
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

    id_assessment, id_pest, scientific_name, eppo_code = result

    # Get regular answers with questions
    cursor.execute("""
        SELECT a.idAnswer, a.justification,
               q.[group] || q.number as code,
               q.question, q.info
        FROM answers a
        JOIN questions q ON a.idQuestion = q.idQuestion
        WHERE a.idAssessment = ?
        ORDER BY q.[group], CAST(q.number AS INTEGER)
    """, (assessment_id,))

    answers = []
    for row in cursor.fetchall():
        answers.append({
            'idAnswer': row[0],
            'justification': row[1],
            'code': row[2],
            'text': row[3],
            'info': row[4],
        })

    # Get pathway questions
    cursor.execute("""
        SELECT pa.idPathAnswer, pa.justification,
               pq.[group] || pq.number as code,
               pq.question, pq.info,
               ep.idPathway, p.name as pathway_name
        FROM pathwayAnswers pa
        JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
        JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
        JOIN pathways p ON ep.idPathway = p.idPathway
        WHERE ep.idAssessment = ?
        ORDER BY ep.idPathway, pq.[group], CAST(pq.number AS INTEGER)
    """, (assessment_id,))

    pathway_answers = []
    for row in cursor.fetchall():
        pathway_answers.append({
            'idPathAnswer': row[0],
            'justification': row[1],
            'code': row[2],
            'text': row[3],
            'info': row[4],
            'idPathway': row[5],
            'pathway_name': row[6],
        })

    conn.close()

    return {
        'idAssessment': id_assessment,
        'idPest': id_pest,
        'scientificName': scientific_name,
        'eppoCode': eppo_code,
        'answers': answers,
        'pathway_answers': pathway_answers,
    }

def update_answer_justification(db_path: str, id_answer: int, justification: str):
    """Update answer with justification."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    try:
        cursor.execute("""
            UPDATE answers
            SET justification = ?
            WHERE idAnswer = ?
        """, (justification, id_answer))

        conn.commit()

    except sqlite3.Error as e:
        print(f"❌ Database error: {str(e)}")
        print(f"   Database: {db_path}")
        print(f"   Answer ID: {id_answer}")
        raise
    finally:
        conn.close()

def update_pathway_justification(db_path: str, id_path_answer: int, justification: str):
    """Update pathway answer with justification."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    try:
        cursor.execute("""
            UPDATE pathwayAnswers
            SET justification = ?
            WHERE idPathAnswer = ?
        """, (justification, id_path_answer))

        conn.commit()

    except sqlite3.Error as e:
        print(f"❌ Database error: {str(e)}")
        print(f"   Database: {db_path}")
        print(f"   PathAnswer ID: {id_path_answer}")
        raise
    finally:
        conn.close()

# =============================================================================
# RESEARCH QUERY CONSTRUCTION
# =============================================================================

def create_research_query(pest_name: str, question_code: str, question_text: str,
                         question_info: str = "", pathway_name: str = None) -> str:
    """Create research query for GPT Researcher MCP."""

    pathway_context = f" for the entry pathway '{pathway_name}'" if pathway_name else ""

    base_query = f"""
Research and provide a scientific justification for the following pest risk assessment question:

PEST SPECIES: {pest_name}
QUESTION CODE: {question_code}{pathway_context}
QUESTION: {question_text}

{'ADDITIONAL CONTEXT: ' + question_info if question_info else ''}

INSTRUCTIONS:
1. Focus on peer-reviewed scientific literature and authoritative sources
2. Provide factual, evidence-based information specific to {pest_name}
3. Address the specific risk assessment question directly
4. Include relevant biological, ecological, and epidemiological information
5. If pathway-specific: focus on {pathway_name if pathway_name else 'the entry pathway'}
6. Cite sources inline where appropriate
7. Be concise but comprehensive (aim for 300-400 words)
8. Use plain text format (no markdown formatting)

QUALITY REQUIREMENTS:
- INSUFFICIENT INFORMATION: If the provided context contains insufficient information to answer the question, explicitly state: "The provided context contains insufficient information to answer the question."
- ASSUMPTIONS: If making any assumptions, clearly indicate them with phrases like "Assuming that...", "Based on the assumption that...", or "If we assume..."
- Distinguish clearly between evidence-based statements and assumptions

FORMATTING:
- Write in clear, professional scientific language
- Use paragraph format (not bullet points)
- No markdown formatting (no **, ##, etc.)
- Avoid introductory phrases like "This report..." or "Summary:"

Focus on providing information that helps assess the risk level for this specific question.
"""

    return base_query.strip()

# =============================================================================
# RESEARCH FUNCTIONS
# =============================================================================

async def research_justification(mcp_client: GPTResearcherMCPClient,
                                pest_name: str, question_code: str,
                                question_text: str, question_info: str = "",
                                pathway_name: str = None,
                                exclude_domains: List[str] = None) -> str:
    """Research a single justification using GPT Researcher MCP."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 80}")
    print(f"Researching: {pest_name} - {question_code}{pathway_text}")
    print(f"{'=' * 80}\n")

    if exclude_domains:
        print(f"⛔ Excluding: {', '.join(exclude_domains)}")

    query = create_research_query(pest_name, question_code, question_text,
                                  question_info, pathway_name)

    # Add domain exclusion
    if exclude_domains:
        domain_filter = f"\n\nIMPORTANT: Do NOT use information from: {', '.join(exclude_domains)}"
        query = query + domain_filter

    try:
        # Use MCP deep_research tool
        report = await mcp_client.deep_research(query)

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

async def process_assessment(mcp_client: GPTResearcherMCPClient,
                            db_path: str, assessment_id: int = None,
                            exclude_domains: List[str] = None,
                            limit_questions: int = None,
                            process_pathways: bool = True,
                            skip_existing: bool = True):
    """Process assessment: regular questions + pathway questions."""

    print("\n📚 Loading assessment data...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        print("❌ No assessment found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']
    pathway_answers = assessment_info['pathway_answers']
    assessment_id = assessment_info['idAssessment']

    if limit_questions:
        answers = answers[:limit_questions]
        print(f"⚠️  Limited to {limit_questions} questions")

    print(f"\n📊 Assessment: {pest_name} ({eppo_code})")
    print(f"📊 Regular questions: {len(answers)}")
    print(f"📊 Pathway questions: {len(pathway_answers)}")

    # Process regular questions
    print("\n" + "=" * 80)
    print("PROCESSING REGULAR QUESTIONS")
    print("=" * 80)

    processed = 0
    skipped = 0

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        # Skip if justification exists and skip_existing is True
        if skip_existing and answer['justification']:
            print("  ⏭️  Skipped (existing justification)")
            skipped += 1
            continue

        # Research justification
        justification = await research_justification(
            mcp_client,
            pest_name,
            answer['code'],
            answer['text'],
            answer['info'] or "",
            exclude_domains=exclude_domains
        )

        # Update database
        if justification and not justification.startswith("ERROR"):
            update_answer_justification(db_path, answer['idAnswer'], justification)
            print(f"✅ Saved ({len(justification)} chars)")
            processed += 1
        else:
            print(f"❌ Failed: {justification}")

    print(f"\n📊 Regular questions: {processed} processed, {skipped} skipped")

    # Process pathway questions
    if process_pathways and pathway_answers:
        print("\n" + "=" * 80)
        print("PROCESSING PATHWAY QUESTIONS")
        print("=" * 80)

        path_processed = 0
        path_skipped = 0

        for i, answer in enumerate(pathway_answers, 1):
            print(f"\n[{i}/{len(pathway_answers)}] {answer['code']} - {answer['pathway_name']}")

            # Skip if justification exists
            if skip_existing and answer['justification']:
                print("  ⏭️  Skipped (existing justification)")
                path_skipped += 1
                continue

            # Research justification
            justification = await research_justification(
                mcp_client,
                pest_name,
                answer['code'],
                answer['text'],
                answer['info'] or "",
                pathway_name=answer['pathway_name'],
                exclude_domains=exclude_domains
            )

            # Update database
            if justification and not justification.startswith("ERROR"):
                update_pathway_justification(db_path, answer['idPathAnswer'], justification)
                print(f"✅ Saved ({len(justification)} chars)")
                path_processed += 1
            else:
                print(f"❌ Failed: {justification}")

        print(f"\n📊 Pathway questions: {path_processed} processed, {path_skipped} skipped")

async def main(source_db: str = DEFAULT_DB_PATH,
              output_dir: str = DEFAULT_OUTPUT_DIR,
              assessment_id: int = None,
              limit_questions: int = None,
              no_pathways: bool = False,
              overwrite: bool = False,
              exclude_domains: List[str] = None,
              no_default_exclusions: bool = False):
    """Main execution function."""

    print("\n" + "=" * 80)
    print("FinnPRIO JUSTIFICATION POPULATOR v4 - MCP EDITION")
    print("=" * 80)
    print("\n📦 Using GPT Researcher MCP Server")
    print(f"   Server: {GPTR_MCP_SERVER_PATH}")

    # Setup exclusions
    if no_default_exclusions:
        domain_exclusions = exclude_domains or []
    else:
        domain_exclusions = EXCLUDED_DOMAINS + (exclude_domains or [])

    if domain_exclusions:
        print(f"\n⛔ Excluding domains: {', '.join(domain_exclusions)}")

    # Copy database
    output_db = copy_database(source_db, output_dir)

    # Connect to MCP server
    mcp_client = GPTResearcherMCPClient(GPTR_MCP_SERVER_PATH)

    if not await mcp_client.connect():
        print("\n❌ Failed to connect to MCP server. Exiting.")
        return

    try:
        # Get assessments to process
        if assessment_id:
            assessment_ids = [assessment_id]
            print(f"\n📋 Processing single assessment: {assessment_id}")
        else:
            assessment_ids = get_all_assessment_ids(output_db)
            print(f"\n📋 Processing {len(assessment_ids)} assessment(s)")

        # Process each assessment
        for idx, aid in enumerate(assessment_ids, 1):
            if len(assessment_ids) > 1:
                print(f"\n{'=' * 80}")
                print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
                print(f"{'=' * 80}")

            await process_assessment(
                mcp_client,
                output_db,
                assessment_id=aid,
                exclude_domains=domain_exclusions,
                limit_questions=limit_questions,
                process_pathways=not no_pathways,
                skip_existing=not overwrite
            )

        print("\n" + "=" * 80)
        print("✅ COMPLETE")
        print("=" * 80)
        print(f"\n📁 Output database: {output_db}")

    finally:
        await mcp_client.close()

# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description='Populate FinnPRIO justifications using GPT Researcher MCP')
    parser.add_argument('--db', type=str, help='Source database path')
    parser.add_argument('--output', type=str, help='Output directory')
    parser.add_argument('--assessment-id', type=int, help='Process single assessment ID')
    parser.add_argument('--limit-questions', type=int, help='Limit number of questions to process')
    parser.add_argument('--no-pathways', action='store_true', help='Skip pathway questions')
    parser.add_argument('--overwrite', action='store_true', help='Overwrite existing justifications')
    parser.add_argument('--exclude-domains', nargs='+', help='Additional domains to exclude')
    parser.add_argument('--no-default-exclusions', action='store_true', help='Do not use default domain exclusions')

    args = parser.parse_args()

    asyncio.run(main(
        source_db=args.db or DEFAULT_DB_PATH,
        output_dir=args.output or DEFAULT_OUTPUT_DIR,
        assessment_id=args.assessment_id,
        limit_questions=args.limit_questions,
        no_pathways=args.no_pathways,
        overwrite=args.overwrite,
        exclude_domains=args.exclude_domains,
        no_default_exclusions=args.no_default_exclusions
    ))
