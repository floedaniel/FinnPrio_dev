"""
MCP Servers for FinnPRIO

Available servers:
- eppo_mcp_server: EPPO Global Database API integration
"""

from pathlib import Path

SERVERS_DIR = Path(__file__).parent
EPPO_SERVER = SERVERS_DIR / "eppo_mcp_server.py"
