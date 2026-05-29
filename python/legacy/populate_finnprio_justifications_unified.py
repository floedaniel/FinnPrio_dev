"""
FinnPRIO Unified Justification Populator

"One script to bind them all"

Combines two complementary data sources:
1. EPPO MCP Server - Authoritative structured data (distribution, hosts, regulatory)
2. GPT Researcher MCP Server - Scientific literature and web research

Workflow per question:
1. Query EPPO for structured, authoritative data
2. Build context-aware research query using EPPO data
3. Call GPT Researcher for broader scientific context
4. Synthesize both into comprehensive justification

Features:
- Parallel MCP server connections
- EPPO data as reliable foundation
- GPT Researcher for literature/studies
- Smart query building with EPPO context
- Graceful fallback (EPPO down -> research only)
- Caching on both sides
- Configurable LLM backend

Requirements:
- pip install mcp httpx aiosqlite
- EPPO API key
- OpenAI/Anthropic API key
- Tavily API key (for GPT Researcher)

Usage:
    python populate_finnprio_justifications_unified.py --eppo-codes XYLEFA
    python populate_finnprio_justifications_unified.py --assessment-id 1
"""

import os
import sys
import asyncio
import sqlite3
import shutil
import re
import json
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from contextlib import AsyncExitStack

# MCP imports
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# =============================================================================
# CONFIGURATION
# =============================================================================

# Skip existing justifications
SKIP_EXISTING_JUSTIFICATION = False

# Database paths
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel.db"
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026"

# Filter by EPPO codes (empty list = process all)
EPPOCODES_TO_POPULATE = ["ANOLHO"]

# MCP Server Paths
EPPO_MCP_SERVER_PATH = Path(__file__).parent / "servers" / "eppo_mcp_server.py"
GPTR_MCP_SERVER_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\python\gptr-mcp-master\server.py"

# API Keys
OPENAI_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\chatgpt_apikey.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\Tavily_key.txt"
EPPO_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\EPPO_beta.txt"

# Excluded domains for research
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# API KEY LOADING
# =============================================================================

def load_api_key(file_path: str) -> str:
    """Load API key from file"""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"Warning: API key file not found: {file_path}")
        return ""


# Set environment variables
os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)

# =============================================================================
# MCP CLIENT CLASSES
# =============================================================================

