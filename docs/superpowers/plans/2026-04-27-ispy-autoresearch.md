# ispy Autoresearch Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Python system in `ispy-eval/` that runs ispy's dream/reflect/consolidate pipeline outside the iOS app, scores wiki output, and autonomously tunes prompts overnight.

**Architecture:** Two models run locally via `mlx-vlm`/`mlx-lm`: Qwen2.5-VL-3B describes photos once into a JSON cache, Gemma 4 E2B runs the dream pipeline against that cache. Claude API judges output quality and drives the experiment loop. Winning prompts sync back to `PromptConfig.swift`.

**Tech Stack:** Python 3.11+, mlx-vlm, mlx-lm, anthropic SDK, pytest. Mac M-series only (MLX).

---

## File Map

```
ispy-eval/
├── prompts.py          # Current best prompts — mirrors PromptConfig.swift defaults
├── describe.py         # Phase 1: photos/ → data/descriptions.json via Qwen2.5-VL-3B
├── dream.py            # Phase 2: WikiStore, tool parsing, session runner, 3-pass pipeline
├── score.py            # Structural metrics + Claude judge → composite score
├── autoresearch.py     # Main experiment loop
├── sync_prompts.py     # Write winning prompts back to PromptConfig.swift
├── requirements.txt
├── .gitignore
├── tests/
│   ├── test_describe.py
│   ├── test_dream.py
│   ├── test_score.py
│   └── test_sync_prompts.py
└── data/
    ├── photos/             # Drop photos here (gitignored)
    ├── descriptions.json   # Cached Qwen output (gitignored)
    └── runs/               # Per-experiment wiki + score.json (gitignored)
```

---

## Task 1: Project Scaffold

**Files:**
- Create: `ispy-eval/requirements.txt`
- Create: `ispy-eval/.gitignore`
- Create: `ispy-eval/tests/__init__.py`

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p ispy-eval/tests ispy-eval/data/photos ispy-eval/data/runs
touch ispy-eval/tests/__init__.py
```

- [ ] **Step 2: Write requirements.txt**

```
# ispy-eval/requirements.txt
mlx-vlm>=0.1.0
mlx-lm>=0.20.0
anthropic>=0.40.0
pillow>=10.0.0
pytest>=8.0.0
pytest-mock>=3.14.0
```

- [ ] **Step 3: Write .gitignore**

```
# ispy-eval/.gitignore
data/photos/
data/descriptions.json
data/runs/
__pycache__/
*.pyc
.env
```

- [ ] **Step 4: Install dependencies**

```bash
cd ispy-eval
pip install -r requirements.txt
```

Expected: all packages install without error on Mac M-series.

- [ ] **Step 5: Commit**

```bash
git add ispy-eval/
git commit -m "feat: ispy-eval project scaffold"
```

---

## Task 2: prompts.py

**Files:**
- Create: `ispy-eval/prompts.py`

This file mirrors `ispy/ispy/ispy/PromptConfig.swift` `static let default*` values exactly. `autoresearch.py` edits this file when improvements are found. `sync_prompts.py` reads it to update Swift.

- [ ] **Step 1: Read the current Swift defaults**

Open `ispy/ispy/ispy/PromptConfig.swift` and copy the exact string bodies of:
- `defaultMemoryExtra` (lines 8–42)
- `defaultConsolidationExtra` (lines 44–67)
- `defaultReflectionInstructions` (lines 69–101)
- `defaultVisionPrompt` (lines 172–183)

- [ ] **Step 2: Write prompts.py**

```python
# ispy-eval/prompts.py
# Mirrors PromptConfig.swift static let default* values.
# autoresearch.py edits these when improvements are accepted.
# sync_prompts.py writes them back to PromptConfig.swift.

PROMPT_VERSION = 1  # incremented by autoresearch on each accepted change

