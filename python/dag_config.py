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
    "EST1":   [],              # No Rmd-cited dependency; EST1 depends on pest biology vs
                               # Norwegian climate, not global range (ENT1 removed 2026-05-29).
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
    "MAN1":   ["ENT1"],        # ENT1 is weak ordering context: global range gives approximate
                               # distance from Norway. The stronger prior — natural spread
                               # pathway assessment (ENT2A) — would require cross-table dep
                               # wiring not currently supported. Flag if interface is extended.
    "MAN2":   [],
    "MAN3":   [],
    "MAN4":   [],              # Possible EST1 dep (outdoor spread context) but not explicit
                               # in Rmd. Flagged 2026-05-29 — do not add without Rmd citation.
    "MAN5":   ["EST3", "EST2"],# EST3 = spread rate (Rmd: "Pest's natural potential to spread");
                               # EST2 = host distribution (Rmd: "Abundance and distribution of
                               # host plants"). Both explicitly listed in MAN5 guidance.
}

# Pathway question dependencies: {pathway_question_code: [list_of_dependency_codes]}
# Deps may be regular question codes (e.g. "ENT1") or same-pathway codes (e.g. "ENT2A").
# Cross-pathway dependencies do not exist — these are always re-instantiated per pathway.
PATHWAY_DEPENDENCIES = {
    "ENT2A": ["ENT1"],
    "ENT2B": ["ENT2A"],
    "ENT3":  [],
    "ENT4":  ["ENT2A"],        # ENT2A retained (same-pathway transport context).
                               # ENT3 removed 2026-05-29 — Rmd ENT4 guidance references
                               # season and destination/use, not trade volume. Same logic
                               # applies here as in QUESTION_DEPENDENCIES["ENT4"].
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
