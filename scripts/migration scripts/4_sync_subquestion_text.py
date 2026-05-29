"""
Sync sub-question text in the DB `questions` table from the parsed Rmd JSON.

Background
----------
After the IMP2/IMP4 restructure (2026-04-17) the database still holds the
old parent-level question text on the sub-question rows — e.g. all of
IMP2.1, IMP2.2, IMP2.3 share the generic text
    "Would the pest cause the following indirect economic impacts in the PRA area?"
whereas the Rmd (and generated JSON cache) holds the correct sub-question
text
    "Would the pest impact foreign trade?" (IMP2.1)
    "Is the pest a vector for other pests?" (IMP2.2)
    "Would the pest have a significant impact on the profitability ..." (IMP2.3)

The Shiny app renders from the DB, so users see identical generic labels
for all three sub-questions. This script resyncs the DB text from the JSON.

The script is generic: it syncs every top-level JSON question key that
contains a dot (i.e. any sub-question code), not just IMP2/IMP4. Rows
already matching the JSON text are left untouched.

Usage
-----
    python 4_sync_subquestion_text.py /path/to/database.db
    python 4_sync_subquestion_text.py /path/to/database.db --dry-run
    python 4_sync_subquestion_text.py /path/to/database.db --json /path/to/finnprio_instructions.json
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sqlite3
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_JSON_PATH = REPO_ROOT / "python" / "instructions_cache" / "finnprio_instructions.json"

CODE_PATTERN = re.compile(r'^(?P<group>[A-Z]+?)(?P<number>\d+(?:\.\d+)?[AB]?)$')


def parse_code(code: str) -> tuple[str, str] | None:
    """Split 'IMP2.3' -> ('IMP', '2.3'); return None if the shape is unexpected."""
    match = CODE_PATTERN.match(code)
    if not match:
        return None
    return match.group('group'), match.group('number')


def truncate(text: str, limit: int = 80) -> str:
    text = text.replace('\n', ' ').strip()
    return text if len(text) <= limit else text[: limit - 1] + '…'


def sync_subquestion_text(db_path: Path, json_path: Path, dry_run: bool) -> int:
    """Sync sub-question text from JSON into DB. Returns count of rows updated."""
    logging.info("DB:   %s", db_path)
    logging.info("JSON: %s", json_path)
    if dry_run:
        logging.info("Mode: DRY RUN (no writes)")

    instructions = json.loads(json_path.read_text(encoding='utf-8'))
    questions = instructions.get('questions', {})

    sub_codes = sorted(c for c in questions if '.' in c)
    if not sub_codes:
        logging.warning("No dotted sub-question codes found in JSON; nothing to do.")
        return 0
    logging.info("Candidate sub-questions in JSON: %s", ', '.join(sub_codes))

    conn = sqlite3.connect(str(db_path))
    try:
        cursor = conn.cursor()
        updated = 0
        skipped_match = 0
        missing_db = 0
        skipped_empty_json = 0
        malformed = 0

        for code in sub_codes:
            parsed = parse_code(code)
            if parsed is None:
                logging.warning("Skipping malformed code %r", code)
                malformed += 1
                continue
            group, number = parsed
            new_text = (questions[code].get('text') or '').strip()
            if not new_text:
                logging.warning("%s: JSON 'text' is empty; skipping.", code)
                skipped_empty_json += 1
                continue

            cursor.execute(
                'SELECT idQuestion, question FROM questions WHERE "group" = ? AND number = ?',
                (group, number),
            )
            row = cursor.fetchone()
            if row is None:
                logging.warning("%s: no row in DB (group=%r, number=%r); skipping.", code, group, number)
                missing_db += 1
                continue

            id_question, old_text = row
            old_text = old_text or ''
            if old_text == new_text:
                logging.info("%s (idQuestion=%d): already in sync; no change.", code, id_question)
                skipped_match += 1
                continue

            logging.info(
                "%s (idQuestion=%d): OLD %r -> NEW %r",
                code, id_question, truncate(old_text), truncate(new_text),
            )
            if not dry_run:
                cursor.execute(
                    'UPDATE questions SET question = ? WHERE idQuestion = ?',
                    (new_text, id_question),
                )
            updated += 1

        if not dry_run:
            conn.commit()

        logging.info("Summary: updated=%d, already-in-sync=%d, missing-in-db=%d, empty-json=%d, malformed=%d",
                     updated, skipped_match, missing_db, skipped_empty_json, malformed)
        return updated
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync sub-question text from JSON into the DB questions table.")
    parser.add_argument('db_path', type=Path, help="Path to the SQLite database to update.")
    parser.add_argument('--json', dest='json_path', type=Path, default=DEFAULT_JSON_PATH,
                        help=f"Path to finnprio_instructions.json (default: {DEFAULT_JSON_PATH})")
    parser.add_argument('--dry-run', action='store_true',
                        help="Log what would change but do not commit.")
    parser.add_argument('-v', '--verbose', action='store_true',
                        help="Enable DEBUG-level logging.")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s',
        datefmt='%H:%M:%S',
    )

    if not args.db_path.is_file():
        logging.error("Database not found: %s", args.db_path)
        return 2
    if not args.json_path.is_file():
        logging.error("JSON not found: %s", args.json_path)
        return 2

    sync_subquestion_text(args.db_path, args.json_path, args.dry_run)
    return 0


if __name__ == '__main__':
    sys.exit(main())
