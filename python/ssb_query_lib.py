"""
ssb_query_lib.py — Pure SSB PxWebApi v2 helper functions + Norwegian customs tariff search.

No agentic loop, no Anthropic/OpenAI SDK. Just urllib calls to SSB that
return JSON strings. Used by ssb_mcp_server.py (MCP tool backend) and
imported by standalone_ssb_MPC.py (CLI agent backend).
"""

import json
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SSB_BASE = "https://data.ssb.no/api/pxwebapi/v2"

# Norwegian customs tariff (English) — 8-digit Varekoder matching SSB table 08801
_TOLL_XML_URL = (
    "https://data.toll.no/dataset/4e6ec703-ca3c-4aad-b7f2-d9e45da21e0a"
    "/resource/1564857f-93bc-431e-80ba-efd91201c993"
    "/download/customstariffstructure.xml"
)
_TOLL_CACHE = Path(__file__).parent / "customstariffstructure.xml"
_TOLL_INDEX: list | None = None  # in-memory cache after first parse

# Default chapters relevant for plant pest pathways
_PLANT_CHAPTERS = {
    "06",  # Live trees and plants, cuttings, roots
    "07",  # Edible vegetables
    "08",  # Edible fruit and nuts
    "09",  # Coffee, tea, spices
    "10",  # Cereals
    "11",  # Mill products, malt, starch
    "12",  # Oil seeds, straw, fodder plants
    "13",  # Resins, extracts
    "14",  # Vegetable plaiting materials
    "44",  # Wood and wood articles
    "45",  # Cork
}

# HS headings within Ch 44 that are too highly processed to represent a
# viable plant pest pathway (no bark, heat-treated, or composite).
# Automatically excluded from toll_search_hs_codes() results when Ch 44
# is in scope, so only raw/minimally-processed wood codes are returned.
#
# INCLUDED (genuine pest pathway): 4401 fuel wood, 4403 roundwood,
#   4404 split poles/stakes, 4407 sawnwood,
#   4415 packaging wood (crates/pallets — ISPM 15 regulated)
#
# EXCLUDED (negligible phytosanitary risk):
_EXCLUDED_WOOD_HEADINGS: frozenset = frozenset({
    "4402",  # Charcoal — heat-killed
    "4405",  # Wood wool / wood flour — ground to particles
    "4408",  # Veneer sheets ≤6 mm — sliced/peeled, no bark
    "4409",  # Continuously shaped wood (parquet strips, mouldings)
    "4410",  # Particleboard, OSB, waferboard
    "4411",  # Fibreboard (MDF, HDF, softboard)
    "4412",  # Plywood and laminated wood
    "4406",  # Railway/tramway sleepers — typically heat-treated or preserved
    "4413",  # Densified wood blocks and profiles
    "4416",  # Casks and barrels (coopers' products)
    "4417",  # Tools and tool handles of wood
    "4418",  # Builders' joinery (doors, windows, stairs, parquet panels)
    "4419",  # Tableware and kitchenware of wood
    "4420",  # Marquetry and ornamental wood articles
    "4421",  # Other articles of wood (e.g. coat hangers, bobbins)
})


