# python/tests/test_lids_flora_lib.py
"""Tests for lids_flora_lib.py — scientific name -> Norwegian common name.

Verified live (see nibio_query_lib.nibio_list_groups, which matches
search terms against Norwegian-only group names): "Pinus", "Picea",
"Solanum tuberosum", "Potato", "wheat" all -> 0 groups, while "potet" and
"korn" (Norwegian) each -> 1 group. This module bridges scientific host
names to the Norwegian terms NIBIO's search actually matches.

Tests run against the real Lids_flora.xls (2934 rows, local file, no
network) rather than a fixture, since the whole point is verifying real
translations for real host names.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import lids_flora_lib as lib


def test_exact_species_match():
    assert lib.lookup_norwegian_name("Solanum tuberosum") == "Potet"


def test_exact_species_match_case_insensitive():
    assert lib.lookup_norwegian_name("solanum tuberosum") == "Potet"


def test_exact_species_match_pine():
    assert lib.lookup_norwegian_name("Pinus sylvestris") is not None


def test_genus_fallback_for_unlisted_species():
    """"Pinus nonexistentia" isn't a real species and won't be in the
    flora, but the genus "Pinus" has many entries — fall back to the
    first one found rather than returning nothing."""
    result = lib.lookup_norwegian_name("Pinus nonexistentia")
    assert result is not None


def test_unmatched_name_returns_none():
    assert lib.lookup_norwegian_name("Zzznonexistentgenus xyzabc") is None


def test_empty_string_returns_none():
    assert lib.lookup_norwegian_name("") is None
    assert lib.lookup_norwegian_name(None) is None


def test_index_is_cached_across_calls():
    lib._FLORA_INDEX = None
    lib.lookup_norwegian_name("Solanum tuberosum")
    assert lib._FLORA_INDEX is not None
    cached = lib._FLORA_INDEX
    lib.lookup_norwegian_name("Pinus sylvestris")
    assert lib._FLORA_INDEX is cached  # same object, not rebuilt