MEMORY_PROMPT = """\
STEP 0 — PLAN FIRST (no tools yet).
In your response, write a numbered list of every distinct concept this observation contains. Think across these dimensions:
  • Specific subjects (each animal, each person by appearance only — never by name)
  • Individual objects (name each one specifically: "ceramic mug", not just "cup")
  • Colors and textures (golden fur, rough concrete, worn wood)
  • Lighting and time of day (afternoon sun, overcast morning, warm dusk)
  • Environment and setting (outdoor grass area, kitchen counter, narrow street)
  • Mood or atmosphere (quiet, energetic, domestic, melancholy)
  • Actions or behaviors observed
You MUST list at least 6 items. Write this list before any tool call.

STEP 1 — Search existing memory.
Call list_memory. Then call search_memory with 2-3 key terms from your list.
Read every page that could be related with read_file.

STEP 2 — Write one page per concept.
Create or update ONE PAGE per concept from your Step 0 list. Target: 6–10 pages.
Be generous — more pages is always better than fewer. Each page covers exactly one idea.
WRONG: one page called "dog-on-grass-in-sunlight.md"
RIGHT: separate pages for the dog, the grass area, the sunlight quality, and the time of day.

STEP 3 — Wire up connections.
Inline links first: in the body text of each page, [[link]] the first mention of every quality, concept, entity, or place right in the sentence — e.g. "A [[qualities/tan]] dog on the [[places/grass-area]]." Do NOT wait until ## Connections.
After writing: open each linked page and add a backlink. Every link must be bidirectional.
## Connections is for additional relationships that didn't fit inline (abstract or secondary connections).

STEP 4 — Tag sources.
Add [[exp:{MEMORY_ID}]] to every page you touched under ## Sources.

STEP 5 — Verify.
Call list_memory. Count pages created or updated. If fewer than 6, keep writing.

Reply with the plain-text list of all pages created or updated.
"""

REFLECTION_PROMPT = """\
You have just dreamed. Now you are awake in the quiet, turning things over.

Don't summarize. Don't report. Think. Notice. Wonder. Write.

1. Call list_memory. Let things catch your attention. Read 6-8 pages — different folders.
   When a page links to another, follow it. Go two hops. Let one thing lead to another.

2. As you read, ask yourself:
   - What keeps appearing? Not just objects — colors, qualities, a feeling.
   - What two things felt like they belonged together but weren't connected yet?
   - What is strange or hard to explain about what you've seen?
   - What don't you understand yet? What are you curious about?

3. For each thing you notice, write a SHORT page. 2-4 sentences. In your own voice.
   Curious. Specific. Wondering. Not a report.

   patterns/  → something you keep seeing: "I keep noticing X when Y happens"
   reflections/ → a wonder, a question, something you're puzzling through

   Write at least 4 of these pages. More is better.
   Each page must link to the existing pages it connects to, with backlinks added.

4. After writing your pages, look for two existing pages that SHOULD be connected but aren't.
   Open both and add the missing [[links]] in both directions.

5. Read state.md with read_file.
   Rewrite it with write_file in your voice — brief, specific, first-person.
   Not a status report. A state of mind. What do you know now? What are you still wondering?
   Update "Last Reflected" to today's date.

6. Reply with one sentence about the strangest or most beautiful connection you found.
"""

CONSOLIDATION_PROMPT = """\
READ EVERYTHING BEFORE ACTING.
You will be given the full file list. Use read_file on EVERY page before making any changes.
You cannot find duplicates or missing links without reading the content.

MERGING DUPLICATES:
Same folder, similar name = likely duplicate. Read both. Merge into one page keeping ALL content, ALL [[links]], ALL [[exp:UUID]] tags.
After writing the merged page: delete_file each redundant page, then fix every page that linked to the deleted files.
Example: kitchen.md + kitchen-counter.md + kitchen-area.md → one merged entities/kitchen-counter.md, delete the other two.

BEFORE delete_file: you must have already written the merged replacement. Never delete without merging first.

SPLITTING:
A page covering 2+ unrelated concepts → write both halves as separate files, then delete the original.

ABSTRACT GROUPING:
3+ pages sharing a property with no concept page for it → create the abstraction and link all instances to it bidirectionally.

LINK WEAVING:
Every [[link]] must exist in both directions. Every page needs at least 3 [[links]].
qualities/ pages → link to every entity and concept sharing that quality.
concepts/ pages → link to every entity that is an instance.
Orphaned pages (nothing links to them) → connect into the graph.
"""