class EPPOMCPClient:
    """Client for EPPO MCP Server"""

    def __init__(self, server_path: str):
        self.server_path = str(server_path)
        self.exit_stack = AsyncExitStack()
        self.session: Optional[ClientSession] = None
        self.connected = False

    async def connect(self) -> bool:
        """Connect to EPPO MCP server"""
        print("\n[EPPO] Connecting to EPPO MCP server...")

        server_params = StdioServerParameters(
            command="python",
            args=[self.server_path],
            env=dict(os.environ)
        )

        try:
            stdio_transport = await self.exit_stack.enter_async_context(
                stdio_client(server_params)
            )
            self.stdio, self.write = stdio_transport

            self.session = await self.exit_stack.enter_async_context(
                ClientSession(self.stdio, self.write)
            )

            await self.session.initialize()
            response = await self.session.list_tools()
            tools = [tool.name for tool in response.tools]

            print(f"[EPPO] Connected! Tools: {', '.join(tools)}")
            self.connected = True
            return True

        except Exception as e:
            print(f"[EPPO] Connection failed: {e}")
            print("[EPPO] Will continue with GPT Researcher only")
            self.connected = False
            return False

    async def get_pest_info(self, eppo_code: str) -> Optional[str]:
        """Get comprehensive pest info"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_pest_info",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting pest info: {e}")
            return None

    async def get_distribution(self, eppo_code: str) -> Optional[str]:
        """Get distribution data"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_distribution",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting distribution: {e}")
            return None

    async def get_hosts(self, eppo_code: str) -> Optional[str]:
        """Get host plants"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_hosts",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting hosts: {e}")
            return None

    async def get_categorization(self, eppo_code: str) -> Optional[str]:
        """Get regulatory categorization"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_categorization",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting categorization: {e}")
            return None

    async def get_vectors(self, eppo_code: str) -> Optional[str]:
        """Get vector organisms"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_vectors",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting vectors: {e}")
            return None

    async def get_bca(self, eppo_code: str) -> Optional[str]:
        """Get biological control agents"""
        if not self.connected or not self.session:
            return None

        try:
            result = await self.session.call_tool(
                "eppo_get_bca",
                arguments={"eppo_code": eppo_code}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[EPPO] Error getting BCA: {e}")
            return None

    def _extract_text(self, result) -> str:
        """Extract text from MCP result"""
        if result and result.content:
            parts = []
            for item in result.content:
                if hasattr(item, 'text'):
                    parts.append(item.text)
            return '\n'.join(parts)
        return ""

    async def close(self):
        """Close connection"""
        try:
            await self.exit_stack.aclose()
        except (RuntimeError, Exception) as e:
            # Ignore cleanup errors - work is already done
            pass
        print("[EPPO] Disconnected")


class GPTResearcherMCPClient:
    """Client for GPT Researcher MCP Server"""

    def __init__(self, server_path: str):
        self.server_path = server_path
        self.exit_stack = AsyncExitStack()
        self.session: Optional[ClientSession] = None
        self.connected = False

    async def connect(self) -> bool:
        """Connect to GPT Researcher MCP server"""
        print("\n[GPTR] Connecting to GPT Researcher MCP server...")

        # Pass full environment to ensure Python can find packages
        env = dict(os.environ)
        env['OPENAI_API_KEY'] = os.environ.get('OPENAI_API_KEY', '')
        env['TAVILY_API_KEY'] = os.environ.get('TAVILY_API_KEY', '')

        server_params = StdioServerParameters(
            command="python",
            args=[self.server_path],
            env=env
        )

        try:
            stdio_transport = await self.exit_stack.enter_async_context(
                stdio_client(server_params)
            )
            self.stdio, self.write = stdio_transport

            self.session = await self.exit_stack.enter_async_context(
                ClientSession(self.stdio, self.write)
            )

            await self.session.initialize()
            response = await self.session.list_tools()
            tools = [tool.name for tool in response.tools]

            print(f"[GPTR] Connected! Tools: {', '.join(tools)}")
            self.connected = True
            return True

        except Exception as e:
            print(f"[GPTR] Connection failed: {e}")
            self.connected = False
            return False

    async def deep_research(self, query: str) -> str:
        """Perform deep research"""
        if not self.connected or not self.session:
            return "ERROR: GPT Researcher not connected"

        try:
            result = await self.session.call_tool(
                "deep_research",
                arguments={"query": query}
            )
            return self._extract_text(result)
        except Exception as e:
            print(f"[GPTR] Research error: {e}")
            return f"ERROR: {e}"

    def _extract_text(self, result) -> str:
        """Extract text from MCP result, handling JSON responses"""
        if result and result.content:
            parts = []
            for item in result.content:
                text = None
                if hasattr(item, 'text'):
                    text = item.text
                elif isinstance(item, dict) and 'text' in item:
                    text = item['text']

                if text:
                    # Try to parse as JSON and extract the actual content
                    try:
                        data = json.loads(text)
                        if isinstance(data, dict):
                            # GPT Researcher returns {"status":"success","context":"..."}
                            # Priority order: context > report > result > content
                            if 'context' in data and data['context']:
                                parts.append(data['context'])
                            elif 'report' in data and data['report']:
                                parts.append(data['report'])
                            elif 'result' in data and data['result']:
                                parts.append(data['result'])
                            elif 'content' in data and data['content']:
                                parts.append(data['content'])
                            # Skip if no usable content found (don't add raw JSON)
                        else:
                            parts.append(text)
                    except (json.JSONDecodeError, TypeError):
                        # Not JSON, use as-is
                        parts.append(text)
            return '\n'.join(parts)
        return ""

    async def close(self):
        """Close connection"""
        try:
            await self.exit_stack.aclose()
        except (RuntimeError, Exception) as e:
            # Ignore cleanup errors - work is already done
            pass
        print("[GPTR] Disconnected")

# =============================================================================
# TEXT PROCESSING
# =============================================================================

def clean_markdown(text: str) -> str:
    """Remove markdown formatting"""
    if not text:
        return ""

    # Remove headings (keep text)
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)

    # Remove bold/italic
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    text = re.sub(r'\*([^*]+)\*', r'\1', text)
    text = re.sub(r'__([^_]+)__', r'\1', text)
    text = re.sub(r'_([^_]+)_', r'\1', text)

    # Remove links (keep text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)

    # Remove tables
    text = re.sub(r'^\s*\|[\s\-:|]+\|\s*$', '', text, flags=re.MULTILINE)
    text = re.sub(r'\|', ' ', text)

    # Remove bullets
    text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\d+\.\s+', '', text, flags=re.MULTILINE)

    # Remove code blocks
    text = re.sub(r'```\w*\n?', '', text)
    text = re.sub(r'`([^`]+)`', r'\1', text)

    # Clean whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = text.strip()

    return text

# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy database to new location with timestamp"""
    source_file = Path(source_path)
    original_name = source_file.stem
    timestamp = datetime.now().strftime("%d_%m_%Y")

    # Extract base name
    for pattern in ["_unified_", "_ai_enhanced_mcp_", "_ai_enhanced_"]:
        if pattern in original_name:
            original_name = original_name.split(pattern)[0]
            break

    output_name = f"{original_name}_unified_{timestamp}.db"
    output_path = Path(output_dir) / output_name

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # Same-day re-run check
    if source_file.resolve() == output_path.resolve():
        print(f"\n[DB] Using existing database (same-day re-run)")
        return str(output_path)

    print(f"\n[DB] Copying database...")
    print(f"     From: {source_path}")
    print(f"     To:   {output_path}")

    shutil.copy2(source_path, output_path)
    print(f"[DB] Copied ({output_path.stat().st_size / 1024:.1f} KB)")

    return str(output_path)


