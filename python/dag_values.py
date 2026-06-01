"""
DAG enforcement layer for populate_finnprio_values.py.

Stateless functions only — no database connection, no global state.
The caller owns all mutable state: scored_context, scored_context_pathway,
options_map.

Reuses QUESTION_DEPENDENCIES, PATHWAY_DEPENDENCIES, SIBLING_CONSTRAINTS
from dag_config.py. Adds values-side enforcement: zero-forcing, topological
sort, sibling clamp, scored-value context builder, JSONL audit writer.
"""

import json
from collections import deque
from typing import Dict, List, Optional

from dag_config import QUESTION_DEPENDENCIES, PATHWAY_DEPENDENCIES, SIBLING_CONSTRAINTS


# ─── Enforcement constants ────────────────────────────────────────────────────

ZERO_FORCING_RULES: Dict[str, Dict] = {
    "EST1": {
        "zero_option": "a",
        "targets": [
            "IMP1", "IMP2.1", "IMP2.3", "IMP3",
            "IMP4.1", "IMP4.2", "IMP4.3",
        ],
        "reason": (
            "EST1='a' (climate unsuitable): establishment score is zero by definition "
            "(Heikkila et al. 2016, p. 1832); direct impacts in Norway must be zero."
        ),
    },
    "EST2": {
        "zero_option": "a",
        "targets": [
            "IMP1", "IMP2.1", "IMP2.3", "IMP3",
            "IMP4.1", "IMP4.2", "IMP4.3",
        ],
        "reason": (
            "EST2='a' (no host plants in Norway): establishment score is zero by definition "
            "(Heikkila et al. 2016, p. 1832); direct impacts in Norway must be zero."
        ),
    },
}

PATHWAY_ZERO_FORCING_RULES: Dict[str, Dict] = {
    "ENT2A": {
        "zero_option": "a",
        "targets": ["ENT3"],
        "reason": (
            "ENT2A='a' (pest cannot be transported via this pathway): ENT3 (trade volume) "
            "contributes zero regardless of volume (Heikkila et al. 2016, Table 2, p. 1830)."
        ),
    },
}

PATHWAY_VALUES_DEPENDENCIES: Dict[str, List[str]] = dict(PATHWAY_DEPENDENCIES)
PATHWAY_VALUES_DEPENDENCIES["ENT3"] = ["ENT2A"]
# Ordering-only. ENT2A must be scored before ENT3 so Tier 1 zero-forcing
# can read scored_context_pathway["ENT2A"]. Table 2 non-zero rows are
# applied at simulation time in simulations.R — ENT2A is NOT injected
# into the ENT3 GPT prompt. Do not add ENT2A to ENT3's context block.


# ─── Functions ───────────────────────────────────────────────────────────────

def _normalize(code: str) -> str:
    """Canonical question code: uppercase, no trailing dot."""
    return code.upper().rstrip('.')


def get_zero_option(options: List[Dict], question_type: str = "minmax") -> Optional[str]:
    """Return the opt code whose points == 0, or None for boolean questions.

    Uses float() cast to guard against DB-returned strings and non-integer
    values (EST1: 0/1.5/4.5/9; ENT2: 0/0.5/1/2/3).
    Raises ValueError if no zero-points option exists (degenerate — not in schema).
    """
    if question_type == "boolean":
        return None
    zero_opts = [o for o in options if float(o["points"]) == 0.0]
    if not zero_opts:
        raise ValueError(
            f"No zero-points option found. Options: {[o['opt'] for o in options]}"
        )
    return zero_opts[0]["opt"]


def topological_sort_answers(
    answers: List[Dict], is_pathway: bool = False
) -> List[Dict]:
    """Sort answers in dependency order using Kahn's algorithm.

    Uses PATHWAY_VALUES_DEPENDENCIES when is_pathway=True (which adds the
    ordering-only ENT2A→ENT3 edge), QUESTION_DEPENDENCIES otherwise.
    Questions not in the dependency map are treated as having no deps.
    """
    deps = PATHWAY_VALUES_DEPENDENCIES if is_pathway else QUESTION_DEPENDENCIES
    code_to_q = {_normalize(q["code"]): q for q in answers}
    codes = sorted(code_to_q.keys())

    in_degree: Dict[str, int] = {c: 0 for c in codes}
    adj: Dict[str, List[str]] = {c: [] for c in codes}

    for code in codes:
        for dep in deps.get(code, []):
            if dep in code_to_q:
                in_degree[code] += 1
                adj[dep].append(code)

    queue = deque(sorted(c for c in codes if in_degree[c] == 0))
    result: List[Dict] = []

    while queue:
        node = queue.popleft()
        result.append(code_to_q[node])
        for dependent in sorted(adj[node]):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)

    # Append any remaining (cycle guard — not expected in this schema)
    processed = {_normalize(q["code"]) for q in result}
    result.extend(code_to_q[c] for c in codes if c not in processed)

    return result


