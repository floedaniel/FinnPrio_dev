"""lids_flora_lib.py — Lid's Norwegian Flora (Lids_flora.xls): scientific
(Latin) name -> Norwegian common name lookup.

No agentic loop, no network calls. Used to translate scientific host names
into Norwegian plant/crop names before searching NIBIO Totalkalkylen,
since nibio_list_groups() matches search terms against Norwegian-only
group names (postgruppenavnBm) and never matches a scientific name or
English common name directly — verified live: "Pinus", "Picea",
"Solanum tuberosum", "Potato", "wheat" all -> 0 groups, while "potet" and
"korn" each -> 1 group.
"""
from pathlib import Path

import pandas as pd

_FLORA_PATH = Path(__file__).resolve().parent.parent / "information" / "Lids_flora.xls"
_FLORA_INDEX: list | None = None


def _build_flora_index() -> list:
    """Parse Lids_flora.xls into a flat list of {latin_lower, norwegian}
    records (cached after first load).

    Columns are accessed by position, not name: the header row for the
    accented columns ("Forslag bokmål", "Rekkefølge...") is fragile to
    hand-type correctly in source, while position is stable. Column 0 is
    the scientific name (GNAVN); column 1 is a suggested standard Bokmål
    name (preferred — more likely to match NIBIO's own naming); column 2
    is the name actually used in the Lid 1994 reference text (fallback,
    sometimes Nynorsk-flavored, e.g. "Vanleg" vs "Vanlig").
    """
    global _FLORA_INDEX
    if _FLORA_INDEX is not None:
        return _FLORA_INDEX

    df = pd.read_excel(_FLORA_PATH, sheet_name=0)
    latin_col, bokmal_col, lid_col = df.columns[0], df.columns[1], df.columns[2]

    records = []
    for _, row in df.iterrows():
        latin = str(row[latin_col]).strip()
        if not latin or latin.lower() == "nan":
            continue
        norwegian = str(row[bokmal_col]).strip()
        if not norwegian or norwegian.lower() == "nan":
            norwegian = str(row[lid_col]).strip()
        if not norwegian or norwegian.lower() == "nan":
            continue
        records.append({"latin_lower": latin.lower(), "norwegian": norwegian})

    _FLORA_INDEX = records
    return records


def lookup_norwegian_name(scientific_name: str) -> str | None:
    """Look up the Norwegian common name for a scientific host name.

    Tries the full name first (e.g. "Solanum tuberosum" -> "Potet"), then
    falls back to the bare genus (e.g. an unlisted "Pinus xyz" -> "Pinus"
    -> the first Pinus entry's name) since a host list's exact species
    may not itself appear in the flora even when its genus does.

    Returns None if nothing matches — callers should fall back to the
    original (untranslated) name rather than searching with an empty
    string.
    """
    name = (scientific_name or "").strip()
    if not name:
        return None

    records = _build_flora_index()
    name_lower = name.lower()

    for r in records:
        if r["latin_lower"] == name_lower:
            return r["norwegian"]

    genus_lower = name_lower.split()[0] if " " in name_lower else name_lower
    for r in records:
        if r["latin_lower"] == genus_lower:
            return r["norwegian"]
    for r in records:
        if r["latin_lower"].startswith(genus_lower + " "):
            return r["norwegian"]

    return None
