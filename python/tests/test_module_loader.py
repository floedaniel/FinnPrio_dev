# python/tests/test_module_loader.py
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from module_loader import normalize_code, load_module, strip_light


def test_normalize_code_variants():
    assert normalize_code("ENT1.") == "ENT1"
    assert normalize_code("est2") == "EST2"
    assert normalize_code("IMP2.1") == "IMP2.1"
    assert normalize_code("ENT2A") == "ENT2A"


ALL_CODES = [
    "ENT1", "ENT2A", "ENT2B", "ENT3", "ENT4",
    "EST1", "EST2", "EST3", "EST4",
    "IMP1", "IMP2.1", "IMP2.2", "IMP2.3", "IMP3", "IMP4.1", "IMP4.2", "IMP4.3",
    "MAN1", "MAN2", "MAN3", "MAN4", "MAN5",
]


@pytest.mark.parametrize("code", ALL_CODES)
def test_every_code_resolves_to_a_module(code):
    text = load_module(code)
    assert text.startswith("##")


def test_trailing_dot_and_case_resolve_same_file():
    assert load_module("ent1.") == load_module("ENT1")


def test_missing_code_raises_filenotfound():
    with pytest.raises(FileNotFoundError):
        load_module("ZZZ9")


def test_strip_light_headings_keep_text():
    assert strip_light("## Known distribution") == "Known distribution"
    assert strip_light("### Native vs introduced range") == "Native vs introduced range"


def test_strip_light_removes_bold_and_italic_markers():
    assert strip_light("**bold** and *italic*") == "bold and italic"
    assert strip_light("__b__ and _i_") == "b and i"


def test_strip_light_leaves_other_markdown_intact():
    assert strip_light("- item one") == "- item one"
    assert strip_light("[text](http://example.com)") == "[text](http://example.com)"


def test_strip_light_preserves_intra_word_markers():
    assert strip_light("text_embedding_3_small") == "text_embedding_3_small"
    assert strip_light("[a](http://a_b_c.com)") == "[a](http://a_b_c.com)"
    # standalone emphasis still stripped
    assert strip_light("_i_ and **b**") == "i and b"
