/gpt-resercher
/brainstorm

Wire SSB (Statistics Norway) trade data into the FinnPRIO pipeline via
GPT Researcher's NATIVE MCP support — NOT as subprocess or module import.

═══════════════════════════════════════════════════════════════════════════
READ THESE FIRST (use WebFetch on each):
═══════════════════════════════════════════════════════════════════════════

GPT Researcher (the framework we use):
  • Main repo:    https://github.com/assafelovic/gpt-researcher
  • MCP config docs:
                  https://docs.gptr.dev/docs/gpt-researcher/retrievers/mcp-configs
  • MCP module README (source-level details on how mcp_configs works,
    tool selector behaviour, connection types stdio/websocket/http):
                  https://github.com/assafelovic/gpt-researcher/blob/master/gpt_researcher/mcp/README.md
  • MCP module source (client.py, tool_selector.py, research.py):
                  https://github.com/assafelovic/gpt-researcher/tree/master/gpt_researcher/mcp

FastMCP (the framework we use to BUILD the SSB MCP server):
  • Official docs: https://gofastmcp.com
  • LLM-friendly:  https://gofastmcp.com/llms-full.txt
                  (full docs as plain text — readable in one fetch)
  • GitHub repo:   https://github.com/PrefectHQ/fastmcp
  • Current version: FastMCP 3.x (released Jan 2026)
  • Install:       uv add "fastmcp"  OR  pip install fastmcp

Existing FinnPRIO reference (DO NOT call directly — extract semantics):
  C:\Dev\FinnPrio\FinnPRIO_development\python\standalone_ssb_MPC.py

═══════════════════════════════════════════════════════════════════════════
ARCHITECTURE
═══════════════════════════════════════════════════════════════════════════

GPT Researcher already does this natively:

  os.environ["RETRIEVER"] = "tavily,mcp"   # hybrid retrieval
       ↓
  GPTResearcher(query=..., mcp_configs=[...])
       ↓
  Stage 1: LLM analyses query + available MCP tools → selects relevant ones
  Stage 2: LLM calls selected tools with contextual args
       ↓
  Research context includes SSB data alongside Tavily web results

We do NOT subprocess-call ssb_query.py. We do NOT import its run().
We expose SSB as an MCP server. GPT Researcher orchestrates everything.

═══════════════════════════════════════════════════════════════════════════
TWO OPTIONS FOR THE MCP SERVER
═══════════════════════════════════════════════════════════════════════════

Option A: Use existing npm `ssb-mcp-server` (by langtind)
  + Zero build effort
  + mcp_configs entry is one line: npx -y ssb-mcp-server
  - May lack Daniel's domain knowledge (HS chapter 44 structure,
    continent-to-country mappings for pest pathways)
  - Third-party trust assumption

Option B: Build our own FastMCP server from standalone_ssb_MPC.py
  + Preserves Daniel's domain knowledge in MCP tool descriptions
  + Reuses existing tested SSB API functions verbatim
  + Full control over tool descriptions (which the GPT Researcher
    stage-1 selector reads to decide when to invoke)
  - ~50-150 lines of FastMCP wrapper code
  - Requires `fastmcp` Python dependency

RECOMMENDATION: Option B. The SSB tool functions in standalone_ssb_MPC.py
are already written, tested, and tuned to FinnPRIO use cases. Wrapping
them with FastMCP @mcp.tool decorators is mechanical. The domain
knowledge currently in SYSTEM_PROMPT becomes MCP tool descriptions.

═══════════════════════════════════════════════════════════════════════════
DESIGN QUESTIONS — RESOLVE BEFORE IMPLEMENTING
═══════════════════════════════════════════════════════════════════════════

1. **MCP Transport: stdio vs SSE/HTTP?**

   Option A: stdio (subprocess-per-researcher)
     + Default GPT Researcher pattern
     + No service to manage
     - 0.5-3s cold start × ~1386 GPTResearcher instances (63 species × 22 q)
     - Wasted if only ENT3 needs SSB

   Option B: SSE/HTTP (long-running service)
     + Single startup, server stays warm
     + Survives multiple pipeline runs
     - Background service to manage (port, lifecycle)
     - Config uses connection_url instead of command/args

   Option C: stdio but only enabled for ENT3
     + Cold start amortised over only 63 ENT3 calls
     + Other questions skip the SSB overhead entirely
     - Requires per-question conditional mcp_configs

   Which fits your orchestration model?

2. **MCP availability scope: always-on vs ENT3-only?**

   GPT Researcher's stage-1 LLM tool selector decides relevance.
   If SSB MCP is always available, the selector SHOULD only call it
   for trade-volume questions. But each MCP server adds context to
   every query's tool-selection prompt → token cost.

   Option A: Always-on, trust the selector
   Option B: Per-question conditional mcp_configs (couple with Q1 Opt C)
   Option C: Always-on with very strong tool descriptions that bias
             the selector deterministically toward trade questions

3. **Pathway + hosts + country origin: where in the DB?**

   The ENT3 query string must include these for GPT Researcher to
   construct correct SSB tool arguments. Sources:
     - Pathway label → entryPathways table?
     - Host list → assessment metadata OR EST1 justification (DAG context)?
     - Country origin → native distribution field?
     - Years → pipeline default (5)?

   Confirm exact column names against the actual schema.