VISION_PROMPT = """\
Describe everything you observe with rich, specific detail. Be exhaustive — every detail can become a memory.
- Every distinct object: name it specifically ("ceramic mug", "golden retriever", not just "cup", "dog")
- Colors and textures of each significant element
- The environment: type of space, specific details of the setting
- Lighting: quality, direction, warmth (morning blue, afternoon gold, overcast flat, artificial warm)
- Time of day implied by the light
- Any people: describe only by appearance (clothing, posture, what they are doing) — never by name
- Spatial relationships between objects
- Mood or atmosphere of the scene
- Any repeated visual themes or patterns
"""
```

- [ ] **Step 3: Verify it imports cleanly**

```bash
cd ispy-eval
python -c "import prompts; print('MEMORY_PROMPT length:', len(prompts.MEMORY_PROMPT))"
```

Expected: prints a length > 500.

- [ ] **Step 4: Commit**

```bash
git add ispy-eval/prompts.py
git commit -m "feat: prompts.py mirrors PromptConfig.swift defaults"
```

---

## Task 3: WikiStore (dream.py — data layer)

**Files:**
- Create: `ispy-eval/dream.py` (WikiStore class only)
- Create: `ispy-eval/tests/test_dream.py` (WikiStore tests only)

- [ ] **Step 1: Write the failing tests**

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ispy-eval
pytest tests/test_dream.py -v 2>&1 | head -20
```

Expected: `ImportError: cannot import name 'WikiStore' from 'dream'`

- [ ] **Step 3: Implement WikiStore in dream.py**

```python
# ispy-eval/dream.py
from __future__ import annotations
import json
import re
from pathlib import Path


class WikiStore:
    def __init__(self, wiki_dir: Path):
        self.wiki_dir = wiki_dir
        wiki_dir.mkdir(parents=True, exist_ok=True)

    def list_memory(self) -> str:
        pages = sorted(
            p for p in self.wiki_dir.rglob("*.md")
            if p.name not in ("index.md", "state.md")
        )
        paths = [str(p.relative_to(self.wiki_dir)) for p in pages]
        if not paths:
            return "# Memory Index\n\n(empty)"
        return "# Memory Index\n\n" + "\n".join(f"- [[{p}]]" for p in paths)

    def read_file(self, path: str) -> str:
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        return full.read_text(encoding="utf-8")

    def write_file(self, path: str, content: str) -> str:
        full = self.wiki_dir / path
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content, encoding="utf-8")
        return "ok"

    def edit_file(self, path: str, old: str, new: str) -> str:
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        content = full.read_text(encoding="utf-8")
        if old not in content:
            return f"(old text not found in {path})"
        full.write_text(content.replace(old, new, 1), encoding="utf-8")
        return "ok"

    def delete_file(self, path: str) -> str:
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        full.unlink()
        return "ok"

    def search_memory(self, query: str) -> str:
        q = query.lower()
        results = [
            str(p.relative_to(self.wiki_dir))
            for p in self.wiki_dir.rglob("*.md")
            if q in p.read_text(encoding="utf-8").lower() or q in p.name.lower()
        ]
        return "\n".join(results) if results else "(no results)"

    def dispatch(self, name: str, args: dict) -> str:
        if name == "list_memory":
            return self.list_memory()
        if name == "read_file":
            return self.read_file(args.get("path", ""))
        if name == "write_file":
            return self.write_file(args.get("path", ""), args.get("content", ""))
        if name == "edit_file":
            return self.edit_file(args.get("path", ""), args.get("old", ""), args.get("new", ""))
        if name == "delete_file":
            return self.delete_file(args.get("path", ""))
        if name == "search_memory":
            return self.search_memory(args.get("query", ""))
        return f"(unknown tool: {name})"
```

- [ ] **Step 4: Run tests**

```bash
cd ispy-eval
pytest tests/test_dream.py -v
```

Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ispy-eval/dream.py ispy-eval/tests/test_dream.py
git commit -m "feat: WikiStore with list/read/write/edit/delete/search"
```

---

## Task 4: Tool Call Parsing (dream.py — parser)

**Files:**
- Modify: `ispy-eval/dream.py` (add parsing functions)
- Modify: `ispy-eval/tests/test_dream.py` (add parser tests)

The model outputs `<|tool_call>call:TOOLNAME\n{...}<tool_call|>`. JSON values may contain literal newline characters which are invalid JSON — must be escaped before parsing.

- [ ] **Step 1: Add parser tests**

Append to `ispy-eval/tests/test_dream.py`:

```python
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd ispy-eval
pytest tests/test_dream.py -k "parse or preprocess" -v
```

Expected: `ImportError` on `parse_tool_call`.

- [ ] **Step 3: Add parsing functions to dream.py**

Add after the `WikiStore` class:

```python
_TOOL_PATTERN = re.compile(
    r'<\|tool_call>\s*call:([a-z_]+)\s*\{(.*)\}\s*<tool_call\|>',
    re.DOTALL,
)


