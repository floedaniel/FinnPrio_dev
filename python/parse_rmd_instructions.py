"""
FinnPRIO Rmd Instructions Parser

Parses Instructions_FinnPRIO_assessments.Rmd and generates structured JSON.

Features:
- Extracts all questions with full context
- Handles new clean format with ### Options and ### Guidance sections
- Parses options with descriptions
- Handles special cases (EST4 scoring, IMP2/IMP4 boolean sub-questions)
- Unicode-safe (handles special characters)
- Generates versioned JSON with source metadata

Usage:
    python parse_rmd_instructions.py
    python parse_rmd_instructions.py --force
    python parse_rmd_instructions.py path/to/Instructions.Rmd --output path/to/output.json
"""

import re
import json
import hashlib
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple

# Default paths
DEFAULT_RMD_PATH = Path(__file__).parent.parent / "information" / "Instructions_FinnPRIO_assessments.Rmd"
DEFAULT_JSON_PATH = Path(__file__).parent / "instructions_cache" / "finnprio_instructions.json"


class RmdParsingError(Exception):
    """Raised when Rmd parsing fails"""
    pass


class RmdInstructionsParser:
    """Parser for FinnPRIO Instructions Rmd file (new clean format)"""

    # Question code patterns - matches ## ENT1. or ## MAN1. etc.
    QUESTION_PATTERN = re.compile(
        r'^##\s+(?P<code>(?:ENT|EST|IMP|MAN)\d+[AB]?)\.\s*(?P<text>.+)$',
        re.MULTILINE
    )

    def __init__(self, rmd_path: str):
        self.rmd_path = Path(rmd_path)
        self.content = ""
        self.questions: Dict[str, Dict] = {}
        self.pathways: Dict = {}

    def parse(self) -> Dict:
        """Main parsing method"""
        self._load_file()
        self._parse_pathways()
        self._parse_questions()
        self._validate()
        return self._build_output()

    def _load_file(self):
        """Load Rmd file with UTF-8 encoding"""
        if not self.rmd_path.exists():
            raise RmdParsingError(f"Rmd file not found: {self.rmd_path}")

        with open(self.rmd_path, 'r', encoding='utf-8') as f:
            self.content = f.read()

        if not self.content.strip():
            raise RmdParsingError(f"Rmd file is empty: {self.rmd_path}")

    def _parse_pathways(self):
        """Parse pathway definitions from Pathways section"""
        pathways_match = re.search(
            r'^## Pathways\s*\n(.*?)(?=^## |\Z)',
            self.content,
            re.MULTILINE | re.DOTALL
        )
        if pathways_match:
            self.pathways = self._extract_pathway_types(pathways_match.group(1))

    def _extract_pathway_types(self, section: str) -> Dict:
        """Extract pathway type definitions"""
        categories = []
        current_category = None
        current_types = []

        lines = section.split('\n')
        for line in lines:
            line_stripped = line.strip()

            # Category header: **Host plant commodities**
            if line_stripped.startswith('**') and line_stripped.endswith('**') and not line_stripped.startswith('- **'):
                if current_category:
                    categories.append({
                        'name': current_category,
                        'types': current_types
                    })
                current_category = line_stripped.strip('*').strip()
                current_types = []

            # Pathway type: - **Seeds** or - **Seeds:** description
            elif line_stripped.startswith('- **'):
                match = re.match(r'^-\s+\*\*(.+?)\*\*(?::\s*(.*))?$', line_stripped)
                if match:
                    current_types.append({
                        'id': self._to_snake_case(match.group(1)),
                        'name': match.group(1),
                        'description': (match.group(2) or "").strip()
                    })

        # Add last category
        if current_category:
            categories.append({
                'name': current_category,
                'types': current_types
            })

        return {
            'description': 'Entry pathway types and definitions',
            'categories': categories
        }

    def _parse_questions(self):
        """Parse all questions from Rmd"""
        for match in self.QUESTION_PATTERN.finditer(self.content):
            code = match.group('code')
            text = match.group('text').strip()

            # Extract content until next ## header
            start = match.end()
            next_h2 = re.search(r'^## ', self.content[start:], re.MULTILINE)
            end = start + next_h2.start() if next_h2 else len(self.content)
            content = self.content[start:end]

            self.questions[code] = self._parse_question(code, text, content)

    def _parse_question(self, code: str, text: str, content: str) -> Dict:
        """Parse a single question section"""
        question = {
            'code': code,
            'group': self._determine_group(code),
            'subgroup': self._determine_subgroup(code),
            'text': text.strip(),
            'type': self._determine_type(code),
            'is_pathway_question': code in ['ENT2A', 'ENT2B', 'ENT3', 'ENT4'],
            'options': [],
            'guidance': [],
            'additional_notes': ""
        }

        # Parse ### Options section
        question['options'] = self._extract_options(code, content)

        # Parse ### Guidance section
        question['guidance'] = self._extract_guidance(content)

        # Extract text before first ### section as additional notes
        question['additional_notes'] = self._extract_additional_notes(content)

        # Handle special cases
        if code == 'EST4':
            question['scoring_characteristics'] = self._extract_est4_characteristics(content)

        if code in ['IMP2', 'IMP4']:
            question['sub_questions'] = self._extract_sub_questions(content)

        return question

    def _determine_group(self, code: str) -> str:
        """Determine question group from code"""
        if code.startswith('ENT'):
            return 'ENTRY'
        elif code.startswith('EST'):
            return 'ESTABLISHMENT AND SPREAD'
        elif code.startswith('IMP'):
            return 'IMPACT'
        elif code.startswith('MAN'):
            return 'MANAGEMENT'
        return 'UNKNOWN'

    def _determine_subgroup(self, code: str) -> Optional[str]:
        """Determine question subgroup (for MAN questions)"""
        if code in ['MAN1', 'MAN2', 'MAN3']:
            return 'Preventability'
        elif code in ['MAN4', 'MAN5']:
            return 'Controllability'
        return None

    def _determine_type(self, code: str) -> str:
        """Determine question type (minmax or boolean)"""
        if code in ['IMP2', 'IMP4']:
            return 'boolean'
        return 'minmax'

    def _extract_options(self, code: str, content: str) -> List[Dict]:
        """Extract options from ### Options section"""
        options = []

        # Find ### Options section
        options_match = re.search(r'^### Options\s*\n(.*?)(?=^###|\Z)', content, re.MULTILINE | re.DOTALL)
        if not options_match:
            return options

        options_content = options_match.group(1)

        # IMP2 and IMP4 are boolean - no options to extract
        if code in ['IMP2', 'IMP4']:
            return []

        # Parse options: **a. Text** (detail) followed by description paragraph
        # Pattern handles: **a. Small** (<2 million km²) or **a.** It would not cause...
        current_option = None
        current_letter = None
        current_title = None
        current_description_lines = []

        for line in options_content.split('\n'):
            line_stripped = line.strip()

            # Check for option header: **a. Small** or **a.** text
            opt_match = re.match(r'^\*\*([a-m])\.?\s*(.+?)\*\*(?:\s*(.*))?$', line_stripped)
            if opt_match:
                # Save previous option
                if current_letter:
                    options.append({
                        'opt': current_letter,
                        'text': current_title,
                        'description': ' '.join(current_description_lines).strip() if current_description_lines else None,
                        'points': ord(current_letter) - ord('a') + 1
                    })

                current_letter = opt_match.group(1)
                current_title = opt_match.group(2).strip()
                # If there's text after the bold header on same line
                extra = opt_match.group(3)
                current_description_lines = [extra.strip()] if extra and extra.strip() else []

            # Description line (not empty, not a new option, not a header)
            elif line_stripped and not line_stripped.startswith('**') and not line_stripped.startswith('#') and current_letter:
                current_description_lines.append(line_stripped)

        # Save last option
        if current_letter:
            options.append({
                'opt': current_letter,
                'text': current_title,
                'description': ' '.join(current_description_lines).strip() if current_description_lines else None,
                'points': ord(current_letter) - ord('a') + 1
            })

        return options

    def _extract_guidance(self, content: str) -> List[str]:
        """Extract guidance bullet points from ### Guidance section"""
        guidance = []

        # Find ### Guidance section
        guidance_match = re.search(r'^### Guidance\s*\n(.*?)(?=^###|\Z)', content, re.MULTILINE | re.DOTALL)
        if not guidance_match:
            return guidance

        guidance_content = guidance_match.group(1)

        # Parse bullet points and plain text
        current_section = None  # Track "Take into account:" etc.
        current_bullets = []

        for line in guidance_content.split('\n'):
            line_stripped = line.strip()

            # Skip separator lines and empty lines
            if not line_stripped or line_stripped.startswith('---'):
                continue

            # Section headers like "Take into account:"
            if line_stripped.endswith(':') and not line_stripped.startswith('-'):
                if current_section and current_bullets:
                    guidance.append(f"{current_section} {'; '.join(current_bullets)}")
                    current_bullets = []
                current_section = line_stripped
            # Bullet point
            elif line_stripped.startswith('- '):
                bullet_text = line_stripped[2:].strip()
                if current_section:
                    current_bullets.append(bullet_text)
                else:
                    guidance.append(bullet_text)
            # Plain text (not bullet, not header)
            elif not line_stripped.startswith('#'):
                if current_section:
                    current_bullets.append(line_stripped)
                else:
                    guidance.append(line_stripped)

        # Save last section
        if current_section and current_bullets:
            guidance.append(f"{current_section} {'; '.join(current_bullets)}")

        return guidance

    def _extract_additional_notes(self, content: str) -> str:
        """Extract notes before first ### section"""
        first_h3 = re.search(r'^###\s', content, re.MULTILINE)
        if not first_h3:
            notes = content
        else:
            notes = content[:first_h3.start()]

        # Clean up
        notes = re.sub(r'\n{3,}', '\n\n', notes)
        notes = notes.strip()
        notes = re.sub(r'^-+\s*', '', notes)

        return notes

    def _extract_est4_characteristics(self, content: str) -> List[str]:
        """Extract EST4 scoring characteristics from Guidance section"""
        characteristics = []

        guidance_match = re.search(r'^### Guidance\s*\n(.*?)(?=^###|\Z)', content, re.MULTILINE | re.DOTALL)
        if not guidance_match:
            return characteristics

        guidance_content = guidance_match.group(1)

        # Look for "Score the following characteristics" section
        in_list = False
        for line in guidance_content.split('\n'):
            line_stripped = line.strip()

            if 'Score the following' in line_stripped:
                in_list = True
                continue

            if in_list and line_stripped.startswith('- '):
                characteristics.append(line_stripped[2:].strip())

        return characteristics

    def _extract_sub_questions(self, content: str) -> List[Dict]:
        """Extract sub-questions for IMP2/IMP4"""
        sub_questions = []

        # Find ### Sub-questions section
        subq_match = re.search(r'^### Sub-questions\s*\n(.*?)(?=^###|\Z)', content, re.MULTILINE | re.DOTALL)
        if not subq_match:
            return sub_questions

        subq_content = subq_match.group(1)

        # Parse **IMP2.1. text** patterns
        current_code = None
        current_text = None
        current_description_lines = []

        for line in subq_content.split('\n'):
            line_stripped = line.strip()

            # Check for sub-question header
            match = re.match(r'^\*\*(?P<code>IMP\d+\.\d+)\.\s*(?P<text>.+?)\*\*$', line_stripped)
            if match:
                # Save previous
                if current_code:
                    sub_questions.append({
                        'code': current_code,
                        'text': current_text,
                        'description': ' '.join(current_description_lines).strip() if current_description_lines else None
                    })

                current_code = match.group('code')
                current_text = match.group('text').strip()
                current_description_lines = []

            # Description line
            elif line_stripped and not line_stripped.startswith('**') and not line_stripped.startswith('#') and current_code:
                current_description_lines.append(line_stripped)

        # Save last
        if current_code:
            sub_questions.append({
                'code': current_code,
                'text': current_text,
                'description': ' '.join(current_description_lines).strip() if current_description_lines else None
            })

        return sub_questions

    def _to_snake_case(self, text: str) -> str:
        """Convert text to snake_case ID"""
        text = text.lower()
        text = re.sub(r'[^\w\s]', '', text)
        text = re.sub(r'\s+', '_', text)
        return text

    def _validate(self):
        """Validate that all required questions were parsed"""
        required_codes = [
            'ENT1', 'ENT2A', 'ENT2B', 'ENT3', 'ENT4',
            'EST1', 'EST2', 'EST3', 'EST4',
            'IMP1', 'IMP2', 'IMP3', 'IMP4',
            'MAN1', 'MAN2', 'MAN3', 'MAN4', 'MAN5'
        ]

        missing = [c for c in required_codes if c not in self.questions]
        if missing:
            print(f"[Warning] Missing questions: {missing}")

        # Validate options exist
        for code, q in self.questions.items():
            if not q.get('options') and code not in ['IMP2', 'IMP4']:
                print(f"[Warning] No options parsed for {code}")

    def _build_output(self) -> Dict:
        """Build final JSON output"""
        stat = self.rmd_path.stat()

        return {
            'title': 'FinnPRIO Instructions',
            'version': '2.0.0',  # Version bump for new format
            'generated': datetime.now().isoformat(),
            'source_file': str(self.rmd_path.name),
            'source_modified': datetime.fromtimestamp(stat.st_mtime).isoformat(),
            'source_hash': self._compute_hash(),
            'pra_area': 'Norway',
            'pathways': self.pathways,
            'questions': self.questions
        }

    def _compute_hash(self) -> str:
        """Compute MD5 hash of source file for change detection"""
        return hashlib.md5(self.content.encode('utf-8')).hexdigest()


