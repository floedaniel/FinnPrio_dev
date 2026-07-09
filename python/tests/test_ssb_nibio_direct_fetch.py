# python/tests/test_ssb_nibio_direct_fetch.py
"""Regression tests for fetch_ssb_data / fetch_nibio_data / _toll_search_with_fallback.

These functions silently returned {} for every pest, always, because
`import json` was missing from populate_finnprio_justifications.py — every
json.loads/json.dumps call inside them raised NameError, which the
surrounding `except Exception: continue` / `return {}` blocks swallowed
without a trace. Discovered live against the real Fusarium euwallaceae
host list (130 species) while investigating why ENT3 justifications always
reported "no SSB data could be fetched automatically".

A second, independent bug fixed alongside it: keyword iteration was capped
at keywords[:3], so any host list where the first three tokens don't
produce a match (common for scientific names, since toll.no/NIBIO's text
is Norwegian/English common names) silently found nothing even when later
tokens would have matched.
"""
import asyncio
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import populate_finnprio_justifications as pfj


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ─── regression: missing `import json` silently swallowed by except blocks ────

def test_fetch_ssb_data_returns_real_results_not_swallowed_by_internal_error(monkeypatch):
    """If json.loads/json.dumps inside this module ever NameErrors again,
    this must fail loudly instead of silently returning {}."""
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda *a, **k: json.dumps({"matches": [{"id": "07011000"}]}))
    monkeypatch.setattr(pfj, "ssb_query_data",
                         lambda *a, **k: json.dumps({"n_rows": 1, "rows": [{"value": 42}]}))

    result = run(pfj.fetch_ssb_data("Food", hosts="Solanum tuberosum"))

    assert result.get("ssb_results"), "fetch_ssb_data returned no results for a mocked success path"
    assert result["ssb_results"][0]["data"]["rows"][0]["value"] == 42


def test_fetch_nibio_data_returns_real_results_not_swallowed_by_internal_error(monkeypatch):
    monkeypatch.setattr(pfj, "nibio_list_groups",
                         lambda *a, **k: json.dumps({"groups": [{"id": 2607, "name": "Poteter"}]}))
    monkeypatch.setattr(pfj, "nibio_list_posts",
                         lambda *a, **k: json.dumps({"posts": [{"id": 62693, "name": "Salg. Matpoteter"}]}))
    monkeypatch.setattr(pfj, "nibio_get_data",
                         lambda *a, **k: json.dumps({"data": [{"aar": 2024, "verdi": 999}]}))

    result = run(pfj.fetch_nibio_data("IMP1", hosts="Poteter"))

    assert result.get("nibio_results"), "fetch_nibio_data returned no results for a mocked success path"
    assert result["nibio_results"][0]["data"]["data"][0]["verdi"] == 999


# ─── regression: keywords[:3] cap dropped hosts past the third token ──────────

def test_fetch_ssb_data_dedupes_hosts_that_share_a_commodity_code(monkeypatch):
    """Several scientific names in the same genus (e.g. Acer negundo, Acer
    buergerianum, Acer macrophyllum) all resolve to the same genus-level
    Varekode. Presenting the identical SSB rows three times risks the
    downstream LLM double-counting the same trade volume — group them into
    one result entry listing all the hosts it covers instead."""
    ssb_call_count = {"n": 0}
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda *a, **k: json.dumps({"matches": [{"id": "44079300"}]}))

    def fake_ssb_query_data(*a, **k):
        ssb_call_count["n"] += 1
        return json.dumps({"n_rows": 1, "rows": [{"value": 100}]})
    monkeypatch.setattr(pfj, "ssb_query_data", fake_ssb_query_data)

    hosts = "Acer negundo, Acer buergerianum, Acer macrophyllum"
    result = run(pfj.fetch_ssb_data("Wood", hosts=hosts))

    assert len(result["ssb_results"]) == 1
    assert sorted(result["ssb_results"][0]["hosts"]) == sorted(
        ["Acer negundo", "Acer buergerianum", "Acer macrophyllum"])
    assert ssb_call_count["n"] == 1, "should query SSB once per unique code set, not once per host"


