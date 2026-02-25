"""
Populate FinnPRIO Min/Likely/Max Values from AI Justifications

This script:
1. Reads the AI-enhanced database (output from populate_finnprio_justifications_v3.py)
2. For each answer with justification, uses GPT-4o to determine appropriate min/likely/max values
3. Updates the database with selected option codes

Usage:
    python populate_finnprio_values.py
    python populate_finnprio_values.py --db path/to/database.db
    python populate_finnprio_values.py --assessment-id 5
"""

import sqlite3
import json
import os
import asyncio
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import argparse
from datetime import datetime
import openai
from openai import AsyncOpenAI

# Import instructions loader for value selection prompts
from instructions_loader import build_value_selection_prompt

################################################################################
# CONFIGURATION - EDIT THESE SETTINGS
################################################################################

# Skip Existing Values
# Set to False to overwrite existing values, True to skip answers that already have values
SKIP_EXISTING_VALUES = False

# API Keys - Read from files
OPENAI_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\chatgpt_apikey.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\Desktop\API keys\Tavily_key.txt"

# Load API keys from files
def load_api_key(file_path: str) -> str:
    """Load API key from file, stripping whitespace"""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"⚠️  Warning: API key file not found: {file_path}")
        return ""

os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)

# Database Path - CHOOSE ONE OPTION:
#
# OPTION 1: Manual path (uncomment and edit the line below)
# INPUT_DATABASE = None
INPUT_DATABASE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel_ai_enhanced_25_02_2026.db"
# INPUT_DATABASE = r"C:/full/path/to/your/database.db"
#
# OPTION 2: Auto-detect (leave INPUT_DATABASE = None)
# Automatically finds most recent *_ai_enhanced_*.db in outputs/ folder
#
# OPTION 3: Command line (leave INPUT_DATABASE = None and use --db parameter)
# python populate_finnprio_values.py --db "path/to/database.db"

# Filter by EPPO codes (empty list = process all species)
# Example: EPPOCODES_TO_POPULATE = ["XYLEFA", "ANOLGL", "DROSSU"]
EPPOCODES_TO_POPULATE = ["ANOLHO"]

# Output: Same as input (updates in place)
# The script modifies the input database directly, adding min/likely/max values

################################################################################
# END CONFIGURATION
################################################################################

# Initialize OpenAI client AFTER setting API key
client = AsyncOpenAI(api_key=os.environ['OPENAI_API_KEY'])


