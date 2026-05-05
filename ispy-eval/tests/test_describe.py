# ispy-eval/tests/test_describe.py
import json
import tempfile
from pathlib import Path
from describe import load_cache, save_cache, needs_description


def test_load_cache_missing():
    with tempfile.TemporaryDirectory() as tmp:
        result = load_cache(Path(tmp) / "descriptions.json")
        assert result == []


def test_save_and_load_roundtrip():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "descriptions.json"
        entries = [{
            "id": "photo_001",
            "filename": "test.jpg",
            "description": "A dog.",
            "described_at": "2026-04-27T00:00:00Z",
            "vision_prompt_version": 1,
        }]
        save_cache(path, entries)
        assert load_cache(path) == entries


def test_needs_description_new_photo():
    assert needs_description("new.jpg", cache=[], force=False) is True


def test_needs_description_cached():
    cache = [{"filename": "existing.jpg", "vision_prompt_version": 1}]
    assert needs_description("existing.jpg", cache=cache, force=False) is False


def test_needs_description_force_overrides():
    cache = [{"filename": "existing.jpg", "vision_prompt_version": 1}]
    assert needs_description("existing.jpg", cache=cache, force=True) is True
