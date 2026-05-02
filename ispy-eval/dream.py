# ispy-eval/dream.py
# Phase 2 of the pipeline: run the three-pass dream cycle on cached photo descriptions.
# This replicates what DreamAgent.swift does on the iPhone, but in Python on your Mac.
#
# Three passes:
#   1. Memory   — one session per photo; builds wiki pages from the description
#   2. Reflection — one session over the whole wiki; finds patterns and wonders
#   3. Consolidation — one session; merges duplicates, weaves links
#
# Run: python dream.py --verbose

from __future__ import annotations
import json
import os
import re
from pathlib import Path


# ── Environment ───────────────────────────────────────────────────────────────

def _load_dotenv() -> None:
    # Reads .env and sets environment variables (e.g. HF_TOKEN for model downloads).
    # os.environ.setdefault means the shell always wins over the file.
    env = Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()


# ── WikiStore — the model's filesystem ───────────────────────────────────────
#
# The model writes memory pages as markdown files inside a directory.
# WikiStore is the Python equivalent of WikiStore.swift — it gives the model
# six "tools" it can call: list, read, write, edit, delete, search.
# The model never sees raw file paths; it always goes through these methods.

class WikiStore:
    def __init__(self, wiki_dir: Path):
        self.wiki_dir = wiki_dir
        wiki_dir.mkdir(parents=True, exist_ok=True)  # create the directory if needed

    def list_memory(self) -> str:
        # Returns an index of all pages, formatted like ispy's index.md.
        # index.md and state.md are excluded — they're housekeeping files, not memories.
        pages = sorted(
            p for p in self.wiki_dir.rglob("*.md")
            if p.name not in ("index.md", "state.md")
        )
        paths = [str(p.relative_to(self.wiki_dir)) for p in pages]
        if not paths:
            return "# Memory Index\n\n(empty)"
        return "# Memory Index\n\n" + "\n".join(f"- [[{p}]]" for p in paths)

    def read_file(self, path: str) -> str:
        # Returns the file contents, or a clear error string if the file doesn't exist.
        # Returning a string (not raising) keeps the model's tool loop running.
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        return full.read_text(encoding="utf-8")

    def write_file(self, path: str, content: str) -> str:
        # Creates or overwrites a file. Creates parent directories automatically.
        # Returning "ok" tells the model the tool call succeeded.
        full = self.wiki_dir / path
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content, encoding="utf-8")
        return "ok"

    def edit_file(self, path: str, old: str, new: str) -> str:
        # Replaces the first occurrence of `old` with `new` inside an existing file.
        # Used for small targeted edits (e.g. adding a backlink) without rewriting the whole page.
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        content = full.read_text(encoding="utf-8")
        if old not in content:
            return f"(old text not found in {path})"
        full.write_text(content.replace(old, new, 1), encoding="utf-8")
        return "ok"

    def delete_file(self, path: str) -> str:
        # Permanently deletes a file (used during consolidation to remove duplicates).
        full = self.wiki_dir / path
        if not full.exists():
            return f"(file not found: {path})"
        full.unlink()
        return "ok"

    def search_memory(self, query: str) -> str:
        # Full-text search: returns paths of files whose name or content contains the query.
        # Case-insensitive. Used by the model to find related pages before writing.
        q = query.lower()
        results = [
            str(p.relative_to(self.wiki_dir))
            for p in self.wiki_dir.rglob("*.md")
            if q in p.read_text(encoding="utf-8").lower() or q in p.name.lower()
        ]
        return "\n".join(results) if results else "(no results)"

    def dispatch(self, name: str, args: dict) -> str:
        # Routes a tool call (name + args dict) to the right method.
        # Called by run_session every time the model emits a tool call token.
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


# ── Tool call parsing ─────────────────────────────────────────────────────────
#
# The on-device Gemma model signals a tool call with a special token sequence:
#   <|tool_call>call:TOOLNAME\n{"arg": "value"}<tool_call|>
#
# We parse this out of the model's raw text output.

# Regex that captures the tool name and the JSON body between the markers.
# re.DOTALL lets . match newlines (the JSON body can span multiple lines).
_TOOL_PATTERN = re.compile(
    r'<\|tool_call>\s*call:([a-z_]+)\s*\{(.*)\}\s*<tool_call\|>',
    re.DOTALL,
)


def preprocess_json(s: str) -> str:
    # The model sometimes emits literal newline characters *inside* a JSON string value,
    # which is invalid JSON (JSON requires \n not a real newline inside strings).
    # This walks the string character by character, tracking whether we're inside a
    # quoted string, and escapes any raw newlines/tabs it finds there.
    result: list[str] = []
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (i == 0 or s[i - 1] != "\\"):
            in_string = not in_string  # toggle: entering or leaving a JSON string
            result.append(c)
        elif in_string and c == "\n":
            result.append("\\n")  # escape the literal newline
        elif in_string and c == "\t":
            result.append("\\t")
        elif in_string and c == "\r":
            result.append("\\r")
        else:
            result.append(c)
        i += 1
    return "".join(result)