def test_fetch_ssb_data_tries_every_host_not_just_first_three(monkeypatch):
    seen = []

    def fake_toll_search(keyword, chapters=None, max_results=10):
        seen.append(keyword)
        if keyword == "fourth host":
            return json.dumps({"matches": [{"id": "07011000"}]})
        return json.dumps({"matches": []})
    monkeypatch.setattr(pfj, "toll_search_hs_codes", fake_toll_search)
    monkeypatch.setattr(pfj, "ssb_query_data",
                         lambda *a, **k: json.dumps({"n_rows": 0, "rows": []}))

    hosts = "first host, second host, third host, fourth host"
    result = run(pfj.fetch_ssb_data("Food", hosts=hosts))

    assert "fourth host" in seen
    assert result.get("ssb_results")


def test_fetch_nibio_data_translates_scientific_names_to_norwegian(monkeypatch):
    """nibio_list_groups() matches search terms against Norwegian-only
    group names (postgruppenavnBm) — verified live: "Pinus", "Picea",
    "Solanum tuberosum" all -> 0 groups, "potet" -> 1 group. Scientific
    host names must be translated before searching."""
    seen = []

    def fake_list_groups(keyword):
        seen.append(keyword)
        return json.dumps({"groups": []})
    monkeypatch.setattr(pfj, "nibio_list_groups", fake_list_groups)
    monkeypatch.setattr(pfj, "lookup_norwegian_name",
                         lambda name: "Potet" if name == "Solanum tuberosum" else None)

    run(pfj.fetch_nibio_data("IMP1", hosts="Solanum tuberosum"))

    # Direct search used the translated term; the subsequent
    # posts-across-groups fallback call (empty search) is separate.
    assert "Potet" in seen


def test_fetch_nibio_data_searches_posts_across_groups_when_no_group_matches(monkeypatch):
    """"Purre" (leek) and "Tomater" (tomatoes) are posts inside the
    broader "Hagebruksprodukter" group (id 2608), not groups themselves —
    verified live via nibio_list_posts(2608). nibio_list_groups("Purre")
    correctly finds nothing (no group is named "Purre"); the crop is only
    findable by searching posts across all groups."""
    def fake_list_groups(search=""):
        # Direct group search for the crop name always misses (that's
        # the whole point — it's a post, not a group). An empty/no-arg
        # call is the "give me everything" listing used by the
        # posts-across-groups fallback.
        if search:
            return json.dumps({"groups": []})
        return json.dumps({"groups": [
            {"id": 2607, "name": "Poteter"},
            {"id": 2608, "name": "Hagebruksprodukter"},
        ]})

    def fake_list_posts(group_id, search=""):
        if group_id == 2608 and search.lower() == "purre":
            return json.dumps({"posts": [{"id": 62032, "name": "Purre"}]})
        return json.dumps({"posts": []})

    monkeypatch.setattr(pfj, "nibio_list_groups", fake_list_groups)
    monkeypatch.setattr(pfj, "nibio_list_posts", fake_list_posts)
    monkeypatch.setattr(pfj, "lookup_norwegian_name", lambda name: "Purre")
    monkeypatch.setattr(pfj, "nibio_get_data",
                         lambda *a, **k: json.dumps({"data": [{"aar": 2024, "kvantum": 123}]}))

    result = run(pfj.fetch_nibio_data("IMP1", hosts="Allium ampeloprasum"))

    assert result.get("nibio_results")
    posts = [r["post"]["name"] for r in result["nibio_results"]]
    assert "Purre" in posts


def test_fetch_nibio_data_falls_back_to_raw_keyword_when_no_translation(monkeypatch):
    seen = []

    def fake_list_groups(keyword):
        seen.append(keyword)
        return json.dumps({"groups": []})
    monkeypatch.setattr(pfj, "nibio_list_groups", fake_list_groups)
    monkeypatch.setattr(pfj, "lookup_norwegian_name", lambda name: None)

    run(pfj.fetch_nibio_data("IMP1", hosts="Unknownus genus"))

    # Direct search used the raw keyword (not translated); the subsequent
    # posts-across-groups fallback call (empty search, "give me
    # everything") is a separate, expected call.
    assert "Unknownus genus" in seen


