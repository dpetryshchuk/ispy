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
