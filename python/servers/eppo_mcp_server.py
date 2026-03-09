"""
EPPO MCP Server - EPPO Global Database API Integration

Provides MCP tools for accessing EPPO plant pest data:
- Distribution data
- Host plants
- Categorization (regulatory status)
- Taxonomy
- Documents and datasheets

Features:
- SQLite caching (7-day TTL)
- Rate limiting (60 requests per 10 seconds)
- Async HTTP client
- MCP protocol compliance

Requirements:
- pip install mcp httpx aiosqlite

Usage:
    python eppo_mcp_server.py

Or as MCP server in client configuration.
"""

import os
import sys
import json
import asyncio
import hashlib
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Any
import logging

# MCP imports
try:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import Tool, TextContent
except ImportError:
    print("MCP package not found. Install with: pip install mcp")
    sys.exit(1)

# HTTP client
try:
    import httpx
except ImportError:
    print("httpx package not found. Install with: pip install httpx")
    sys.exit(1)

# Async SQLite for caching
try:
    import aiosqlite
except ImportError:
    print("aiosqlite package not found. Install with: pip install aiosqlite")
    sys.exit(1)

# =============================================================================
# CONFIGURATION
# =============================================================================

# API Configuration
EPPO_API_BASE = "https://api.eppo.int/gd/v2"
EPPO_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\EPPO_beta.txt"

# Cache Configuration
CACHE_DIR = Path(__file__).parent.parent / "cache"
CACHE_DB = CACHE_DIR / "eppo_cache.db"
CACHE_TTL_DAYS = 7

# Rate Limiting: 60 requests per 10 seconds
RATE_LIMIT_REQUESTS = 60
RATE_LIMIT_WINDOW_SECONDS = 10

# Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# =============================================================================
# RATE LIMITER
# =============================================================================

class RateLimiter:
    """Token bucket rate limiter for EPPO API (60 req / 10 sec)"""

    def __init__(self, max_requests: int = RATE_LIMIT_REQUESTS,
                 window_seconds: int = RATE_LIMIT_WINDOW_SECONDS):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.requests: List[float] = []
        self._lock = asyncio.Lock()

    async def acquire(self):
        """Wait until a request slot is available"""
        async with self._lock:
            now = asyncio.get_event_loop().time()

            # Remove old requests outside window
            cutoff = now - self.window_seconds
            self.requests = [t for t in self.requests if t > cutoff]

            # If at limit, wait for oldest request to expire
            if len(self.requests) >= self.max_requests:
                wait_time = self.requests[0] - cutoff + 0.1
                if wait_time > 0:
                    logger.debug(f"Rate limit reached, waiting {wait_time:.2f}s")
                    await asyncio.sleep(wait_time)
                    # Clean up again after waiting
                    now = asyncio.get_event_loop().time()
                    cutoff = now - self.window_seconds
                    self.requests = [t for t in self.requests if t > cutoff]

            # Record this request
            self.requests.append(now)

# =============================================================================
# CACHE MANAGER
# =============================================================================

