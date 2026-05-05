# ispy — Design Spec
**Date:** 2026-04-14  
**Status:** Approved for implementation planning

---

## What ispy is

ispy is a local AI creature that lives inside your phone. Its entire world is the photos you feed it and the files it has written from what it has seen. It does not experience time between photos. It processes each moment, updates its own memory, and builds a personal wiki — entirely on-device, entirely private.

You feed it. It learns. You can ask it what it knows.

Philosophical anchor: most days vanish because nothing noticed them. ispy notices. Three weeks from now you can ask it what you were doing on a random Tuesday afternoon and it actually knows.

**One-sentence pitch:** a $5 local AI creature that witnesses your life in periodic flashes and builds its own memory from what it sees.

---

## Technical stack

- **Framework:** Flutter (cross-platform, write on Windows, compile/run on Mac/iPhone)
- **AI model:** Gemma 4 E4B — on-device via `flutter_gemma`, no cloud, no API costs
- **Model capabilities used:** multimodal (image + text), native function calling (6 special tokens), structured tool use
- **Platform target:** iOS (iPhone), Android secondary
- **Storage:** local app documents directory, plain files (markdown + images)

---

## Filesystem structure

Two zones. The log is sacred. The wiki is ispy's.

```
app_documents/
├── log/                               ← append-only, never modified after write
│   ├── 2026-04-14T14-23-00Z/
│   │   ├── photo.jpg
│   │   └── entry.md                  ← ispy's memory + raw EXIF
│   └── 2026-04-14T18-45-00Z/
│       ├── photo.jpg
│       └── entry.md
│
└── wiki/                              ← ispy's brain, no rules, ispy owns this
    ├── index.md                       ← only stable file, ispy's master map
    ├── places/
    │   ├── home.md
    │   └── coffee_shops/
    │       └── the_corner_one.md
    ├── people/
    ├── plants/
    └── patterns.md
```

