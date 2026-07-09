# python/tests/test_evidence_context_injection.py
"""Tests for injecting pre-fetched SSB/NIBIO data into researcher.context
(the "Information" slot) instead of researcher.query (the "task" slot).

Traced end-to-end through the installed gpt_researcher package:
- generate_report_prompt(question, context, ...) renders
  'Information: "{context}"' ... 'answer the query or task: "{question}"'
  (gpt_researcher/prompts.py:294).
- ReportGenerator.__init__ sets research_params["query"] = researcher.query
  and write_report() sets report_params["context"] = researcher.context —
  two independent values (gpt_researcher/skills/writer.py:39,77,99).
- Our own create_research_query() folds prior_context (including the raw
  fetched_data JSON) into the single query string, so pre-fetched SSB/NIBIO
  numbers landed in "task", not "Information" — and report_source="web"
  mandates URL citations, which a JSON blob with no URL can't satisfy.

Fix: keep narrative framing (host list, "don't fabricate", ENT1/EST1
excerpts) in the query/task text, but inject the actual fetched numeric
data into researcher.context after conduct_research(), with a real,
citable URL.

researcher.context's type varies at that point depending on CURATE_SOURCES:
source_curator normalizes a List[dict] into a single joined string when
curation is on (our default config, used for ENT3/IMP2.2), but leaves it
as a list when curation is off (forced off for deep-research questions:
ENT2A/B, EST1, EST2, IMP1). The injection must handle both without
crashing or silently dropping data.
"""
import json
import os
import sys
import types

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import populate_finnprio_justifications as pfj


def _researcher_with_context(context):
    return types.SimpleNamespace(context=context)


# ─── _inject_evidence_into_context: both researcher.context shapes ────────────

def test_inject_evidence_appends_to_list_context():
    researcher = _researcher_with_context([{"title": "Web result", "href": "https://x", "body": "b"}])
    entries = [{"title": "SSB", "href": "https://ssb.no", "body": "data"}]

    pfj._inject_evidence_into_context(researcher, entries)

    assert isinstance(researcher.context, list)
    assert researcher.context[-1] == entries[0]
    assert researcher.context[0]["title"] == "Web result"  # existing entries preserved


def test_inject_evidence_appends_to_string_context():
    """CURATE_SOURCES=true (our default for ENT3/IMP2.2) normalizes
    researcher.context from a list into a single string before this
    injection point runs — must not crash on a str, must not silently
    drop the data."""
    researcher = _researcher_with_context("Title: Web result\nContent: b\nSource: https://x")
    entries = [{"title": "SSB", "href": "https://ssb.no", "body": "data"}]

    pfj._inject_evidence_into_context(researcher, entries)

    assert isinstance(researcher.context, str)
    assert "Title: Web result" in researcher.context  # existing content preserved
    assert "Title: SSB" in researcher.context
    assert "https://ssb.no" in researcher.context


def test_inject_evidence_handles_empty_string_context():
    researcher = _researcher_with_context("")
    entries = [{"title": "SSB", "href": "https://ssb.no", "body": "data"}]

    pfj._inject_evidence_into_context(researcher, entries)

    assert researcher.context.strip().startswith("Title: SSB")


def test_inject_evidence_no_entries_is_a_no_op():
    researcher = _researcher_with_context("original")
    pfj._inject_evidence_into_context(researcher, [])
    assert researcher.context == "original"
    pfj._inject_evidence_into_context(researcher, None)
    assert researcher.context == "original"


# ─── ssb_evidence_entries / nibio_evidence_entries ─────────────────────────────

def test_ssb_evidence_entries_has_real_citable_url():
    fetched = {"ssb_results": [
        {"hosts": ["Quercus robur"], "codes": ["44079100*"], "data": {"n_rows": 1, "rows": [{"value": 5}]}},
    ]}

    entries = pfj.ssb_evidence_entries(fetched)

    assert len(entries) == 1
    assert entries[0]["href"].startswith("https://www.ssb.no/")
    assert "Quercus robur" in entries[0]["body"]
    assert "44079100*" in entries[0]["body"]
    assert "5" in entries[0]["body"]


def test_ssb_evidence_entries_empty_when_no_results():
    assert pfj.ssb_evidence_entries({}) == []
    assert pfj.ssb_evidence_entries({"ssb_results": []}) == []
    assert pfj.ssb_evidence_entries(None) == []


def test_nibio_evidence_entries_has_real_citable_url():
    fetched = {"nibio_results": [
        {"group": {"id": 2607, "name": "Poteter"}, "post": {"id": 62693, "name": "Salg"},
         "data": {"data": [{"aar": 2024, "verdi": 999}]}},
    ]}

    entries = pfj.nibio_evidence_entries(fetched)

    assert len(entries) == 1
    assert entries[0]["href"].startswith("https://www.nibio.no/")
    assert "Poteter" in entries[0]["body"]
    assert "999" in entries[0]["body"]


def test_nibio_evidence_entries_empty_when_no_results():
    assert pfj.nibio_evidence_entries({}) == []
    assert pfj.nibio_evidence_entries({"nibio_results": []}) == []
    assert pfj.nibio_evidence_entries(None) == []


# ─── build_ent3_ssb_context / build_nibio_context no longer dump raw JSON ─────

def test_build_ent3_ssb_context_does_not_embed_raw_json(monkeypatch):
    monkeypatch.setattr(pfj, "get_regular_prior_answers", lambda *a, **k: {})
    fetched = {"ssb_results": [
        {"hosts": ["Quercus robur"], "codes": ["44079100*"], "data": {"n_rows": 1, "rows": [{"value": 5}]}},
    ]}

    ctx = pfj.build_ent3_ssb_context("db.db", 1, "Wood", hosts="Quercus robur",
                                      fetched_data=fetched)

    assert '"ssb_results"' not in ctx
    assert '"n_rows"' not in ctx
    assert "provided separately" in ctx.lower() or "research evidence" in ctx.lower()


def test_build_nibio_context_does_not_embed_raw_json(monkeypatch):
    monkeypatch.setattr(pfj, "get_regular_prior_answers", lambda *a, **k: {})
    fetched = {"nibio_results": [
        {"group": {"id": 2607, "name": "Poteter"}, "post": {"id": 62693, "name": "Salg"},
         "data": {"data": [{"aar": 2024, "verdi": 999}]}},
    ]}

    ctx = pfj.build_nibio_context("db.db", 1, "IMP1", hosts="Solanum tuberosum",
                                   fetched_data=fetched)

    assert '"nibio_results"' not in ctx
    assert '"verdi"' not in ctx
    assert "provided separately" in ctx.lower() or "research evidence" in ctx.lower()