def test_fetch_nibio_data_tries_every_host_not_just_first_three(monkeypatch):
    seen = []

    def fake_list_groups(keyword):
        seen.append(keyword)
        if keyword == "fourth host":
            return json.dumps({"groups": [{"id": 1, "name": "Match"}]})
        return json.dumps({"groups": []})
    monkeypatch.setattr(pfj, "nibio_list_groups", fake_list_groups)
    monkeypatch.setattr(pfj, "nibio_list_posts",
                         lambda *a, **k: json.dumps({"posts": [{"id": 1, "name": "Salg"}]}))
    monkeypatch.setattr(pfj, "nibio_get_data",
                         lambda *a, **k: json.dumps({"data": []}))

    hosts = "first host, second host, third host, fourth host"
    result = run(pfj.fetch_nibio_data("IMP1", hosts=hosts))

    assert "fourth host" in seen
    assert result.get("nibio_results")


def test_fetch_nibio_data_has_no_artificial_caps(monkeypatch):
    """No cap on groups tried per host, posts tried per group, or overall
    results — cost/latency of extra NIBIO calls is not a concern; only
    return everything found (previously capped at groups[:4], posts[:3],
    and an overall 6-result cutoff)."""
    monkeypatch.setattr(pfj, "nibio_list_groups",
                         lambda kw: json.dumps({"groups": [{"id": i, "name": f"group{i}"} for i in range(8)]}))
    monkeypatch.setattr(pfj, "nibio_list_posts",
                         lambda group_id: json.dumps({"posts": [{"id": group_id * 100 + j, "name": f"Salg {j}"} for j in range(5)]}))
    monkeypatch.setattr(pfj, "nibio_get_data",
                         lambda *a, **k: json.dumps({"data": [{"aar": 2024, "verdi": 1}]}))

    result = run(pfj.fetch_nibio_data("IMP1", hosts="onehost"))

    assert len(result["nibio_results"]) == 8 * 5  # every group x every post, no truncation


# ─── _toll_search_with_fallback: genus fallback for scientific binomials ──────

def test_toll_search_with_fallback_falls_back_to_genus(monkeypatch):
    def fake_toll_search(query, chapters=None, max_results=10):
        if query == "Quercus":
            return json.dumps({"matches": [{"id": "44079100"}]})
        return json.dumps({"matches": []})
    monkeypatch.setattr(pfj, "toll_search_hs_codes", fake_toll_search)

    matches = run(pfj._toll_search_with_fallback("Quercus robur", ["44", "45"]))

    assert matches == [{"id": "44079100"}]


def test_toll_search_with_fallback_returns_empty_when_nothing_matches(monkeypatch):
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda *a, **k: json.dumps({"matches": []}))

    matches = run(pfj._toll_search_with_fallback("Unknown species", ["44", "45"]))

    assert matches == []


def test_toll_search_with_fallback_single_word_host_has_no_genus_retry(monkeypatch):
    """A single-word host (no space) has no genus to fall back to — must not
    crash trying to split a name that's already just one word."""
    calls = []
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda q, *a, **k: calls.append(q) or json.dumps({"matches": []}))

    matches = run(pfj._toll_search_with_fallback("Wood", ["44", "45"]))

    assert matches == []
    assert calls.count("Wood") == 1  # exactly one attempt, no genus retry, no chapter-widening retry


def test_toll_search_with_fallback_uses_the_given_chapters_only(monkeypatch):
    seen_chapters = []
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda q, chapters=None, max_results=10:
                             seen_chapters.append(chapters) or json.dumps({"matches": []}))

    run(pfj._toll_search_with_fallback("Quercus robur", ["44", "45"]))

    assert seen_chapters == [["44", "45"], ["44", "45"]]  # full name, then genus — same scope both times


