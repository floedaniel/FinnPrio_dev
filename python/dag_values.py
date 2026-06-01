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
