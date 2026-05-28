#!/usr/bin/env python3
"""
ssb_query.py — Fetch SSB trade data for FinnPRIO ENT 3.

Usage:
    python ssb_query.py            # run with built-in prompt
    python ssb_query.py -v         # verbose (show tool calls)
    python ssb_query.py "custom question here"  # override prompt

Requires: pip install anthropic
"""

import argparse
import json
import os
import sys
from pathlib import Path
from textwrap import dedent

# ── Load API key from file ────────────────────────────────────────────────
API_KEY_FILE = Path(
    r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\anthropic_key.txt"
)
if not os.environ.get("ANTHROPIC_API_KEY"):
    if API_KEY_FILE.exists():
        os.environ["ANTHROPIC_API_KEY"] = API_KEY_FILE.read_text().strip()
    else:
        sys.exit(f"API key not found: {API_KEY_FILE}")

from anthropic import Anthropic

from ssb_query_lib import ssb_search_tables, ssb_get_metadata, ssb_search_codes, ssb_query_data


# ── Tool definitions for Claude ───────────────────────────────────────────

TOOLS = [
    {
        "name": "ssb_search_tables",
        "description": "Search SSB Statistikkbanken for tables by keyword. "
                       "Returns table IDs, titles, variables, and last period.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "Search keywords (Norwegian or English)"},
                "lang": {"type": "string", "enum": ["en", "no"], "default": "en"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "ssb_get_metadata",
        "description": "Get metadata for an SSB table: variable names, "
                       "value codes and labels (first 30 per variable), "
                       "and elimination info.",
        "input_schema": {
            "type": "object",
            "properties": {
                "table_id": {"type": "string",
                             "description": "5-digit SSB table ID, e.g. '08801'"},
                "lang": {"type": "string", "enum": ["en", "no"], "default": "en"},
            },
            "required": ["table_id"],
        },
    },
    {
        "name": "ssb_search_codes",
        "description": "Search for specific value codes within a table variable. "
                       "Use this to find HS commodity codes, region codes, etc. "
                       "E.g. search variable 'Varekoder' for 'birch' or '4403'.",
        "input_schema": {
            "type": "object",
            "properties": {
                "table_id": {"type": "string"},
                "variable": {"type": "string",
                             "description": "Variable ID from metadata, "
                                            "e.g. 'Varekoder', 'Region'"},
                "search": {"type": "string",
                           "description": "Search term to match in code or label"},
                "lang": {"type": "string", "enum": ["en", "no"], "default": "en"},
            },
            "required": ["table_id", "variable", "search"],
        },
    },
    {
        "name": "ssb_query_data",
        "description": dedent("""\
            Query data from an SSB table using POST with selection filters.
            Returns flattened rows with labels and values.

            Selection format — list of dicts, each with:
              - variableCode: variable ID (e.g. "Varekoder", "ImpEks", "Tid")
              - valueCodes: list of code patterns. Supports SSB wildcards:
                  * = any characters, ? = single character
                  top(N) = N most recent, from(X) = from value X onward

            Example selection for wood imports, last 3 years:
            [
              {"variableCode": "Varekoder", "valueCodes": ["44039700*"]},
              {"variableCode": "ImpEks", "valueCodes": ["1"]},
              {"variableCode": "Land", "valueCodes": ["*"]},
              {"variableCode": "ContentsCode", "valueCodes": ["Mengde1","Verdi"]},
              {"variableCode": "Tid", "valueCodes": ["top(3)"]}
            ]

            Max 800,000 cells per query. Use filters to stay under the limit.
        """),
        "input_schema": {
            "type": "object",
            "properties": {
                "table_id": {"type": "string"},
                "selection": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "variableCode": {"type": "string"},
                            "valueCodes": {
                                "type": "array",
                                "items": {"type": "string"},
                            },
                        },
                        "required": ["variableCode", "valueCodes"],
                    },
                },
                "lang": {"type": "string", "enum": ["en", "no"], "default": "en"},
            },
            "required": ["table_id", "selection"],
        },
    },
]

TOOL_DISPATCH = {
    "ssb_search_tables": lambda args: ssb_search_tables(
        args["query"], args.get("lang", "en")),
    "ssb_get_metadata": lambda args: ssb_get_metadata(
        args["table_id"], args.get("lang", "en")),
    "ssb_search_codes": lambda args: ssb_search_codes(
        args["table_id"], args["variable"], args["search"],
        args.get("lang", "en")),
    "ssb_query_data": lambda args: ssb_query_data(
        args["table_id"], args["selection"], args.get("lang", "en")),
}

