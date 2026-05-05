# ispy-eval/describe.py
# Phase 1 of the pipeline: turn a folder of photos into a JSON cache of descriptions.
# Uses Qwen2.5-VL-3B (a small vision-language model) running locally via mlx-vlm.
# Once photos are described, this step is skipped on future runs — the cache is reused.
# Run: python describe.py --photos-dir data/photos --output data/descriptions.json

from __future__ import annotations
import argparse
import datetime
import json
import os
from pathlib import Path


# ── Environment ──────────────────────────────────────────────────────────────

def _load_dotenv() -> None:
    # Reads KEY=VALUE lines from .env and sets them as environment variables.
    # os.environ.setdefault means we never overwrite a variable already set in
    # the shell — the shell always wins over the file.
    env = Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()  # runs once at import time, before anything else


# ── Cache helpers ─────────────────────────────────────────────────────────────

def load_cache(path: Path) -> list[dict]:
    # Returns the existing list of description entries, or an empty list if the
    # file doesn't exist yet (first run).
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def save_cache(path: Path, entries: list[dict]) -> None:
    # Writes the full list back to disk as pretty-printed JSON.
    # Called after every photo so a crash mid-run doesn't lose work.
    path.write_text(json.dumps(entries, indent=2, ensure_ascii=False), encoding="utf-8")


def needs_description(filename: str, cache: list[dict], force: bool) -> bool:
    # Returns True if we should describe this photo.
    # With --force we always re-describe; otherwise skip photos already in cache.
    if force:
        return True
    return not any(e["filename"] == filename for e in cache)


# ── Model helpers ─────────────────────────────────────────────────────────────

def describe_image(image_path: Path, vision_prompt: str, model, processor, config) -> str:
    # Runs Qwen2.5-VL-3B on one image and returns the description as a plain string.
    # apply_chat_template formats the prompt the way Qwen expects (with image tokens).
    # generate runs the model via MLX (Apple Metal) and returns a GenerationResult.
    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template

    prompt = apply_chat_template(processor, config, prompt=vision_prompt, num_images=1)
    result = generate(model, processor, image=str(image_path), prompt=prompt,
                      max_tokens=512, verbose=False)
    # result is a GenerationResult object; .text is the string the model produced
    return result.text.strip()


# Models live in ispy-eval/models/qwen-2.5-vl-3b/.
# Run download_models.py once to fetch them. After that, no internet needed.
_QWEN_MODEL_DIR = Path(__file__).parent / "models" / "qwen-2.5-vl-3b"

def load_vision_model():
    # Loads Qwen2.5-VL-3B from the local models/ directory.
    # Raises a clear error if you haven't run download_models.py yet.
    if not _QWEN_MODEL_DIR.exists():
        raise FileNotFoundError(
            f"Model not found at {_QWEN_MODEL_DIR}\n"
            "Run: python download_models.py"
        )
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    print(f"Loading {_QWEN_MODEL_DIR.name} …")
    model, processor = load(str(_QWEN_MODEL_DIR))
    config = load_config(str(_QWEN_MODEL_DIR))
    print("Vision model ready.")
    return model, processor, config


# ── CLI entry point ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Describe photos with Qwen2.5-VL-3B")
    parser.add_argument("--photos-dir", default="data/photos")
    # expects a json object in the json, at least a []
    parser.add_argument("--output", default="data/descriptions.json")
    parser.add_argument("--force", action="store_true", help="Re-describe all photos")
    args = parser.parse_args()

    import prompts as p  # loaded here so the module-level cache isn't polluted

    photos_dir = Path(args.photos_dir)
    output_path = Path(args.output)
    cache = load_cache(output_path)

    # Collect all supported image files, sorted for deterministic order
    photos = sorted(
        f for f in photos_dir.iterdir()
        if f.suffix.lower() in (".jpg", ".jpeg", ".png", ".heic", ".webp")
    )

    # Filter to only photos that aren't in the cache yet (or all if --force)
    pending = [ph for ph in photos if needs_description(ph.name, cache, args.force)]

    if not pending:
        print(f"All {len(photos)} photos already described. Use --force to regenerate.")
    else:
        model, processor, config = load_vision_model()

        # When forcing, strip old entries for the photos we're about to redo
        if args.force:
            cache = [e for e in cache if not any(ph.name == e["filename"] for ph in pending)]

        for i, photo in enumerate(pending):
            print(f"[{i+1}/{len(pending)}] {photo.name}")
            desc = describe_image(photo, p.VISION_PROMPT, model, processor, config)

            # Each entry records the filename, description, timestamp, and which
            # version of the vision prompt produced it — useful for future A/B comparisons
            cache.append({
                "id": f"photo_{len(cache)+1:03d}",
                "filename": photo.name,
                "description": desc,
                "described_at": datetime.datetime.utcnow().isoformat() + "Z",
                "vision_prompt_version": p.PROMPT_VERSION,
            })
            save_cache(output_path, cache)  # save after each photo in case of crash

        print(f"\nDescribed {len(pending)} photos → {output_path}")
