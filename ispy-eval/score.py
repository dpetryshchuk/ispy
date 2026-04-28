# ispy-eval/score.py
from __future__ import annotations
import json
import random
import re
from pathlib import Path

_LINK_RE = re.compile(r'\[\[([^\]]+)\]\]')
_EXP_RE  = re.compile(r'\[\[exp:[^\]]+\]\]')


def _pages(wiki_dir: Path) -> list[Path]:
    return [
        p for p in wiki_dir.rglob("*.md")
        if p.name not in ("index.md", "state.md")
    ]


def compute_structural_metrics(wiki_dir: Path, capture_count: int) -> dict:
    pages = _pages(wiki_dir)
    page_count = len(pages)

    all_links: dict[str, set[str]] = {}
    for page in pages:
        content = _EXP_RE.sub("", page.read_text(encoding="utf-8"))
        raw_links = {m.group(1).strip() for m in _LINK_RE.finditer(content)}
        all_links[str(page.relative_to(wiki_dir))] = raw_links

    total_links = 0
    bidirectional = 0
    for src_path, links in all_links.items():
        src_stem = Path(src_path).stem.lower()
        for link in links:
            total_links += 1
            link_key = (link if link.endswith(".md") else link + ".md")
            target_links = all_links.get(link_key, set())
            if any(src_stem in l.lower() for l in target_links):
                bidirectional += 1

    all_targets: set[str] = set()
    for links in all_links.values():
        all_targets.update(l.lower() for l in links)

    orphans = sum(
        1 for p in all_links
        if not any(Path(p).stem.lower() in t for t in all_targets)
    )

    reflection_count = sum(
        1 for p in pages
        if p.parent.name in ("patterns", "reflections")
    )

    return {
        "page_count": page_count,
        "pages_per_capture": page_count / max(capture_count, 1),
        "bidirectional_link_rate": bidirectional / max(total_links, 1),
        "avg_links_per_page": total_links / max(page_count, 1),
        "reflection_page_count": reflection_count,
        "orphan_rate": orphans / max(page_count, 1),
    }


def judge_wiki(wiki_dir: Path, anthropic_api_key: str) -> tuple[float, str]:
    import anthropic
    pages = _pages(wiki_dir)
    sample = random.sample(pages, min(5, len(pages)))
    sample_text = "\n\n---\n\n".join(
        f"**{p.relative_to(wiki_dir)}**\n{p.read_text(encoding='utf-8')}"
        for p in sample
    )
    client = anthropic.Anthropic(api_key=anthropic_api_key)
    resp = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=256,
        messages=[{"role": "user", "content": f"""\
Rate 0-10: Do these wiki pages feel like genuine, specific observations about a real world seen through a camera — or generic filler?

10 = highly specific, evocative, every detail grounded in something actually visible.
0 = could have been written about anything, no real specificity.

Pages:
{sample_text}

Respond with JSON only: {{"score": <float 0-10>, "reasoning": "<one sentence>"}}"""}],
    )
    data = json.loads(resp.content[0].text)
    return float(data["score"]), data["reasoning"]


def compute_composite(metrics: dict, judge_score: float) -> float:
    def norm(val: float, target: float) -> float:
        return min(val / target, 1.0)

    return (
        0.3 * norm(metrics["pages_per_capture"], 4.0)
        + 0.2 * metrics["bidirectional_link_rate"]
        + 0.2 * norm(metrics["avg_links_per_page"], 3.0)
        + 0.1 * norm(metrics["reflection_page_count"], 4.0)
        + 0.1 * (1.0 - metrics["orphan_rate"])
        + 0.1 * (judge_score / 10.0)
    )


def score_run(wiki_dir: Path, capture_count: int, anthropic_api_key: str) -> dict:
    metrics = compute_structural_metrics(wiki_dir, capture_count)
    judge_score, judge_reasoning = judge_wiki(wiki_dir, anthropic_api_key)
    composite = compute_composite(metrics, judge_score)
    return {
        **metrics,
        "judge_score": judge_score,
        "judge_reasoning": judge_reasoning,
        "composite": composite,
    }


if __name__ == "__main__":
    import argparse, os
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir")
    parser.add_argument("--capture-count", type=int, default=1)
    args = parser.parse_args()

    wiki_dir = Path(args.run_dir) / "wiki"
    result = score_run(wiki_dir, args.capture_count, os.environ["ANTHROPIC_API_KEY"])
    out_path = Path(args.run_dir) / "score.json"
    out_path.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