SYSTEM_PROMPT = dedent("""\
    You are a data assistant with access to Statistics Norway (SSB) via
    their PxWebApi v2. You answer questions about Norwegian statistics
    by searching for relevant tables, inspecting their metadata, and
    querying actual data.

    Key SSB tables:
    - 08801: Annual foreign trade by HS commodity code and country
    - 08799: Monthly foreign trade by HS commodity code and country

    HS code chapters relevant for trade in biological commodities:
    - Ch 06: Live trees, plants, cuttings, roots
    - Ch 07: Edible vegetables
    - Ch 08: Edible fruit and nuts
    - Ch 10: Cereals
    - Ch 12: Oil seeds, plants, straw, fodder
    - Ch 44: Wood and articles of wood
      - 4403: Roundwood (genus-level codes: .91 oak, .92 beech,
        .95/.96 birch, .97 poplar, .99 other non-coniferous)
      - 4407: Sawnwood (genus-level: .91 oak, .92 beech, .93 maple,
        .94 cherry/Prunus, .95 ash, .96 birch, .97 poplar,
        .99 other non-coniferous)
      - 4415: Packaging wood (crates, pallets)

    ## Country / region handling
    The "country" field in the prompt may contain:
    - A specific country name (e.g. "China", "Italy", "Japan")
    - A continent or region (e.g. "Asia", "Europe", "South America",
      "East Asia", "Mediterranean")
    - Empty or "all" → query all countries, report top sources

    When a continent or region is given:
    1. First query with Land="*" (all countries) to get the full dataset
    2. Then filter/aggregate results for countries belonging to that
       region in your summary
    3. SSB table 11009 has data by handelsområde/verdensdel (trade
       region/continent) — use this as an alternative if it fits better

    Common continent-to-country mappings for pest risk context:
    - Asia: China, Japan, South Korea, India, Vietnam, Thailand,
      Turkey, Iran, Pakistan, Indonesia, Malaysia, etc.
    - East Asia: China, Japan, South Korea, Taiwan, Mongolia
    - Southeast Asia: Vietnam, Thailand, Indonesia, Malaysia,
      Philippines, Myanmar, Cambodia, Laos
    - Mediterranean: Italy, Spain, Greece, Turkey, France (south),
      Portugal, Croatia, Tunisia, Morocco, Algeria, Egypt, Israel
    - North America: USA, Canada, Mexico
    - South America: Brazil, Argentina, Chile, Colombia, Peru, etc.

    When a region is specified, report BOTH:
    - Total imports from ALL countries (for overall volume context)
    - Imports specifically from the specified region/countries
      (for pathway risk relevance)

    ## Output structure
    Structure your answer as follows:

    1. A short HS code coverage table (which genera have own codes,
       which fall under catch-alls)
    2. TOTAL annual imports across all source countries (aggregated
       across all relevant HS codes) — one summary table, not per-code
    3. A single concluding data paragraph for the assessment

    Keep it concise. Do NOT repeat per-HS-code breakdowns for every
    code — aggregate first, then show per-code detail only if needed.

    ## Years handling
    - If years is empty or not specified: use top(3) for 3 most recent
    - If a number: use top(N) for N most recent years
    - If a range like "2020-2024": use from(2020) and filter

    Always query real data — never make up numbers. If the data isn't
    available at the level of detail needed, say so and provide what is
    available.
""")


# ── Agent loop ────────────────────────────────────────────────────────────

def run(prompt: str, verbose: bool = False) -> str:
    """Run the agent: prompt → SSB tool calls → final answer."""
    client = Anthropic()
    messages = [{"role": "user", "content": prompt}]

    while True:
        if verbose:
            print(f"  → Calling Claude ({len(messages)} messages)...",
                  file=sys.stderr)

        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=4096,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )

        # Collect tool uses and text
        tool_uses = []
        text_parts = []
        for block in response.content:
            if block.type == "tool_use":
                tool_uses.append(block)
            elif block.type == "text":
                text_parts.append(block.text)

        # If no tool calls, we're done
        if not tool_uses:
            return "\n".join(text_parts)

        # Execute tool calls
        messages.append({"role": "assistant", "content": response.content})
        tool_results = []
        for tu in tool_uses:
            fn = TOOL_DISPATCH.get(tu.name)
            if not fn:
                result = json.dumps({"error": f"Unknown tool: {tu.name}"})
            else:
                if verbose:
                    print(f"  → Tool: {tu.name}({json.dumps(tu.input, ensure_ascii=False)[:120]})",
                          file=sys.stderr)
                try:
                    result = fn(tu.input)
                except Exception as e:
                    result = json.dumps({"error": str(e)})
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tu.id,
                "content": result,
            })
        messages.append({"role": "user", "content": tool_results})

        # Safety: max 10 iterations
        if len(messages) > 20:
            return ("(Reached max iterations)\n\n"
                    + "\n".join(text_parts))


# ── PROMPT ────────────────────────────────────────────────────────────────

DEFAULT_PROMPT = dedent("""\
    ENT 3: How large a volume of the considered host plant commodity is
    traded into Norway annually?

    Pathway: plants for planting

    Host list: Pinus banksiana, Pinus caribaea var. bahamensis, Pinus caribaea var. hondurensis, Pinus contorta, Pinus echinata, Pinus elliottii, Pinus glabra, Pinus halepensis, Pinus mugo, Pinus nigra subsp. laricio, Pinus palustris, Pinus pinaster, Pinus pinea, Pinus resinosa, Pinus strobus, Pinus sylvestris, Pinus taeda, Pinus virginiana, Cryptomeria sp.
    
    Country of origin:  Albania, Canada, France, Italy, Mexico, Puerto Rico, Turks & Caicos Islands, United States.
    
    Years: 5

    Find the annual import volumes (tonnes and NOK) for the Pathway of these host genera into Norway. Use SSB trade data.
    Identify which host genera have genus-specific HS codes and which
    fall under catch-all categories.
""")

# ── CLI ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Query SSB data using natural language.")
    parser.add_argument("prompt", nargs="?",
                        help="Override the built-in prompt")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show tool calls on stderr")
    args = parser.parse_args()

    prompt = args.prompt or DEFAULT_PROMPT
    print(run(prompt, verbose=args.verbose))


if __name__ == "__main__":
    main()