def get_all_assessment_ids(db_path: str, eppo_codes: List[str] = None) -> List[int]:
    """Get assessment IDs, optionally filtered"""
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


def get_assessment_info(db_path: str, assessment_id: int) -> Optional[Dict]:
    """Get assessment with answers and pathway answers"""
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

    # Get regular answers
    cursor.execute("""
        SELECT a.idAnswer, a.justification,
               q.[group] || q.number as code,
               q.question, q.info
        FROM answers a
        JOIN questions q ON a.idQuestion = q.idQuestion
        WHERE a.idAssessment = ?
        ORDER BY q.[group], CAST(q.number AS INTEGER)
    """, (assessment_id,))

    answers = [{
        'idAnswer': row[0],
        'justification': row[1],
        'code': row[2],
        'text': row[3],
        'info': row[4],
    } for row in cursor.fetchall()]

    # Get pathway answers
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

    pathway_answers = [{
        'idPathAnswer': row[0],
        'justification': row[1],
        'code': row[2],
        'text': row[3],
        'info': row[4],
        'idPathway': row[5],
        'pathway_name': row[6],
    } for row in cursor.fetchall()]

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
    """Update answer justification"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("UPDATE answers SET justification = ? WHERE idAnswer = ?",
                   (justification, id_answer))
    conn.commit()
    conn.close()


def update_pathway_justification(db_path: str, id_path_answer: int, justification: str):
    """Update pathway answer justification"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("UPDATE pathwayAnswers SET justification = ? WHERE idPathAnswer = ?",
                   (justification, id_path_answer))
    conn.commit()
    conn.close()

# =============================================================================
# QUESTION-SPECIFIC EPPO DATA MAPPING
# =============================================================================

