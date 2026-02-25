"""
FinnPRIO Instructions Loader

Provides unified access to parsed Rmd instructions for all populate scripts.
Handles auto-regeneration, caching, and instruction lookup.

Usage:
    from instructions_loader import load_instructions, build_justification_prompt

    # Load all instructions
    instructions = load_instructions()

    # Build prompt for a specific question
    prompt = build_justification_prompt('ENT1', 'Xylella fastidiosa')
"""

import json
from pathlib import Path
from typing import Dict, List, Optional
from datetime import datetime

# Default paths
DEFAULT_RMD_PATH = Path(__file__).parent.parent / "information" / "Instructions_FinnPRIO_assessments.Rmd"
DEFAULT_JSON_PATH = Path(__file__).parent / "instructions_cache" / "finnprio_instructions.json"

# In-memory cache
_cached_instructions: Optional[Dict] = None


def load_instructions(
    rmd_path: str = None,
    json_path: str = None,
    force_reload: bool = False
) -> Dict:
    """
    Load instructions with auto-regeneration.

    Caches in memory for subsequent calls within the same session.

    Args:
        rmd_path: Path to Rmd source file
        json_path: Path to JSON cache file
        force_reload: Force reload from disk (bypass memory cache)

    Returns:
        Dict containing all parsed instructions
    """
    global _cached_instructions

    if _cached_instructions and not force_reload:
        return _cached_instructions

    rmd_path = Path(rmd_path) if rmd_path else DEFAULT_RMD_PATH
    json_path = Path(json_path) if json_path else DEFAULT_JSON_PATH

    # Check if regeneration needed
    needs_regen = False

    if not json_path.exists():
        needs_regen = True
        print("[Instructions] JSON cache not found, generating...")
    elif rmd_path.exists() and rmd_path.stat().st_mtime > json_path.stat().st_mtime:
        needs_regen = True
        print("[Instructions] Rmd file modified, regenerating JSON...")

    if needs_regen:
        from parse_rmd_instructions import parse_rmd_to_json
        json_path.parent.mkdir(parents=True, exist_ok=True)
        _cached_instructions = parse_rmd_to_json(str(rmd_path), str(json_path), force=True)
    else:
        print("[Instructions] Using cached JSON")
        _cached_instructions = json.loads(json_path.read_text(encoding='utf-8'))

    return _cached_instructions


def get_question_instructions(question_code: str) -> Dict:
    """
    Get complete instructions for a specific question.

    Args:
        question_code: e.g., "ENT1", "EST4", "IMP2.1"

    Returns:
        Question dict with text, options, guidance, etc.

    Raises:
        KeyError: If question not found in instructions.
    """
    instructions = load_instructions()

    # Handle sub-questions (IMP2.1 -> IMP2)
    base_code = question_code.split('.')[0]

    # Also handle codes with trailing dot (ENT1. -> ENT1)
    base_code = base_code.rstrip('.')

    question = instructions.get('questions', {}).get(base_code)
    if not question:
        available = list(instructions.get('questions', {}).keys())
        raise KeyError(f"Question '{question_code}' not found in instructions. Available: {available}")

    # For sub-questions, add sub_question context
    if '.' in question_code and question.get('sub_questions'):
        for subq in question['sub_questions']:
            if subq['code'] == question_code:
                return {
                    **question,
                    'current_subquestion': subq
                }

    return question


