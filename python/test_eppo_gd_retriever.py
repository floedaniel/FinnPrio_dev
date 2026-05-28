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


if __name__ == "__main__":
    test_empty_eppo_code_returns_empty_list()
    test_unset_eppo_code_explicitly_empty_string_returns_empty_list()
    print("\nTask 1 smoke tests passed.")
    test_reporting_index_for_xylefa_returns_sorted_items()
    test_search_returns_reporting_results_with_bodies()
