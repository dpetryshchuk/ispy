# ispy-eval/autoresearch.py
from __future__ import annotations
import argparse
import datetime
import importlib
import json
import os
import sys
from pathlib import Path

import anthropic

import prompts as p
from dream import run_dream
from score import score_run


def _reload_prompts():
    importlib.reload(p)
    return p


def propose_change(client: anthropic.Anthropic, current_prompts, history: list[dict]) -> dict:
    history_text = "\n".join(
        f"- Changed {h['target']}: {h['before']:.3f} → {h['after']:.3f} "
        f"({'ACCEPTED' if h['accepted'] else 'REJECTED'}): {h['reasoning']}"
        for h in history[-10:]
    )
    cur_score = f"{history[-1]['after']:.3f}" if history else "none yet"
    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1024,
        messages=[{"role": "user", "content": f"""\
You are optimizing prompts for ispy, an AI memory system that looks at photos and builds a wiki of observations.

Current composite score: {cur_score} (higher is better, max 1.0)

Scoring weights:
- 30%: pages_per_capture (target ≥4)
- 20%: bidirectional_link_rate (target 1.0)
- 20%: avg_links_per_page (target ≥3)
- 10%: reflection_page_count (target ≥4)
- 10%: orphan_rate (lower is better)
- 10%: judge_score (Claude rates specificity 0-10)

Recent experiment history:
{history_text or "(no history yet)"}

Current prompts:

MEMORY_PROMPT:
{current_prompts.MEMORY_PROMPT}

REFLECTION_PROMPT:
{current_prompts.REFLECTION_PROMPT}

CONSOLIDATION_PROMPT:
{current_prompts.CONSOLIDATION_PROMPT}

Propose ONE specific, targeted change to ONE prompt. Focus on the weakest metric.
Respond with JSON only:
{{
  "target": "MEMORY_PROMPT" | "REFLECTION_PROMPT" | "CONSOLIDATION_PROMPT",
  "old_text": "<exact substring to replace>",
  "new_text": "<replacement>",
  "reasoning": "<one sentence>"
}}"""}],
    )
    return json.loads(response.content[0].text)


def apply_change(change: dict) -> bool:
    """Apply proposed change to prompts.py. Returns False if old_text not found."""
    path = Path("prompts.py")
    content = path.read_text(encoding="utf-8")
    if change["old_text"] not in content:
        return False
    path.write_text(content.replace(change["old_text"], change["new_text"], 1))
    return True


def revert_change(change: dict) -> None:
    path = Path("prompts.py")
    content = path.read_text(encoding="utf-8")
    path.write_text(content.replace(change["new_text"], change["old_text"], 1))


def run_experiment(descriptions: list[dict], api_key: str, verbose: bool) -> tuple[Path, dict]:
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = Path("data/runs") / ts
    run_dir.mkdir(parents=True, exist_ok=True)
    cur = _reload_prompts()
    wiki_dir = run_dream(
        descriptions=descriptions,
        run_dir=run_dir,
        memory_prompt=cur.MEMORY_PROMPT,
        reflection_prompt=cur.REFLECTION_PROMPT,
        consolidation_prompt=cur.CONSOLIDATION_PROMPT,
        verbose=verbose,
    )
    scores = score_run(wiki_dir, len(descriptions), api_key)
    (run_dir / "score.json").write_text(json.dumps(scores, indent=2))
    return run_dir, scores


def main():
    parser = argparse.ArgumentParser(description="ispy autoresearch loop")
    parser.add_argument("--descriptions", default="data/descriptions.json")
    parser.add_argument("--max-iters", type=int, default=0, help="0 = run forever")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.exit("Set ANTHROPIC_API_KEY environment variable.")

    descriptions = json.loads(Path(args.descriptions).read_text())
    client = anthropic.Anthropic(api_key=api_key)
    history: list[dict] = []

    print("Running baseline experiment…")
    _, baseline_scores = run_experiment(descriptions, api_key, args.verbose)
    baseline = baseline_scores["composite"]
    print(f"Baseline composite: {baseline:.3f}")
    history.append({"target": "baseline", "before": 0.0, "after": baseline,
                    "accepted": True, "reasoning": "baseline"})

    iteration = 0
    while True:
        if args.max_iters and iteration >= args.max_iters:
            break
        iteration += 1
        cur = _reload_prompts()
        print(f"\n[Iter {iteration}] Proposing change…")
        try:
            change = propose_change(client, cur, history)
        except Exception as e:
            print(f"  Agent error: {e}. Skipping.")
            continue

        print(f"  Target: {change['target']}")
        print(f"  Reasoning: {change['reasoning']}")

        if not apply_change(change):
            print("  old_text not found in prompts.py — skipping.")
            continue

        _, scores = run_experiment(descriptions, api_key, args.verbose)
        new_score = scores["composite"]
        prev_score = history[-1]["after"]
        accepted = new_score > prev_score

        if accepted:
            print(f"  ACCEPTED: {prev_score:.3f} → {new_score:.3f} (+{new_score-prev_score:.3f})")
        else:
            revert_change(change)
            print(f"  REJECTED: {prev_score:.3f} → {new_score:.3f}. Reverted.")

        history.append({
            "target": change["target"],
            "before": prev_score,
            "after": new_score if accepted else prev_score,
            "accepted": accepted,
            "reasoning": change["reasoning"],
        })

        if iteration % 10 == 0:
            best = max(history, key=lambda h: h["after"])
            print(f"\n  --- Leaderboard after {iteration} iters ---")
            print(f"  Best score: {best['after']:.3f}")
            accepted_count = sum(1 for h in history if h["accepted"])
            print(f"  Accepted: {accepted_count}/{len(history)-1}")

    print(f"\nDone. Final score: {history[-1]['after']:.3f}")
    print("Run `python sync_prompts.py` to write winners to PromptConfig.swift.")


if __name__ == "__main__":
    main()