def build_justification_prompt(
    question_code: str,
    pest_name: str,
    pathway_name: str = None,
    hosts: str = None
) -> str:
    """
    Build research prompt for justification generation.

    Uses structured instructions from JSON to create a comprehensive
    research prompt with options, guidance, and constraints.

    Args:
        question_code: Question code (e.g., "ENT1", "EST4")
        pest_name: Scientific name of the pest
        pathway_name: Name of pathway (for pathway-specific questions)
        hosts: Host plants from database (for EST2 and other host-related questions)

    Returns:
        Formatted prompt string for GPT Researcher
    """
    q = get_question_instructions(question_code)  # Raises KeyError if not found

    pathway_text = f' via the pathway "{pathway_name}"' if pathway_name else ""

    # Build the prompt
    prompt_parts = []

    # Question header
    prompt_parts.append(f"""Answer the following question about {pest_name}{pathway_text}:

QUESTION ({q['code']}): {q['text']}""")

    # Add hosts information for host-related questions
    host_related_questions = ['EST1', 'EST2', 'EST3', 'IMP1', 'IMP2', 'IMP3', 'IMP4']
    if hosts and question_code in host_related_questions:
        prompt_parts.append(f"""

HOST PLANTS FOR THIS PEST (from database):
{hosts}

Use these specific host plants when researching host distribution, cultivation areas, and impacts in Norway.""")

    # Add options with descriptions (new format)
    options = q.get('options', [])
    if options:
        prompt_parts.append("\n\nAVAILABLE OPTIONS:")
        for opt in options:
            desc = f" - {opt['description']}" if opt.get('description') else ""
            prompt_parts.append(f"{opt['opt'].upper()}. {opt['text']}{desc}")

    # Add guidance (new format - replaces old sections)
    guidance = q.get('guidance', [])
    if guidance:
        prompt_parts.append("\n\nGUIDANCE:")
        for item in guidance:
            prompt_parts.append(f"- {item}")

    # Add EST4 scoring characteristics if present
    scoring_chars = q.get('scoring_characteristics', [])
    if scoring_chars:
        prompt_parts.append("\n\nCHARACTERISTICS TO EVALUATE (score 1-2 points each):")
        for char in scoring_chars:
            prompt_parts.append(f"- {char}")

    # Add sub-questions for IMP2/IMP4
    sub_questions = q.get('sub_questions', [])
    if sub_questions:
        prompt_parts.append("\n\nSUB-QUESTIONS TO ADDRESS:")
        for subq in sub_questions:
            desc = f" ({subq['description']})" if subq.get('description') else ""
            prompt_parts.append(f"- {subq['code']}: {subq['text']}{desc}")

    # Add additional notes
    if q.get('additional_notes'):
        prompt_parts.append(f"\n\nADDITIONAL CONTEXT: {q['additional_notes']}")

    # Add sub-question context if applicable
    if q.get('current_subquestion'):
        subq = q['current_subquestion']
        prompt_parts.append(f"\n\nSPECIFIC SUB-QUESTION: {subq['text']}")
        if subq.get('description'):
            prompt_parts.append(f"Context: {subq['description']}")

    return '\n'.join(prompt_parts)


def build_value_selection_prompt(
    question_code: str,
    pest_name: str,
    justification: str,
    options_override: List[Dict] = None
) -> str:
    """
    Build prompt for value (min/likely/max) selection.

    Includes full instructions from Rmd so AI can compare justification against criteria.

    Args:
        question_code: Question code (e.g., "ENT1", "EST4")
        pest_name: Scientific name of the pest
        justification: The AI-generated justification text to analyze
        options_override: Override options (from database) if different from Rmd

    Returns:
        Formatted prompt string for GPT value selection
    """
    q = get_question_instructions(question_code)

    if not q:
        # Minimal fallback
        return f"""Analyze the justification for {pest_name} and select min/likely/max values.

JUSTIFICATION:
{justification}

Return JSON: {{"min": "a", "likely": "b", "max": "c"}}"""

    options = options_override or q.get('options', [])
    question_type = q.get('type', 'minmax')

    # Build FULL options text with descriptions
    options_text = ""
    for opt in options:
        options_text += f"\n\n**{opt['opt'].upper()}. {opt['text']}**"
        if opt.get('description'):
            options_text += f"\n{opt['description']}"

    # Build guidance text
    guidance_text = ""
    guidance = q.get('guidance', [])
    if guidance:
        guidance_text = "\n\nGUIDANCE FOR ANSWERING:\n"
        for item in guidance:
            guidance_text += f"- {item}\n"

    # Add scoring characteristics for EST4
    scoring_chars = q.get('scoring_characteristics', [])
    if scoring_chars:
        guidance_text += "\nCHARACTERISTICS TO SCORE:\n"
        for char in scoring_chars:
            guidance_text += f"- {char}\n"

    if question_type == "minmax":
        prompt = f"""TASK: Compare the JUSTIFICATION against the ANSWER OPTIONS and select min/likely/max.

===== QUESTION =====
{q['code']}: {q['text']}

===== ANSWER OPTIONS (from FinnPRIO instructions) ====={options_text}
{guidance_text}
===== JUSTIFICATION TO EVALUATE =====
{justification}

===== YOUR TASK =====
Compare the justification above against each answer option.

1. Which option does the justification's MAIN CONCLUSION match? -> This is LIKELY
2. What is the LOWEST option that could apply based on the justification? -> This is MIN
3. What is the HIGHEST option that could apply based on the justification? -> This is MAX

RULES:
- The justification may explicitly state an option (e.g., "A. No, it cannot") - use that
- Match numbers in the justification to thresholds in the options
- If the justification is certain/definitive, min and max should equal likely
- If the justification mentions uncertainty or a range, reflect that in min/max

Return ONLY: {{"min": "a", "likely": "b", "max": "c"}}"""

    else:  # boolean type (IMP2, IMP4)
        # Get sub-questions if available
        sub_questions = q.get('sub_questions', [])
        sub_q_text = ""
        if sub_questions:
            sub_q_text = "\n\nSUB-QUESTIONS:\n"
            for sq in sub_questions:
                sub_q_text += f"- {sq['code']}: {sq['text']}\n"
                if sq.get('description'):
                    sub_q_text += f"  {sq['description']}\n"

        option_code = options[0]['opt'] if options else 'a'
        option_text = options[0]['text'] if options else 'Yes'

        prompt = f"""TASK: Determine YES/NO based on the justification.

===== QUESTION =====
{q['code']}: {q['text']}
{sub_q_text}
{guidance_text}
===== JUSTIFICATION TO EVALUATE =====
{justification}

===== YOUR TASK =====
Does the justification support YES or NO for this question?

- If justification says this impact/effect DOES occur -> YES
- If justification says this impact/effect does NOT occur -> NO
- If justification does not mention this topic -> NO

If YES: {{"min": "{option_code}", "likely": "{option_code}", "max": "{option_code}"}}
If NO: {{"min": null, "likely": null, "max": null}}

Return ONLY the JSON object."""

    return prompt