4. **MCP server skeleton (FastMCP 3.x):**

   ```python
   # ssb_mcp_server.py
   from fastmcp import FastMCP
   from ssb_query_lib import (   # extracted from standalone_ssb_MPC.py
       ssb_search_tables, ssb_get_metadata,
       ssb_search_codes, ssb_query_data,
   )

   mcp = FastMCP("ssb-trade")

   @mcp.tool
   def search_tables(query: str, lang: str = "en") -> str:
       """Search SSB Statistikkbanken for tables by keyword.
       Returns table IDs, titles, variables, last period.
       Useful for finding the right table before querying data —
       e.g. table 08801 for annual foreign trade by HS code & country."""
       return ssb_search_tables(query, lang)

   # ... three more @mcp.tool decorators

   if __name__ == "__main__":
       mcp.run()  # stdio by default; set transport="sse" for HTTP
   ```

   Pipeline config (Option B from Q1):
   ```python
   mcp_configs = [{
       "name": "ssb_trade",
       "command": "python",
       "args": ["ssb_mcp_server.py"],
       "env": {}  # no API key — SSB is open data
   }]
   ```

   Pipeline config (SSE from Q1):
   ```python
   mcp_configs = [{
       "name": "ssb_trade",
       "connection_url": "http://localhost:8765/sse",
       "connection_type": "sse",
   }]
   ```

   Verify this matches the current `gpt_researcher/mcp` API by
   reading the MCP module README above.

5. **Domain knowledge: tool descriptions vs question prompt?**

   standalone_ssb_MPC.py's SYSTEM_PROMPT contains:
     - HS chapter mappings (Ch 06, 07, 08, 10, 12, 44)
     - Genus-specific HS codes (4403.91 oak, .92 beech, …)
     - Continent-to-country expansions (Asia → CN, JP, KR, …)
     - Output structure rules (aggregate first, then per-code)

   This splits across two places in the MCP architecture:
     a) MCP tool docstrings — read by stage-1 selector
     b) ENT3 question prompt — read by stage-2 args generation

   Option A: Minimal docstrings, full knowledge in question prompt
   Option B: Rich docstrings, minimal question prompt
   Option C: Both rich (some duplication, each level has what it needs)

6. **Fallback if MCP fails?**

   With RETRIEVER=tavily,mcp, does GPT Researcher gracefully degrade
   to Tavily-only if MCP errors, or does it hard-fail?
   Verify against the MCP module source before deciding fallback policy.

═══════════════════════════════════════════════════════════════════════════
IMPLEMENTATION TASKS (after Q1-Q6 answered)
═══════════════════════════════════════════════════════════════════════════

  ✓ Read standalone_ssb_MPC.py — extract the 4 SSB API helper functions
  ✓ Create ssb_query_lib.py — pure functions, no Anthropic SDK, no
    agentic loop (just urllib calls returning JSON strings)
  ✓ Create ssb_mcp_server.py — FastMCP wrapper exposing the 4 functions
    as MCP tools with rich domain-aware docstrings
  ✓ Refactor standalone_ssb_MPC.py to import from ssb_query_lib.py
    (preserve CLI behaviour — backwards-compatible)
  ✓ Test the MCP server in isolation:
        uv run mcp dev ssb_mcp_server.py
    Confirm 4 tools registered, callable, return real SSB data
  ✓ Update populate_finnprio_justifications.py:
        - Add "mcp" to RETRIEVER env var
        - Pass mcp_configs= to GPTResearcher() init
        - For ENT3: build query string with pathway + hosts + origin
        - If Q1 Option C: only attach mcp_configs when processing ENT3
  ✓ End-to-end test: question_filter=["ENT3"], one species
        - MCP server starts
        - Stage-1 selector picks SSB tools
        - Trade volumes appear in justification
        - Audit log shows which MCP tools called with which args

═══════════════════════════════════════════════════════════════════════════
DELIVERABLES
═══════════════════════════════════════════════════════════════════════════

  1. ssb_query_lib.py        — pure SSB API functions
  2. ssb_mcp_server.py       — FastMCP server wrapping them
  3. standalone_ssb_MPC.py   — refactored to import from lib (CLI unchanged)
  4. populate_finnprio_justifications.py — modified with mcp_configs

  Console output should narrate the MCP lifecycle:
    🔌 Starting SSB MCP server (stdio)…
    ✅ SSB MCP ready — 4 tools: search_tables, get_metadata,
                      search_codes, query_data
    📊 Stage-1 selector picked: ssb_trade.query_data for ENT3
    📊 Stage-2: query_data(table=08801, valueCodes=[4403.97*], …)
    ✅ SSB context injected into ENT3 research
    🔌 SSB MCP server stopped

═══════════════════════════════════════════════════════════════════════════
DO NOT
═══════════════════════════════════════════════════════════════════════════

  ✗ Subprocess-call standalone_ssb_MPC.py from the pipeline
  ✗ Import standalone_ssb_MPC.py's run() function
  ✗ Duplicate the agentic loop — GPT Researcher IS the agentic loop
  ✗ Hardcode HS code mappings in Python — let the LLM reason
  ✗ Skip reading the GPT Researcher MCP README — it documents the exact
    schema for mcp_configs and the tool-selector behaviour we depend on

Ask the design questions first. Wait for answers. Then implement.
