"""
Populate FinnPRIO Min/Likely/Max Values from AI Justifications - LOCAL VERSION

Uses Ollama (local LLM) instead of OpenAI API for ZERO COST operation.

This script:
1. Reads the AI-enhanced database
2. For each answer with justification, uses local LLM to determine min/likely/max values
3. Updates the database with selected option codes

Requirements:
    pip install openai  # Uses OpenAI-compatible API format
    ollama pull mistral:7b-instruct  # Fast and good quality (recommended)

Usage:
    python populate_finnprio_values_local.py
    python populate_finnprio_values_local.py --db path/to/database.db
    python populate_finnprio_values_local.py --eppo-codes XYLEFA ANOLGL
"""

import sqlite3
import json
import asyncio
from pathlib import Path
from typing import Dict, List, Optional
import argparse
from openai import AsyncOpenAI

################################################################################
# CONFIGURATION - EDIT THESE SETTINGS
################################################################################

# Skip Existing Values
SKIP_EXISTING_VALUES = False

# Ollama Configuration
OLLAMA_BASE_URL = "http://localhost:11434/v1"  # /v1 required for OpenAI-compatible API
OLLAMA_MODEL = "qwen2.5:14b"  # Better reasoning, still fast (8.9GB, ~90% GPU)
# Alternative models (uncomment to use):
# OLLAMA_MODEL = "qwen2.5:7b"           # Faster, smaller (4.7GB, 100% GPU)
# OLLAMA_MODEL = "mistral:7b-instruct"  # Good instruction following (4.4GB)
# OLLAMA_MODEL = "llama3.2"             # Fastest, smaller (2GB)

# Performance settings
MAX_TOKENS = 300  # Enough for JSON response
MAX_JUSTIFICATION_LENGTH = 3000  # Keep more justification context

# Temperature (lower = more deterministic)
TEMPERATURE = 0.1

# Database Path
INPUT_DATABASE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\test databases\daniel_local_fast_17_02_2026.db"

# Filter by EPPO codes (empty list = process all species)
EPPOCODES_TO_POPULATE = ["ANOLHO"]

################################################################################
# END CONFIGURATION
################################################################################