def parse_tool_call(output: str) -> tuple[str, dict] | None:
    # Tries to find a tool call in the model output.
    # Returns (tool_name, args_dict) if found, or None if the output is plain text.
    m = _TOOL_PATTERN.search(output)
    if not m:
        return None
    name = m.group(1)
    raw = "{" + m.group(2) + "}"
    try:
        args = json.loads(preprocess_json(raw))
        return name, args
    except json.JSONDecodeError:
        return None  # malformed JSON — treat as plain text


# ── System prompt builder ─────────────────────────────────────────────────────
#
# The system prompt tells the model who it is and what tools it has.
# It uses the exact token format the on-device Gemma model was trained with:
#   <|turn>system\n...content...<turn|>
#
# Tool declarations describe each tool's name, parameters, and return type.
# This is identical to what DreamAgent.swift sends to the on-device model.

_Q = '"'  # shorthand for a double-quote character inside f-strings

# Each tool declaration block follows this structure:
#   <|tool>declaration:TOOLNAME
#   description:"..."
#   ,parameters:{properties:{...},required:[...],type:"OBJECT"},response:{...}
#   <tool|>
TOOL_DECLARATIONS = (
    f'<|tool>declaration:list_memory\n'
    f'description:{_Q}List all pages in ispy\'s memory{_Q}\n'
    f',parameters:{{properties:{{}},required:[],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}Memory index{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
    f'<|tool>declaration:read_file\n'
    f'description:{_Q}Read a memory page by path{_Q}\n'
    f',parameters:{{properties:{{path:{{description:{_Q}e.g. places/coffee-shop.md{_Q},'
    f'type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q}],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}File contents{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
    f'<|tool>declaration:write_file\n'
    f'description:{_Q}Create or overwrite a memory page{_Q}\n'
    f',parameters:{{properties:{{path:{{description:{_Q}File path e.g. places/name.md{_Q},'
    f'type:{_Q}STRING{_Q}}},content:{{description:{_Q}Full markdown content{_Q},'
    f'type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q},{_Q}content{_Q}],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
    f'<|tool>declaration:edit_file\n'
    f'description:{_Q}Replace a section in an existing memory page{_Q}\n'
    f',parameters:{{properties:{{path:{{description:{_Q}File path{_Q},type:{_Q}STRING{_Q}}},'
    f'old:{{description:{_Q}Exact text to find and replace{_Q},type:{_Q}STRING{_Q}}},'
    f'new:{{description:{_Q}Replacement text{_Q},type:{_Q}STRING{_Q}}}}}'
    f',required:[{_Q}path{_Q},{_Q}old{_Q},{_Q}new{_Q}],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
    f'<|tool>declaration:delete_file\n'
    f'description:{_Q}Delete a memory page by path{_Q}\n'
    f',parameters:{{properties:{{path:{{description:{_Q}File path e.g. places/name.md{_Q},'
    f'type:{_Q}STRING{_Q}}}}},required:[{_Q}path{_Q}],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}ok or error{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
    f'<|tool>declaration:search_memory\n'
    f'description:{_Q}Full-text search across all memory pages{_Q}\n'
    f',parameters:{{properties:{{query:{{description:{_Q}Search terms{_Q},'
    f'type:{_Q}STRING{_Q}}}}},required:[{_Q}query{_Q}],type:{_Q}OBJECT{_Q}}}'
    f',response:{{description:{_Q}Matching pages and snippets{_Q},type:{_Q}STRING{_Q}}}\n'
    f'<tool|>\n'
)


def build_system_prompt(role_preamble: str) -> str:
    # Wraps a role description and the tool declarations in the model's system-turn format.
    # role_preamble is different for each pass (memory / reflection / consolidation).
    return (
        "<|turn>system\n"
        + role_preamble
        + "TOOL RULE: After your initial plan, act immediately — call tools, do not describe what you plan to do. One tool call per turn.\n\n"
        + TOOL_DECLARATIONS
        + "<turn|>\n"
    )


# ── Session runner ────────────────────────────────────────────────────────────
#
# One "session" = one complete conversation with the model until it stops calling tools.
# The model alternates: text/tool-call → tool result → text/tool-call → ...
# We feed it the tool result and it keeps going until it writes a plain-text reply.

