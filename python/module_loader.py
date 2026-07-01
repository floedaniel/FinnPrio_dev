"""Load FinnPRIO question modules and lightly clean report output.

Used only by populate_finnprio_justifications_custom.py. Each module file in
finnprio_question_modules/ holds the question, options, guidance, and headings
for one question code, and is passed verbatim into the custom_report query.

Kept dependency-free (only stdlib) so the pure helpers are unit-testable without
triggering the main script's import-time side effects (API-key loading, retriever
registration).
"""

import re
from pathlib import Path

MODULES_DIR = Path(__file__).resolve().parent.parent / "finnprio_question_modules"

_cache: dict = {}


def normalize_code(code: str) -> str:
    """Canonical form: uppercase, no trailing dot.

    "ENT1." -> "ENT1", "est2" -> "EST2", "IMP2.1" -> "IMP2.1", "ENT2A" -> "ENT2A"
    """
    return code.upper().rstrip('.')


def load_module(code: str) -> str:
    """Return the raw Markdown text of the question module for `code`.

    Resolves to MODULES_DIR / f"{normalize_code(code)}.md". Cached per run.
    Raises FileNotFoundError naming the code and expected path if missing.
    """
    norm = normalize_code(code)
    if norm in _cache:
        return _cache[norm]
    path = MODULES_DIR / f"{norm}.md"
    if not path.exists():
        raise FileNotFoundError(
            f"Question module not found for code '{code}' "
            f"(normalized '{norm}'): expected {path}"
        )
    text = path.read_text(encoding='utf-8').strip()
    _cache[norm] = text
    return text


def strip_light(text: str) -> str:
    """Remove only heading markers, bold, and italic markers; keep all text.

    Everything else (lists, links, tables) is left untouched. Heading text is
    preserved as a plain line — only the leading '#' markers are removed.
    """
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)  # headings -> plain line
    text = re.sub(r'(?<!\w)\*\*([^*]+)\*\*(?!\w)', r'\1', text)   # **bold**
    text = re.sub(r'(?<!\w)__([^_]+)__(?!\w)', r'\1', text)       # __bold__
    text = re.sub(r'(?<!\w)\*([^*]+)\*(?!\w)', r'\1', text)       # *italic*
    text = re.sub(r'(?<!\w)_([^_]+)_(?!\w)', r'\1', text)         # _italic_
    return text.strip()
