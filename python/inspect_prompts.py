"""
FinnPRIO LLM Prompt Inspector

Renders all research prompts that populate_finnprio_justifications.py would
send to the LLM, without making any API calls.

For each question code the output shows:
  - The instructions fragment (output of build_justification_prompt)
  - The full research query (output of create_research_query, i.e. the
    exact string passed as query= to GPTResearcher)
  - Appended domain exclusions, as they appear in production

Usage:
    python inspect_prompts.py [--output FILE] [--species NAME]

Examples:
    python inspect_prompts.py --output prompt_inspection.md
    python inspect_prompts.py --species "Agrilus planipennis" --output agrilus_prompts.md
"""

import argparse
import os
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# ---------------------------------------------------------------------------
# Import prompt-building logic — do not duplicate, call originals.
# ---------------------------------------------------------------------------
# populate_finnprio_justifications.py requires gpt_researcher at module level.
# If unavailable (e.g. dev environment without the package), we fall back to
# instructions_loader alone, which covers the instructions fragment but cannot
# render the full wrapped query.
# ---------------------------------------------------------------------------

try:
    from populate_finnprio_justifications import create_research_query, EXCLUDED_DOMAINS
    _FULL_QUERY_AVAILABLE = True
except ImportError as _import_err:
    _FULL_QUERY_AVAILABLE = False
    EXCLUDED_DOMAINS: list = []
    print(
        f"[inspect_prompts] Warning: could not import populate_finnprio_justifications "
        f"({_import_err}).\n"
        f"  → 'Full Research Query' sections will be omitted.\n"
        f"  → Install gpt-researcher to enable them."
    )

from instructions_loader import load_instructions, build_justification_prompt

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_SPECIES = "Xylella fastidiosa"
DEFAULT_PATHWAY = "Plants for planting"

# Canonical question order matching the FinnPRIO assessment workflow
QUESTION_ORDER = [
    "ENT1",
    "ENT2A", "ENT2B", "ENT3", "ENT4",
    "EST1", "EST2", "EST3", "EST4",
    "IMP1", "IMP2.1", "IMP2.2", "IMP2.3", "IMP3", "IMP4.1", "IMP4.2", "IMP4.3",
    "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
]

PATHWAY_QUESTION_CODES = {"ENT2A", "ENT2B", "ENT3", "ENT4"}

# env keys read by GPTResearcher (set by populate_finnprio_justifications at import time)
_GPTR_ENV_KEYS = [
    "FAST_LLM", "SMART_LLM", "STRATEGIC_LLM",
    "TEMPERATURE", "REASONING_EFFORT",
    "EMBEDDING", "SIMILARITY_THRESHOLD",
    "RETRIEVER", "SCRAPER",
    "MAX_SEARCH_RESULTS_PER_QUERY", "TOTAL_WORDS",
    "REPORT_FORMAT", "CURATE_SOURCES", "LANGUAGE",
]

# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------

def _fence(text: str) -> str:
    return f"```\n{text.strip()}\n```"


def _gptr_config_section() -> str:
    rows = "\n".join(
        f"| `{k}` | `{os.environ.get(k, '(not set)')}` |"
        for k in _GPTR_ENV_KEYS
    )
    table = f"| Setting | Value |\n|---|---|\n{rows}"

    constructor = _fence(
        'report_type   = "research_report"\n'
        "tone          = Tone.Formal\n"
        'report_source = "web"'
    )

    domain_list = (
        ", ".join(f"`{d}`" for d in EXCLUDED_DOMAINS)
        if EXCLUDED_DOMAINS else "_none_"
    )

    return "\n\n".join([
        "## GPT Researcher Configuration",
        "_Environment variables set by `populate_finnprio_justifications.py` at import time._\n\n" + table,
        "**Fixed constructor args** (same for every question):\n\n" + constructor,
        f"**Excluded domains** (appended to query in production): {domain_list}",
    ])


