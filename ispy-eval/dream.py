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