def run_session(
    model,
    tokenizer,
    system_prompt: str,
    wiki: WikiStore,
    user_message: str,
    max_turns: int = 40,   # safety cap — prevents infinite tool loops
    max_tokens: int = 2048,
    verbose: bool = False,
) -> str:
    """Run one multi-turn tool-use session. Returns final assistant text."""
    if max_turns < 1:
        raise ValueError(f"max_turns must be >= 1, got {max_turns}")

    from mlx_lm import generate  # lazy import — mlx_lm only needed at runtime

    # The system prompt is embedded as a prefix in the first user message.
    # This matches the format used by DreamAgent.swift for the on-device model.
    messages = [
        {"role": "user", "content": system_prompt + "\n\n" + user_message},
    ]

    last_output = ""
    final_output = ""
    for turn in range(max_turns):
        # apply_chat_template serialises the message list into a single string
        # using the model's expected format (e.g. <start_of_turn>user\n...<end_of_turn>)
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        # generate runs the model and returns the new tokens as a plain string
        output = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)
        last_output = output

        if verbose:
            print(f"  [turn {turn + 1}] {output[:120].replace(chr(10), ' ')}")

        tool_call = parse_tool_call(output)
        if tool_call is None:
            # No tool call — the model is done. This is its final reply.
            final_output = output
            break

        # Execute the tool and feed the result back as the next user message
        name, args = tool_call
        result = wiki.dispatch(name, args)
        if verbose:
            print(f"  → {name}({list(args.keys())}) = {result[:80]}")

        messages.append({"role": "assistant", "content": output})
        messages.append({"role": "user", "content": f"<tool_response>{result}</tool_response>"})
    else:
        # Loop exhausted max_turns without the model stopping — return whatever it last said
        final_output = last_output

    return final_output


# ── Model loader ──────────────────────────────────────────────────────────────

# Models live in ispy-eval/models/gemma-4-e2b-it/.
# Run download_models.py once to fetch them. After that, no internet needed.
# Using the mlx-community OptiQ-4bit build — google/gemma-4-E2B-it is a VLM
# and can't be loaded directly by mlx_lm; this is the text-only MLX conversion.
_GEMMA_MODEL_DIR = Path(__file__).parent / "models" / "gemma-4-e2b-it"

def load_model():
    # Loads Gemma 4 E2B from the local models/ directory.
    # Raises a clear error if you haven't run download_models.py yet.
    if not _GEMMA_MODEL_DIR.exists():
        raise FileNotFoundError(
            f"Model not found at {_GEMMA_MODEL_DIR}\n"
            "Run: python download_models.py"
        )
    from mlx_lm import load
    print(f"Loading {_GEMMA_MODEL_DIR.name} …")
    model, tokenizer = load(str(_GEMMA_MODEL_DIR))
    print("Model ready.")
    return model, tokenizer


# ── Role preambles (one per pass) ─────────────────────────────────────────────
#
# Each pass gives the model a different identity and goal.
# These are prepended to the system prompt before the tool declarations.

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


# ── Three-pass pipeline ───────────────────────────────────────────────────────

def run_dream(
    descriptions: list[dict],  # list of entries from descriptions.json
    run_dir: Path,              # output folder for this experiment (data/runs/TIMESTAMP/)
    memory_prompt: str,         # from prompts.py — the instructions for the memory pass
    reflection_prompt: str,
    consolidation_prompt: str,
    verbose: bool = False,
) -> Path:
    """Run the full three-pass dream pipeline. Returns path to wiki directory."""
    wiki_dir = run_dir / "wiki"
    wiki = WikiStore(wiki_dir)
    model, tokenizer = load_model()  # loaded once, reused across all three passes

    # ── Pass 1: Memory ────────────────────────────────────────────────────────
    # One session per photo description. Each session builds several wiki pages
    # for the concepts, entities, and qualities in that photo.
    memory_sys = build_system_prompt(_MEMORY_PREAMBLE)
    for i, entry in enumerate(descriptions):
        memory_id = entry["id"]
        description = entry["description"]
        # The user message combines the prompt instructions with this specific observation
        user_msg = (
            f"{memory_prompt}\n\n"
            f"OBSERVATION (id: {memory_id}):\n{description}"
        )
        if verbose:
            print(f"\n[Memory {i+1}/{len(descriptions)}] {memory_id}")
        run_session(model, tokenizer, memory_sys, wiki, user_msg, verbose=verbose)

    # ── Pass 2: Reflection ────────────────────────────────────────────────────
    # A single session that reads the whole wiki and writes pattern/reflection pages.
    # We pass the current state.md into the preamble so the model knows where it is.
    state = wiki.read_file("state.md") if (wiki_dir / "state.md").exists() else "(no state yet)"
    reflection_sys = build_system_prompt(_REFLECTION_PREAMBLE + f"Current state:\n{state}\n\n")
    if verbose:
        print("\n[Reflection pass]")
    run_session(model, tokenizer, reflection_sys, wiki, reflection_prompt, verbose=verbose)

    # ── Pass 3: Consolidation ─────────────────────────────────────────────────
    # A single session that merges duplicate pages, weaves missing links, and
    # ensures every page belongs to a valid folder.
    consolidation_sys = build_system_prompt(_CONSOLIDATION_PREAMBLE)
    if verbose:
        print("\n[Consolidation pass]")
    run_session(model, tokenizer, consolidation_sys, wiki, consolidation_prompt, verbose=verbose)

    return wiki_dir


# ── CLI entry point ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    import datetime

    parser = argparse.ArgumentParser(description="Run ispy dream pipeline")
    parser.add_argument("--descriptions", default="data/descriptions.json")
    parser.add_argument("--run-dir", default=None, help="Output dir (default: data/runs/TIMESTAMP)")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--model-dir", help="Local directory containing the model files (downloads if not provided)")
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