QUESTION_EPPO_MAPPING = {
    # Entry questions - use distribution
    'ENT1': ['distribution', 'categorization'],

    # Establishment questions - use hosts, distribution
    'EST1': ['distribution'],  # Climate/establishment
    'EST2': ['hosts'],         # Host availability
    'EST3': ['distribution'],  # Spread rate
    'EST4': ['hosts', 'vectors'],  # Characteristics

    # Impact questions - use hosts
    'IMP1': ['hosts'],  # Economic impact
    'IMP2': ['hosts'],  # Affected sectors
    'IMP3': ['hosts'],  # Environmental
    'IMP4': ['hosts'],  # Social

    # Management questions - use categorization, BCA
    'MAN1': ['distribution', 'categorization'],  # Natural spread
    'MAN2': ['categorization'],  # EU presence
    'MAN3': ['categorization'],  # Detection
    'MAN4': ['bca'],  # Eradication
    'MAN5': ['bca'],  # Surveillance

    # Pathway questions - use distribution
    'ENT2A': ['distribution'],
    'ENT2B': ['distribution'],
    'ENT3': ['distribution'],
    'ENT4': ['hosts'],
}


async def get_eppo_context_for_question(
    eppo_client: EPPOMCPClient,
    eppo_code: str,
    question_code: str,
    cached_data: Dict[str, str]
) -> str:
    """Get relevant EPPO data for a specific question"""

    # Determine which data types are needed
    base_code = question_code.rstrip('.0123456789')
    data_types = QUESTION_EPPO_MAPPING.get(base_code, ['distribution'])

    context_parts = []

    for data_type in data_types:
        # Check cache first
        cache_key = f"{eppo_code}_{data_type}"
        if cache_key in cached_data:
            context_parts.append(cached_data[cache_key])
            continue

        # Fetch from EPPO
        data = None
        if data_type == 'distribution':
            data = await eppo_client.get_distribution(eppo_code)
        elif data_type == 'hosts':
            data = await eppo_client.get_hosts(eppo_code)
        elif data_type == 'categorization':
            data = await eppo_client.get_categorization(eppo_code)
        elif data_type == 'vectors':
            data = await eppo_client.get_vectors(eppo_code)
        elif data_type == 'bca':
            data = await eppo_client.get_bca(eppo_code)

        if data:
            cached_data[cache_key] = data
            context_parts.append(data)

    return '\n\n'.join(context_parts) if context_parts else ""

# =============================================================================
# QUERY CONSTRUCTION
# =============================================================================

def build_research_query(
    pest_name: str,
    question_code: str,
    question_text: str,
    question_info: str,
    eppo_context: str,
    pathway_name: str = None,
    exclude_domains: List[str] = None
) -> str:
    """Build research query enriched with EPPO context"""

    pathway_text = f" via the pathway '{pathway_name}'" if pathway_name else ""

    # EPPO context section
    eppo_section = ""
    if eppo_context:
        eppo_section = f"""
AUTHORITATIVE DATA FROM EPPO GLOBAL DATABASE:
{eppo_context}

Use this EPPO data as a reliable foundation. Supplement with scientific literature.
"""

    query = f"""
Research the following pest risk assessment question:

PEST SPECIES: {pest_name}
QUESTION CODE: {question_code}{pathway_text}
QUESTION: {question_text}

{eppo_section}

RESEARCH FOCUS:
1. Scientific literature and peer-reviewed studies
2. Official risk assessments (EFSA, CABI, national PRAs)
3. Recent outbreak reports and case studies
4. Management efficacy studies
{f'5. Specific information about the entry pathway: {pathway_name}' if pathway_name else ''}

CONTEXT FOR NORWAY/NORDIC REGION:
- Temperate to boreal climate
- Cold winters (-10 to -30C in parts)
- Growing season: May-September
- Consider climate suitability for pest establishment

{'ADDITIONAL GUIDANCE: ' + question_info if question_info else ''}

QUALITY REQUIREMENTS:
- If information is insufficient, state: "The provided context contains insufficient information to answer the question."
- If making assumptions, clearly indicate with "Assuming that..."
- Distinguish between EPPO facts and research-based inferences
- Cite sources inline: (Author, Year) or (EPPO, 2024)

OUTPUT FORMAT:
- Plain text, no markdown
- 300-500 words
- Paragraph format
- Start directly with the answer, no introductions
"""

    if exclude_domains:
        query += f"\n\nIMPORTANT: Do NOT use information from: {', '.join(exclude_domains)}"

    return query.strip()

