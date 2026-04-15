# ispy

a local AI creature that lives inside your phone. it witnesses your life in periodic flashes and builds its own memory from what it sees. no cloud. no api costs. just gemma 4 running on your phone.

---

## setup (mac required for iOS)

### 1. clone and scaffold

```bash
git clone https://github.com/dpetryshchuk/ispy.git
cd ispy
flutter create . --org com.ispy --platforms ios,android
flutter pub get
cd ios && pod install && cd ..
```

### 2. download the model

download `gemma4-e4b-it-int4.task` (~3-4GB) from:  
https://www.kaggle.com/models/google/gemma

then place it in the app's documents directory. easiest way after first launch:
- connect iPhone, open Xcode → Window → Devices and Simulators
- select your iPhone → ispy app → download container
- navigate to `AppData/Documents/` and drop the model file in

### 3. run

```bash
# connect iPhone via USB, trust computer on device
# enable Developer Mode: Settings → Privacy & Security → Developer Mode
flutter devices       # verify iPhone appears
flutter run           # builds and deploys
```

### 4. run tests (no mac needed)

```bash
flutter test
```

---

## project structure

```
lib/
├── core/
│   ├── filesystem/     # LogStore (append-only log) + WikiStore (wiki graph)
│   ├── vision/         # ExifExtractor (GPS + reverse geocode)
│   ├── model/          # GemmaService (flutter_gemma wrapper)
│   └── agent/          # AgentHarness (tool-calling loop) + Prompts + Tools
├── features/
│   ├── capture/        # camera + context input + two-stage pipeline
│   ├── memories/       # reverse-chrono log list
│   ├── wiki/           # force-directed graph + file detail view
│   └── chat/           # chat with ispy
└── shared/             # tab bar + app shell
```

---

## how it works

1. notification fires → open capture screen → take photo
2. stage 1: gemma 4 extracts raw visual observations from the image
3. stage 2: ispy agent runs — reads its wiki, writes a memory entry, updates its wiki
4. ispy decides its own folder structure under `wiki/` — no schema imposed
5. `log/` is append-only (one UTC-named folder per capture, photo + entry)
6. wiki screen shows a force-directed graph of ispy's self-organized knowledge
7. chat lets you ask ispy about what it has seen

---

## docs

- [design spec](docs/superpowers/specs/2026-04-14-ispy-design.md)
- [implementation plan](docs/superpowers/plans/2026-04-14-ispy-poc.md)
