"""
ContextStore — SQLite sidecar for GPT Researcher artifacts.

Saves researcher.context (processed text chunks), researcher.research_sources
(raw scraped pages; image_urls field ignored), visited_urls, and cost metadata after
each conduct_research() call. Enables auditability and future FactChecker use.

Future methods load_context() and query_sources() are stubbed — implement
when adding re-use or FactChecker functionality.
"""

import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

try:
    from importlib.metadata import version as _pkg_version
    _GPTR_VERSION: Optional[str] = _pkg_version('gpt-researcher')
except Exception:
    _GPTR_VERSION = None

_SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS contexts (
    id                INTEGER PRIMARY KEY,
    timestamp         TEXT    NOT NULL,
    source_db         TEXT    NOT NULL,
    assessment_id     INTEGER NOT NULL,
    eppo_code         TEXT    NOT NULL,
    question_code     TEXT    NOT NULL,
    pathway_name      TEXT    NOT NULL DEFAULT '',
    gptr_version      TEXT,
    research_costs    REAL,
    step_costs_json   TEXT,
    visited_urls_json TEXT,
    UNIQUE(source_db, assessment_id, question_code, pathway_name)
);

CREATE TABLE IF NOT EXISTS context_chunks (
    id          INTEGER PRIMARY KEY,
    context_id  INTEGER NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    chunk_text  TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS research_sources (
    id           INTEGER PRIMARY KEY,
    context_id   INTEGER NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    source_index INTEGER NOT NULL,
    url          TEXT,
    title        TEXT,
    content      TEXT
);
"""


class ContextStore:
    def __init__(self, db_path: str):
        self.db_path = str(db_path)
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._init_schema()

    def _init_schema(self) -> None:
        # executescript() implicitly commits and handles transactions
        self._conn.executescript(_SCHEMA)

    def save(self, record: Dict) -> None:
        """Insert or replace one question's research artifacts."""
        conn = self._conn
        conn.execute("PRAGMA foreign_keys = ON")
        try:
            cursor = conn.execute("""
                INSERT OR REPLACE INTO contexts
                    (timestamp, source_db, assessment_id, eppo_code,
                     question_code, pathway_name, gptr_version,
                     research_costs, step_costs_json, visited_urls_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                datetime.now().isoformat(),
                record.get('source_db', ''),
                record.get('assessment_id'),
                record.get('eppo_code', ''),
                record.get('question_code', ''),
                record.get('pathway_name') or '',
                _GPTR_VERSION,
                record.get('research_costs'),
                json.dumps(record.get('step_costs') or {}),
                json.dumps(record.get('visited_urls') or []),
            ))
            context_id = cursor.lastrowid

            chunks = record.get('context') or []
            if chunks:
                conn.executemany("""
                    INSERT INTO context_chunks (context_id, chunk_index, chunk_text)
                    VALUES (?, ?, ?)
                """, [(context_id, i, str(chunk)) for i, chunk in enumerate(chunks)])

            sources = record.get('research_sources') or []
            rows = []
            for i, src in enumerate(sources):
                if not isinstance(src, dict):
                    continue
                rows.append((
                    context_id,
                    i,
                    src.get('url') or src.get('href', ''),
                    src.get('title', ''),
                    src.get('raw_content') or src.get('content', ''),
                ))
            if rows:
                conn.executemany("""
                    INSERT INTO research_sources
                        (context_id, source_index, url, title, content)
                    VALUES (?, ?, ?, ?, ?)
                """, rows)

            conn.commit()
        except Exception:
            conn.rollback()
            raise

    def load_context(self, assessment_id: int, question_code: str,
                     pathway_name: str = '') -> Optional[List[str]]:
        """Return context chunk list for most recent match, or None. (Future: re-use)"""
        return None

    def query_sources(self, assessment_id: int, question_code: str,
                      pathway_name: str = '') -> List[Dict]:
        """Return research_sources for most recent match. (Future: FactChecker)"""
        return []

    def close(self) -> None:
        """Close the database connection."""
        if self._conn:
            self._conn.close()
