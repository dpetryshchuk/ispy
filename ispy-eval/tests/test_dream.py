# ispy-eval/tests/test_dream.py
import pytest
import tempfile
from pathlib import Path
from dream import WikiStore


def test_list_memory_empty():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        result = wiki.list_memory()
        assert "Memory Index" in result


def test_write_then_list():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        listing = wiki.list_memory()
        assert "entities/dog.md" in listing


def test_write_and_read():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        assert wiki.read_file("entities/dog.md") == "A tan dog."


def test_read_missing():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        assert "not found" in wiki.read_file("missing.md")


def test_search_finds_content():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A golden retriever.")
        assert "entities/dog.md" in wiki.search_memory("golden retriever")


def test_search_no_results():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        assert "no results" in wiki.search_memory("purple elephant")


def test_delete_file():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        wiki.delete_file("entities/dog.md")
        assert "not found" in wiki.read_file("entities/dog.md")


def test_edit_file():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        wiki.edit_file("entities/dog.md", old="tan", new="golden")
        assert wiki.read_file("entities/dog.md") == "A golden dog."


def test_edit_file_old_not_found():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("entities/dog.md", "A tan dog.")
        result = wiki.edit_file("entities/dog.md", old="purple", new="golden")
        assert "not found" in result


def test_index_and_state_excluded_from_list():
    with tempfile.TemporaryDirectory() as tmp:
        wiki = WikiStore(Path(tmp) / "wiki")
        wiki.write_file("index.md", "index")
        wiki.write_file("state.md", "state")
        wiki.write_file("entities/dog.md", "A dog.")
        listing = wiki.list_memory()
        assert "index.md" not in listing
        assert "state.md" not in listing
        assert "entities/dog.md" in listing


import json
from dream import parse_tool_call, preprocess_json


def test_parse_json_args():
    out = '<|tool_call>call:write_file\n{"path":"entities/dog.md","content":"A tan dog."}<tool_call|>'
    name, args = parse_tool_call(out)
    assert name == "write_file"
    assert args["path"] == "entities/dog.md"
    assert args["content"] == "A tan dog."


def test_parse_empty_args():
    out = '<|tool_call>call:list_memory\n{}<tool_call|>'
    name, args = parse_tool_call(out)
    assert name == "list_memory"
    assert args == {}


def test_parse_literal_newline_in_value():
    # Model emits real \n inside a JSON string — should still parse
    out = '<|tool_call>call:write_file\n{"path":"a.md","content":"line1\nline2"}<tool_call|>'
    name, args = parse_tool_call(out)
    assert args["content"] == "line1\nline2"


def test_parse_returns_none_for_plain_text():
    assert parse_tool_call("just some text from the model") is None


def test_preprocess_json_escapes_in_string():
    raw = '{"content":"line1\nline2"}'
    result = json.loads(preprocess_json(raw))
    assert result["content"] == "line1\nline2"


def test_preprocess_json_leaves_outside_string_alone():
    raw = '{"a":1}'
    assert preprocess_json(raw) == raw