def _ensure_toll_xml() -> Path:
    """Download the customs tariff XML if not already cached locally."""
    if not _TOLL_CACHE.exists():
        req = urllib.request.Request(
            _TOLL_XML_URL,
            headers={"User-Agent": "FinnPRIO-assessor/1.0"},
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            _TOLL_CACHE.write_bytes(response.read())
    return _TOLL_CACHE


def _build_toll_index() -> list:
    """Parse the tariff XML into a flat list of commodity records (cached)."""
    global _TOLL_INDEX
    if _TOLL_INDEX is not None:
        return _TOLL_INDEX

    tree = ET.parse(_ensure_toll_xml())
    root = tree.getroot()

    records = []
    for sections in root.findall("sections"):
        for chap in sections.findall("chapters/chapter"):
            chap_id = (chap.findtext("id") or "").strip()
            chap_desc = (chap.findtext("description") or "").strip()
            for heading in chap.findall(".//heading"):
                h_id = (heading.findtext("id") or "").strip()
                h_desc = (heading.findtext("description") or "").strip()
                for comm in heading.findall(".//commodity"):
                    c_id = (comm.findtext("id") or "").strip()
                    hs = (comm.findtext("hsNumber") or "").strip()
                    item = (comm.findtext("item") or "").strip()
                    records.append({
                        "id": c_id,
                        "hsNumber": hs,
                        "chapter": chap_id,
                        "chapter_desc": chap_desc,
                        "heading_id": h_id,
                        "heading_desc": h_desc,
                        "item": item,
                        "_search": f"{h_desc} {item}".lower(),
                    })

    _TOLL_INDEX = records
    return records


def toll_search_hs_codes(query: str, chapters: list | None = None,
                          max_results: int = 40) -> str:
    """Search Norwegian customs tariff for commodity codes matching a keyword.

    Returns 8-digit commodity IDs suitable for use as Varekoder in SSB table 08801.

    chapters: list of 2-digit chapter IDs to restrict the search.
              Defaults to plant-relevant chapters (06-14, 44, 45).
              Pass [] to search all chapters.
    max_results: cap on returned matches (default 40).

    Ch 44 note: highly processed wood products with negligible phytosanitary
    risk are automatically excluded even when Ch 44 is in scope. The
    following headings are never returned: 4402 (charcoal), 4405 (wood
    wool/flour), 4408 (veneer sheets), 4409 (shaped wood/parquet),
    4410 (particleboard/OSB), 4411 (fibreboard/MDF), 4412 (plywood),
    4413 (densified wood), 4416-4421 (finished articles). Only raw/
    minimally processed codes with bark retention or ISPM 15 relevance
    are returned: 4401, 4403, 4404, 4407, 4415.
    """
    records = _build_toll_index()
    query_lower = query.lower()
    chapter_filter = set(chapters) if chapters is not None else _PLANT_CHAPTERS

    matches = []
    for rec in records:
        if chapter_filter and rec["chapter"] not in chapter_filter:
            continue
        # Exclude highly processed wood products (no viable pest pathway)
        if rec["chapter"] == "44" and rec["id"][:4] in _EXCLUDED_WOOD_HEADINGS:
            continue
        if query_lower in rec["_search"]:
            matches.append({
                "id": rec["id"],
                "hsNumber": rec["hsNumber"],
                "chapter": rec["chapter"],
                "heading": f"{rec['heading_id']}: {rec['heading_desc']}",
                "item": rec["item"],
            })
            if len(matches) >= max_results:
                break

    return json.dumps(
        {
            "query": query,
            "chapters_searched": sorted(chapter_filter) if chapter_filter else "all",
            "n_matches": len(matches),
            "note": "Use 'id' (8-digit) as Varekoder in SSB table 08801.",
            "matches": matches,
        },
        indent=2,
        ensure_ascii=False,
    )


def ssb_search_tables(query: str, lang: str = "en", pagesize: int = 10) -> str:
    """Search SSB tables by keyword."""
    q = urllib.parse.quote(query)
    url = f"{SSB_BASE}/tables?query={q}&lang={lang}&pagesize={pagesize}"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())
    tables = data.get("tables", [])
    return json.dumps([
        {"id": t["id"], "label": t["label"],
         "variables": t.get("variableNames", []),
         "lastPeriod": t.get("lastPeriod", "")}
        for t in tables
    ], indent=2, ensure_ascii=False)


def ssb_get_metadata(table_id: str, lang: str = "en") -> str:
    """Get metadata (variables, codes, labels) for an SSB table."""
    url = f"{SSB_BASE}/tables/{table_id}/metadata?lang={lang}"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())
    summary = {}
    for dim_id, dim in data.get("dimension", {}).items():
        cats = dim.get("category", {})
        labels = cats.get("label", {})
        items = list(labels.items())
        summary[dim_id] = {
            "label": dim.get("label", ""),
            "n_values": len(items),
            "values_sample": dict(items[:30]),
            "elimination": dim.get("extension", {}).get("elimination", None),
        }
    return json.dumps(summary, indent=2, ensure_ascii=False)


def ssb_search_codes(table_id: str, variable: str, search: str,
                     lang: str = "en") -> str:
    """Search for value codes within a table variable matching a search term."""
    url = f"{SSB_BASE}/tables/{table_id}/metadata?lang={lang}"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())
    dim = data.get("dimension", {}).get(variable)
    if not dim:
        return json.dumps({"error": f"Variable '{variable}' not found"})
    labels = dim["category"]["label"]
    search_lower = search.lower()
    matches = {k: v for k, v in labels.items()
               if search_lower in v.lower() or search_lower in k.lower()}
    return json.dumps({
        "variable": variable,
        "search": search,
        "n_matches": len(matches),
        "matches": dict(list(matches.items())[:50]),
    }, indent=2, ensure_ascii=False)


