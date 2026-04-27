# ispy Autoresearch Loop — Design Spec

**Date:** 2026-04-27

---

## Goal

A local Python system that runs ispy's dream/reflect/consolidate pipeline outside the iOS app, enabling fast prompt iteration and an autonomous overnight improvement loop — modeled on Karpathy's autoresearch pattern.

---

## Context

ispy currently requires deploying to iPhone to test any prompt change. This makes iteration slow and scoring purely subjective. This system moves the pipeline to Python so experiments run in seconds, results are scored numerically, and a loop agent can improve prompts autonomously.

---

## Architecture

Two-phase pipeline:

**Phase 1 — Describe (one-time per photo set)**
Qwen2.5-VL-3B processes a folder of photos and writes descriptions to a JSON cache. Subsequent experiment runs skip this entirely. Re-running with `--force` regenerates descriptions (used later to optimize vision prompts as a separate target).

**Phase 2 — Dream loop (per experiment)**
Gemma 4 E2B takes cached descriptions and runs the full dream → reflect → consolidate pipeline, writing wiki pages to an output directory. The output is then scored. A loop agent reads scores and proposes prompt edits, running overnight.

---

## File Structure

```
ispy-eval/
├── describe.py           # Phase 1: photos/ → data/descriptions.json
├── dream.py              # Phase 2: descriptions → wiki output in runs/TIMESTAMP/
├── score.py              # Score a wiki output directory
├── autoresearch.py       # Main experiment loop
├── prompts.py            # Current best prompts (mirrors PromptConfig.swift defaults)
├── sync_prompts.py       # Write winning prompts back to PromptConfig.swift
├── requirements.txt
└── data/
    ├── photos/           # User drops photos here
    ├── descriptions.json # Cached Qwen output (immutable unless --force)
    └── runs/             # TIMESTAMP/ directories, each with wiki/ + score.json
```

---

## Models

| Role | Model | Runtime | Notes |
|------|-------|---------|-------|
| Vision (photo → description) | `Qwen/Qwen2.5-VL-3B-Instruct` | `mlx-vlm` | Metal acceleration on Mac |
| Dream/Reflect/Consolidate | `google/gemma-4-E2B-it` | `mlx-lm` | Same family as on-device model |
| Judge (scoring) | `claude-sonnet-4-6` | Anthropic API | Cheap per call, high signal |
| Loop agent (prompt tuning) | `claude-sonnet-4-6` | Anthropic API | Reads scores, proposes edits |

---

## describe.py

**Input:** `data/photos/` (any .jpg/.png/.heic)
**Output:** `data/descriptions.json`

```json
[
  {
    "id": "photo_001",
    "filename": "IMG_4821.jpg",
    "description": "A tan dog lying on a patch of dry grass...",
    "described_at": "2026-04-27T14:32:00Z",
    "vision_prompt_version": 1
  }
]
```

- Loads Qwen2.5-VL-3B via `mlx-vlm`
- Uses the same vision prompt text as `PromptConfig.defaultVisionPrompt`
- Skips photos already in cache (idempotent)
- `--force` flag regenerates all descriptions
- `vision_prompt_version` increments when the vision prompt changes, enabling future A/B comparison

---

## dream.py

**Input:** `data/descriptions.json` + prompts from `prompts.py`
**Output:** `data/runs/TIMESTAMP/wiki/` (markdown files)

Replicates the three passes from `DreamAgent.swift`:

1. **Memory pass** — for each description, runs Gemma 4 E2B with the memory prompt, calls wiki tools (list_memory, read_file, write_file, search_memory) to build pages
2. **Reflection pass** — runs Gemma 4 E2B with the reflection prompt, reads existing pages, writes patterns/ and reflections/ pages
3. **Consolidation pass** — runs Gemma 4 E2B with the consolidation prompt, merges duplicates, weaves links

Wiki tools are implemented as Python functions operating on the run's output directory — no iOS dependency.

Each pass has a max-turn limit (same as DreamAgent) to prevent runaway loops.

---

## score.py