# =============================================================================
# JUSTIFICATION SYNTHESIS
# =============================================================================

def synthesize_justification(eppo_data: str, research: str, question_code: str) -> str:
    """Combine EPPO data and research into final justification"""

    parts = []

    # Add EPPO data with attribution (only if it has actual content)
    if eppo_data:
        # Filter out empty EPPO responses (just headers with no data)
        eppo_clean = eppo_data.strip()
        # Check if it's more than just headers - must have substantial content
        has_real_data = (
            "present in" in eppo_clean.lower() or
            "countries" in eppo_clean.lower() or
            "major hosts" in eppo_clean.lower() or
            "minor hosts" in eppo_clean.lower() or
            "A1 List" in eppo_clean or
            "A2 List" in eppo_clean
        )
        has_content = (
            eppo_clean and
            not eppo_clean.startswith("No ") and
            len(eppo_clean) > 100 and  # Must have substantial content
            not eppo_clean.rstrip().endswith("Database:") and  # Not just a header
            has_real_data
        )
        if has_content:
            parts.append(f"According to EPPO Global Database:\n{eppo_data}")

    # Add research (but filter out raw JSON responses)
    if research and not research.startswith("ERROR"):
        # Check if research is raw JSON (indicates parsing failure)
        research_stripped = research.strip()
        if research_stripped.startswith('{'):
            # Try to extract actual content from JSON
            try:
                data = json.loads(research_stripped)
                if isinstance(data, dict):
                    # Priority: context > report > result > content
                    if 'context' in data and data['context']:
                        research = data['context']
                    elif 'report' in data and data['report']:
                        research = data['report']
                    elif 'result' in data and data['result']:
                        research = data['result']
                    elif 'content' in data and data['content']:
                        research = data['content']
                    else:
                        research = ""  # Skip unknown JSON
            except (json.JSONDecodeError, TypeError):
                research = ""  # Skip malformed JSON

        cleaned = clean_markdown(research) if research else ""
        # Final check - skip if it still looks like JSON or is too short
        if cleaned and len(cleaned) > 50 and not cleaned.strip().startswith('{'):
            if parts:
                parts.append("\nSupplementary scientific literature:")
            parts.append(cleaned)

    if not parts:
        return "Insufficient information available from EPPO and scientific literature."

    return '\n\n'.join(parts)

# =============================================================================
# MAIN PROCESSING
# =============================================================================

async def process_question(
    eppo_client: EPPOMCPClient,
    gptr_client: GPTResearcherMCPClient,
    pest_name: str,
    eppo_code: str,
    question_code: str,
    question_text: str,
    question_info: str,
    cached_eppo_data: Dict[str, str],
    pathway_name: str = None,
    exclude_domains: List[str] = None
) -> str:
    """Process a single question using both EPPO and GPT Researcher"""

    pathway_text = f" ({pathway_name})" if pathway_name else ""
    print(f"\n{'=' * 70}")
    print(f"Processing: {pest_name} - {question_code}{pathway_text}")
    print(f"{'=' * 70}")

    # Step 1: Get EPPO context
    print("[1/3] Fetching EPPO data...")
    eppo_context = ""
    if eppo_client.connected:
        eppo_context = await get_eppo_context_for_question(
            eppo_client, eppo_code, question_code, cached_eppo_data
        )
        if eppo_context:
            print(f"      Got {len(eppo_context)} chars of EPPO data")
        else:
            print("      No relevant EPPO data found")
    else:
        print("      EPPO not connected, skipping")

    # Step 2: Build and execute research query
    print("[2/3] Conducting web research...")
    research_result = ""
    if gptr_client.connected:
        query = build_research_query(
            pest_name, question_code, question_text, question_info,
            eppo_context, pathway_name, exclude_domains
        )
        research_result = await gptr_client.deep_research(query)
        if research_result and not research_result.startswith("ERROR"):
            print(f"      Got {len(research_result)} chars of research")
        else:
            print(f"      Research failed or empty")
    else:
        print("      GPT Researcher not connected, skipping")

    # Step 3: Synthesize
    print("[3/3] Synthesizing justification...")
    justification = synthesize_justification(eppo_context, research_result, question_code)
    print(f"      Final: {len(justification)} chars")

    return justification