def _build_question_section(code: str, q: dict, species: str) -> str:
    """Return the full markdown section for one question."""
    is_pathway_q = code in PATHWAY_QUESTION_CODES
    pathway_name = DEFAULT_PATHWAY if is_pathway_q else None

    # ── heading ──────────────────────────────────────────────────────────────
    pathway_note = f" _(example pathway: {DEFAULT_PATHWAY})_" if is_pathway_q else ""
    heading = f"## {code} — {q['text']}{pathway_note}"

    meta = (
        f"**Group:** {q['group']}  "
        f"**Type:** `{q['type']}`  "
        f"**Pathway question:** {'Yes' if q.get('is_pathway_question') else 'No'}"
    )

    if q['type'] != 'boolean':
        opts_summary = ", ".join(
            f"`{o['opt']}`" for o in q.get('options', [])
        ) or "_none_"
        meta += f"  \n**Options:** {opts_summary}"

    # ── host-constraint note ──────────────────────────────────────────────────
    host_related_prefixes = ("EST1", "EST2", "EST3", "IMP1", "IMP2", "IMP3", "IMP4")
    if code.startswith(host_related_prefixes):
        host_note = (
            "> **Note:** In production, host plants from the database are injected "
            "into this prompt under `DOCUMENTED HOST PLANTS`. "
            "That block is absent here because no database is connected."
        )
    else:
        host_note = ""

    # ── instructions fragment ─────────────────────────────────────────────────
    instructions_fragment = build_justification_prompt(code, species, pathway_name)

    fragment_section = (
        "### Instructions Fragment\n"
        "_Output of `build_justification_prompt()` — the question-specific context "
        "built from the Rmd instructions. This is the `{specific}` block embedded "
        "inside the full research query._\n\n"
        + _fence(instructions_fragment)
    )

    # ── full research query ───────────────────────────────────────────────────
    if _FULL_QUERY_AVAILABLE:
        full_query = create_research_query(
            pest_name=species,
            question_code=code,
            question_text=q["text"],
            question_info="",
            pathway_name=pathway_name,
            hosts="",
            exclude_domains=EXCLUDED_DOMAINS or None,
        )

        query_section = (
            "### Full Research Query\n"
            "_Passed as `query=` to `GPTResearcher()`. Contains the structured metadata "
            "header, question block, answering rules, sources, format rules, and "
            "excluded domains — assembled by `create_research_query()`._\n\n"
            + _fence(full_query)
        )
    else:
        query_section = (
            "### Full Research Query\n"
            "_Not available: `gpt_researcher` package not installed. "
            "The full query wraps the instructions fragment above with fixed "
            "SCOPE LIMITATION, RESEARCH REQUIREMENTS, and OUTPUT FORMAT blocks "
            "defined in `populate_finnprio_justifications.create_research_query()`._"
        )

    parts = [heading, meta]
    if host_note:
        parts.append(host_note)
    parts += [fragment_section, query_section, "---"]

    return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Render all LLM prompts from populate_finnprio_justifications.py "
            "without calling the LLM."
        )
    )
    parser.add_argument(
        "--output", "-o",
        default="prompt_inspection.md",
        help="Output markdown file (default: prompt_inspection.md)",
    )
    parser.add_argument(
        "--species", "-s",
        default=None,
        metavar="NAME",
        help=f'Species name for variable substitution (default: "{DEFAULT_SPECIES}")',
    )
    args = parser.parse_args()

    species = args.species or DEFAULT_SPECIES
    output_path = Path(args.output)

    print(f"[inspect_prompts] Loading instructions...")
    data = load_instructions()
    questions = data["questions"]

    lines: list[str] = [
        "# FinnPRIO LLM Prompt Inspection",
        "",
        f"**Species:** {species}  ",
        f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}  ",
        f"**Source script:** `populate_finnprio_justifications.py`",
        "",
        "> Prompts are shown exactly as they would be sent to the LLM. "
        "Variable parts: species name (shown above) and host plants "
        "(injected from the database at runtime — omitted here).",
        "",
        "---",
        "",
        _gptr_config_section(),
        "",
        "---",
        "",
        "## Prompts by Question",
        "",
        "_One section per question code in assessment order. "
        "Pathway questions (ENT2A/B, ENT3, ENT4) are shown with an example pathway "
        f'("{DEFAULT_PATHWAY}"); in production a separate prompt is sent per selected pathway._',
        "",
        "---",
        "",
    ]

    # Questions in canonical order, then any extras not in QUESTION_ORDER
    seen: set[str] = set()
    ordered = [c for c in QUESTION_ORDER if c in questions]
    extras = [c for c in questions if c not in set(QUESTION_ORDER)]

    for code in ordered + sorted(extras):
        seen.add(code)
        q = questions[code]
        print(f"[inspect_prompts] {code}")
        lines.append(_build_question_section(code, q, species))
        lines.append("")

    # Warn about codes in QUESTION_ORDER that are missing from instructions
    missing = [c for c in QUESTION_ORDER if c not in questions]
    if missing:
        lines.append("## Missing Questions")
        lines.append("")
        lines.append(
            "_The following codes appear in QUESTION_ORDER but were not found "
            "in the parsed instructions JSON:_"
        )
        lines.append("")
        for c in missing:
            lines.append(f"- `{c}`")
        lines.append("")

    output_path.write_text("\n".join(lines), encoding="utf-8")

    total = len(ordered) + len(extras)
    print(f"\n[inspect_prompts] Written: {output_path.resolve()}")
    print(f"[inspect_prompts] {total} questions × '{species}'")
    if _FULL_QUERY_AVAILABLE:
        print(f"[inspect_prompts] Full query rendered for all questions.")
    else:
        print(f"[inspect_prompts] Instructions fragments only (install gpt-researcher for full queries).")


if __name__ == "__main__":
    main()