class ValuePopulator:
    def __init__(self, db_path: str, assessment_id: Optional[int] = None):
        self.db_path = db_path
        self.assessment_id = assessment_id
        self.conn = None

    def connect(self):
        """Connect to database"""
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row

    def disconnect(self):
        """Close database connection"""
        if self.conn:
            self.conn.close()

    def get_all_assessment_ids(self, eppo_codes: List[str] = None) -> List[int]:
        """Get all assessment IDs in database, optionally filtered by EPPO codes."""
        cursor = self.conn.cursor()

        if eppo_codes:
            # Filter by EPPO codes (case-insensitive)
            placeholders = ','.join(['?' for _ in eppo_codes])
            cursor.execute(f"""
                SELECT a.idAssessment
                FROM assessments a
                JOIN pests p ON a.idPest = p.idPest
                WHERE UPPER(p.eppoCode) IN ({placeholders})
                ORDER BY a.idAssessment
            """, [code.upper() for code in eppo_codes])
        else:
            cursor.execute("SELECT idAssessment FROM assessments ORDER BY idAssessment")

        return [row['idAssessment'] for row in cursor.fetchall()]

    def get_eppo_codes_for_assessments(self, assessment_ids: List[int]) -> List[str]:
        """Get EPPO codes for a list of assessment IDs."""
        if not assessment_ids:
            return []
        cursor = self.conn.cursor()
        placeholders = ','.join(['?' for _ in assessment_ids])
        cursor.execute(f"""
            SELECT DISTINCT p.eppoCode
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE a.idAssessment IN ({placeholders})
        """, assessment_ids)
        return [row['eppoCode'] for row in cursor.fetchall() if row['eppoCode']]

    def get_question_options(self, id_question: int, table: str = "questions") -> List[Dict]:
        """
        Get question details and options from database

        Returns:
            Dict with 'question', 'options', 'type', and 'code' keys
        """
        cursor = self.conn.cursor()
        if table == "questions":
            # Include group and number to build question code
            cursor.execute(
                'SELECT question, list, type, "group", number, subgroup FROM questions WHERE idQuestion = ?',
                (id_question,)
            )
        else:
            # Pathway questions have group and number too
            cursor.execute(
                'SELECT question, list, "group", number FROM pathwayQuestions WHERE idPathQuestion = ?',
                (id_question,)
            )

        row = cursor.fetchone()
        if not row:
            return None

        question_text = row['question']
        options_json = row['list']

        if table == "questions":
            question_type = row['type'] if row['type'] else "minmax"
            # Build question code: e.g., "ENT1" or "IMP2.1"
            group = row['group'] or ""
            number = row['number'] or ""
            subgroup = row['subgroup'] or ""
            if subgroup:
                question_code = f"{group}{number}.{subgroup}"
            else:
                question_code = f"{group}{number}"
        else:
            question_type = "minmax"
            # Pathway question code: e.g., "ENT2A" or "ENT3"
            group = row['group'] or ""
            number = row['number'] or ""
            question_code = f"{group}{number}"

        options = json.loads(options_json)

        return {
            'question': question_text,
            'options': options,
            'type': question_type,
            'code': question_code
        }

    def get_pest_name(self, id_assessment: int) -> str:
        """Get pest scientific name for assessment"""
        cursor = self.conn.cursor()
        cursor.execute("""
            SELECT p.scientificName
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE a.idAssessment = ?
        """, (id_assessment,))

        row = cursor.fetchone()
        return row['scientificName'] if row else "Unknown pest"

    async def determine_values_with_gpt(
        self,
        pest_name: str,
        question_text: str,
        options: List[Dict],
        justification: str,
        question_type: str = "minmax",
        question_code: str = None
    ) -> Dict[str, str]:
        """
        Use GPT-4o to determine appropriate min/likely/max values based on justification.

        Args:
            pest_name: Scientific name of the pest
            question_text: The question text (unused, kept for compatibility)
            options: List of option dicts with 'opt', 'text', 'points'
            justification: The AI-generated justification to analyze
            question_type: 'minmax' or 'boolean' (unused, derived from question_code)
            question_code: Question code (e.g., 'ENT1') - required

        Returns:
            Dict with keys 'min', 'likely', 'max' containing option codes
        """
        prompt = build_value_selection_prompt(question_code, pest_name, justification, options)
        return await self._call_gpt_for_values(prompt, options)

    def _build_basic_prompt(
        self,
        pest_name: str,
        question_text: str,
        options: List[Dict],
        justification: str,
        question_type: str
    ) -> str:
        """Build basic prompt without Rmd-derived examples (fallback)."""

        # Build FULL options text with descriptions
        options_text = ""
        for opt in options:
            options_text += f"\n\n**{opt['opt'].upper()}. {opt['text']}**"
            if opt.get('description'):
                options_text += f"\n{opt['description']}"

        if question_type == "minmax":
            prompt = f"""TASK: Compare the JUSTIFICATION against the ANSWER OPTIONS and select min/likely/max.

===== QUESTION =====
{question_text}

===== ANSWER OPTIONS ====={options_text}

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
            option_code = options[0]['opt'] if options else 'a'
            option_text = options[0]['text'] if options else ''

            prompt = f"""TASK: Determine YES/NO based on the justification.

