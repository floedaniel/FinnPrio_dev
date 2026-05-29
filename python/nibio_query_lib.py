"""
nibio_query_lib.py — Pure NIBIO Totalkalkylen API helper functions.

No agentic loop, no Anthropic/OpenAI SDK. Just urllib calls that return
JSON strings. Used by nibio_mcp_server.py (MCP tool backend).

API: https://www.nibio.no/tjenester/totalkalkylen-statistikk/_/service/com.norsedigital.nibio/statistics

Endpoints:
  GET /statistics                          → all product groups
  GET /statistics?type=posts&ID={group}    → posts (line items) in a group
  GET /statistics?type=data&ID={post}      → 68-year time series (1959–2026)
"""

import json
import urllib.parse
import urllib.request

NIBIO_BASE = (
    "https://www.nibio.no/tjenester/totalkalkylen-statistikk"
    "/_/service/com.norsedigital.nibio/statistics"
)


def _get(params: dict | None = None) -> list:
    url = NIBIO_BASE
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())
    return data.get("content", [])


def nibio_list_groups(search: str = "") -> str:
    """Return all top-level agricultural product groups with their IDs.

    Optionally filter by keyword (case-insensitive substring match on name).
    Example groups: Poteter (2607), Korn og erter (2606), Grønnsaker (varies), Melk (varies).
    """
    items = _get()
    if search:
        lo = search.lower()
        items = [g for g in items
                 if lo in str(g.get("postgruppenavnBm", "")).lower()]
    return json.dumps(
        {
            "n_groups": len(items),
            "groups": [
                {"id": g["id"], "name": g.get("postgruppenavnBm", "")}
                for g in items
            ],
        },
        indent=2,
        ensure_ascii=False,
    )


def nibio_list_posts(group_id: int, search: str = "") -> str:
    """Return all line items (posts) within a product group.

    group_id: numeric ID from nibio_list_groups().
    Optionally filter by keyword (case-insensitive substring match on name).
    Example posts in group 2607: Salg. Matpoteter (62693), Salg. Matpoteter i spesialpk (62722), etc.
    Note: time-series data is embedded in each post under 'items'.
    """
    items = _get({"type": "posts", "ID": group_id})
    if search:
        lo = search.lower()
        items = [p for p in items
                 if lo in str(p.get("postnavnKortBm", "")).lower()]
    return json.dumps(
        {
            "group_id": group_id,
            "n_posts": len(items),
            "posts": [
                {"id": p["id"], "name": p.get("postnavnKortBm", "")}
                for p in items
            ],
        },
        indent=2,
        ensure_ascii=False,
    )


def nibio_get_data(post_id: int, years_back: int = 15) -> str:
    """Return time series data for a specific post.

    post_id: numeric ID from nibio_list_posts().
    years_back: limit to this many most recent years (default 15).
                Pass 0 for the full series back to 1959.

    Each record contains: aar (year), kvantum (quantity + unit),
    pris (price + unit), verdi (value + unit). The most recent year
    is a budget estimate (budsjettanslag).
    """
    items = _get({"type": "data", "ID": post_id})
    if years_back and years_back > 0 and len(items) > years_back:
        items = items[-years_back:]
    return json.dumps(
        {
            "post_id": post_id,
            "n_years": len(items),
            "note": "Most recent year is a budget estimate (budsjettanslag). "
                    "kvantum = production quantity, pris = price, verdi = total value.",
            "data": items,
        },
        indent=2,
        ensure_ascii=False,
    )