class CacheManager:
    """SQLite-based cache for EPPO API responses"""

    def __init__(self, db_path: Path = CACHE_DB, ttl_days: int = CACHE_TTL_DAYS):
        self.db_path = db_path
        self.ttl_days = ttl_days
        self._initialized = False

    async def _ensure_initialized(self):
        """Create cache database and table if needed"""
        if self._initialized:
            return

        self.db_path.parent.mkdir(parents=True, exist_ok=True)

        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("""
                CREATE TABLE IF NOT EXISTS cache (
                    cache_key TEXT PRIMARY KEY,
                    data TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    expires_at TIMESTAMP NOT NULL
                )
            """)
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_expires ON cache(expires_at)
            """)
            await db.commit()

        self._initialized = True
        logger.info(f"Cache initialized at {self.db_path}")

    def _make_key(self, endpoint: str, params: Dict = None) -> str:
        """Create unique cache key from endpoint and params"""
        key_data = f"{endpoint}:{json.dumps(params or {}, sort_keys=True)}"
        return hashlib.sha256(key_data.encode()).hexdigest()[:32]

    async def get(self, endpoint: str, params: Dict = None) -> Optional[Dict]:
        """Get cached response if valid"""
        await self._ensure_initialized()

        cache_key = self._make_key(endpoint, params)

        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(
                "SELECT data FROM cache WHERE cache_key = ? AND expires_at > datetime('now')",
                (cache_key,)
            ) as cursor:
                row = await cursor.fetchone()
                if row:
                    logger.debug(f"Cache hit: {endpoint}")
                    return json.loads(row[0])

        logger.debug(f"Cache miss: {endpoint}")
        return None

    async def set(self, endpoint: str, data: Dict, params: Dict = None):
        """Store response in cache"""
        await self._ensure_initialized()

        cache_key = self._make_key(endpoint, params)
        expires_at = datetime.now() + timedelta(days=self.ttl_days)

        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """INSERT OR REPLACE INTO cache (cache_key, data, expires_at)
                   VALUES (?, ?, ?)""",
                (cache_key, json.dumps(data), expires_at.isoformat())
            )
            await db.commit()

        logger.debug(f"Cached: {endpoint}")

    async def clear_expired(self):
        """Remove expired cache entries"""
        await self._ensure_initialized()

        async with aiosqlite.connect(self.db_path) as db:
            result = await db.execute(
                "DELETE FROM cache WHERE expires_at < datetime('now')"
            )
            await db.commit()
            logger.info(f"Cleared {result.rowcount} expired cache entries")

# =============================================================================
# EPPO API CLIENT
# =============================================================================

class EPPOClient:
    """Async client for EPPO Global Database API v2"""

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.base_url = EPPO_API_BASE
        self.rate_limiter = RateLimiter()
        self.cache = CacheManager()
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client"""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                headers={
                    "X-Api-Key": self.api_key,
                    "Accept": "application/json"
                },
                timeout=30.0
            )
        return self._client

    async def close(self):
        """Close HTTP client"""
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def _request(self, endpoint: str, use_cache: bool = True) -> Dict:
        """Make API request with caching and rate limiting"""

        # Check cache first
        if use_cache:
            cached = await self.cache.get(endpoint)
            if cached is not None:
                return cached

        # Rate limit
        await self.rate_limiter.acquire()

        # Make request
        client = await self._get_client()
        url = f"{self.base_url}{endpoint}"

        try:
            response = await client.get(url)
            response.raise_for_status()
            data = response.json()

            # Cache successful response
            if use_cache:
                await self.cache.set(endpoint, data)

            return data

        except httpx.HTTPStatusError as e:
            if e.response.status_code == 429:
                logger.warning("Rate limit exceeded, waiting...")
                await asyncio.sleep(10)
                return await self._request(endpoint, use_cache)
            raise

    # -------------------------------------------------------------------------
    # TAXON ENDPOINTS
    # -------------------------------------------------------------------------

    async def get_overview(self, eppo_code: str) -> Dict:
        """Get basic taxon information"""
        return await self._request(f"/taxons/taxon/{eppo_code}/overview")

    async def get_names(self, eppo_code: str) -> Dict:
        """Get all scientific and common names"""
        return await self._request(f"/taxons/taxon/{eppo_code}/names")

    async def get_taxonomy(self, eppo_code: str) -> Dict:
        """Get taxonomic classification"""
        return await self._request(f"/taxons/taxon/{eppo_code}/taxonomy")

    async def get_hosts(self, eppo_code: str) -> Dict:
        """Get host plants"""
        return await self._request(f"/taxons/taxon/{eppo_code}/hosts")

    async def get_distribution(self, eppo_code: str) -> Dict:
        """Get geographic distribution"""
        return await self._request(f"/taxons/taxon/{eppo_code}/distribution")

    async def get_categorization(self, eppo_code: str) -> Dict:
        """Get regulatory categorization by country"""
        return await self._request(f"/taxons/taxon/{eppo_code}/categorization")

    async def get_documents(self, eppo_code: str) -> Dict:
        """Get datasheets and documents"""
        return await self._request(f"/taxons/taxon/{eppo_code}/documents")

    async def get_pests(self, eppo_code: str) -> Dict:
        """Get pests affecting this taxon (for host plants)"""
        return await self._request(f"/taxons/taxon/{eppo_code}/pests")

    async def get_vectors(self, eppo_code: str) -> Dict:
        """Get vector organisms"""
        return await self._request(f"/taxons/taxon/{eppo_code}/vectors")

    async def get_bca(self, eppo_code: str) -> Dict:
        """Get biological control agents"""
        return await self._request(f"/taxons/taxon/{eppo_code}/bca")

    # -------------------------------------------------------------------------
    # REFERENCE ENDPOINTS
    # -------------------------------------------------------------------------

    async def get_countries_states(self) -> Dict:
        """Get reference list of countries and states"""
        return await self._request("/references/countriesStates")

    async def get_distribution_status(self) -> Dict:
        """Get reference list of distribution status codes"""
        return await self._request("/references/distributionStatus")

    async def get_qlist(self) -> Dict:
        """Get quarantine list classifications"""
        return await self._request("/references/qList")

    # -------------------------------------------------------------------------
    # SEARCH ENDPOINTS
    # -------------------------------------------------------------------------

    async def search_by_name(self, name: str) -> Dict:
        """Search for EPPO codes by taxon name"""
        # URL encode the name
        encoded = httpx.URL("", params={"term": name}).params
        return await self._request(f"/tools/name2codes?term={encoded['term']}", use_cache=False)

# =============================================================================
# DATA FORMATTERS
# =============================================================================