===== QUESTION =====
{option_text}

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

    async def _call_gpt_for_values(self, prompt: str, options: List[Dict]) -> Dict[str, str]:
        """Call GPT API with prompt and parse response."""

        try:
            response = await client.chat.completions.create(
                model=os.getenv("LLM_MODEL", "gpt-4o-mini"),
                messages=[
                    {"role": "system", "content": "You are an expert in plant pest risk assessment. You analyze scientific evidence and determine appropriate risk estimates."},
                    {"role": "user", "content": prompt}
                ],
                temperature=float(os.getenv("TEMPERATURE", "0.1")),
                max_tokens=int(os.getenv("LLM_MAX_TOKENS", "500"))
            )

            content = response.choices[0].message.content.strip()

            # Extract JSON from response (in case model adds extra text)
            if "```json" in content:
                content = content.split("```json")[1].split("```")[0].strip()
            elif "```" in content:
                content = content.split("```")[1].split("```")[0].strip()

            # Parse JSON
            values = json.loads(content)

            # Build mapping from points to option codes (for when GPT returns integers)
            points_to_opt = {opt['points']: opt['opt'] for opt in options}
            valid_opts = {opt['opt'] for opt in options}

            # Convert values to lowercase and handle integers
            for key in ['min', 'likely', 'max']:
                if key in values and values[key] is not None:
                    val = values[key]
                    # Handle integer responses (GPT sometimes returns points instead of letters)
                    if isinstance(val, int):
                        if val in points_to_opt:
                            values[key] = points_to_opt[val]
                        else:
                            # Try to convert 1->a, 2->b, etc.
                            values[key] = chr(ord('a') + val - 1) if 1 <= val <= 26 else str(val)
                    else:
                        values[key] = str(val).lower()

            # Validate that all keys exist and values are valid option codes
            required_keys = ['min', 'likely', 'max']
            if not all(k in values for k in required_keys):
                raise ValueError(f"Missing required keys. Got: {values.keys()}")

            for key in required_keys:
                # Allow None/null for boolean questions (when answer is NO)
                if values[key] is not None and values[key] not in valid_opts:
                    raise ValueError(f"Invalid option code '{values[key]}' for {key}. Valid options: {valid_opts}")

            return values

        except json.JSONDecodeError as e:
            print(f"  ⚠️  JSON parsing error: {e}")
            print(f"  Response content: {content if 'content' in locals() else 'N/A'}")
            return None
        except Exception as e:
            print(f"  ⚠️  Error determining values with GPT: {type(e).__name__}: {e}")
            print(f"  Response content: {content if 'content' in locals() else 'N/A'}")
            import traceback
            traceback.print_exc()
            return None

    def update_answer_values(self, id_answer: int, min_val: str, likely_val: str, max_val: str):
        """Update min/likely/max values in answers table"""
        cursor = self.conn.cursor()
        cursor.execute("""
            UPDATE answers
            SET min = ?, likely = ?, max = ?
            WHERE idAnswer = ?
        """, (min_val, likely_val, max_val, id_answer))
        self.conn.commit()

    def update_pathway_answer_values(self, id_path_answer: int, min_val: str, likely_val: str, max_val: str):
        """Update min/likely/max values in pathwayAnswers table"""
        cursor = self.conn.cursor()
        cursor.execute("""
            UPDATE pathwayAnswers
            SET min = ?, likely = ?, max = ?
            WHERE idPathAnswer = ?
        """, (min_val, likely_val, max_val, id_path_answer))
        self.conn.commit()

    def get_answers_to_populate(self) -> List[Dict]:
        """
        Get all answers with justification but missing min/likely/max values

        Returns:
            List of answer dicts with idAnswer, idAssessment, idQuestion, justification
        """
        cursor = self.conn.cursor()

        where_clause = ""
        params = []
        if self.assessment_id:
            where_clause = "AND a.idAssessment = ?"
            params = [self.assessment_id]

        cursor.execute(f"""
            SELECT a.idAnswer, a.idAssessment, a.idQuestion, a.justification, a.min, a.likely, a.max
            FROM answers a
            WHERE a.justification IS NOT NULL
              AND a.justification != ''
              {where_clause}
        """, params)

        results = []
        for row in cursor.fetchall():
            results.append({
                'idAnswer': row['idAnswer'],
                'idAssessment': row['idAssessment'],
                'idQuestion': row['idQuestion'],
                'justification': row['justification'],
                'has_values': bool(row['min'] and row['likely'] and row['max'])
            })

        return results

    def get_pathway_answers_to_populate(self) -> List[Dict]:
        """
        Get all pathway answers with justification but missing min/likely/max values

        Returns:
            List of pathway answer dicts
        """
        cursor = self.conn.cursor()

        where_clause = ""
        params = []
        if self.assessment_id:
            where_clause = """
                AND ep.idAssessment = ?
            """
            params = [self.assessment_id]

        cursor.execute(f"""
            SELECT pa.idPathAnswer, ep.idAssessment, pa.idPathQuestion, pa.justification,
                   pa.min, pa.likely, pa.max, pa.idEntryPathway
            FROM pathwayAnswers pa
            JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
            WHERE pa.justification IS NOT NULL
              AND pa.justification != ''
              {where_clause}
        """, params)

        results = []
        for row in cursor.fetchall():
            results.append({
                'idPathAnswer': row['idPathAnswer'],
                'idAssessment': row['idAssessment'],
                'idPathQuestion': row['idPathQuestion'],
                'idEntryPathway': row['idEntryPathway'],
                'justification': row['justification'],
                'has_values': bool(row['min'] and row['likely'] and row['max'])
            })

        return results

    async def populate_values_for_assessment(self, assessment_id: int, skip_existing: bool = True):
        """Populate values for a single assessment"""
        # Temporarily set assessment_id
        original_id = self.assessment_id
        self.assessment_id = assessment_id

        try:
            # Get pest name for this assessment
            pest_name = self.get_pest_name(assessment_id)
            print(f"\n{'=' * 80}")
            print(f"Assessment {assessment_id}: {pest_name}")
            print(f"{'=' * 80}")

            # Get answers to populate
            answers = self.get_answers_to_populate()
            pathway_answers = self.get_pathway_answers_to_populate()

            # Filter out answers that already have values (if skip_existing=True)
            if skip_existing:
                answers = [a for a in answers if not a['has_values']]
                pathway_answers = [pa for pa in pathway_answers if not pa['has_values']]

            total = len(answers) + len(pathway_answers)

            print(f"Found {len(answers)} regular answers to populate")
            print(f"Found {len(pathway_answers)} pathway answers to populate")
            print(f"Total: {total} answers\n")

            if total == 0:
                print("✅ No answers to populate!")
                return

            # Process regular answers
            print("=" * 80)
            print("Processing Regular Answers")
            print("=" * 80 + "\n")

            for i, answer in enumerate(answers, 1):
                id_answer = answer['idAnswer']
                id_assessment = answer['idAssessment']
                id_question = answer['idQuestion']
                justification = answer['justification']

                # Get pest name
                pest_name = self.get_pest_name(id_assessment)

                # Get question details
                question_data = self.get_question_options(id_question, "questions")
                if not question_data:
                    print(f"[{i}/{len(answers)}] ⚠️  Question {id_question} not found, skipping")
                    continue

                print(f"[{i}/{len(answers)}] Processing answer {id_answer}")
                print(f"  Pest: {pest_name}")
                print(f"  Question ({question_data['code']}): {question_data['question'][:70]}...")
                print(f"  Type: {question_data['type']}")

                # Determine values with GPT
                values = await self.determine_values_with_gpt(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type'],
                    question_code=question_data['code']
                )

                if values:
                    # Check if all values are None (boolean NO answer)
                    if all(v is None for v in [values['min'], values['likely'], values['max']]):
                        print(f"  Selected: NO (all values null)")
                        print(f"  ⚠️  Skipped (boolean question answered NO)")
                    else:
                        print(f"  Selected: min={values['min']}, likely={values['likely']}, max={values['max']}")
                        self.update_answer_values(id_answer, values['min'], values['likely'], values['max'])
                        print(f"  ✅ Updated")
                else:
                    print(f"  ⚠️  Skipped (error determining values)")

                print()

            # Process pathway answers
            print("=" * 80)
            print("Processing Pathway Answers")
            print("=" * 80 + "\n")

            for i, answer in enumerate(pathway_answers, 1):
                id_path_answer = answer['idPathAnswer']
                id_assessment = answer['idAssessment']
                id_path_question = answer['idPathQuestion']
                justification = answer['justification']

                # Get pest name
                pest_name = self.get_pest_name(id_assessment)

                # Get question details
                question_data = self.get_question_options(id_path_question, "pathwayQuestions")
                if not question_data:
                    print(f"[{i}/{len(pathway_answers)}] ⚠️  Pathway question {id_path_question} not found, skipping")
                    continue

                print(f"[{i}/{len(pathway_answers)}] Processing pathway answer {id_path_answer}")
                print(f"  Pest: {pest_name}")
                print(f"  Question ({question_data['code']}): {question_data['question'][:70]}...")

                # Determine values with GPT
                values = await self.determine_values_with_gpt(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type'],
                    question_code=question_data['code']
                )

                if values:
                    # Check if all values are None (boolean NO answer)
                    if all(v is None for v in [values['min'], values['likely'], values['max']]):
                        print(f"  Selected: NO (all values null)")
                        print(f"  ⚠️  Skipped (boolean question answered NO)")
                    else:
                        print(f"  Selected: min={values['min']}, likely={values['likely']}, max={values['max']}")
                        self.update_pathway_answer_values(id_path_answer, values['min'], values['likely'], values['max'])
                        print(f"  ✅ Updated")
                else:
                    print(f"  ⚠️  Skipped (error determining values)")

                print()

            return total  # Return number of answers processed

        finally:
            # Restore original assessment_id
            self.assessment_id = original_id

    async def populate_values(self, skip_existing: bool = True, eppo_codes: List[str] = None):
        """Main function to populate all missing values"""

        print("\n" + "=" * 80)
        print("FinnPRIO Value Populator")
        print("=" * 80)
        print(f"\nDatabase: {self.db_path}")
        print(f"Skip existing values: {skip_existing}")
        print()

        self.connect()

        try:
            # Determine EPPO codes to use (command-line overrides config)
            effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

            # Get list of assessments to process
            if self.assessment_id:
                assessment_ids = [self.assessment_id]
                print(f"ℹ️  Processing single assessment: {self.assessment_id}\n")
            elif effective_eppo_codes:
                assessment_ids = self.get_all_assessment_ids(effective_eppo_codes)
                print(f"ℹ️  Filtering by EPPO codes: {effective_eppo_codes}")
                print(f"    Found {len(assessment_ids)} matching assessment(s)\n")
                # Verify all requested codes were found
                if assessment_ids:
                    found_codes = self.get_eppo_codes_for_assessments(assessment_ids)
                    missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
                    if missing:
                        print(f"⚠️  Warning: No assessments found for EPPO codes: {missing}\n")
            else:
                assessment_ids = self.get_all_assessment_ids()
                print(f"ℹ️  Processing all assessments: {len(assessment_ids)} total\n")

            # Process each assessment
            total_processed = 0
            for idx, aid in enumerate(assessment_ids, 1):
                if len(assessment_ids) > 1:
                    print(f"\n{'=' * 80}")
                    print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
                    print(f"{'=' * 80}")

                processed = await self.populate_values_for_assessment(aid, skip_existing)
                total_processed += processed if processed else 0

            print("\n" + "=" * 80)
            print(f"✅ All assessments complete! Total answers processed: {total_processed}")
            print("=" * 80)

        finally:
            self.disconnect()


