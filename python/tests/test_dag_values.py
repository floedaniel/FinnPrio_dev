# python/tests/test_dag_values.py
import json
import os
import tempfile
import pytest

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from dag_values import (
    get_zero_option,
)

# ─── Shared fixtures ──────────────────────────────────────────────────────────

EST1_OPTIONS = [
    {"opt": "a", "text": "No it could not", "points": 0},
    {"opt": "b", "text": "It could, but it is unlikely", "points": 1.5},
    {"opt": "c", "text": "It could, and it is likely", "points": 4.5},
    {"opt": "d", "text": "It could, and it is very likely", "points": 9},
]

IMP1_OPTIONS = [
    {"opt": "a", "text": "It would not cause losses in Finland", "points": 0},
    {"opt": "b", "text": "<0.05 million per year", "points": 0.5},
    {"opt": "c", "text": "0.05-0.1 million per year", "points": 1},
]

BOOLEAN_OPTIONS = [
    {"opt": "a", "text": "Yes", "points": 1},
]

ENT2_OPTIONS = [
    {"opt": "a", "text": "No it cannot", "points": 0},
    {"opt": "b", "text": "Very unlikely", "points": 0.5},
    {"opt": "c", "text": "Unlikely", "points": 1},
    {"opt": "d", "text": "Likely", "points": 2},
    {"opt": "e", "text": "Very likely", "points": 3},
]

# ─── get_zero_option ──────────────────────────────────────────────────────────

def test_get_zero_option_minmax_integer_points():
    assert get_zero_option(EST1_OPTIONS, "minmax") == "a"

def test_get_zero_option_minmax_float_points():
    assert get_zero_option(IMP1_OPTIONS, "minmax") == "a"

def test_get_zero_option_minmax_string_points():
    options = [
        {"opt": "a", "text": "None", "points": "0"},
        {"opt": "b", "text": "Small", "points": "0.5"},
    ]
    assert get_zero_option(options, "minmax") == "a"

def test_get_zero_option_boolean_returns_none():
    assert get_zero_option(BOOLEAN_OPTIONS, "boolean") is None

def test_get_zero_option_no_zero_raises():
    options = [
        {"opt": "a", "text": "First", "points": 1},
        {"opt": "b", "text": "Second", "points": 2},
    ]
    with pytest.raises(ValueError):
        get_zero_option(options, "minmax")

def test_get_zero_option_ent2_half_point():
    # ENT2 has points=0.5 for option "b" — "a" is zero
    assert get_zero_option(ENT2_OPTIONS, "minmax") == "a"
