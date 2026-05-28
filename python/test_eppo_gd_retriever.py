"""Disposable smoke test for eppo_gd_retriever.

Run from the python/ directory:  python test_eppo_gd_retriever.py
Deleted in Task 9.
"""
import os
import sys

# Ensure local imports resolve when run from python/
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from eppo_gd_retriever import EPPOGDSearch, register


def test_empty_eppo_code_returns_empty_list():
    os.environ.pop("EPPO_CODE", None)
    r = EPPOGDSearch("any query")
    results = r.search(max_results=10)
    assert results == [], f"expected [], got {results!r}"
    print("PASS  empty EPPO_CODE -> []")


def test_unset_eppo_code_explicitly_empty_string_returns_empty_list():
    os.environ["EPPO_CODE"] = ""
    r = EPPOGDSearch("any query")
    results = r.search(max_results=10)
    assert results == [], f"expected [], got {results!r}"
    print("PASS  EPPO_CODE='' -> []")


def test_reporting_index_for_xylefa_returns_sorted_items():
    """Live integration test against gd.eppo.int. XYLEFA = Xylella fastidiosa
    (well-populated species with many reporting articles)."""
    from eppo_gd_retriever import EPPOGDSearch, MAX_REPORTING_ARTICLES

    r = EPPOGDSearch("any query")
    items = r._fetch_reporting_index("XYLEFA")
    assert isinstance(items, list), f"expected list, got {type(items)}"
    assert len(items) > 0, "expected >0 reporting items for XYLEFA"
    assert len(items) <= MAX_REPORTING_ARTICLES, \
        f"expected <= {MAX_REPORTING_ARTICLES}, got {len(items)}"
    for it in items:
        assert set(it.keys()) >= {"article_id", "title", "year_month", "url"}
        assert it["url"].startswith("https://gd.eppo.int/reporting/article-"), it["url"]
    # Sorted descending by year_month
    yms = [it["year_month"] for it in items]
    assert yms == sorted(yms, reverse=True), f"not sorted desc: {yms}"
    print(f"PASS  reporting index returned {len(items)} items, sorted desc")


def test_search_returns_reporting_results_with_bodies():
    os.environ["EPPO_CODE"] = "XYLEFA"
    # Force cache reset for repeatable runs
    from eppo_gd_retriever import _CACHE
    _CACHE.clear()
    r = EPPOGDSearch("any query")
    results = r.search(max_results=5)
    assert len(results) > 0, "expected >0 results for XYLEFA"
    assert len(results) <= 5
    for res in results:
        assert set(res.keys()) >= {"url", "raw_content", "title"}, res.keys()
        assert res["url"].startswith("https://"), res["url"]
        assert isinstance(res["title"], str) and res["title"], res["title"]
        # raw_content should include the title and at least some body text
        assert "Title:" in res["raw_content"], res["raw_content"][:200]
        assert len(res["raw_content"]) > 60, len(res["raw_content"])
    print(f"PASS  search returned {len(results)} populated reporting results")


def test_search_includes_pra_links_after_reporting():
    os.environ["EPPO_CODE"] = "XYLEFA"
    from eppo_gd_retriever import _CACHE
    _CACHE.clear()
    r = EPPOGDSearch("any query")
    results = r.search(max_results=50)  # large cap to capture all PRA links
    pra_results = [x for x in results if "pra.eppo.int/pra/" in x["url"]]
    reporting_results = [x for x in results if "gd.eppo.int/reporting/article-" in x["url"]]
    assert len(pra_results) > 0, "expected >=1 PRA link for XYLEFA"
    # Ordering invariant: PRA results come AFTER reporting results in the list
    if reporting_results and pra_results:
        last_reporting_idx = max(results.index(x) for x in reporting_results)
        first_pra_idx = min(results.index(x) for x in pra_results)
        assert last_reporting_idx < first_pra_idx, "PRA results must appear after reporting"
    for p in pra_results:
        assert p["raw_content"], "PRA raw_content must not be empty (title fallback at minimum)"
    print(f"PASS  search returned {len(reporting_results)} reporting + {len(pra_results)} PRA results")


def test_cache_short_circuits_second_call():
    import time
    from eppo_gd_retriever import _CACHE
    _CACHE.clear()
    os.environ["EPPO_CODE"] = "XYLEFA"

    r = EPPOGDSearch("any query")
    t0 = time.monotonic()
    first = r.search(max_results=5)
    first_elapsed = time.monotonic() - t0

    t1 = time.monotonic()
    second = r.search(max_results=5)
    second_elapsed = time.monotonic() - t1

    assert first == second, "cached result must equal first result"
    # Cached call must be at least 50x faster than uncached (typically >1000x)
    assert second_elapsed * 50 < first_elapsed, (
        f"cache not effective: first={first_elapsed:.3f}s second={second_elapsed:.3f}s"
    )
    print(f"PASS  cache short-circuited (first={first_elapsed:.2f}s, second={second_elapsed*1000:.1f}ms)")


if __name__ == "__main__":
    test_empty_eppo_code_returns_empty_list()
    test_unset_eppo_code_explicitly_empty_string_returns_empty_list()
    print("\nTask 1 smoke tests passed.")
    test_reporting_index_for_xylefa_returns_sorted_items()
    test_search_returns_reporting_results_with_bodies()
    test_search_includes_pra_links_after_reporting()
    test_cache_short_circuits_second_call()