def get_option_points(question_code: str, option: str) -> int:
    """
    Get points value for an option.

    Args:
        question_code: Question code
        option: Option letter (a, b, c, etc.)

    Returns:
        Points value, or 0 if not found
    """
    q = get_question_instructions(question_code)
    for opt in q.get('options', []):
        if opt['opt'] == option.lower():
            return opt['points']
    return 0


def get_all_question_codes() -> List[str]:
    """Get list of all question codes."""
    instructions = load_instructions()
    return list(instructions.get('questions', {}).keys())


def get_pathway_question_codes() -> List[str]:
    """Get list of pathway-specific question codes."""
    instructions = load_instructions()
    return [
        code for code, q in instructions.get('questions', {}).items()
        if q.get('is_pathway_question')
    ]


def is_pathway_question(question_code: str) -> bool:
    """Check if a question is pathway-specific."""
    q = get_question_instructions(question_code)
    return q.get('is_pathway_question', False)


def clear_cache():
    """Clear the in-memory cache."""
    global _cached_instructions
    _cached_instructions = None
    print("[Instructions] Cache cleared")


if __name__ == "__main__":
    # Test the loader
    print("Testing instructions loader...")
    print("=" * 60)

    # Load instructions
    instructions = load_instructions()
    print(f"Loaded {len(instructions.get('questions', {}))} questions")

    # Test question lookup
    print("\nTesting question lookup:")
    for code in ['ENT1', 'EST4', 'IMP2', 'MAN3']:
        q = get_question_instructions(code)
        print(f"  {code}: {q.get('text', 'NOT FOUND')[:50]}...")
        print(f"    Options: {len(q.get('options', []))}")
        print(f"    Guidance: {len(q.get('guidance', []))}")

    # Test prompt building
    print("\nTesting prompt building (ENT1):")
    prompt = build_justification_prompt('ENT1', 'Xylella fastidiosa')
    print(f"  Prompt length: {len(prompt)} chars")
    print(f"  First 300 chars:\n{prompt[:300]}...")

    # Test value selection prompt
    print("\nTesting value selection prompt (ENT1):")
    value_prompt = build_value_selection_prompt(
        'ENT1',
        'Xylella fastidiosa',
        'The pest has a wide distribution across Mediterranean regions and parts of the Americas, covering approximately 5 million km².'
    )
    print(f"  Prompt length: {len(value_prompt)} chars")

    # Test pathway questions
    print("\nPathway questions:")
    print(f"  {get_pathway_question_codes()}")
