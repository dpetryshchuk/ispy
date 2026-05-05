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
