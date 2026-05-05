# ispy-eval/autoresearch.py
# The main experiment loop. Runs the full dream pipeline, scores the output,
# then asks Claude to propose a prompt improvement. Accepts the change if it scores
# higher, reverts it if not. Repeat overnight.
#
# This is the "autoresearch" pattern: define a metric, run experiments autonomously,
# keep improvements. No human in the loop.
#
# Run: python autoresearch.py --max-iters 20 --verbose

from __future__ import annotations
import argparse
import datetime
import importlib
import json
import os
import sys
from pathlib import Path


# ── Environment ───────────────────────────────────────────────────────────────

def _load_dotenv() -> None:
    env = Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()

import anthropic  # needs ANTHROPIC_API_KEY from .env above

import prompts as p
from dream import run_dream
from score import score_run


# ── Prompt hot-reload ─────────────────────────────────────────────────────────

def _reload_prompts():
    # prompts.py is edited on disk by apply_change(). importlib.reload() re-reads it
    # so the next experiment picks up the updated text without restarting the process.
    importlib.reload(p)
    return p


# ── Loop agent: propose a change ──────────────────────────────────────────────

def propose_change(client: anthropic.Anthropic, current_prompts, history: list[dict]) -> dict:
    # Asks Claude to look at the current score, the last 10 experiments, and the
    # current prompt text, then propose ONE targeted edit to ONE prompt.
    # Returns a dict with: target, old_text, new_text, reasoning.
    history_text = "\n".join(
        f"- Changed {h['target']}: {h['before']:.3f} → {h['after']:.3f} "
        f"({'ACCEPTED' if h['accepted'] else 'REJECTED'}): {h['reasoning']}"
        for h in history[-10:]  # only show recent history to stay within context window
    )
    # Use the last accepted score as the current baseline
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


# ── Prompt file mutation ───────────────────────────────────────────────────────

def apply_change(change: dict) -> bool:
    # Edits prompts.py on disk by replacing old_text with new_text.
    # Returns False if old_text isn't found (Claude hallucinated a substring that
    # doesn't exist) — caller should skip this iteration.
    path = Path("prompts.py")
    content = path.read_text(encoding="utf-8")
    if change["old_text"] not in content:
        return False
    path.write_text(content.replace(change["old_text"], change["new_text"], 1))
    return True


def revert_change(change: dict) -> None:
    # Undoes apply_change() by swapping new_text back to old_text.
    # Called when a proposed change didn't improve the score.
    path = Path("prompts.py")
    content = path.read_text(encoding="utf-8")
    path.write_text(content.replace(change["new_text"], change["old_text"], 1))


# ── Single experiment ─────────────────────────────────────────────────────────

def run_experiment(descriptions: list[dict], api_key: str, verbose: bool) -> tuple[Path, dict]:
    # One experiment = dream pipeline + scoring.
    # Creates a timestamped run directory, writes wiki pages and score.json into it.
    # Returns (run_dir, scores_dict).
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = Path("data/runs") / ts
    run_dir.mkdir(parents=True, exist_ok=True)

    # Reload prompts from disk so we pick up any changes made by apply_change()
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


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="ispy autoresearch loop")
    parser.add_argument("--descriptions", default="data/descriptions.json")
    parser.add_argument("--max-iters", type=int, default=0, help="0 = run forever")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.exit("Set ANTHROPIC_API_KEY in .env or environment.")

    descriptions = json.loads(Path(args.descriptions).read_text())
    client = anthropic.Anthropic(api_key=api_key)
    history: list[dict] = []  # running log of every experiment this session

    # ── Baseline ──────────────────────────────────────────────────────────────
    # Run once with the current prompts so we have a score to beat.
    print("Running baseline experiment…")
    _, baseline_scores = run_experiment(descriptions, api_key, args.verbose)
    baseline = baseline_scores["composite"]
    print(f"Baseline composite: {baseline:.3f}")
    history.append({
        "target": "baseline",
        "before": 0.0,
        "after": baseline,
        "accepted": True,
        "reasoning": "baseline",
    })

    # ── Improvement loop ──────────────────────────────────────────────────────
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
            # If the Claude call fails (rate limit, bad JSON, etc.), skip and retry
            print(f"  Agent error: {e}. Skipping.")
            continue

        print(f"  Target: {change['target']}")
        print(f"  Reasoning: {change['reasoning']}")

        if not apply_change(change):
            # Claude proposed replacing text that doesn't exist in the file
            print("  old_text not found in prompts.py — skipping.")
            continue

        _, scores = run_experiment(descriptions, api_key, args.verbose)
        new_score = scores["composite"]
        prev_score = history[-1]["after"]
        accepted = new_score > prev_score  # strictly better = keep

        if accepted:
            print(f"  ACCEPTED: {prev_score:.3f} → {new_score:.3f} (+{new_score-prev_score:.3f})")
        else:
            # Score didn't improve — undo the edit so next iteration starts clean
            revert_change(change)
            print(f"  REJECTED: {prev_score:.3f} → {new_score:.3f}. Reverted.")

        history.append({
            "target": change["target"],
            "before": prev_score,
            "after": new_score if accepted else prev_score,
            "accepted": accepted,
            "reasoning": change["reasoning"],
        })

        # Every 10 iterations print a summary so you can see progress at a glance
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