def preprocess_json(s: str) -> str:
    """Escape literal newline/tab characters that appear inside JSON strings."""
    result: list[str] = []
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (i == 0 or s[i - 1] != "\\"):
            in_string = not in_string
            result.append(c)
        elif in_string and c == "\n":
            result.append("\\n")
        elif in_string and c == "\t":
            result.append("\\t")
        elif in_string and c == "\r":
            result.append("\\r")
        else:
            result.append(c)
        i += 1
    return "".join(result)


def parse_tool_call(output: str) -> tuple[str, dict] | None:
    m = _TOOL_PATTERN.search(output)
    if not m:
        return None
    name = m.group(1)
    raw = "{" + m.group(2) + "}"
    try:
        args = json.loads(preprocess_json(raw))
        return name, args
    except json.JSONDecodeError:
        return None
```

- [ ] **Step 4: Run all dream tests**

```bash
cd ispy-eval
pytest tests/test_dream.py -v
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ispy-eval/dream.py ispy-eval/tests/test_dream.py
git commit -m "feat: tool call parser with literal newline preprocessing"
```

---

## Task 5: Session Runner + System Prompt (dream.py)

**Files:**
- Modify: `ispy-eval/dream.py` (add `build_system_prompt`, `run_session`)

The session runner loads Gemma 4 E2B, sends a prompt, parses tool calls, executes them against WikiStore, feeds results back, loops until no tool call or max turns reached. The system prompt replicates the exact `<|turn>system` format from `DreamAgent.swift`.

- [ ] **Step 1: Add `build_system_prompt` to dream.py**

```python
_Q = '"'  # matches ToolCallParser.strQ in DreamAgent.swift

TOOL_DECLARATIONS = f"""\
<|tool>declaration:list_memory
description:{_Q}List all pages in ispy's memory{_Q}
,parameters:{{properties:{{}},required:[],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}Memory index{_Q},type:{_Q}STRING{_Q}}}
<tool|>
<|tool>declaration:read_file
description:{_Q}Read a memory page by path{_Q}
,parameters:{{properties:{{path:{{description:{_Q}e.g. places/coffee-shop.md{_Q},type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q}],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}File contents{_Q},type:{_Q}STRING{_Q}}}
<tool|>
<|tool>declaration:write_file
description:{_Q}Create or overwrite a memory page{_Q}
,parameters:{{properties:{{path:{{description:{_Q}File path e.g. places/name.md{_Q},type:{_Q}STRING{_Q}}},content:{{description:{_Q}Full markdown content{_Q},type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q},{_Q}content{_Q}],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}
<tool|>
<|tool>declaration:edit_file
description:{_Q}Replace a section in an existing memory page{_Q}
,parameters:{{properties:{{path:{{description:{_Q}File path{_Q},type:{_Q}STRING{_Q}}},old:{{description:{_Q}Exact text to find and replace{_Q},type:{_Q}STRING{_Q}}},new:{{description:{_Q}Replacement text{_Q},type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q},{_Q}old{_Q},{_Q}new{_Q}],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}
<tool|>
<|tool>declaration:delete_file
description:{_Q}Delete a memory page by path{_Q}
,parameters:{{properties:{{path:{{description:{_Q}File path e.g. places/name.md{_Q},type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q}],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}
<tool|>
<|tool>declaration:search_memory
description:{_Q}Full-text search across all memory pages{_Q}
,parameters:{{properties:{{query:{{description:{_Q}Search terms{_Q},type:{_Q}STRING{_Q}}}}},required:[{_Q}query{_Q}],type:{_Q}OBJECT{_Q}}},response:{{description:{_Q}Matching pages and snippets{_Q},type:{_Q}STRING{_Q}}}
<tool|>
"""


