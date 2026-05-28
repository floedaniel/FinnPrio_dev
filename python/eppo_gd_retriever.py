"""EPPO Global Database retriever for GPT Researcher.

Provides Reporting Service articles and EPPO PRA Platform document links
for the species identified by os.environ["EPPO_CODE"]. Register at runtime
by calling register() once before any GPTResearcher instance is created.
"""
from __future__ import annotations

import logging
import os
import re
from typing import Any

import requests
from bs4 import BeautifulSoup

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

    _ARTICLE_HREF_RE = re.compile(r"^/reporting/article-(\d+)")
    _PRA_HREF_RE = re.compile(r"^https?://pra\.eppo\.int/pra/[0-9a-fA-F\-]+")

    def _fetch_reporting_index(self, code: str) -> list[dict[str, Any]]:
        """Return reporting articles for `code`, sorted by year_month desc, capped."""
        url = f"https://gd.eppo.int/taxon/{code}/reporting"
        try:
            resp = requests.get(url, headers=_HEADERS, timeout=REQUEST_TIMEOUT)
            resp.raise_for_status()
        except requests.RequestException as e:
            logger.warning("EPPO GD reporting index fetch failed for %s: %s", code, e)
            return []

        try:
            soup = BeautifulSoup(resp.text, "html.parser")
            rows: list[dict[str, Any]] = []
            for a in soup.find_all("a", href=self._ARTICLE_HREF_RE):
                article_id = self._ARTICLE_HREF_RE.match(a["href"]).group(1)
                title = a.get_text(strip=True)
                # The year-month sits in a sibling cell on the same row.
                tr = a.find_parent("tr")
                year_month = ""
                if tr is not None:
                    cells = [c.get_text(strip=True) for c in tr.find_all(["td", "th"])]
                    # Last non-empty cell is the date column
                    for txt in reversed(cells):
                        if txt and txt != title:
                            year_month = txt
                            break
                rows.append({
                    "article_id": article_id,
                    "title": title,
                    "year_month": year_month,
                    "url": f"https://gd.eppo.int/reporting/article-{article_id}",
                })
        except Exception as e:
            logger.warning("EPPO GD reporting index parse failed for %s: %s", code, e)
            return []

        rows.sort(key=lambda r: r["year_month"], reverse=True)
        return rows[:MAX_REPORTING_ARTICLES]

    def _fetch_article_body(self, url: str) -> str:
        """Return plain-text body of a reporting article. Empty string on failure."""
        try:
            resp = requests.get(url, headers=_HEADERS, timeout=REQUEST_TIMEOUT)
            resp.raise_for_status()
        except requests.RequestException as e:
            logger.warning("EPPO GD article fetch failed for %s: %s", url, e)
            return ""

        try:
            soup = BeautifulSoup(resp.text, "html.parser")
            # The article content sits inside the main content container.
            # Strategy: take all text from the first <h2> onward, inside the
            # primary content div if findable, else the whole document.
            main = soup.find("div", id="content") or soup.find("main") or soup.body or soup
            h2 = main.find("h2") if main else None
            if h2:
                parts: list[str] = []
                for sib in h2.next_siblings:
                    text = getattr(sib, "get_text", lambda **_: str(sib))(separator=" ", strip=True)
                    if text:
                        parts.append(text)
                return "\n\n".join(parts).strip()
            return main.get_text(separator=" ", strip=True) if main else ""
        except Exception as e:
            logger.warning("EPPO GD article parse failed for %s: %s", url, e)
            return ""

    def _fetch_pra_links(self, code: str) -> list[dict[str, Any]]:
        """Return EPPO PRA Platform links for `code`, each with a body."""
        url = f"https://gd.eppo.int/taxon/{code}/eppolinks"
        try:
            resp = requests.get(url, headers=_HEADERS, timeout=REQUEST_TIMEOUT)
            resp.raise_for_status()
        except requests.RequestException as e:
            logger.warning("EPPO GD eppolinks fetch failed for %s: %s", code, e)
            return []

        try:
            soup = BeautifulSoup(resp.text, "html.parser")
            # Find the section whose heading mentions "EPPO PRA Platform".
            # The page uses <div class="process-meta"><span>Found in EPPO PRA
            # Platform</span></div> rather than a conventional h2/h3/h4, so we
            # search all tags and then walk up to the nearest ancestor that
            # actually contains pra.eppo.int anchors.
            section_root = None
            for tag in soup.find_all(True):
                if "EPPO PRA Platform" in tag.get_text(strip=True):
                    # Walk up until we find a container that holds PRA links.
                    candidate = tag
                    while candidate is not None:
                        if candidate.find("a", href=self._PRA_HREF_RE):
                            section_root = candidate
                            break
                        candidate = candidate.parent
                    if section_root is not None:
                        break
            if section_root is None:
                return []

            pra_anchors = [
                a for a in section_root.find_all("a", href=True)
                if self._PRA_HREF_RE.match(a["href"])
            ]
            results: list[dict[str, Any]] = []
            seen: set[str] = set()
            for a in pra_anchors:
                pra_url = a["href"]
                if pra_url in seen:
                    continue
                seen.add(pra_url)
                title = a.get_text(strip=True) or pra_url
                results.append({
                    "url": pra_url,
                    "raw_content": f"EPPO PRA Platform document: {title}\nURL: {pra_url}",
                    "title": title,
                })
            return results
        except Exception as e:
            logger.warning("EPPO GD eppolinks parse failed for %s: %s", code, e)
            return []

    def _fetch_all(self, code: str) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []

        reporting = self._fetch_reporting_index(code)
        for item in reporting:
            body = self._fetch_article_body(item["url"])
            raw = f"Title: {item['title']}\n\n{body}" if body else f"Title: {item['title']}"
            results.append({
                "url": item["url"],
                "raw_content": raw,
                "title": item["title"],
            })

        pra_results = self._fetch_pra_links(code)
        results.extend(pra_results)

        logger.info(
            "EPPO GD cached %d reporting + %d PRA results for %s",
            len(reporting), len(pra_results), code,
        )
        return results


_REGISTERED = False


def register() -> None:
    """Patch gpt_researcher's retriever factory to recognise 'eppo_gd'.
    Implemented in Task 6.
    """
    raise NotImplementedError("Registration implemented in Task 6")