def format_distribution(data: Dict, pest_name: str = "") -> str:
    """Format distribution data as readable text"""
    if not data:
        return "No distribution data available."

    # Handle list or dict response
    records = data if isinstance(data, list) else data.get('data', [])

    if not records:
        return "No distribution records found in EPPO Global Database."

    # Group by presence status
    present_countries = set()
    absent_countries = set()

    for record in records:
        country = record.get('country_iso', 'Unknown')
        status = record.get('peststatus', '')

        if 'present' in status.lower():
            present_countries.add(country)
        elif 'absent' in status.lower():
            absent_countries.add(country)

    lines = []
    if pest_name:
        lines.append(f"Distribution data for {pest_name} from EPPO Global Database:")

    if present_countries:
        lines.append(f"\nPresent in {len(present_countries)} countries/regions: {', '.join(sorted(present_countries))}")

    if absent_countries:
        lines.append(f"\nConfirmed absent in: {', '.join(sorted(absent_countries))}")

    return '\n'.join(lines) if lines else "No distribution summary available."


def format_hosts(data: Dict, pest_name: str = "") -> str:
    """Format host data as readable text"""
    if not data:
        return "No host data available."

    records = data if isinstance(data, list) else data.get('data', [])

    if not records:
        return "No host plants recorded in EPPO Global Database."

    # Group by classification
    major_hosts = []
    minor_hosts = []
    other_hosts = []

    for record in records:
        host_name = record.get('full_name', record.get('eppocode', 'Unknown'))
        classification = record.get('classification', '').lower()

        if 'major' in classification:
            major_hosts.append(host_name)
        elif 'minor' in classification:
            minor_hosts.append(host_name)
        else:
            other_hosts.append(host_name)

    lines = []
    if pest_name:
        lines.append(f"Host plants for {pest_name} from EPPO Global Database:")

    if major_hosts:
        lines.append(f"\nMajor hosts ({len(major_hosts)}): {', '.join(sorted(major_hosts)[:20])}")
        if len(major_hosts) > 20:
            lines.append(f"  ... and {len(major_hosts) - 20} more")

    if minor_hosts:
        lines.append(f"\nMinor hosts ({len(minor_hosts)}): {', '.join(sorted(minor_hosts)[:10])}")
        if len(minor_hosts) > 10:
            lines.append(f"  ... and {len(minor_hosts) - 10} more")

    total = len(major_hosts) + len(minor_hosts) + len(other_hosts)
    lines.append(f"\nTotal: {total} host species recorded")

    return '\n'.join(lines) if lines else "No host summary available."


def format_categorization(data: Dict, pest_name: str = "") -> str:
    """Format regulatory categorization as readable text"""
    if not data:
        return "No categorization data available."

    records = data if isinstance(data, list) else data.get('data', [])

    if not records:
        return "No regulatory categorization found in EPPO Global Database."

    # Group by list type
    a1_list = []
    a2_list = []
    alert_list = []
    other = []

    for record in records:
        country = record.get('country_iso', record.get('rppo', 'Unknown'))
        qlist = record.get('qlist', '').upper()

        if 'A1' in qlist:
            a1_list.append(country)
        elif 'A2' in qlist:
            a2_list.append(country)
        elif 'ALERT' in qlist:
            alert_list.append(country)
        else:
            other.append(f"{country}: {qlist}")

    lines = []
    if pest_name:
        lines.append(f"Regulatory status for {pest_name} from EPPO Global Database:")

    if a1_list:
        lines.append(f"\nA1 List (absent, regulated): {', '.join(sorted(a1_list))}")
    if a2_list:
        lines.append(f"\nA2 List (present, regulated): {', '.join(sorted(a2_list))}")
    if alert_list:
        lines.append(f"\nAlert List: {', '.join(sorted(alert_list))}")

    return '\n'.join(lines) if lines else "No regulatory summary available."


def format_comprehensive(overview: Dict, distribution: Dict, hosts: Dict,
                         categorization: Dict, pest_name: str) -> str:
    """Format comprehensive pest information"""
    sections = []

    # Overview
    if overview:
        data = overview.get('data', overview)
        if isinstance(data, dict):
            sections.append(f"## {pest_name}")
            if data.get('full_name'):
                sections.append(f"Scientific name: {data['full_name']}")
            if data.get('eppocode'):
                sections.append(f"EPPO Code: {data['eppocode']}")
            if data.get('type'):
                sections.append(f"Type: {data['type']}")

    # Distribution
    sections.append("\n## Distribution")
    sections.append(format_distribution(distribution))

    # Hosts
    sections.append("\n## Host Plants")
    sections.append(format_hosts(hosts))

    # Regulatory
    sections.append("\n## Regulatory Status")
    sections.append(format_categorization(categorization))

    return '\n'.join(sections)