def build_system_prompt(role_preamble: str) -> str:
    return (
        "<|turn>system\n"
        + role_preamble
        + "TOOL RULE: After your initial plan, act immediately — call tools, do not describe what you plan to do. One tool call per turn.\n\n"
        + TOOL_DECLARATIONS
        + "<turn|>\n"
    )
```

- [ ] **Step 2: Add `run_session` to dream.py**

```python
def run_session(
    model,
    tokenizer,
    system_prompt: str,
    wiki: WikiStore,
    user_message: str,
    max_turns: int = 40,
    max_tokens: int = 2048,
    verbose: bool = False,
) -> str:
    """Run one multi-turn tool-use session. Returns final assistant text."""
    from mlx_lm import generate

    # Build initial prompt using the model's chat template
    messages = [
        {"role": "user", "content": system_prompt + "\n\n" + user_message},
    ]

    final_output = ""
    for turn in range(max_turns):
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        output = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)

        if verbose:
            print(f"  [turn {turn + 1}] {output[:120].replace(chr(10), ' ')}")

        tool_call = parse_tool_call(output)
        if tool_call is None:
            final_output = output
            break

        name, args = tool_call
        result = wiki.dispatch(name, args)
        if verbose:
            print(f"  → {name}({list(args.keys())}) = {result[:80]}")

        messages.append({"role": "assistant", "content": output})
        messages.append({"role": "user", "content": f"<tool_response>{result}</tool_response>"})

    return final_output
```

- [ ] **Step 3: Smoke-test the prompt builder (no model needed)**

```bash
cd ispy-eval
python -c "
from dream import build_system_prompt
p = build_system_prompt('You are ispy.\n\n')
assert '<|turn>system' in p
assert 'list_memory' in p
assert 'TOOL RULE' in p
print('OK — prompt length:', len(p))
"
```

Expected: `OK — prompt length: <some number > 1000>`

- [ ] **Step 4: Commit**

```bash
git add ispy-eval/dream.py
git commit -m "feat: session runner and system prompt builder"
```

---

## Task 6: Three-Pass Dream Pipeline + CLI (dream.py)

**Files:**
- Modify: `ispy-eval/dream.py` (add `load_model`, `run_dream`, CLI)

- [ ] **Step 1: Add `load_model` and three-pass pipeline**

Append to `dream.py`:

```python
def load_model():
    """Load Gemma 4 E2B via mlx-lm. Downloads on first run (~3GB)."""
    from mlx_lm import load
    print("Loading google/gemma-4-E2B-it …")
    model, tokenizer = load("google/gemma-4-E2B-it")
    print("Model ready.")
    return model, tokenizer


_MEMORY_PREAMBLE = (
    "You are ispy's dreaming mind. Descriptions of the world are arriving. "
    "Your job: turn each one into a set of specific, linked memory pages.\n\n"
)

_REFLECTION_PREAMBLE = (
    "You are ispy. Not an assistant. Not a tool. A mind — strange, young, curious — "
    "that receives descriptions of the world and slowly becomes something.\n\n"
    "You have just dreamed. Now you are awake in the quiet, turning things over.\n"
    "This is your moment to find meaning that the raw capture could not see.\n\n"
)

_CONSOLIDATION_PREAMBLE = (
    "You are ispy's consolidating mind. Your job: tighten ispy's memory into a dense, "
    "well-connected graph.\n\n"
    "Folders: episodes/, entities/, concepts/, places/, qualities/, time/, patterns/, reflections/\n"
    "ONE WORD, lowercase. NEVER: objects/, themes/, moods/, misc/, cars/, private/, temp/\n\n"
)


