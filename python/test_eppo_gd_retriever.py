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


if __name__ == "__main__":
    test_empty_eppo_code_returns_empty_list()
    test_unset_eppo_code_explicitly_empty_string_returns_empty_list()
    print("\nTask 1 smoke tests passed.")