**log/** is the raw source layer. One folder per capture, named by UTC timestamp. Each contains the original photo and ispy's entry markdown. Never touched after written. These are ispy's raw sensory inputs.

**wiki/** is ispy's derived knowledge. ispy can create any folder structure it decides makes sense — `places/`, `people/`, `plants/`, `recurring_objects/`, whatever. The only stable file is `wiki/index.md` which ispy maintains as its master navigation map. Links between wiki files use `[[wikilink]]` syntax, which the app parses to build the graph.

---

## The agent harness

ispy is not a one-shot model call. It is an agent that navigates its own filesystem using native Gemma 4 function calling.

**The loop:**
```
Send prompt + tools to Gemma 4 E4B
    → Model outputs text OR a tool call (native special tokens)
    → If tool call: Dart executes the file operation
    → Result returned to model
    → Model continues
    → Repeat until no more tool calls
```

**Tools ispy has access to:**

| Tool | Signature | Purpose |
|---|---|---|
| `read_file` | `(path: string) → string` | Read any file |
| `write_file` | `(path: string, content: string) → void` | Create or overwrite a file |
| `list_directory` | `(path: string) → string[]` | See folder contents |
| `create_directory` | `(path: string) → void` | Make a new folder |
| `search_files` | `(query: string) → [{path, excerpt}]` | Search across file contents |
| `move_file` | `(from: string, to: string) → void` | Reorganize the wiki |

All file operations are scoped to `app_documents/`. ispy cannot access anything outside its own storage.

---

## The two-stage memory pipeline

When a photo is taken, two model calls run sequentially.

**Stage 1 — Vision extraction** (fast, no character, pure observation):

> Look at this image. List everything directly observable. Be exhaustive. Objects and their positions. Colors, textures, materials. Light — direction, quality, natural or artificial. Any text. Any people or animals. Architectural details. Weather or environment. Anything unusual. Do not interpret. Do not assume. Only report what is visible.

Output: a dense description of raw observations. Cheap call — no tool use, no character, just eyes.

**Stage 2 — ispy agent** (full agentic loop, character, tool use):

*System prompt (set once):*
> you are ispy. you live inside a phone. your whole world is the photos you are shown and the files you have written. you do not experience time between photos — you do not know how long you were not seeing. you have tools to read and write your own memory. you are curious and specific. you notice details. when you are uncertain, you say so. you write simply, without lists or formatting, just your thoughts. you are being addressed.

*Per-capture user turn:*
> here is what was observed in the photo you are being shown:
> [stage 1 output]
>
> here is the metadata:
> time: [UTC timestamp]
> local time: [human-readable]
> location: [reverse-geocoded label]
> coordinates: [lat, lon]
>
> [if user provided context]: the person who took this photo added: "[user context]"
>
> look at the photo. use your tools to check your wiki. write your memory of this moment to the log. update your wiki however you decide makes sense.

ispy then decides on its own:
- Whether to read `wiki/index.md` first
- Whether to search for related memories
- What wiki files to create or update
- How to organize new knowledge
- What the log entry should say

The uncertainty and hypothesis-forming is natural to the character: "I think I've seen this window before. Maybe three times. I'm not sure if this is the same place."

---

## Screens

Four screens, one tab bar at the bottom: **Capture · Memories · Wiki · Chat**

### Capture
The home screen. Full-bleed, dark. A single shutter button at the bottom. Notification brings you here.

After photo taken: Stage 1 vision extraction begins immediately. A minimal text field appears below with placeholder text — *"add context (optional)"* — where the user can type something like "this is the window in my home" or "frozen food section of a Jewel Osco". This is ground truth ispy cannot infer from vision alone. The user can type or dismiss. Either way, Stage 2 starts when they do — context is included if provided, skipped if not.

While the agent loop runs: *"ispy is looking."*  
When complete: *"ispy looked."*  
No spinner, no progress bar. Tap anywhere to dismiss.

### Memories
Reverse-chronological log of every entry. Thumbnail + timestamp + location label + first line of ispy's entry. Tap to read the full memory. Read-only. This is the raw log, not the wiki.

### Wiki
A force-directed graph of `wiki/`. Nodes are files. Edges are `[[wikilinks]]` parsed from file contents. Nodes scale by connection count. Spring physics. Pan and zoom. Tap a node to read the file — read-only, you are a guest in ispy's filesystem.

The graph reveals ispy's organizational decisions: clusters emerge naturally from how it chose to link things.

### Chat
Minimal text input at the bottom. ispy's responses above. ispy has full wiki access when answering. Responds in character — short, curious, no formatting, addressed as *you*.

---

## Capture trigger

Ambient notifications on a configurable interval (default: every few hours). Calm, not urgent. The notification text reflects ispy's character — e.g. *"ispy is awake."* User taps the notification, app opens to Capture screen.

---

## Consolidation (post-POC)

When the phone is charging, ispy runs a deeper consolidation pass: reads the full log since last consolidation, rewrites and expands wiki pages, creates new connections, reorganizes folders if needed. Triggered by iOS background task on charging event. Not in the POC — stubbed as a manual "consolidate" button for now.

---

## POC scope

The POC validates the core loop:

1. Camera capture with EXIF extraction (GPS, timestamp)
2. GPS reverse-geocoded to human label
3. Stage 1 vision extraction prompt → raw observations
4. Gemma 4 E4B loaded on device via flutter_gemma
5. Stage 2 agentic loop with file system tools
6. ispy writes `log/[timestamp]/entry.md` and updates `wiki/index.md`
7. Memories screen shows the log
8. Wiki screen shows basic graph of whatever ispy has built
9. Chat screen with wiki-aware ispy responses

Consolidation is a button in the POC. Notifications are a button in the POC. The goal is each technical feature working in isolation, then connected.

---

## What success looks like for the POC

You take a photo of your apartment window. ispy processes it. You open the Wiki screen and see a node appear. You open the Memories screen and see ispy's description of the window — specific, a little strange, uncertain where it should be. You ask ispy in Chat: "what have you seen today?" and it tells you about a window, and what it thinks it might mean.
