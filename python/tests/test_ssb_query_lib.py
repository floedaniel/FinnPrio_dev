# python/tests/test_ssb_query_lib.py
"""Tests for ssb_query_lib.py transient-error retry behavior.

Live-observed: a real ENT3 run hit "HTTP Error 503: Service Unavailable"
from data.ssb.no on a query that succeeds when retried moments later — SSB
is occasionally transiently overloaded. Since the caller wants maximum
data recovery ("return as much as possible"), a single transient blip
should not permanently drop that commodity from the results.
"""
import io
import os
import sys
import urllib.error

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import ssb_query_lib as lib


def _http_error(status):
    return urllib.error.HTTPError(
        url="https://data.ssb.no/x", code=status, msg="error",
        hdrs=None, fp=io.BytesIO(b"{}"),
    )


class _FakeResponse:
    def __init__(self, payload: bytes):
        self._payload = payload
        self.headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n=None):
        if n is None:
            data, self._payload = self._payload, b""
            return data
        data, self._payload = self._payload[:n], self._payload[n:]
        return data


_GOOD_PAYLOAD = (
    b'{"dimension": {"Tid": {"label": "year", '
    b'"category": {"label": {"2024": "2024"}, "index": {"2024": 0}}}}, '
    b'"value": [1]}'
)

SELECTION = [{"variableCode": "Tid", "valueCodes": ["top(1)"]}]


def test_ssb_query_data_retries_on_503_and_succeeds(monkeypatch):
    calls = {"n": 0}

    def flaky_urlopen(req, timeout=None):
        calls["n"] += 1
        if calls["n"] < 3:
            raise _http_error(503)
        return _FakeResponse(_GOOD_PAYLOAD)
    monkeypatch.setattr(lib.urllib.request, "urlopen", flaky_urlopen)
    monkeypatch.setattr(lib.time, "sleep", lambda s: None)

    result = lib.ssb_query_data("08801", SELECTION)

    assert calls["n"] == 3
    assert '"n_rows"' in result


def test_ssb_query_data_gives_up_after_max_retries_on_persistent_503(monkeypatch):
    calls = {"n": 0}

    def always_503(req, timeout=None):
        calls["n"] += 1
        raise _http_error(503)
    monkeypatch.setattr(lib.urllib.request, "urlopen", always_503)
    monkeypatch.setattr(lib.time, "sleep", lambda s: None)

    with pytest.raises(urllib.error.HTTPError):
        lib.ssb_query_data("08801", SELECTION)

    assert calls["n"] > 1, "should have retried at least once before giving up"


def test_ssb_query_data_does_not_retry_non_transient_errors(monkeypatch):
    """A 400 (bad selection) is deterministic — retrying it wastes time
    and will never succeed, unlike a 503."""
    calls = {"n": 0}

    def bad_request(req, timeout=None):
        calls["n"] += 1
        raise _http_error(400)
    monkeypatch.setattr(lib.urllib.request, "urlopen", bad_request)
    monkeypatch.setattr(lib.time, "sleep", lambda s: None)

    with pytest.raises(urllib.error.HTTPError):
        lib.ssb_query_data("08801", SELECTION)

    assert calls["n"] == 1
