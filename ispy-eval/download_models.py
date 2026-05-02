# ispy-eval/download_models.py
# One-time setup: downloads both models into ispy-eval/models/.
# After this runs, describe.py and dream.py work entirely offline.
#
# Run once: python download_models.py
# (~7GB total download, stored in ispy-eval/models/)

import os
from pathlib import Path
from huggingface_hub import snapshot_download


def _load_dotenv() -> None:
    # Load HF_TOKEN from .env so the download is authenticated (faster rate limits)
    env = Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()

MODELS_DIR = Path(__file__).parent / "models"

# Where each model ends up locally
GEMMA_DIR = MODELS_DIR / "gemma-4-e2b-it"
QWEN_DIR  = MODELS_DIR / "qwen-2.5-vl-3b"


def download_gemma() -> None:
    # Downloads mlx-community/gemma-4-e2b-it-OptiQ-4bit — the pre-converted MLX
    # 4-bit quantized version. google/gemma-4-E2B-it is a VLM and can't be loaded
    # by mlx_lm; this mlx-community build is the text-only MLX conversion.
    # Check for the actual weights file, not just config/metadata files.
    if (GEMMA_DIR / "model.safetensors").exists():
        print(f"✓ Gemma already at {GEMMA_DIR}")
        return
    print("Downloading mlx-community/gemma-4-e2b-it-OptiQ-4bit (~2GB) …")
    GEMMA_DIR.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id="mlx-community/gemma-4-e2b-it-OptiQ-4bit", local_dir=str(GEMMA_DIR))
    print(f"✓ Gemma saved to {GEMMA_DIR}")


def download_qwen() -> None:
    # Downloads Qwen2.5-VL-3B-Instruct weights from HuggingFace.
    if (QWEN_DIR / "model.safetensors").exists():
        print(f"✓ Qwen already at {QWEN_DIR}")
        return
    print("Downloading Qwen/Qwen2.5-VL-3B-Instruct (~3.5GB) …")
    QWEN_DIR.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id="Qwen/Qwen2.5-VL-3B-Instruct", local_dir=str(QWEN_DIR))
    print(f"✓ Qwen saved to {QWEN_DIR}")


if __name__ == "__main__":
    MODELS_DIR.mkdir(exist_ok=True)
    download_gemma()
    download_qwen()
    print("\nAll models ready. describe.py and dream.py will load from models/.")