# Initialize Ollama client (OpenAI-compatible API)
client = AsyncOpenAI(
    base_url=OLLAMA_BASE_URL,
    api_key="ollama"  # Required but ignored by Ollama
)


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

    def get_question_options(self, id_question: int, table: str = "questions") -> Dict:
        """Get question details and options from database"""
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

    async def determine_values_with_ollama(
        self,
        pest_name: str,
        question_text: str,
        options: List[Dict],
        justification: str,
        question_type: str = "minmax"
    ) -> Dict[str, str]:
        """
        Use local Ollama LLM to determine min/likely/max values based on justification.
        """

        options_text = "\n".join([
            f"  {opt['opt'].upper()}: {opt['text']} (points: {opt['points']})"
            for opt in options
        ])

        # Truncate long justifications to speed up inference
        if len(justification) > MAX_JUSTIFICATION_LENGTH:
            justification = justification[:MAX_JUSTIFICATION_LENGTH] + "..."

        if question_type == "minmax":
            # Count options to help model understand scale
            num_options = len(options)

            prompt = f"""FinnPRIO Pest Risk Assessment for: {pest_name}

QUESTION: {question_text}

ANSWER OPTIONS ({num_options} levels, from lowest to highest risk/likelihood):
{options_text}

SCIENTIFIC JUSTIFICATION:
{justification}

YOUR TASK:
Analyze the justification and select THREE values that capture the uncertainty range:
- MIN: Best-case scenario (lowest reasonable estimate given the evidence)
- LIKELY: Most probable outcome (what the evidence most strongly supports)
- MAX: Worst-case scenario (highest reasonable estimate given the evidence)

DECISION RULES:
1. Match specific claims in the justification to the option descriptions
2. If justification mentions "limited", "unlikely", "rare" → lean toward lower options
3. If justification mentions "widespread", "likely", "common" → lean toward higher options
4. If justification mentions "uncertain", "unclear", "variable" → use wider spread (min far from max)
5. If justification is confident → use narrow spread (min close to max)
6. Consider Norway/Nordic cold climate context
7. The points value indicates severity - higher points = more severe/likely

RESPONSE FORMAT (JSON only, no other text):
{{"min": "a", "likely": "b", "max": "c"}}

Rules: Use option codes only (a, b, c, etc.). Ensure min <= likely <= max by points."""

        else:  # boolean type
            option_code = options[0]['opt'] if options else 'a'
            option_text = options[0]['text'] if options else ''

            prompt = f"""FinnPRIO Pest Risk Assessment for: {pest_name}

YES/NO QUESTION: {option_text}

SCIENTIFIC JUSTIFICATION:
{justification}

YOUR TASK:
Determine if the evidence supports answering YES to this question.

DECISION RULES:
1. Look for explicit statements about this specific impact/effect
2. "YES" = Clear evidence the pest would cause this impact in Norway/Nordic region
3. "NO" = No evidence, or evidence suggests this impact would NOT occur
4. "UNCERTAIN" = Mixed evidence or insufficient information

RESPONSE FORMAT (JSON only, no other text):

If YES (evidence clearly supports this):
{{"min": "{option_code}", "likely": "{option_code}", "max": "{option_code}"}}

If NO (evidence does not support this):
{{"min": null, "likely": null, "max": null}}

If UNCERTAIN (weak or conflicting evidence):
{{"min": null, "likely": "{option_code}", "max": "{option_code}"}}"""

        try:
            response = await client.chat.completions.create(
                model=OLLAMA_MODEL,
                messages=[
                    {"role": "system", "content": "You are an EPPO plant pest risk assessment expert using the FinnPRIO methodology for Norway. Your task is to convert scientific justifications into min/likely/max value selections. Read the justification carefully, match the evidence to the available options, and return ONLY a JSON object. Consider Nordic climate conditions. Be conservative when evidence is weak."},
                    {"role": "user", "content": prompt}
                ],
                temperature=TEMPERATURE,
                max_tokens=MAX_TOKENS,  # Limit response length for speed
            )

            content = response.choices[0].message.content
            if not content:
                print(f"  ⚠️  Empty response from model")
                return None
            content = content.strip()

            # Handle DeepSeek-R1 thinking tags: <think>...</think>
            if "</think>" in content:
                content = content.split("</think>")[-1].strip()
            if "<think>" in content:
                content = content.split("<think>")[0].strip()

            # Extract JSON from response
            if "```json" in content:
                content = content.split("```json")[1].split("```")[0].strip()
            elif "```" in content:
                content = content.split("```")[1].split("```")[0].strip()

            # Find JSON object in response
            start_idx = content.find('{')
            end_idx = content.rfind('}') + 1
            if start_idx != -1 and end_idx > start_idx:
                content = content[start_idx:end_idx]
            else:
                print(f"  ⚠️  No JSON found in response: {content[:100]}...")
                return None

            values = json.loads(content)

            # Convert to lowercase
            for key in ['min', 'likely', 'max']:
                if key in values and values[key]:
                    values[key] = values[key].lower()

            # Validate
            required_keys = ['min', 'likely', 'max']
            if not all(k in values for k in required_keys):
                raise ValueError(f"Missing required keys. Got: {values.keys()}")

            valid_opts = {opt['opt'] for opt in options}
            for key in required_keys:
                if values[key] is not None and values[key] not in valid_opts:
                    raise ValueError(f"Invalid option code '{values[key]}' for {key}")

            return values

        except json.JSONDecodeError as e:
            print(f"  ⚠️  JSON parsing error: {e}")
            print(f"  Response: {content[:200] if 'content' in locals() else 'N/A'}...")
            return None
        except Exception as e:
            print(f"  ⚠️  Error: {type(e).__name__}: {e}")
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
        """Get all answers with justification"""
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
        """Get all pathway answers with justification"""
        cursor = self.conn.cursor()

        where_clause = ""
        params = []
        if self.assessment_id:
            where_clause = "AND ep.idAssessment = ?"
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
        original_id = self.assessment_id
        self.assessment_id = assessment_id

        try:
            pest_name = self.get_pest_name(assessment_id)
            print(f"\n{'=' * 80}")
            print(f"Assessment {assessment_id}: {pest_name}")
            print(f"{'=' * 80}")

            answers = self.get_answers_to_populate()
            pathway_answers = self.get_pathway_answers_to_populate()

            if skip_existing:
                answers = [a for a in answers if not a['has_values']]
                pathway_answers = [pa for pa in pathway_answers if not pa['has_values']]

            total = len(answers) + len(pathway_answers)

            print(f"Regular answers to populate: {len(answers)}")
            print(f"Pathway answers to populate: {len(pathway_answers)}")
            print(f"Total: {total}\n")

            if total == 0:
                print("No answers to populate!")
                return 0

            # Process regular answers
            print("=" * 80)
            print("Processing Regular Answers")
            print("=" * 80 + "\n")

            for i, answer in enumerate(answers, 1):
                id_answer = answer['idAnswer']
                id_question = answer['idQuestion']
                justification = answer['justification']

                question_data = self.get_question_options(id_question, "questions")
                if not question_data:
                    print(f"[{i}/{len(answers)}] Question {id_question} not found, skipping")
                    continue

                print(f"[{i}/{len(answers)}] Processing answer {id_answer}")
                print(f"  Question: {question_data['question'][:60]}...")

                values = await self.determine_values_with_ollama(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type']
                )

                if values:
                    if all(v is None for v in [values['min'], values['likely'], values['max']]):
                        print(f"  Selected: NO (boolean)")
                    else:
                        print(f"  Selected: min={values['min']}, likely={values['likely']}, max={values['max']}")
                        self.update_answer_values(id_answer, values['min'], values['likely'], values['max'])
                        print(f"  Updated")
                else:
                    print(f"  Skipped (error)")

                print()

            # Process pathway answers
            print("=" * 80)
            print("Processing Pathway Answers")
            print("=" * 80 + "\n")

            for i, answer in enumerate(pathway_answers, 1):
                id_path_answer = answer['idPathAnswer']
                id_path_question = answer['idPathQuestion']
                justification = answer['justification']

                question_data = self.get_question_options(id_path_question, "pathwayQuestions")
                if not question_data:
                    print(f"[{i}/{len(pathway_answers)}] Pathway question {id_path_question} not found, skipping")
                    continue

                print(f"[{i}/{len(pathway_answers)}] Processing pathway answer {id_path_answer}")
                print(f"  Question: {question_data['question'][:60]}...")

                values = await self.determine_values_with_ollama(
                    pest_name=pest_name,
                    question_text=question_data['question'],
                    options=question_data['options'],
                    justification=justification,
                    question_type=question_data['type']
                )

                if values:
                    if all(v is None for v in [values['min'], values['likely'], values['max']]):
                        print(f"  Selected: NO (boolean)")
                    else:
                        print(f"  Selected: min={values['min']}, likely={values['likely']}, max={values['max']}")
                        self.update_pathway_answer_values(id_path_answer, values['min'], values['likely'], values['max'])
                        print(f"  Updated")
                else:
                    print(f"  Skipped (error)")

                print()

            return total

        finally:
            self.assessment_id = original_id

    async def populate_values(self, skip_existing: bool = True, eppo_codes: List[str] = None):
        """Main function to populate all missing values"""

        print("\n" + "=" * 80)
        print("FinnPRIO Value Populator - LOCAL VERSION (Ollama)")
        print("=" * 80)
        print(f"\nDatabase: {self.db_path}")
        print(f"Model: {OLLAMA_MODEL}")
        print(f"Ollama URL: {OLLAMA_BASE_URL}")
        print(f"Skip existing: {skip_existing}")
        print(f"Cost: $0.00 (local LLM)")
        print()

        self.connect()

        try:
            # Test Ollama connection
            print("Testing Ollama connection...")
            try:
                test_response = await client.chat.completions.create(
                    model=OLLAMA_MODEL,
                    messages=[{"role": "user", "content": "Say OK"}],
                    max_tokens=10
                )
                print(f"Ollama connected: {OLLAMA_MODEL}\n")
            except Exception as e:
                print(f"\nOllama connection failed: {e}")
                print("\nMake sure Ollama is running:")
                print("  1. Start Ollama: ollama serve")
                print(f"  2. Pull model: ollama pull {OLLAMA_MODEL}")
                return

            # Determine EPPO codes
            effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

            # Get assessments
            if self.assessment_id:
                assessment_ids = [self.assessment_id]
                print(f"Processing single assessment: {self.assessment_id}\n")
            elif effective_eppo_codes:
                assessment_ids = self.get_all_assessment_ids(effective_eppo_codes)
                print(f"Filtering by EPPO codes: {effective_eppo_codes}")
                print(f"Found {len(assessment_ids)} matching assessment(s)\n")
                if assessment_ids:
                    found_codes = self.get_eppo_codes_for_assessments(assessment_ids)
                    missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
                    if missing:
                        print(f"Warning: No assessments found for EPPO codes: {missing}\n")
            else:
                assessment_ids = self.get_all_assessment_ids()
                print(f"Processing all assessments: {len(assessment_ids)} total\n")

            # Process
            total_processed = 0
            for idx, aid in enumerate(assessment_ids, 1):
                if len(assessment_ids) > 1:
                    print(f"\n{'=' * 80}")
                    print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
                    print(f"{'=' * 80}")

                processed = await self.populate_values_for_assessment(aid, skip_existing)
                total_processed += processed if processed else 0

            print("\n" + "=" * 80)
            print(f"All assessments complete! Total: {total_processed}")
            print(f"Cost: $0.00")
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

    if skip_existing is None:
        skip_existing = SKIP_EXISTING_VALUES

    if not db_path:
        db_path = INPUT_DATABASE

    if not db_path:
        print("No database specified. Use --db parameter or set INPUT_DATABASE")
        return

    if not Path(db_path).exists():
        print(f"Database not found: {db_path}")
        return

    populator = ValuePopulator(db_path, assessment_id)
    await populator.populate_values(skip_existing=skip_existing, eppo_codes=eppo_codes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Populate min/likely/max values using LOCAL Ollama LLM (FREE)"
    )
    parser.add_argument("--db", type=str, help="Path to database")
    parser.add_argument("--assessment-id", type=int, help="Process single assessment")
    parser.add_argument("--eppo-codes", type=str, nargs='+', help="Filter by EPPO codes")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing values")
    parser.add_argument("--model", type=str, default=None, help="Ollama model to use")

    args = parser.parse_args()

    # Override model if specified (must use globals() since we're in __main__)
    if args.model:
        globals()['OLLAMA_MODEL'] = args.model

    skip_existing = False if args.overwrite else None

    asyncio.run(main(
        db_path=args.db,
        assessment_id=args.assessment_id,
        skip_existing=skip_existing,
        eppo_codes=args.eppo_codes
    ))