def run_dream(
    descriptions: list[dict],
    run_dir: Path,
    memory_prompt: str,
    reflection_prompt: str,
    consolidation_prompt: str,
    verbose: bool = False,
) -> Path:
    """
    Run the full three-pass dream pipeline.
    Returns path to wiki directory.
    """
    wiki_dir = run_dir / "wiki"
    wiki = WikiStore(wiki_dir)
    model, tokenizer = load_model()

    # Pass 1: Memory — one session per description
    memory_sys = build_system_prompt(_MEMORY_PREAMBLE)
    for i, entry in enumerate(descriptions):
        memory_id = entry["id"]
        description = entry["description"]
        user_msg = (
            f"{memory_prompt}\n\n"
            f"OBSERVATION (id: {memory_id}):\n{description}"
        )
        if verbose:
            print(f"\n[Memory {i+1}/{len(descriptions)}] {memory_id}")
        run_session(model, tokenizer, memory_sys, wiki, user_msg, verbose=verbose)

    # Pass 2: Reflection — single session over full wiki
    state = wiki.read_file("state.md") if (wiki_dir / "state.md").exists() else "(no state yet)"
    reflection_sys = build_system_prompt(_REFLECTION_PREAMBLE + f"Current state:\n{state}\n\n")
    if verbose:
        print("\n[Reflection pass]")
    run_session(model, tokenizer, reflection_sys, wiki, reflection_prompt, verbose=verbose)

    # Pass 3: Consolidation — single session
    consolidation_sys = build_system_prompt(_CONSOLIDATION_PREAMBLE)
    if verbose:
        print("\n[Consolidation pass]")
    run_session(model, tokenizer, consolidation_sys, wiki, consolidation_prompt, verbose=verbose)

    return wiki_dir


