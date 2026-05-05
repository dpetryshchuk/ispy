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