_TRANSIENT_HTTP_STATUSES = {502, 503, 504}
_RETRY_DELAYS = [1, 2, 4]  # seconds; one entry per retry attempt


def ssb_query_data(table_id: str, selection: list,
                   lang: str = "en") -> str:
    """POST query to SSB and return parsed results as a readable table.

    Retries transient 502/503/504 responses with short backoff — SSB is
    occasionally briefly overloaded/unavailable (observed live: a query
    failed with 503 and succeeded on retry moments later). A deterministic
    error (e.g. 400 bad selection) is not retried, since retrying it can
    never succeed.
    """
    url = f"{SSB_BASE}/tables/{table_id}/data?lang={lang}&outputFormat=json-stat2"
    body = json.dumps({"selection": selection}).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    # Hard cap on response body: SSB can return very large payloads for broad
    # queries (e.g. all live plants × all countries × 5 years). Reading them
    # fully hangs for minutes. Return an actionable error instead.
    # Wall-clock timeout guards against slow-trickle responses that bypass
    # the per-read socket timeout.
    MAX_BYTES = 8 * 1024 * 1024  # 8 MB — headroom for broad-host queries (was 4 MB)
    WALL_TIMEOUT = 120            # seconds total for the entire read (was 90)

    for attempt in range(len(_RETRY_DELAYS) + 1):
        try:
            raw = b""
            deadline = time.monotonic() + WALL_TIMEOUT
            with urllib.request.urlopen(req, timeout=60) as r:
                content_length = r.headers.get("Content-Length")
                if content_length and int(content_length) > MAX_BYTES:
                    return json.dumps({
                        "error": (
                            f"SSB response too large ({int(content_length):,} bytes). "
                            "Narrow the selection: use specific HS codes instead of wildcards, "
                            "limit Land to specific countries, or reduce the time range."
                        ),
                        "selection": selection,
                    }, ensure_ascii=False)
                chunk = r.read(65536)
                while chunk:
                    raw += chunk
                    if time.monotonic() > deadline:
                        return json.dumps({
                            "error": (
                                f"SSB response timed out after {WALL_TIMEOUT}s. "
                                "Narrow the selection: use specific HS codes instead of wildcards, "
                                "limit Land to specific countries, or reduce the time range."
                            ),
                            "selection": selection,
                        }, ensure_ascii=False)
                    if len(raw) > MAX_BYTES:
                        return json.dumps({
                            "error": (
                                f"SSB response exceeded {MAX_BYTES:,} bytes. "
                                "Narrow the selection: use specific HS codes instead of wildcards, "
                                "limit Land to specific countries, or reduce the time range."
                            ),
                            "selection": selection,
                        }, ensure_ascii=False)
                    chunk = r.read(65536)
            break
        except urllib.error.HTTPError as e:
            if e.code in _TRANSIENT_HTTP_STATUSES and attempt < len(_RETRY_DELAYS):
                time.sleep(_RETRY_DELAYS[attempt])
                continue
            raise

    data = json.loads(raw)
    dims = data["dimension"]
    values = data["value"]

    dim_keys = list(dims.keys())
    dim_labels = {}
    for dk in dim_keys:
        dim_labels[dk] = {
            "name": dims[dk]["label"],
            "values": list(dims[dk]["category"]["label"].values()),
            "codes": list(dims[dk]["category"]["index"].keys()),
        }

    # Stop building rows at 500 — don't iterate the full value array first
    rows = []
    total = len(values)
    for i in range(total):
        if values[i] is None or values[i] == 0:
            continue
        row = {}
        idx = i
        for d in reversed(dim_keys):
            n = len(dim_labels[d]["values"])
            pos = idx % n
            idx //= n
            row[dim_labels[d]["name"]] = dim_labels[d]["values"][pos]
            row[f"{dim_labels[d]['name']}_code"] = dim_labels[d]["codes"][pos]
        row["value"] = values[i]
        rows.append(row)
        if len(rows) >= 500:
            return json.dumps({
                "note": f"Showing first 500 non-zero rows (total value cells: {total}). "
                        "Use more specific filters to reduce result size.",
                "rows": rows,
            }, indent=2, ensure_ascii=False)

    return json.dumps({"n_rows": len(rows), "rows": rows},
                      indent=2, ensure_ascii=False)