def parse_rmd_to_json(
    rmd_path: str = None,
    output_path: str = None,
    force: bool = False
) -> Dict:
    """
    Parse Rmd file and save as JSON.

    Args:
        rmd_path: Path to Instructions Rmd file (default: auto-detect)
        output_path: Path for JSON output (default: instructions_cache/)
        force: Regenerate even if JSON is up-to-date

    Returns:
        Parsed JSON data
    """
    rmd_path = Path(rmd_path) if rmd_path else DEFAULT_RMD_PATH
    output_path = Path(output_path) if output_path else DEFAULT_JSON_PATH

    # Create output directory if needed
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Check if regeneration needed
    if not force and output_path.exists():
        try:
            existing = json.loads(output_path.read_text(encoding='utf-8'))
            rmd_mtime = datetime.fromtimestamp(rmd_path.stat().st_mtime).isoformat()

            if existing.get('source_modified') == rmd_mtime:
                print(f"[Parser] JSON is up-to-date, skipping regeneration")
                return existing
        except (json.JSONDecodeError, KeyError):
            pass  # Regenerate if existing JSON is invalid

    # Parse and save
    print(f"[Parser] Parsing: {rmd_path}")
    parser = RmdInstructionsParser(str(rmd_path))
    data = parser.parse()

    output_path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False),
        encoding='utf-8'
    )

    print(f"[Parser] Generated: {output_path}")
    print(f"[Parser] {len(data['questions'])} questions parsed")

    return data


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description='Parse FinnPRIO Rmd Instructions to JSON')
    parser.add_argument('rmd_path', nargs='?', default=None,
                        help='Path to Instructions Rmd file (default: auto-detect)')
    parser.add_argument('--output', '-o', help='Output JSON path')
    parser.add_argument('--force', '-f', action='store_true',
                        help='Force regeneration even if up-to-date')

    args = parser.parse_args()

    try:
        data = parse_rmd_to_json(args.rmd_path, args.output, args.force)

        # Print summary
        print("\n" + "=" * 60)
        print("PARSING SUMMARY")
        print("=" * 60)
        print(f"Questions parsed: {len(data['questions'])}")
        print(f"Pathway categories: {len(data.get('pathways', {}).get('categories', []))}")

        print("\nQuestions by group:")
        groups = {}
        for code, q in data['questions'].items():
            group = q['group']
            groups[group] = groups.get(group, 0) + 1
        for group, count in groups.items():
            print(f"  {group}: {count}")

        print("\nQuestions with options:")
        for code, q in sorted(data['questions'].items()):
            opts = len(q.get('options', []))
            guidance = len(q.get('guidance', []))
            q_type = q.get('type', 'unknown')
            print(f"  {code}: {opts} options, {guidance} guidance items ({q_type})")

    except RmdParsingError as e:
        print(f"[Error] {e}")
        exit(1)
