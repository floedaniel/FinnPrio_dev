"""EPPO Global Database retriever for GPT Researcher.

Provides Reporting Service articles and EPPO PRA Platform document links
for the species identified by os.environ["EPPO_CODE"]. Register at runtime
by calling register() once before any GPTResearcher instance is created.
"""
from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

MAX_REPORTING_ARTICLES = 20
REQUEST_TIMEOUT = 10
_HEADERS = {"User-Agent": "FinnPRIO-EPPO-Retriever/1.0"}

_CACHE: dict[str, list[dict[str, Any]]] = {}


class EPPOGDSearch:
    """GPT Researcher retriever that scrapes gd.eppo.int for the EPPO code
    given in os.environ["EPPO_CODE"]. No-op when the env var is unset/empty.
    """

    def __init__(self, query, query_domains=None, **kwargs):
        self.query = query
        self.query_domains = query_domains

    def search(self, max_results: int = 10) -> list[dict[str, Any]]:
        code = os.environ.get("EPPO_CODE", "").strip().upper()
        if not code:
            logger.debug("EPPO_CODE not set; EPPOGDSearch returning [].")
            return []

        if code not in _CACHE:
            _CACHE[code] = self._fetch_all(code)

        return _CACHE[code][:max_results]

    def _fetch_all(self, code: str) -> list[dict[str, Any]]:
        # Implemented in later tasks.
        raise NotImplementedError("Fetch logic added in Task 2")


_REGISTERED = False


def register() -> None:
    """Patch gpt_researcher's retriever factory to recognise 'eppo_gd'.
    Implemented in Task 6.
    """
    raise NotImplementedError("Registration implemented in Task 6")