async def main(
    db_path: str = None,
    assessment_id: int = None,
    skip_existing: bool = None,
    eppo_codes: List[str] = None
):
    """Main entry point"""

    # Use configuration value if not explicitly set via command line
    if skip_existing is None:
        skip_existing = SKIP_EXISTING_VALUES

    # Use configured database path or command line argument
    if not db_path:
        db_path = INPUT_DATABASE

    # Auto-detect if still not set
    if not db_path:
        # Look for most recent AI-enhanced database in outputs folder
        outputs_dir = Path(__file__).parent / "outputs"
        if outputs_dir.exists():
            ai_dbs = list(outputs_dir.glob("*_ai_enhanced_*.db"))
            if ai_dbs:
                # Sort by modification time, get most recent
                db_path = str(sorted(ai_dbs, key=lambda p: p.stat().st_mtime, reverse=True)[0])
                print(f"Auto-detected database: {db_path}")
            else:
                print("❌ No AI-enhanced database found in outputs folder")
                print("   Please specify database path with --db parameter or set INPUT_DATABASE")
                return
        else:
            print("❌ Outputs folder not found")
            print("   Please specify database path with --db parameter or set INPUT_DATABASE")
            return

    # Check database exists
    if not Path(db_path).exists():
        print(f"❌ Database not found: {db_path}")
        return

    # Create populator and run
    populator = ValuePopulator(db_path, assessment_id)
    await populator.populate_values(skip_existing=skip_existing, eppo_codes=eppo_codes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Populate min/likely/max values in FinnPRIO database based on AI justifications"
    )
    parser.add_argument(
        "--db",
        type=str,
        help="Path to AI-enhanced database (default: auto-detect most recent in outputs/)"
    )
    parser.add_argument(
        "--assessment-id",
        type=int,
        help="Process only specific assessment ID"
    )
    parser.add_argument(
        "--eppo-codes",
        type=str,
        nargs='+',
        default=None,
        help="Filter by EPPO codes (e.g., --eppo-codes XYLEFA ANOLGL)"
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help=f"Overwrite existing values (default behavior: SKIP_EXISTING_VALUES={SKIP_EXISTING_VALUES})"
    )

    args = parser.parse_args()

    # Check for API key
    if not os.getenv("OPENAI_API_KEY"):
        print("❌ OPENAI_API_KEY environment variable not set")
        print("   Please set it in your .env file or environment")
        exit(1)

    # Determine skip_existing based on command line flag or use config default
    skip_existing = False if args.overwrite else None  # None means use config default

    asyncio.run(main(
        db_path=args.db,
        assessment_id=args.assessment_id,
        skip_existing=skip_existing,
        eppo_codes=args.eppo_codes
    ))