**Input:** `data/runs/TIMESTAMP/wiki/`
**Output:** `data/runs/TIMESTAMP/score.json`

### Structural metrics (deterministic)

| Metric | How | Target |
|--------|-----|--------|
| `page_count` | Count .md files (excl. index/state) | ≥ 6 per capture |
| `pages_per_capture` | page_count / capture_count | ≥ 4 |
| `bidirectional_link_rate` | % of [[links]] that have a backlink | ≥ 80% |
| `avg_links_per_page` | Total links / page count | ≥ 3 |
| `reflection_page_count` | Pages in patterns/ + reflections/ | ≥ 4 |
| `orphan_rate` | % of pages with 0 incoming links | ≤ 10% |

### LLM judge score (Claude API)

Samples 5 random wiki pages, sends to Claude with this rubric:

> Rate 0–10: Do these pages feel like genuine, specific observations about a real world seen through a camera — or generic filler? 10 = highly specific, evocative, every detail grounded. 0 = could have been written about anything.

Returns `judge_score` (float, 0–10) and `judge_reasoning` (one sentence).

### Composite score

```
composite = (
    0.3 * normalized(pages_per_capture) +
    0.2 * bidirectional_link_rate +
    0.2 * normalized(avg_links_per_page) +
    0.1 * normalized(reflection_page_count) +
    0.1 * (1 - orphan_rate) +
    0.1 * (judge_score / 10)
)
```

---

## autoresearch.py

The main loop. Runs indefinitely until interrupted (Ctrl+C) or `--max-iters N`.

```
1. Load current prompts from prompts.py
2. Run dream.py → score.py → record baseline score
3. Loop:
   a. Ask Claude (loop agent) to propose ONE targeted change to ONE prompt
      (memory_prompt | reflection_prompt | consolidation_prompt)
      based on current scores + last 5 experiment results
   b. Apply the proposed change to a temp prompts file
   c. Run dream.py + score.py with temp prompts
   d. If composite score improves: accept change, update prompts.py, log win
   e. If not: discard, log miss
   f. Every 10 iterations: print leaderboard of top 5 prompt configurations
4. On exit: write final best prompts to prompts.py
```

The loop agent prompt gives Claude:
- Current composite score and breakdown
- Last N experiment outcomes (what was tried, did it help)
- Full current prompt text for the target being optimized
- Instruction: propose exactly one specific change, explain why it should help

---

## sync_prompts.py

Reads winning prompts from `prompts.py` and writes them into `PromptConfig.swift`'s `static let default*` values, then bumps `currentVersion` to force device reset.

Run manually after reviewing results: `python sync_prompts.py`

---

## prompts.py

Mirrors `PromptConfig.swift` defaults. Edited by `autoresearch.py` when improvements are found.

```python
MEMORY_PROMPT = """..."""       # mirrors defaultMemoryExtra
REFLECTION_PROMPT = """..."""   # mirrors defaultReflectionInstructions
CONSOLIDATION_PROMPT = """...""" # mirrors defaultConsolidationExtra
VISION_PROMPT = """..."""       # mirrors defaultVisionPrompt
PROMPT_VERSION = 1              # incremented on each accepted change
```

---

## Future: Vision Prompt Optimization

Once the dream loop is stable, `describe.py --force --vision-prompt-version N` re-describes photos with a new vision prompt candidate. The autoresearch loop can then target `VISION_PROMPT` as an optimization variable, comparing description quality before it even enters the dream pipeline.

---

## Dependencies

```
mlx-vlm          # Qwen2.5-VL-3B inference
mlx-lm           # Gemma 4 E2B inference
anthropic         # Judge + loop agent
pillow            # Image loading
```

Mac M-series only (MLX). Python 3.11+.

---

## Success Criteria

- `describe.py` processes a folder of 10 photos in under 2 minutes
- `dream.py` completes one full dream cycle (all 3 passes, 10 captures) in under 10 minutes  
- `autoresearch.py` runs 20+ experiments per hour
- After overnight run: composite score improves by ≥ 10% vs baseline
- Winning prompts sync back to iOS app with one command