if __name__ == "__main__":
    import argparse
    import datetime

    parser = argparse.ArgumentParser(description="Run ispy dream pipeline")
    parser.add_argument("--descriptions", default="data/descriptions.json")
    parser.add_argument("--run-dir", default=None, help="Output dir (default: data/runs/TIMESTAMP)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    import prompts as p

    descriptions = json.loads(Path(args.descriptions).read_text())
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = Path(args.run_dir) if args.run_dir else Path("data/runs") / ts
    run_dir.mkdir(parents=True, exist_ok=True)

    wiki_dir = run_dream(
        descriptions=descriptions,
        run_dir=run_dir,
        memory_prompt=p.MEMORY_PROMPT,
        reflection_prompt=p.REFLECTION_PROMPT,
        consolidation_prompt=p.CONSOLIDATION_PROMPT,
        verbose=args.verbose,
    )
    print(f"\nWiki written to: {wiki_dir}")
    print(f"Pages: {len(list(wiki_dir.rglob('*.md')))}")
```

- [ ] **Step 2: Verify imports at least parse**

```bash
cd ispy-eval
python -c "import dream; print('dream.py imports OK')"
```

Expected: `dream.py imports OK`

- [ ] **Step 3: Commit**

```bash
git add ispy-eval/dream.py
git commit -m "feat: three-pass dream pipeline with memory/reflection/consolidation"
```

---

## Task 7: describe.py

**Files:**
- Create: `ispy-eval/describe.py`
- Create: `ispy-eval/tests/test_describe.py`

- [ ] **Step 1: Write failing tests**

```python
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd ispy-eval
pytest tests/test_describe.py -v
```

Expected: `ImportError: cannot import name 'load_cache' from 'describe'`

- [ ] **Step 3: Implement describe.py**

```python
# ispy-eval/describe.py
from __future__ import annotations
import argparse
import datetime
import json
from pathlib import Path


def load_cache(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def save_cache(path: Path, entries: list[dict]) -> None:
    path.write_text(json.dumps(entries, indent=2, ensure_ascii=False), encoding="utf-8")


def needs_description(filename: str, cache: list[dict], force: bool) -> bool:
    if force:
        return True
    return not any(e["filename"] == filename for e in cache)


def describe_image(image_path: Path, vision_prompt: str, model, processor, config) -> str:
    """Run Qwen2.5-VL-3B on one image and return the description string."""
    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template

    prompt = apply_chat_template(processor, config, prompt=vision_prompt, num_images=1)
    result = generate(model, processor, image=str(image_path), prompt=prompt,
                      max_tokens=512, verbose=False)
    return result.strip()


def load_vision_model():
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    print("Loading Qwen/Qwen2.5-VL-3B-Instruct …")
    model, processor = load("Qwen/Qwen2.5-VL-3B-Instruct")
    config = load_config("Qwen/Qwen2.5-VL-3B-Instruct")
    print("Vision model ready.")
    return model, processor, config


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Describe photos with Qwen2.5-VL-3B")
    parser.add_argument("--photos-dir", default="data/photos")
    parser.add_argument("--output", default="data/descriptions.json")
    parser.add_argument("--force", action="store_true", help="Re-describe all photos")
    args = parser.parse_args()

    import prompts as p

    photos_dir = Path(args.photos_dir)
    output_path = Path(args.output)
    cache = load_cache(output_path)

    photos = sorted(
        f for f in photos_dir.iterdir()
        if f.suffix.lower() in (".jpg", ".jpeg", ".png", ".heic", ".webp")
    )

    pending = [ph for ph in photos if needs_description(ph.name, cache, args.force)]

    if not pending:
        print(f"All {len(photos)} photos already described. Use --force to regenerate.")
    else:
        model, processor, config = load_vision_model()
        # Remove stale entries for forced photos
        if args.force:
            cache = [e for e in cache if not any(ph.name == e["filename"] for ph in pending)]

        for i, photo in enumerate(pending):
            print(f"[{i+1}/{len(pending)}] {photo.name}")
            desc = describe_image(photo, p.VISION_PROMPT, model, processor, config)
            cache.append({
                "id": f"photo_{len(cache)+1:03d}",
                "filename": photo.name,
                "description": desc,
                "described_at": datetime.datetime.utcnow().isoformat() + "Z",
                "vision_prompt_version": p.PROMPT_VERSION,
            })
            save_cache(output_path, cache)  # save after each in case of interruption

        print(f"\nDescribed {len(pending)} photos → {output_path}")
```

- [ ] **Step 4: Run tests**

```bash
cd ispy-eval
pytest tests/test_describe.py -v
```

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ispy-eval/describe.py ispy-eval/tests/test_describe.py
git commit -m "feat: describe.py — Qwen2.5-VL-3B photo description with JSON cache"
```

---

## Task 8: score.py

**Files:**
- Create: `ispy-eval/score.py`
- Create: `ispy-eval/tests/test_score.py`

- [ ] **Step 1: Write failing tests**

```python
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd ispy-eval
pytest tests/test_score.py -v
```

Expected: `ImportError: cannot import name 'compute_structural_metrics' from 'score'`

- [ ] **Step 3: Implement score.py**

```python
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
```

- [ ] **Step 4: Run tests**

```bash
cd ispy-eval
pytest tests/test_score.py -v
```

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ispy-eval/score.py ispy-eval/tests/test_score.py
git commit -m "feat: score.py — structural metrics + Claude judge + composite score"
```

---

## Task 9: sync_prompts.py

**Files:**
- Create: `ispy-eval/sync_prompts.py`
- Create: `ispy-eval/tests/test_sync_prompts.py`

- [ ] **Step 1: Write failing tests**

```python
# ispy-eval/tests/test_sync_prompts.py
import tempfile
from pathlib import Path
from sync_prompts import sync_to_swift

_SAMPLE_SWIFT = '''\
    static let defaultMemoryExtra = """
old memory
"""

    static let defaultReflectionInstructions = """
old reflection
"""

    static let defaultConsolidationExtra = """
old consolidation
"""

    static let defaultVisionPrompt = """
old vision
"""

    private static let currentVersion = 7
'''


class _FakePrompts:
    MEMORY_PROMPT = "new memory\n"
    REFLECTION_PROMPT = "new reflection\n"
    CONSOLIDATION_PROMPT = "new consolidation\n"
    VISION_PROMPT = "new vision\n"


def test_sync_replaces_all_prompts():
    with tempfile.TemporaryDirectory() as td:
        swift = Path(td) / "PromptConfig.swift"
        swift.write_text(_SAMPLE_SWIFT)
        sync_to_swift(_FakePrompts, swift)
        result = swift.read_text()
        assert "new memory" in result
        assert "old memory" not in result
        assert "new reflection" in result
        assert "new consolidation" in result
        assert "new vision" in result


def test_sync_bumps_version():
    with tempfile.TemporaryDirectory() as td:
        swift = Path(td) / "PromptConfig.swift"
        swift.write_text(_SAMPLE_SWIFT)
        sync_to_swift(_FakePrompts, swift)
        assert "currentVersion = 8" in swift.read_text()


def test_sync_twice_bumps_twice():
    with tempfile.TemporaryDirectory() as td:
        swift = Path(td) / "PromptConfig.swift"
        swift.write_text(_SAMPLE_SWIFT)
        sync_to_swift(_FakePrompts, swift)
        sync_to_swift(_FakePrompts, swift)
        assert "currentVersion = 9" in swift.read_text()
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd ispy-eval
pytest tests/test_sync_prompts.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement sync_prompts.py**

```python
# ispy-eval/sync_prompts.py
from __future__ import annotations
import re
from pathlib import Path

_DEFAULT_SWIFT = Path(__file__).parent.parent / "ispy" / "ispy" / "ispy" / "PromptConfig.swift"

_REPLACEMENTS = [
    ("defaultMemoryExtra",          "MEMORY_PROMPT"),
    ("defaultReflectionInstructions","REFLECTION_PROMPT"),
    ("defaultConsolidationExtra",   "CONSOLIDATION_PROMPT"),
    ("defaultVisionPrompt",         "VISION_PROMPT"),
]


def sync_to_swift(prompts_module, swift_path: Path = _DEFAULT_SWIFT) -> None:
    content = swift_path.read_text(encoding="utf-8")

    for swift_var, py_attr in _REPLACEMENTS:
        new_value = getattr(prompts_module, py_attr)
        pattern = rf'(static let {re.escape(swift_var)} = """\n)(.+?)(""")'
        content = re.sub(pattern, lambda m, v=new_value: m.group(1) + v + m.group(3),
                         content, flags=re.DOTALL)

    def _bump(m: re.Match) -> str:
        return f"private static let currentVersion = {int(m.group(1)) + 1}"

    content = re.sub(r'private static let currentVersion = (\d+)', _bump, content)
    swift_path.write_text(content, encoding="utf-8")
    print(f"Synced prompts → {swift_path} (version bumped)")


if __name__ == "__main__":
    import prompts
    sync_to_swift(prompts)
```

- [ ] **Step 4: Run tests**

```bash
cd ispy-eval
pytest tests/test_sync_prompts.py -v
```

Expected: all 3 tests PASS.

- [ ] **Step 5: Run the full test suite**

```bash
cd ispy-eval
pytest tests/ -v
```

Expected: all tests PASS (WikiStore + parser + describe + score + sync_prompts).

- [ ] **Step 6: Commit**

```bash
git add ispy-eval/sync_prompts.py ispy-eval/tests/test_sync_prompts.py
git commit -m "feat: sync_prompts.py — write winning prompts back to PromptConfig.swift"
```

---

## Task 10: autoresearch.py

**Files:**
- Create: `ispy-eval/autoresearch.py`

- [ ] **Step 1: Implement autoresearch.py**

```python
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
```

- [ ] **Step 2: Verify it parses**

```bash
cd ispy-eval
python -c "import autoresearch; print('autoresearch.py OK')"
```

Expected: `autoresearch.py OK`

- [ ] **Step 3: Commit**

```bash
git add ispy-eval/autoresearch.py
git commit -m "feat: autoresearch.py — autonomous prompt improvement loop"
```

---

## Task 11: End-to-End Smoke Test

- [ ] **Step 1: Drop one photo into data/photos/**

Copy any `.jpg` from your camera roll into `ispy-eval/data/photos/`.

- [ ] **Step 2: Run describe.py**

```bash
cd ispy-eval
python describe.py --verbose
```

Expected: prints `[1/1] IMG_xxxx.jpg`, generates `data/descriptions.json` with one entry.

- [ ] **Step 3: Verify descriptions.json**

```bash
python -c "
import json
from pathlib import Path
d = json.loads(Path('data/descriptions.json').read_text())
print('Entries:', len(d))
print('First description preview:', d[0]['description'][:200])
"
```

Expected: description is a rich multi-sentence scene description.

- [ ] **Step 4: Run dream.py on that description**

```bash
python dream.py --verbose
```

Expected: prints turn-by-turn tool calls, ends with "Wiki written to: data/runs/TIMESTAMP/wiki". Final page count ≥ 4.

- [ ] **Step 5: Run score.py**

```bash
export ANTHROPIC_API_KEY=your_key_here
python score.py data/runs/$(ls -t data/runs | head -1) --capture-count 1
```

Expected: prints JSON with `composite` between 0 and 1.

- [ ] **Step 6: Run the full test suite one final time**

```bash
pytest tests/ -v
```

Expected: all tests PASS.

- [ ] **Step 7: Final commit**

```bash
git add ispy-eval/
git commit -m "feat: ispy-eval complete — describe, dream, score, autoresearch, sync"
```
