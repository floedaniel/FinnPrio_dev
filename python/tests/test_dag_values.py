# python/tests/test_dag_values.py
import json
import os
import tempfile
import pytest

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from dag_values import (
    get_zero_option,
    topological_sort_answers,
    check_zero_forcing,
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


# ─── topological_sort_answers ─────────────────────────────────────────────────

def test_topological_sort_est_before_imp():
    answers = [
        {"code": "IMP1"},
        {"code": "EST1"},
        {"code": "EST2"},
    ]
    result = topological_sort_answers(answers, is_pathway=False)
    codes = [a["code"] for a in result]
    assert codes.index("EST1") < codes.index("IMP1")
    assert codes.index("EST2") < codes.index("IMP1")

def test_topological_sort_est2_after_est1():
    answers = [{"code": "EST2"}, {"code": "EST1"}]
    result = topological_sort_answers(answers, is_pathway=False)
    codes = [a["code"] for a in result]
    assert codes.index("EST1") < codes.index("EST2")

def test_topological_sort_pathway_ent2a_before_ent3():
    answers = [{"code": "ENT3"}, {"code": "ENT2A"}]
    result = topological_sort_answers(answers, is_pathway=True)
    codes = [a["code"] for a in result]
    assert codes.index("ENT2A") < codes.index("ENT3")

def test_topological_sort_pathway_ent2a_before_ent2b():
    answers = [{"code": "ENT2B"}, {"code": "ENT2A"}]
    result = topological_sort_answers(answers, is_pathway=True)
    codes = [a["code"] for a in result]
    assert codes.index("ENT2A") < codes.index("ENT2B")

def test_topological_sort_preserves_all_answers():
    answers = [{"code": "IMP3"}, {"code": "EST4"}, {"code": "EST1"}]
    result = topological_sort_answers(answers, is_pathway=False)
    assert len(result) == 3

def test_topological_sort_no_deps_stable():
    # EST4 has no dependencies — should not crash
    answers = [{"code": "EST4"}, {"code": "MAN3"}]
    result = topological_sort_answers(answers, is_pathway=False)
    assert len(result) == 2


# ─── check_zero_forcing ───────────────────────────────────────────────────────

def test_check_zero_forcing_all_forced_minmax():
    scored_context = {"EST1": {"min": "a", "likely": "a", "max": "a"}}
    result = check_zero_forcing("IMP1", scored_context, IMP1_OPTIONS, "minmax")
    assert result is not None
    assert result["min"] == "a"
    assert result["likely"] == "a"
    assert result["max"] == "a"
    forced_params = {f["parameter"] for f in result["flags"]}
    assert forced_params == {"min", "likely", "max"}

def test_check_zero_forcing_partial_min_only():
    scored_context = {"EST1": {"min": "a", "likely": "b", "max": "c"}}
    result = check_zero_forcing("IMP1", scored_context, IMP1_OPTIONS, "minmax")
    assert result is not None
    assert result["min"] == "a"
    assert result["likely"] is None   # not forced
    assert result["max"] is None      # not forced
    assert len(result["flags"]) == 1
    assert result["flags"][0]["parameter"] == "min"

def test_check_zero_forcing_no_trigger():
    scored_context = {"EST1": {"min": "b", "likely": "c", "max": "d"}}
    result = check_zero_forcing("IMP1", scored_context, IMP1_OPTIONS, "minmax")
    assert result is None

def test_check_zero_forcing_wrong_target():
    # EST1 does not force EST3
    scored_context = {"EST1": {"min": "a", "likely": "a", "max": "a"}}
    result = check_zero_forcing("EST3", scored_context, EST1_OPTIONS, "minmax")
    assert result is None

def test_check_zero_forcing_est2_triggers():
    scored_context = {"EST2": {"min": "a", "likely": "a", "max": "b"}}
    result = check_zero_forcing("IMP3", scored_context, IMP1_OPTIONS, "minmax")
    assert result is not None
    assert result["min"] == "a"
    assert result["likely"] == "a"
    assert result["max"] is None      # EST2_max is "b", not "a"

def test_check_zero_forcing_boolean_forced():
    # Boolean zero_opt is None — "NO" answer
    scored_context = {"EST1": {"min": "a", "likely": "a", "max": "a"}}
    result = check_zero_forcing("IMP2.1", scored_context, BOOLEAN_OPTIONS, "boolean")
    assert result is not None
    forced_params = {f["parameter"] for f in result["flags"]}
    assert forced_params == {"min", "likely", "max"}
    # forced_option is None for boolean (the NO convention)
    assert all(f["forced_option"] is None for f in result["flags"])

def test_check_zero_forcing_pathway_ent2a_a_forces_ent3():
    scored_context = {"ENT2A": {"min": "a", "likely": "a", "max": "b"}}
    result = check_zero_forcing(
        "ENT3", scored_context, IMP1_OPTIONS, "minmax", is_pathway=True
    )
    assert result is not None
    assert result["min"] == "a"
    assert result["likely"] == "a"
    assert result["max"] is None

def test_check_zero_forcing_original_option_starts_none():
    # original_option is None until caller fills it after GPT runs
    scored_context = {"EST1": {"min": "a", "likely": "a", "max": "a"}}
    result = check_zero_forcing("IMP1", scored_context, IMP1_OPTIONS, "minmax")
    assert all(f["original_option"] is None for f in result["flags"])

def test_check_zero_forcing_no_upstream_in_context():
    # EST1 not yet scored — no forcing
    result = check_zero_forcing("IMP1", {}, IMP1_OPTIONS, "minmax")
    assert result is None
