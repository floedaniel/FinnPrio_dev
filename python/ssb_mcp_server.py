"""
ssb_mcp_server.py — FastMCP server exposing SSB Statistics Norway trade data tools.

Intended to be launched as a stdio subprocess by GPT Researcher when processing
ENT3 (trade volume question). No API key required — SSB is open data.

Usage (standalone test):
    uv run mcp dev ssb_mcp_server.py
    python ssb_mcp_server.py          # stdio mode (used by GPT Researcher)

Install dependency:
    pip install fastmcp
"""

import sys
from pathlib import Path

# Ensure ssb_query_lib is importable from the same directory
sys.path.insert(0, str(Path(__file__).parent))

from fastmcp import FastMCP
from ssb_query_lib import (ssb_search_tables, ssb_get_metadata,
                            ssb_search_codes, ssb_query_data,
                            toll_search_hs_codes)

mcp = FastMCP("ssb-trade")


@mcp.tool
def search_tables(query: str, lang: str = "en") -> str:
    """Search SSB Statistikkbanken for tables by keyword.

    Returns table IDs, titles, variable names, and last available period.
    Use this first to identify the right table before querying data.

    Key tables for biological commodity trade:
    - 08801: Annual foreign trade by HS commodity code and country (use this)
    - 08799: Monthly foreign trade by HS commodity code and country

    HS chapters relevant for plant pest pathways:
    - Ch 06: Live trees, plants, cuttings, roots
    - Ch 07: Edible vegetables
    - Ch 08: Edible fruit and nuts
    - Ch 10: Cereals
    - Ch 12: Oil seeds, plants, straw, fodder
    - Ch 44: Wood — raw/minimally processed codes only (genuine pest
        pathway): 4401 fuel wood, 4403 roundwood, 4404 poles/stakes,
        4407 sawnwood, 4415 packaging wood (ISPM 15).
        Do NOT query: 4406 sleepers (heat-treated/preserved), 4408
        veneer, 4409 shaped/parquet, 4410 OSB/particleboard, 4411
        fibreboard/MDF, 4412 plywood/laminated, 4413+ finished
        articles — highly processed or treated, no pest pathway.
    """
    return ssb_search_tables(query, lang)


@mcp.tool
def get_metadata(table_id: str, lang: str = "en") -> str:
    """Get metadata for an SSB table: variable names, value codes and labels.

    Returns all dimension IDs, their labels, and a sample of value codes
    (first 30 per variable). Use this to find valid codes before querying —
    particularly to identify HS commodity codes (Varekoder), country codes
    (Land), and time period codes (Tid).
    """
    return ssb_get_metadata(table_id, lang)


@mcp.tool
def search_codes(table_id: str, variable: str, search: str,
                 lang: str = "en") -> str:
    """Search for specific value codes within a table variable.

    Fetches full metadata and filters codes/labels matching the search term.
    Use to find HS commodity codes (variable 'Varekoder'), country codes
    (variable 'Land'), etc.

    Examples:
    - search_codes("08801", "Varekoder", "birch") → birch HS codes
    - search_codes("08801", "Varekoder", "4403") → all 4403.xx roundwood codes
    - search_codes("08801", "Land", "China") → China country code
    """
    return ssb_search_codes(table_id, variable, search, lang)


@mcp.tool
def query_data(table_id: str, selection: list, lang: str = "en") -> str:
    """Query actual import/export data from an SSB table.

    Returns flattened rows with dimension labels and values.
    Max 800,000 cells per query — use selection filters to stay under the limit.

    Use table 08801 for annual foreign trade by HS code and country.

    Selection format — list of dicts, each with:
      variableCode: variable ID (e.g. "Varekoder", "ImpEks", "Land", "Tid")
      valueCodes: list of code patterns. Supports SSB wildcards:
          * = any characters, ? = single character
          top(N) = N most recent periods, from(X) = from value X onward

    Wood — plant pest pathway codes only (HS chapter 44, table 08801):
      Roundwood 4403: .91=oak, .92=beech, .95/.96=birch,
          .97=poplar, .99=other non-coniferous (also covers conifers
          via 440310/440320/440391)
      Sawnwood 4407: .91-.99 mirrors 4403 at genus level
      Packaging wood 4415: crates, pallets (ISPM 15 regulated)
      Fuel wood 4401; split poles 4404

      DO NOT query these codes (highly processed, treated, or no pest risk):
        4406 railway sleepers (typically heat-treated or chemically
        preserved — negligible phytosanitary risk in practice),
        4408 veneer sheets, 4409 shaped/parquet wood,
        4410 particleboard/OSB, 4411 fibreboard/MDF,
        4412 plywood/laminated wood, 4413 densified wood,
        4416–4421 all finished wood articles

    ImpEks codes: "1"=imports, "2"=exports.
    ContentsCode: "Mengde1"=quantity (tonnes), "Verdi"=value (NOK 1000).

    Varekoder note: SSB 08801 Varekoder values carry a version suffix
    (e.g. "44039500_1988"). Always append "*" to the 8-digit HS code
    returned by search_tariff_codes so SSB matches the correct value.

    Example — annual birch roundwood imports from all countries, last 5 years:
    [
      {"variableCode": "Varekoder", "valueCodes": ["44039500*", "44039600*"]},
      {"variableCode": "ImpEks",    "valueCodes": ["1"]},
      {"variableCode": "Land",      "valueCodes": ["*"]},
      {"variableCode": "ContentsCode", "valueCodes": ["Mengde1", "Verdi"]},
      {"variableCode": "Tid",       "valueCodes": ["top(5)"]}
    ]
    """
    return ssb_query_data(table_id, selection, lang)


@mcp.tool
def search_tariff_codes(query: str, chapters: list = None) -> str:
    """Search the Norwegian customs tariff for 8-digit commodity codes (Varekoder).

    Use this BEFORE calling query_data to find the correct Varekoder for a
    specific host plant or commodity. The returned 'id' values are exactly
    the codes used in SSB table 08801 (Varekoder variable).

    Defaults to plant-relevant chapters (06–14, 44, 45). Pass chapters=[]
    to search all chapters.

    Recommended workflow for ENT3 trade volume queries:
      1. search_tariff_codes("potato") → get 8-digit codes for potato imports
      2. query_data("08801", [{"variableCode": "Varekoder", "valueCodes": [<ids>]}, ...])

    Key chapters for plant pest pathways:
    - "06": Live trees, plants, cuttings, roots, bulbs
    - "07": Edible vegetables (potatoes, carrots, onions, etc.)
    - "08": Edible fruit and nuts
    - "10": Cereals (wheat, barley, oats, rye, maize)
    - "12": Oil seeds, straw, fodder plants
    - "44": Wood — raw/minimally processed only (4401 fuel wood,
        4403 roundwood, 4404 poles, 4407 sawnwood, 4415 packaging).
        Excluded: 4406 sleepers (heat-treated/preserved), 4408 veneer,
        4410 OSB, 4411 MDF, 4412 plywood, 4413+ articles — all
        carry no viable plant pest pathway.

    Examples:
    - search_tariff_codes("potato")       → 07011000, 07019011, 07019018 …
    - search_tariff_codes("apple")        → apple/cider apple codes in Ch 08
    - search_tariff_codes("wheat")        → wheat codes in Ch 10
    - search_tariff_codes("conifer")      → conifer wood codes in Ch 44
    - search_tariff_codes("seed", ["06"]) → live plant seed/cutting codes only
    """
    return toll_search_hs_codes(query, chapters)


if __name__ == "__main__":
    mcp.run()