def check_zero_forcing(
    question_code: str,
    scored_context: Dict[str, Dict[str, str]],
    options: List[Dict],
    question_type: str = "minmax",
    is_pathway: bool = False,
) -> Optional[Dict]:
    """Tier 1 zero-force check.

    Returns a result dict when at least one parameter must be forced to the
    zero option, or None if no rule fires.

    result = {
        "min":    opt_or_None,   # forced value; None = this param not forced
        "likely": opt_or_None,
        "max":    opt_or_None,
        "flags": [{
            "parameter":       str,
            "rule_fired":      str,
            "original_option": None,   # filled by caller after GPT if GPT ran
            "forced_option":   str | None,
        }]
    }

    forced_option is None for boolean questions (the NO convention).
    """
    rules = PATHWAY_ZERO_FORCING_RULES if is_pathway else ZERO_FORCING_RULES
    code = _normalize(question_code)
    zero_opt = get_zero_option(options, question_type)

    result: Dict = {"min": None, "likely": None, "max": None, "flags": []}
    any_forced = False

    for upstream_code, rule in rules.items():
        if code not in rule["targets"]:
            continue
        upstream = scored_context.get(upstream_code)
        if not upstream:
            continue
        for param in ("min", "likely", "max"):
            if upstream.get(param) == rule["zero_option"]:
                result[param] = zero_opt
                any_forced = True
                result["flags"].append({
                    "parameter": param,
                    "rule_fired": f"{upstream_code}={rule['zero_option']}→{code}=zero",
                    "original_option": None,
                    "forced_option": zero_opt,
                    "reason": rule["reason"],
                })

    return result if any_forced else None


def check_sibling_clamp(
    question_code: str,
    values: Dict[str, Optional[str]],
    scored_context: Dict[str, Dict[str, str]],
    options_map: Dict[str, List[Dict]],
) -> Optional[Dict]:
    """Post-GPT sibling clamp (currently ENT2B ≤ ENT2A).

    Compares each parameter's points to the sibling's corresponding parameter.
    Returns a clamped result dict with flags, or None if no clamp is needed.

    result = {
        "min": opt, "likely": opt, "max": opt,
        "flags": [{"parameter", "rule_fired", "original_option", "forced_option"}]
    }
    """
    code = _normalize(question_code)
    if code not in SIBLING_CONSTRAINTS:
        return None

    sc = SIBLING_CONSTRAINTS[code]
    sibling_code = _normalize(sc["sibling"])
    sibling_scored = scored_context.get(sibling_code)
    sibling_opts = options_map.get(sibling_code, [])
    own_opts = options_map.get(code, [])

    if not sibling_scored or not sibling_opts or not own_opts:
        return None

    sibling_pts: Dict[str, float] = {o["opt"]: float(o["points"]) for o in sibling_opts}
    own_pts: Dict[str, float] = {o["opt"]: float(o["points"]) for o in own_opts}

    result: Dict = {
        "min": values.get("min"),
        "likely": values.get("likely"),
        "max": values.get("max"),
        "flags": [],
    }
    any_clamped = False

    for param in ("min", "likely", "max"):
        own_val = values.get(param)
        sib_val = sibling_scored.get(param)
        if own_val is None or sib_val is None:
            continue
        if own_pts.get(own_val, 0.0) > sibling_pts.get(sib_val, 0.0):
            result[param] = sib_val
            any_clamped = True
            result["flags"].append({
                "parameter": param,
                "rule_fired": f"{code}>{sibling_code} clamp",
                "original_option": own_val,
                "forced_option": sib_val,
            })

    return result if any_clamped else None