async def process_assessment(
    eppo_client: EPPOMCPClient,
    gptr_client: GPTResearcherMCPClient,
    db_path: str,
    assessment_id: int,
    exclude_domains: List[str] = None,
    skip_existing: bool = True,
    process_pathways: bool = True
):
    """Process all questions for an assessment"""

    print(f"\n{'=' * 70}")
    print(f"LOADING ASSESSMENT {assessment_id}")
    print(f"{'=' * 70}")

    assessment = get_assessment_info(db_path, assessment_id)
    if not assessment:
        print("Assessment not found!")
        return

    pest_name = assessment['scientificName']
    eppo_code = assessment['eppoCode']
    answers = assessment['answers']
    pathway_answers = assessment['pathway_answers']

    print(f"Pest: {pest_name} ({eppo_code})")
    print(f"Regular questions: {len(answers)}")
    print(f"Pathway questions: {len(pathway_answers)}")

    # Cache for EPPO data within this assessment
    cached_eppo_data: Dict[str, str] = {}

    # Pre-fetch comprehensive EPPO data
    if eppo_client.connected:
        print("\n[EPPO] Pre-fetching comprehensive pest data...")
        full_info = await eppo_client.get_pest_info(eppo_code)
        if full_info:
            cached_eppo_data[f"{eppo_code}_full"] = full_info
            print(f"[EPPO] Cached {len(full_info)} chars of comprehensive data")

    # Process regular questions
    print(f"\n{'=' * 70}")
    print("PROCESSING REGULAR QUESTIONS")
    print(f"{'=' * 70}")

    processed = 0
    skipped = 0

    for i, answer in enumerate(answers, 1):
        print(f"\n[{i}/{len(answers)}] {answer['code']}")

        if skip_existing and answer['justification']:
            print("  Skipped (existing)")
            skipped += 1
            continue

        justification = await process_question(
            eppo_client, gptr_client,
            pest_name, eppo_code,
            answer['code'], answer['text'], answer['info'] or "",
            cached_eppo_data,
            exclude_domains=exclude_domains
        )

        if justification:
            update_answer_justification(db_path, answer['idAnswer'], justification)
            print(f"  Saved ({len(justification)} chars)")
            processed += 1
        else:
            print("  Failed - no justification generated")

    print(f"\nRegular questions: {processed} processed, {skipped} skipped")

    # Process pathway questions
    if process_pathways and pathway_answers:
        print(f"\n{'=' * 70}")
        print("PROCESSING PATHWAY QUESTIONS")
        print(f"{'=' * 70}")

        path_processed = 0
        path_skipped = 0

        for i, answer in enumerate(pathway_answers, 1):
            print(f"\n[{i}/{len(pathway_answers)}] {answer['code']} - {answer['pathway_name']}")

            if skip_existing and answer['justification']:
                print("  Skipped (existing)")
                path_skipped += 1
                continue

            justification = await process_question(
                eppo_client, gptr_client,
                pest_name, eppo_code,
                answer['code'], answer['text'], answer['info'] or "",
                cached_eppo_data,
                pathway_name=answer['pathway_name'],
                exclude_domains=exclude_domains
            )

            if justification:
                update_pathway_justification(db_path, answer['idPathAnswer'], justification)
                print(f"  Saved ({len(justification)} chars)")
                path_processed += 1
            else:
                print("  Failed - no justification generated")

        print(f"\nPathway questions: {path_processed} processed, {path_skipped} skipped")

