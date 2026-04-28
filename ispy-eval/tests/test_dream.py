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
