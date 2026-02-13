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

################################################################################
# CONFIGURATION - EDIT THESE SETTINGS
################################################################################

# Skip Existing Values
# Set to False to overwrite existing values, True to skip answers that already have values
SKIP_EXISTING_VALUES = True

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
INPUT_DATABASE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\VKM Data\26.08.2024_lopende_oppdrag_plantehelse\FinnPrio databaser\Selamavit\selam_2026.db"
# INPUT_DATABASE = r"C:/full/path/to/your/database.db"
#
# OPTION 2: Auto-detect (leave INPUT_DATABASE = None)
# Automatically finds most recent *_ai_enhanced_*.db in outputs/ folder
#
# OPTION 3: Command line (leave INPUT_DATABASE = None and use --db parameter)
# python populate_finnprio_values.py --db "path/to/database.db"

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

    def get_all_assessment_ids(self) -> List[int]:
        """Get all assessment IDs in database"""
        cursor = self.conn.cursor()
        cursor.execute("SELECT idAssessment FROM assessments ORDER BY idAssessment")
        return [row['idAssessment'] for row in cursor.fetchall()]

    def get_question_options(self, id_question: int, table: str = "questions") -> List[Dict]:
        """
        Get question details and options from database

        Returns:
            List of option dicts with 'opt', 'text', 'points'
        """
        cursor = self.conn.cursor()
        if table == "questions":
            cursor.execute(
                "SELECT question, list, type FROM questions WHERE idQuestion = ?",
                (id_question,)
            )
        else:
            cursor.execute(
                "SELECT question, list FROM pathwayQuestions WHERE idPathQuestion = ?",
                (id_question,)
            )

        row = cursor.fetchone()
        if not row:
            return None

        question_text = row['question']
        options_json = row['list']
        question_type = row['type'] if table == "questions" else "minmax"

        options = json.loads(options_json)

        return {
            'question': question_text,
            'options': options,
            'type': question_type
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
        question_type: str = "minmax"
    ) -> Dict[str, str]:
        """
        Use GPT-4o to determine appropriate min/likely/max values based on justification

        Returns:
            Dict with keys 'min', 'likely', 'max' containing option codes (e.g., 'a', 'b', 'c')
        """

        # Build options description
        options_text = "\n".join([
            f"  {opt['opt'].upper()}: {opt['text']} (points: {opt['points']})"
            for opt in options
        ])

        if question_type == "minmax":
            prompt = f"""You are analyzing a plant pest risk assessment for {pest_name}.

QUESTION: {question_text}

AVAILABLE OPTIONS (from lowest to highest severity/likelihood):
{options_text}

JUSTIFICATION TEXT:
{justification}

Your task:
1. Read the justification carefully
2. Based on the evidence and uncertainty described, select appropriate values for:
   - MINIMUM: The most optimistic/lowest reasonable estimate
   - LIKELY: The most probable/expected value
   - MAXIMUM: The most pessimistic/highest reasonable estimate

3. Return ONLY a JSON object with this exact format:
{{"min": "a", "likely": "b", "max": "c"}}

Guidelines:
- Use only the option codes (a, b, c, etc.) from the available options above
- min <= likely <= max (in terms of severity/points)
- If uncertainty is low, min and max should be close to likely
- If uncertainty is high, min and max should span a wider range
- Base your selection on the evidence strength in the justification
- Consider Norwegian/Nordic context

Return ONLY the JSON object, no additional text."""

        else:  # boolean type (IMP2, IMP4)
            # For boolean questions, there's only ONE option representing the sub-question
            # If YES: return the option code; If NO: return null to skip this answer
            option_code = options[0]['opt'] if options else 'a'
            option_text = options[0]['text'] if options else ''

            prompt = f"""You are analyzing a plant pest risk assessment for {pest_name}.

BOOLEAN QUESTION: {option_text}

AVAILABLE ANSWER:
- Option "{option_code.upper()}": YES to this question (points: {options[0]['points'] if options else 1})
- No option for NO (leave blank if answer is NO)

JUSTIFICATION TEXT:
{justification}

Your task:
1. Read the justification carefully
2. Based on the evidence, determine if the answer to "{option_text}" is YES or NO
3. Return your answer:

If YES (evidence supports this impact/effect):
{{"min": "{option_code}", "likely": "{option_code}", "max": "{option_code}"}}

If NO (evidence does not support this impact/effect):
{{"min": null, "likely": null, "max": null}}

If UNCERTAIN (mixed or unclear evidence), you can vary the values:
{{"min": null, "likely": "{option_code}", "max": "{option_code}"}}

Return ONLY the JSON object, no additional text."""

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

            # Convert values to lowercase (GPT sometimes returns uppercase)
            for key in ['min', 'likely', 'max']:
                if key in values and values[key]:
                    values[key] = values[key].lower()

            # Validate that all keys exist and values are valid option codes
            required_keys = ['min', 'likely', 'max']
            if not all(k in values for k in required_keys):
                raise ValueError(f"Missing required keys. Got: {values.keys()}")

            valid_opts = {opt['opt'] for opt in options}
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
                print(f"  Question: {question_data['question'][:80]}...")
                print(f"  Type: {question_data['type']}")

                # Determine values with GPT
                values = await self.determine_values_with_gpt(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type']
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
                print(f"  Question: {question_data['question'][:80]}...")

                # Determine values with GPT
                values = await self.determine_values_with_gpt(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type']
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

    async def populate_values(self, skip_existing: bool = True):
        """Main function to populate all missing values"""

        print("\n" + "=" * 80)
        print("FinnPRIO Value Populator")
        print("=" * 80)
        print(f"\nDatabase: {self.db_path}")
        print(f"Skip existing values: {skip_existing}")
        print()

        self.connect()

        try:
            # Get list of assessments to process
            if self.assessment_id:
                assessment_ids = [self.assessment_id]
                print(f"ℹ️  Processing single assessment: {self.assessment_id}\n")
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
    skip_existing: bool = None
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
    await populator.populate_values(skip_existing=skip_existing)


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
        skip_existing=skip_existing
    ))
