# ispy

a local AI creature that lives on your iPhone. it witnesses your life through periodic photo captures, builds its own memory as a self-organized wiki, and answers questions about what it's seen — all on-device. no cloud, no api costs, just gemma 4 running on your phone.

---

## how it works

1. **capture** — take a photo. gemma 4 generates raw observations from the image. optionally add voice or text context.
2. **dream** — runs nightly in the background (when plugged in). three phases:
   - *memory*: processes each capture, writes and links wiki pages
   - *reflection*: reads the wiki, finds patterns, updates ispy's state of mind
   - *consolidation*: merges duplicates, abstracts concepts, weaves missing links
3. **chat** — ask ispy what it's seen. it searches its wiki and synthesizes an answer.

ispy decides its own folder structure under `memory/` — no schema imposed. the wiki is plain markdown with `[[bidirectional links]]`.

---

## stack

- swift 5.9+, swiftui, ios 16+
- gemma 4 e4b — on-device via litert lm (mediapipe), ~4gb
- lfm 2.5-vl — fastvlm vision model via mlx (apple)
- cocoapods + swift package manager
- no backend

---

## setup

mac + xcode 16+ required for ios deployment.

### 1. clone and install dependencies

```bash
git clone https://github.com/dpetryshchuk/ispy.git
cd ispy/ispy
pod install
```

### 2. download the model

download `gemma4-e4b-it-int4.task` (~4gb) from:
https://www.kaggle.com/models/google/gemma

place it in the app's documents directory after first launch:
- connect iphone via usb → xcode → window → devices and simulators
- select your iphone → ispy → download container
- drop the model file into `appdata/documents/`

### 3. run

- open `ispy/ispy.xcworkspace` in xcode
- select your iphone as the build target
- enable developer mode: settings → privacy & security → developer mode
- build and run (⌘r)

---

## project structure

```
ispy/ispy/
├── GemmaVisionService.swift    # primary vision model (gemma 4 via litert lm)
├── LFMVisionService.swift      # fastvlm vision model (lfm 2.5-vl via mlx)
├── DreamAgent.swift            # 3-phase dream loop: memory → reflection → consolidation
├── DreamService.swift          # dream lifecycle + background task scheduling
├── ChatService.swift           # query agent: wiki search + answer synthesis
├── MemoryStore.swift           # captured photos + metadata persistence
├── WikiStore.swift             # markdown wiki: read, write, link, search
├── ToolCallParser.swift        # gemma function-call output parser
├── PromptConfig.swift          # centralized, runtime-editable prompt library
├── DreamLog.swift              # structured dream session logging
├── CaptureView.swift           # camera + batch photo import
├── ChatView.swift              # chat with ispy
├── MemoryView.swift            # chronological capture feed
├── MindView.swift              # force-directed wiki graph
├── IspyView.swift              # creature evolution tracker
└── RootView.swift              # tab bar + service initialization

ispy-eval/                      # python research framework (mac only)
├── describe.py                 # vision pass: photos → cached descriptions
├── dream.py                    # full dream cycle on desktop
├── autoresearch.py             # autonomous prompt optimization loop
├── score.py                    # dream output quality scoring
└── sync_prompts.py             # sync optimized prompts back to ios app
```

---

## eval framework

`ispy-eval/` is a python environment for developing and optimizing ispy's prompts without deploying to a device.

- `describe.py` runs the vision pass (qwen2.5-vl-3b) on a folder of photos and caches the descriptions
- `dream.py` runs the full dream cycle on those cached descriptions using mlx + gemma
- `autoresearch.py` runs dream → scores the wiki output → proposes prompt changes via claude api → keeps improvements autonomously

```bash
cd ispy-eval
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # add ANTHROPIC_API_KEY for autoresearch
python describe.py
python dream.py
```

---

## continuing development with claude code

this project was built using the [superpowers plugin](https://github.com/obra/superpowers) for claude code. install it once globally and every claude code session gets structured tdd, brainstorming, planning, and debugging workflows automatically.

```bash
claude plugin install superpowers@claude-plugins-official --global
```

or via the marketplace: open claude code → `/plugin install superpowers`

---

## docs

- [design spec](docs/superpowers/specs/2026-04-14-ispy-design.md)
- [implementation plan](docs/superpowers/plans/2026-04-14-ispy-poc.md)
