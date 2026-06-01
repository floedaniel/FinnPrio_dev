#!/usr/bin/env python3
"""
nibio_query.py — Fetch NIBIO Totalkalkylen data for FinnPRIO IMP1/EST2/IMP2.2.

Usage:
    python standalone_nibio_MPC.py            # run with built-in prompt
    python standalone_nibio_MPC.py -v         # verbose (show tool calls)
    python standalone_nibio_MPC.py "custom question here"  # override prompt

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

from nibio_query_lib import nibio_list_groups, nibio_list_posts, nibio_get_data


# ── Tool definitions for Claude ───────────────────────────────────────────

TOOLS = [
    {
        "name": "nibio_list_groups",
        "description": dedent("""\
            List top-level agricultural product groups in NIBIO Totalkalkylen.
            Returns group IDs and Norwegian names. Optionally filter by keyword.

            Key groups for FinnPRIO impact assessment:
            - 2606: Korn, erter og oljefrø                       → cereals/legumes/oilseeds
            - 2607: Poteter                                      → potatoes
            - 2608: Hagebruksprodukter                           → horticulture (vegetables, fruit, berries)
            - 2609: Andre planteprodukter                        → other plant products
            - 2641: Jordbruksareal fordelt på vekster (1000 daa) → agricultural area by crop
            - 2642: Areal, avling, anvendelser. Produksjon       → total crop production (tonn)
        """),
        "input_schema": {
            "type": "object",
            "properties": {
                "search": {
                    "type": "string",
                    "description": "Optional keyword filter, case-insensitive substring "
                                   "match on group name (Norwegian). E.g. 'potet', 'korn', 'areal'.",
                },
            },
            "required": [],
        },
    },
    {
        "name": "nibio_list_posts",
        "description": dedent("""\
            List all line items (posts) within a product group.
            Posts represent specific accounting items: total production, sales by
            end-use, seed, waste, etc. For impact assessment prefer posts named
            'Salg' (sales), 'Produksjon' (production), or 'Total'.
        """),
        "input_schema": {
            "type": "object",
            "properties": {
                "group_id": {
                    "type": "integer",
                    "description": "Numeric ID from nibio_list_groups, e.g. 2607.",
                },
                "search": {
                    "type": "string",
                    "description": "Optional keyword filter, case-insensitive substring "
                                   "match on post name (Norwegian).",
                },
            },
            "required": ["group_id"],
        },
    },
    {
        "name": "nibio_get_data",
        "description": dedent("""\
            Get time series production data for a specific post (line item).
            Returns per-year records with:
              - aar:     year
              - kvantum: production/sales quantity (typically 1000 tonn)
              - pris:    farmgate price (typically kr/100 kg)
              - verdi:   total value (typically mill. kr)

            The most recent year is a budget estimate (budsjettanslag).
        """),
        "input_schema": {
            "type": "object",
            "properties": {
                "post_id": {
                    "type": "integer",
                    "description": "Numeric ID from nibio_list_posts.",
                },
                "years_back": {
                    "type": "integer",
                    "description": "Number of recent years to return (default 15, "
                                   "max ~68 back to 1959). Pass 0 for the full series.",
                    "default": 15,
                },
            },
            "required": ["post_id"],
        },
    },
]

TOOL_DISPATCH = {
    "nibio_list_groups": lambda args: nibio_list_groups(
        args.get("search", "")),
    "nibio_list_posts": lambda args: nibio_list_posts(
        args["group_id"], args.get("search", "")),
    "nibio_get_data": lambda args: nibio_get_data(
        args["post_id"], args.get("years_back", 15)),
}

SYSTEM_PROMPT = dedent("""\
    You are a data assistant with access to NIBIO Totalkalkylen, the
    Norwegian national accounting statistics for agriculture (1959–2026).
    You answer questions about Norwegian crop production volumes, prices,
    and values by navigating product groups → posts → time series.

    ## Workflow
    1. Use nibio_list_groups (optionally with a search keyword) to find
       the relevant top-level product group ID.
    2. Use nibio_list_posts(group_id) to list the line items in that
       group and pick the right post.
    3. Use nibio_get_data(post_id, years_back) to retrieve the time
       series.

    ## Key groups
    - 2606: Korn, erter og oljefrø  → cereals, legumes, oilseeds
    - 2607: Poteter                 → potatoes (table, processing, starch)
    - 2608: Hagebruksprodukter      → vegetables, fruit, berries, ornamentals
    - 2609: Andre planteprodukter   → other plant products
    - 2641: Jordbruksareal fordelt på vekster (1000 daa) — area by crop
    - 2642: Areal, avling, anvendelser. Produksjon — production in tonn

    ## Fields
    Each yearly record contains:
    - aar     — year (most recent = budget estimate / budsjettanslag)
    - kvantum — physical quantity, usually 1000 tonn (or 1000 daa for area)
    - pris    — farmgate price, usually kr/100 kg
    - verdi   — total value, usually mill. kr (== 1000 1000-kr)

    ## FinnPRIO usage
    - IMP1  (direct economic impact)  → verdi = total crop value at risk
    - IMP2.2 (food security)          → kvantum = Norwegian self-supply
    - EST2  (host area / establishment) → kvantum from group 2641 = daa
                                          by crop type

    ## Output structure
    1. Brief note on which group and post you used (id + Norwegian name).
    2. Short table of the requested time series (year, kvantum, pris, verdi).
    3. One concluding paragraph for the FinnPRIO assessment context.

    Always query real data — never make up numbers. If the data isn't
    available at the level of detail needed, say so and provide the
    closest available figures.