# =============================================================================
# MCP SERVER
# =============================================================================

def load_api_key() -> str:
    """Load EPPO API key from file"""
    try:
        with open(EPPO_API_KEY_FILE, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        logger.error(f"API key file not found: {EPPO_API_KEY_FILE}")
        return ""

# Create server instance
server = Server("eppo-mcp")

# Global client (initialized on first use)
_client: Optional[EPPOClient] = None

async def get_client() -> EPPOClient:
    """Get or create EPPO client"""
    global _client
    if _client is None:
        api_key = load_api_key()
        if not api_key:
            raise ValueError("EPPO API key not configured")
        _client = EPPOClient(api_key)
    return _client

# =============================================================================
# MCP TOOLS
# =============================================================================

@server.list_tools()
async def list_tools() -> List[Tool]:
    """List available EPPO tools"""
    return [
        Tool(
            name="eppo_get_pest_info",
            description="Get comprehensive pest information from EPPO including distribution, hosts, and regulatory status",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code (e.g., XYLEFA for Xylella fastidiosa)"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_distribution",
            description="Get geographic distribution data for a pest from EPPO Global Database",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code (e.g., XYLEFA)"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_hosts",
            description="Get host plants for a pest from EPPO Global Database",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code (e.g., XYLEFA)"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_categorization",
            description="Get regulatory categorization (A1/A2 lists, alert status) for a pest",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code (e.g., XYLEFA)"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_taxonomy",
            description="Get taxonomic classification for a taxon",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_vectors",
            description="Get vector organisms that transmit this pest/pathogen",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_get_bca",
            description="Get biological control agents for a pest",
            inputSchema={
                "type": "object",
                "properties": {
                    "eppo_code": {
                        "type": "string",
                        "description": "EPPO code"
                    }
                },
                "required": ["eppo_code"]
            }
        ),
        Tool(
            name="eppo_search",
            description="Search for EPPO code by taxon name",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Scientific or common name to search"
                    }
                },
                "required": ["name"]
            }
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: Dict) -> List[TextContent]:
    """Handle tool calls"""
    try:
        client = await get_client()

        if name == "eppo_get_pest_info":
            eppo_code = arguments["eppo_code"].upper()

            # Fetch all data in parallel
            overview, distribution, hosts, categorization = await asyncio.gather(
                client.get_overview(eppo_code),
                client.get_distribution(eppo_code),
                client.get_hosts(eppo_code),
                client.get_categorization(eppo_code),
                return_exceptions=True
            )

            # Handle errors gracefully
            overview = overview if not isinstance(overview, Exception) else {}
            distribution = distribution if not isinstance(distribution, Exception) else {}
            hosts = hosts if not isinstance(hosts, Exception) else {}
            categorization = categorization if not isinstance(categorization, Exception) else {}

            pest_name = overview.get('data', {}).get('full_name', eppo_code) if isinstance(overview, dict) else eppo_code
            result = format_comprehensive(overview, distribution, hosts, categorization, pest_name)

        elif name == "eppo_get_distribution":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_distribution(eppo_code)
            result = format_distribution(data, eppo_code)

        elif name == "eppo_get_hosts":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_hosts(eppo_code)
            result = format_hosts(data, eppo_code)

        elif name == "eppo_get_categorization":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_categorization(eppo_code)
            result = format_categorization(data, eppo_code)

        elif name == "eppo_get_taxonomy":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_taxonomy(eppo_code)
            result = json.dumps(data, indent=2)

        elif name == "eppo_get_vectors":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_vectors(eppo_code)
            result = json.dumps(data, indent=2)

        elif name == "eppo_get_bca":
            eppo_code = arguments["eppo_code"].upper()
            data = await client.get_bca(eppo_code)
            result = json.dumps(data, indent=2)

        elif name == "eppo_search":
            search_name = arguments["name"]
            data = await client.search_by_name(search_name)
            if data:
                codes = data if isinstance(data, list) else data.get('data', [])
                if codes:
                    result = f"Found EPPO codes for '{search_name}':\n" + \
                             '\n'.join([f"  {c.get('eppocode', c)}: {c.get('full_name', '')}"
                                       for c in codes[:10]])
                else:
                    result = f"No EPPO codes found for '{search_name}'"
            else:
                result = f"No results for '{search_name}'"
        else:
            result = f"Unknown tool: {name}"

        return [TextContent(type="text", text=result)]

    except Exception as e:
        logger.error(f"Tool error: {e}")
        return [TextContent(type="text", text=f"Error: {str(e)}")]

# =============================================================================
# MAIN
# =============================================================================

async def main():
    """Run the MCP server"""
    logger.info("Starting EPPO MCP Server...")
    logger.info(f"Cache location: {CACHE_DB}")

    # Clean expired cache on startup
    cache = CacheManager()
    await cache.clear_expired()

    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
