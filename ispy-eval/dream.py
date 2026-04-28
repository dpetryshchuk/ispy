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


_Q = '"'  # quote character — matches ToolCallParser.strQ in DreamAgent.swift

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
    return (
        "<|turn>system\n"
        + role_preamble
        + "TOOL RULE: After your initial plan, act immediately — call tools, do not describe what you plan to do. One tool call per turn.\n\n"
        + TOOL_DECLARATIONS
        + "<turn|>\n"
    )


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
    if max_turns < 1:
        raise ValueError(f"max_turns must be >= 1, got {max_turns}")

    from mlx_lm import generate

    messages = [
        {"role": "user", "content": system_prompt + "\n\n" + user_message},
    ]

    last_output = ""
    final_output = ""
    for turn in range(max_turns):
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        output = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)
        last_output = output

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
    else:
        final_output = last_output  # hit max_turns; return last model output

    return final_output


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