""")


# ── Agent loop ────────────────────────────────────────────────────────────

def run(prompt: str, verbose: bool = False) -> str:
    """Run the agent: prompt → NIBIO tool calls → final answer."""
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

        tool_uses = []
        text_parts = []
        for block in response.content:
            if block.type == "tool_use":
                tool_uses.append(block)
            elif block.type == "text":
                text_parts.append(block.text)

        if not tool_uses:
            return "\n".join(text_parts)

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

        if len(messages) > 20:
            return ("(Reached max iterations)\n\n"
                    + "\n".join(text_parts))


# ── PROMPT ────────────────────────────────────────────────────────────────

DEFAULT_PROMPT = dedent("""\
    IMP 1 + EST 2: What is the annual production value AND cultivated
    area of [CROP] in Norway?

    Crop:  [Prunus, Larix, Pinus]        ← replace with the crop or host plant of interest
    Years: [10]       ← replace with number of years (e.g. 10)

    Instructions:
      1. Search NIBIO groups to find the most relevant group for the
         crop. Do not assume a group — use nibio_list_groups() with a
         relevant keyword and pick the best match.
      2. Within that group, find the post for annual production quantity
         (tonn), farmgate price (kr/100 kg), and total value (mill. kr).
      3. From group 2641 (Jordbruksareal fordelt på vekster), find the
         cultivated area (1000 daa) for this crop. If no crop-specific
         post exists, report the closest aggregate and note the
         limitation.

    Use value (mill. kr) for IMP1 (direct economic impact) and
    cultivated area (1000 daa) for EST2 (host area / establishment
    potential).

    ---
    Example usage from the CLI:
      python standalone_nibio_MPC.py "IMP1 + EST2: annual production
      value and area of spring wheat in Norway. Years: 10"
""")

# ── CLI ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Query NIBIO Totalkalkylen data using natural language.")
    parser.add_argument("prompt", nargs="?",
                        help="Override the built-in prompt")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show tool calls on stderr")
    args = parser.parse_args()

    prompt = args.prompt or DEFAULT_PROMPT
    print(run(prompt, verbose=args.verbose))


if __name__ == "__main__":
    main()
