# ispy-eval/describe.py
from __future__ import annotations
import argparse
import datetime
import json
import os
from pathlib import Path


def _load_dotenv() -> None:
    env = Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()


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
