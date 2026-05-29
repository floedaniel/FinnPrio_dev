"""
FinnPRIO DAG configuration — question dependencies and sibling constraints.

This module encodes the logical dependency structure of the FinnPRIO assessment
framework as machine-readable rules.  All entries are sourced directly from the
question guidance text in:

    information/Instructions_FinnPRIO_assessments.Rmd

Do NOT modify these dicts without consulting the Rmd first.  The Rmd is the
authoritative source; these dicts are derived, not invented.
"""

# All question codes are dot-free canonical form: "EST2", "IMP2.1", "ENT2A".

# Regular question dependencies: {question_code: [list_of_dependency_codes]}
# Empty list means no dependencies — process in any order.
QUESTION_DEPENDENCIES = {
    "ENT1":   [],
    "EST1":   ["ENT1"],
    "EST2":   ["EST1"],
    "EST3":   ["EST1", "EST2"],
    "EST4":   [],
    "IMP1":   ["EST1", "EST2"],
    "IMP2.1": ["EST1", "EST2"],
    "IMP2.2": [],              # biological fact (vector status) — independent
    "IMP2.3": ["EST1", "EST2"],
    "IMP3":   ["EST1", "EST2"],
    "IMP4.1": ["EST1", "EST2"],
    "IMP4.2": ["EST1", "EST2"],
    "IMP4.3": ["EST1", "EST2"],
    "MAN1":   ["ENT1"],
    "MAN2":   [],
    "MAN3":   [],
    "MAN4":   [],
    "MAN5":   ["EST3"],
}

# Pathway question dependencies: {pathway_question_code: [list_of_dependency_codes]}
# Deps may be regular question codes (e.g. "ENT1") or same-pathway codes (e.g. "ENT2A").
# Cross-pathway dependencies do not exist — these are always re-instantiated per pathway.
PATHWAY_DEPENDENCIES = {
    "ENT2A": ["ENT1"],
    "ENT2B": ["ENT2A"],
    "ENT3":  [],
    "ENT4":  ["ENT2A", "ENT3"],
}

# Sibling constraints: qualitative rules enforced via prompt injection.
# These apply where two questions describe the same thing under different conditions
# and their conclusions must be logically consistent.
# Numeric enforcement (score comparison) belongs in populate_finnprio_values.py.
SIBLING_CONSTRAINTS = {
    "ENT2B": {
        "sibling": "ENT2A",
        "rule": (
            "ENT2B describes the same pathway WITH phytosanitary management. "
            "Your conclusion must be less favourable or equal to ENT2A — "
            "management can only reduce or maintain entry probability, never increase it."
        ),
    },
}