def test_toll_search_with_fallback_never_falls_back_to_all_chapters(monkeypatch):
    """Proven live: an unscoped, all-chapters search produces cross-kingdom
    false positives (host genus "Morus" — mulberry trees — matched a
    chapter-03 FISH tariff entry, since Morus is also the seabird genus for
    gannets). Every real match in this pipeline was already found within
    plant/wood chapters, so there is no correctness reason to ever widen
    beyond the pathway-appropriate chapters, only false-positive risk."""
    def fake_toll_search(query, chapters=None, max_results=10):
        if chapters is not None and len(chapters) == 0:
            return json.dumps({"matches": [{"id": "03055400"}]})  # only "all chapters" finds this
        return json.dumps({"matches": []})
    monkeypatch.setattr(pfj, "toll_search_hs_codes", fake_toll_search)

    matches = run(pfj._toll_search_with_fallback("Morus alba", ["06", "07", "08", "09", "10", "11", "12", "13", "14"]))

    assert matches == []


# ─── fetch_ssb_data: chapter scope depends on the pathway, not just the host ──

def test_fetch_ssb_data_scopes_to_wood_chapters_for_wood_pathway(monkeypatch):
    seen_chapters = []
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda q, chapters=None, max_results=10:
                             seen_chapters.append(chapters) or json.dumps({"matches": []}))

    run(pfj.fetch_ssb_data("Wood and wood products", hosts="Quercus robur"))

    assert all(c == ["44", "45"] for c in seen_chapters)


def test_fetch_ssb_data_scopes_to_food_chapters_for_food_pathway(monkeypatch):
    seen_chapters = []
    monkeypatch.setattr(pfj, "toll_search_hs_codes",
                         lambda q, chapters=None, max_results=10:
                             seen_chapters.append(chapters) or json.dumps({"matches": []}))

    run(pfj.fetch_ssb_data("Food and fodder", hosts="Persea americana"))

    assert all("44" not in c and "45" not in c for c in seen_chapters)


# ─── fetch_ssb_data: result cap raised so long host lists reach real matches ──

def test_fetch_ssb_data_scans_the_full_host_list_not_just_the_first_few(monkeypatch):
    """toll_search_hs_codes is a free, local, in-memory lookup (no network
    call) — the expensive step is ssb_query_data, called once per UNIQUE
    resolved commodity after dedup. Measured live against Fusarium
    euwallaceae's real 127-host list: scanning every host costs ~0.2-0.3s
    total, and even that exceptionally long list only ever resolves to 6-8
    distinct commodities. A cap on host iteration was therefore capping
    the wrong (free) phase — it clipped the wood pathway from 8 real
    commodities down to 6. The cap must be high enough that realistic host
    lists are never truncated; this uses 20 hosts, each with its own
    unique code, to prove the scan doesn't stop early well past the old
    cap of 6."""
    def fake_toll_search(keyword, chapters=None, max_results=10):
        return json.dumps({"matches": [{"id": keyword[:8]}]})  # unique code per host
    monkeypatch.setattr(pfj, "toll_search_hs_codes", fake_toll_search)
    monkeypatch.setattr(pfj, "ssb_query_data",
                         lambda *a, **k: json.dumps({"n_rows": 0, "rows": []}))

    hosts = ", ".join(f"host{i}" for i in range(20))
    result = run(pfj.fetch_ssb_data("Food and fodder", hosts=hosts))

    assert len(result["ssb_results"]) == 20


def test_fetch_ssb_data_has_no_artificial_result_cap(monkeypatch):
    """No cap on the number of unique commodities returned — cost/latency
    of extra SSB calls is not a concern; only return everything found."""
    def fake_toll_search(keyword, chapters=None, max_results=10):
        return json.dumps({"matches": [{"id": keyword[:8]}]})  # unique code per host
    monkeypatch.setattr(pfj, "toll_search_hs_codes", fake_toll_search)
    monkeypatch.setattr(pfj, "ssb_query_data",
                         lambda *a, **k: json.dumps({"n_rows": 0, "rows": []}))

    hosts = ", ".join(f"host{i}" for i in range(50))
    result = run(pfj.fetch_ssb_data("Food and fodder", hosts=hosts))

    assert len(result["ssb_results"]) == 50
