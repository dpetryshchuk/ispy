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
GEMMA_DIR = MODELS_DIR / "gemma-4-E2B-it"
QWEN_DIR  = MODELS_DIR / "qwen-2.5-vl-3b"


def download_gemma() -> None:
    # Downloads the MLX-quantised Gemma 4 E2B weights directly from HuggingFace.
    # snapshot_download fetches all files and stores them in GEMMA_DIR.
    if GEMMA_DIR.exists() and any(GEMMA_DIR.iterdir()):
        print(f"✓ Gemma already at {GEMMA_DIR}")
        return
    print("Downloading google/gemma-4-E2B-it (~3.5GB) …")
    GEMMA_DIR.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id="google/gemma-4-E2B-it", local_dir=str(GEMMA_DIR))
    print(f"✓ Gemma saved to {GEMMA_DIR}")


def download_qwen() -> None:
    # Downloads Qwen2.5-VL-3B-Instruct weights from HuggingFace.
    if QWEN_DIR.exists() and any(QWEN_DIR.iterdir()):
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
    print("\nAll models ready. describe.py and dream.py will now load from models/.")
