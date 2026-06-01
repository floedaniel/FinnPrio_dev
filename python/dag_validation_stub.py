"""
DAG VALIDATION STUB — add to populate_finnprio_values.py
=========================================================

After populate_finnprio_values.py extracts all min/likely/max scores,
call validate_sibling_constraints() to catch numeric violations that the
qualitative prompt instruction could not guarantee.

Import at top of populate_finnprio_values.py:
    from dag_config import SIBLING_CONSTRAINTS
"""

from dag_config import SIBLING_CONSTRAINTS
import sqlite3
from typing import List, Dict, Optional


def get_score(db_path: str, assessment_id: int, question_code: str,
              id_entry_pathway: Optional[int] = None) -> Optional[Dict]:
    """Fetch min/likely/max option codes for a question from the answers tables.

    Option codes are single lowercase letters ('a', 'b', 'c', ...).
    Returns None if no row is found (scores not yet extracted).
    """
    code_norm = question_code.upper().rstrip('.')
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    if id_entry_pathway:
        # Pathway question scores — stored directly in pathwayAnswers
        cursor.execute("""
            SELECT pa.min, pa.likely, pa.max
            FROM pathwayAnswers pa
            JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
            WHERE pa.idEntryPathway = ?
              AND UPPER(pq."group" || pq.number) = ?
        """, (id_entry_pathway, code_norm))
    else:
        # Regular question scores — stored directly in answers
        cursor.execute("""
            SELECT a.min, a.likely, a.max
            FROM answers a
            JOIN questions q ON a.idQuestion = q.idQuestion
            WHERE a.idAssessment = ?
              AND UPPER(
                    q."group" || q.number ||
                    CASE WHEN q.subgroup IS NOT NULL THEN '.' || q.subgroup ELSE '' END
                  ) = ?
        """, (assessment_id, code_norm))

    row = cursor.fetchone()
    conn.close()

    if row:
        return {'min': row[0], 'likely': row[1], 'max': row[2]}
    return None


def validate_sibling_constraints(
    db_path: str,
    assessment_id: int,
    id_entry_pathway: Optional[int] = None,
) -> List[Dict]:
    """Check numeric sibling constraints after scores are extracted.

    Option codes are single lowercase letters ordered by increasing probability
    ('a' < 'b' < 'c' ...), so string comparison is used to detect violations.

    Returns a list of violation dicts (empty = all constraints satisfied).
    Call this at the end of each assessment's values extraction.

    Example usage in populate_finnprio_values.py:
        violations = validate_sibling_constraints(db_path, assessment_id,
                                                  id_entry_pathway)
        if violations:
            for v in violations:
                print(f"CONSTRAINT VIOLATION: {v['question']} likely={v['constrained_likely']} "
                      f"> {v['sibling']} likely={v['sibling_likely']} — flag for human review")
    """
    violations = []

    for constrained_q, rule in SIBLING_CONSTRAINTS.items():
        sibling_q = rule['sibling']

        constrained_score = get_score(db_path, assessment_id, constrained_q,
                                      id_entry_pathway)
        sibling_score     = get_score(db_path, assessment_id, sibling_q,
                                      id_entry_pathway)

        if constrained_score is None or sibling_score is None:
            continue   # scores not yet extracted — skip silently

        c_likely = constrained_score['likely']
        s_likely = sibling_score['likely']

        if c_likely is None or s_likely is None:
            continue   # boolean NO answer — no numeric comparison possible

        if c_likely > s_likely:
            violations.append({
                'question':           constrained_q,
                'sibling':            sibling_q,
                'rule':               rule['rule'],
                'constrained_likely': c_likely,
                'sibling_likely':     s_likely,
                'assessment_id':      assessment_id,
                'id_entry_pathway':   id_entry_pathway,
            })

    return violations
