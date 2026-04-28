# ispy-eval/tests/test_score.py
import tempfile
from pathlib import Path
import pytest
from score import compute_structural_metrics, compute_composite


def make_wiki(tmp: Path, pages: dict[str, str]) -> Path:
    wiki = tmp / "wiki"
    for rel, content in pages.items():
        p = wiki / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    return wiki


def test_page_count():
    with tempfile.TemporaryDirectory() as td:
        wiki = make_wiki(Path(td), {
            "entities/dog.md": "A dog.",
            "qualities/tan.md": "Tan.",
            "places/grass.md": "Grass.",
        })
        m = compute_structural_metrics(wiki, capture_count=1)
        assert m["page_count"] == 3


def test_index_and_state_excluded():
    with tempfile.TemporaryDirectory() as td:
        wiki = make_wiki(Path(td), {
            "index.md": "index",
            "state.md": "state",
            "entities/dog.md": "A dog.",
        })
        m = compute_structural_metrics(wiki, capture_count=1)
        assert m["page_count"] == 1


def test_pages_per_capture():
    with tempfile.TemporaryDirectory() as td:
        wiki = make_wiki(Path(td), {f"entities/page{i}.md": "x" for i in range(8)})
        m = compute_structural_metrics(wiki, capture_count=2)
        assert m["pages_per_capture"] == 4.0


def test_perfect_bidirectional_links():
    with tempfile.TemporaryDirectory() as td:
        wiki = make_wiki(Path(td), {
            "entities/dog.md": "A [[qualities/tan]] dog.\n## Connections\n[[qualities/tan]]",
            "qualities/tan.md": "Tan. On [[entities/dog]].\n## Connections\n[[entities/dog]]",
        })
        m = compute_structural_metrics(wiki, capture_count=1)
        assert m["bidirectional_link_rate"] == 1.0


def test_reflection_page_count():
    with tempfile.TemporaryDirectory() as td:
        wiki = make_wiki(Path(td), {
            "patterns/warmth.md": "I keep noticing warmth.",
            "reflections/wonder.md": "I wonder about the light.",
            "entities/dog.md": "A dog.",
        })
        m = compute_structural_metrics(wiki, capture_count=1)
        assert m["reflection_page_count"] == 2


def test_composite_in_range():
    m = {
        "page_count": 10,
        "pages_per_capture": 5.0,
        "bidirectional_link_rate": 0.8,
        "avg_links_per_page": 3.0,
        "reflection_page_count": 4,
        "orphan_rate": 0.1,
    }
    score = compute_composite(m, judge_score=7.0)
    assert 0.0 <= score <= 1.0


def test_composite_perfect():
    m = {
        "page_count": 20,
        "pages_per_capture": 10.0,
        "bidirectional_link_rate": 1.0,
        "avg_links_per_page": 5.0,
        "reflection_page_count": 8,
        "orphan_rate": 0.0,
    }
    score = compute_composite(m, judge_score=10.0)
    assert score == pytest.approx(1.0)
