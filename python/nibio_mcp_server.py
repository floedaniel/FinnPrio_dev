"""
nibio_mcp_server.py — FastMCP server exposing NIBIO Totalkalkylen agricultural statistics.

Intended to be launched as a stdio subprocess by GPT Researcher when processing
questions that benefit from Norwegian agricultural production data (IMP1, IMP2, EST2).
No authentication required — NIBIO Totalkalkylen is open data.

Usage (standalone test):
    uv run mcp dev nibio_mcp_server.py
    python nibio_mcp_server.py          # stdio mode (used by GPT Researcher)

Install dependency:
    pip install fastmcp
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fastmcp import FastMCP
from nibio_query_lib import nibio_list_groups, nibio_list_posts, nibio_get_data

mcp = FastMCP("nibio-totalkalkylen")


@mcp.tool
def list_groups(search: str = "") -> str:
    """List all top-level agricultural product groups in NIBIO Totalkalkylen.

    Returns group IDs and Norwegian names. Optionally filter by keyword.

    Use this first to identify the correct group for the crop or livestock
    category you are researching. Then call list_posts() with the group ID.

    Key groups for FinnPRIO impact assessment:
    - 2606: Korn, erter og oljefrø  → IMP1 for cereal/legume pests
    - 2607: Poteter                 → IMP1 for potato pests (Phytophthora, etc.)
    - 2608: Hagebruksprodukter      → IMP1 for horticultural/vegetable/fruit pests
    - 2609: Andre planteprodukter   → IMP1 for other crop pests
    - 2641: Jordbruksareal fordelt på vekster (1000 daa) → EST2 host area (daa by crop type)
    - 2642: Areal, avling, anvendelser. Produksjon      → EST2/IMP total crop production (tonn)

    Example: list_groups("potet") → returns group 2607 (Poteter)
    Example: list_groups("korn")  → returns group 2606 (Korn, erter og oljefrø)
    Example: list_groups("areal") → returns crop area groups (2641, 2642, etc.)
    """
    return nibio_list_groups(search)


@mcp.tool
def list_posts(group_id: int, search: str = "") -> str:
    """List all line items (posts) within a product group.

    group_id: numeric ID from list_groups().
    Optionally filter by keyword.

    Posts represent specific accounting line items: total production,
    sales by end-use, seed, waste, etc. For impact assessment, prefer
    posts named 'Salg' (sales), 'Produksjon' (production), or 'Total'.

    Example: list_posts(2607) → all posts in Poteter group, including
             post 62693 = "Salg. Matpoteter" (table potato sales)
    """
    return nibio_list_posts(group_id, search)


@mcp.tool
def get_data(post_id: int, years_back: int = 15) -> str:
    """Get time series production data for a specific post (line item).

    post_id: numeric ID from list_posts().
    years_back: number of recent years to return (default 15, max ~68 back to 1959).
                Pass 0 for the full historical series.

    Returns per-year records with:
    - aar:    year
    - kvantum: production/sales quantity (typically 1000 tonn)
    - pris:   farmgate price (typically kr/100 kg)
    - verdi:  total value (typically mill. kr)

    The most recent year is a budget estimate (budsjettanslag).

    Use for FinnPRIO questions:
    - IMP1 (direct economic impact):  verdi = total crop value at risk (1000 kr)
    - IMP2.2 (food security):         kvantum = Norwegian self-sufficiency volume
    - EST2 (host area/establishment): kvantum as proxy for national crop presence

    Example: get_data(62693) → 15 years of table potato sales, quantity, price, value
    """
    return nibio_get_data(post_id, years_back)


if __name__ == "__main__":
    mcp.run()