# =============================================================================
# MAIN
# =============================================================================

async def main(
    source_db: str = DEFAULT_DB_PATH,
    output_dir: str = DEFAULT_OUTPUT_DIR,
    assessment_id: int = None,
    eppo_codes: List[str] = None,
    skip_existing: bool = True,
    process_pathways: bool = True,
    exclude_domains: List[str] = None,
):
    """Main execution"""

    print("\n" + "=" * 70)
    print("FinnPRIO UNIFIED JUSTIFICATION POPULATOR")
    print("EPPO + GPT Researcher Combined")
    print("=" * 70)

    # Setup exclusions
    all_exclusions = EXCLUDED_DOMAINS + (exclude_domains or [])

    # Copy database
    working_db = copy_database(source_db, output_dir)

    # Initialize MCP clients
    eppo_client = EPPOMCPClient(EPPO_MCP_SERVER_PATH)
    gptr_client = GPTResearcherMCPClient(GPTR_MCP_SERVER_PATH)

    try:
        # Connect to both servers (in parallel)
        eppo_connected, gptr_connected = await asyncio.gather(
            eppo_client.connect(),
            gptr_client.connect(),
            return_exceptions=True
        )

        # Handle connection results
        if isinstance(eppo_connected, Exception):
            print(f"[EPPO] Connection exception: {eppo_connected}")
            eppo_client.connected = False
        if isinstance(gptr_connected, Exception):
            print(f"[GPTR] Connection exception: {gptr_connected}")
            gptr_client.connected = False

        if not eppo_client.connected and not gptr_client.connected:
            print("\nERROR: Neither server connected. Cannot proceed.")
            return

        # Determine assessments to process
        effective_codes = eppo_codes or EPPOCODES_TO_POPULATE or None

        if assessment_id:
            assessment_ids = [assessment_id]
        elif effective_codes:
            assessment_ids = get_all_assessment_ids(working_db, effective_codes)
            print(f"\nFiltering by EPPO codes: {effective_codes}")
            print(f"Found {len(assessment_ids)} assessment(s)")
        else:
            assessment_ids = get_all_assessment_ids(working_db)
            print(f"\nProcessing all {len(assessment_ids)} assessment(s)")

        if not assessment_ids:
            print("No assessments found!")
            return

        # Process each assessment
        for idx, aid in enumerate(assessment_ids, 1):
            if len(assessment_ids) > 1:
                print(f"\n{'#' * 70}")
                print(f"# ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
                print(f"{'#' * 70}")

            await process_assessment(
                eppo_client, gptr_client,
                working_db, aid,
                exclude_domains=all_exclusions,
                skip_existing=skip_existing,
                process_pathways=process_pathways
            )

        print("\n" + "=" * 70)
        print("COMPLETE")
        print("=" * 70)
        print(f"\nOutput database: {working_db}")

    finally:
        # Clean up
        await eppo_client.close()
        await gptr_client.close()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description='FinnPRIO Unified Justification Populator (EPPO + GPT Researcher)'
    )
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH,
                        help='Source database path')
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR,
                        help='Output directory')
    parser.add_argument('--assessment-id', type=int,
                        help='Process single assessment')
    parser.add_argument('--eppo-codes', type=str, nargs='+',
                        help='Filter by EPPO codes')
    parser.add_argument('--overwrite', action='store_true',
                        help='Overwrite existing justifications')
    parser.add_argument('--no-pathways', action='store_true',
                        help='Skip pathway questions')
    parser.add_argument('--exclude-domains', type=str, nargs='+',
                        help='Additional domains to exclude')

    args = parser.parse_args()

    asyncio.run(main(
        source_db=args.db,
        output_dir=args.output,
        assessment_id=args.assessment_id,
        eppo_codes=args.eppo_codes,
        skip_existing=not args.overwrite,
        process_pathways=not args.no_pathways,
        exclude_domains=args.exclude_domains,
    ))
