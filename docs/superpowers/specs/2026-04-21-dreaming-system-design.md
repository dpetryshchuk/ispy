# Dreaming System Design

## Overview

ispy dreams on a schedule (nightly / when plugged in) or on demand via a button. Dreaming means: loading the Gemma 4 E2B agent, processing all unprocessed captures chronologically, and using tool calls to build and maintain an Obsidian-style wiki of ispy's experiences. A second GC pass merges duplicates and strengthens links. The dream log streams all agent activity to a live UI.

---

## Filesystem

```
Documents/memory/
  raw/
    2026-04-21/
      captures.json      ← daily entries, UTC timestamps
      photos/
        <uuid>.jpg
    2026-04-20/
      captures.json
      photos/
  wiki/
    places/              ← e.g. coffee-shop.md, park-bench.md
    themes/              ← e.g. morning-light.md, solitude.md
    objects/             ← e.g. ceramic-mug.md, red-bicycle.md
    index.md             ← master list of all wiki pages
  dream.json             ← { "lastDreamed": "2026-04-21T14:30:00Z" }
  cache.json             ← [{ "page": "wiki/themes/solitude.md", "lastSeen": "2026-04-18T09:00:00Z" }]
```

**Raw captures** are grouped by date for browsability but processed by UTC timestamp cursor — `dream.json` stores a single `lastDreamed` ISO8601 timestamp. Any capture with `timestamp > lastDreamed` is unprocessed, regardless of which day folder it lives in. This handles multiple dream runs per day correctly.

**Wiki pages** are Obsidian-style markdown with `[[wikilinks]]`. ispy only creates pages for things it can actually observe: places, recurring objects, themes/moods. Named people are not created unless the user labels them (future feature).

Example wiki page:
```markdown
# Coffee Shop
Last seen: 2026-04-21T08:14:00Z

A recurring indoor space with warm lighting, small tables, and ambient noise.

## Connections
- [[Morning Light]] — frequently co-occurs
- [[Ceramic Mug]] — recurring object in this setting
- [[Solitude]] — associated mood
```

**`cache.json`** tracks which wiki pages have been recently accessed (read or written), with UTC timestamps. Used to select which old pages to surface as entropy injections.

---

## MemoryStore Refactor

`MemoryStore` currently writes to a flat `index.json`. It needs to:

- Write new captures to `raw/YYYY-MM-DD/captures.json` (create dir + file if needed)
- Save photos to `raw/YYYY-MM-DD/photos/<uuid>.jpg`
- Read all captures by scanning all `raw/*/captures.json` files

`MemoryEntry` gains no new fields — the raw capture is just timestamped description + photo path.

---

## Tool Definitions

Five tools available to the dream agent:

| Tool | Parameters | Returns |
|------|-----------|---------|
| `read_file` | `path: String` | File contents as string |
| `write_file` | `path: String, content: String` | `"ok"` or error |
| `edit_file` | `path: String, old: String, new: String` | `"ok"` or error |
| `search_wiki` | `query: String` | Matching page names + first-line snippets |
| `list_wiki` | — | Contents of `wiki/index.md` |

Tools are described in the Gemma 4 system prompt as a schema. The agent emits `<|tool_call>` tokens; the loop parses them with regex, executes the Swift function, injects the result as `<|tool_response>`, and continues. `cache.json` is updated on every `read_file` or `write_file` call.

---

## Dream Pipeline

```
Dream triggered (button or BGProcessingTask)
│
├─ 1. Collect captures: scan raw/*/captures.json, filter timestamp > lastDreamed, sort asc
├─ 2. Entropy injection: pick 1-2 wiki pages from cache.json weighted toward least-recently-seen
│      → prepend their content to the agent's context
│
├─ 3. MEMORY LOOP — for each capture:
│     ├─ Prompt = system (tools schema + instructions) + wiki index + entropy pages + capture description
│     ├─ Run Gemma 4 agent loop:
│     │     parse <|tool_call> → execute tool → inject <|tool_response> → continue
│     │     repeat until no tool call emitted (or max 20 iterations)
│     └─ Stream each tool call line to DreamLog
│
├─ 4. GC PASS — second agent loop:
│     ├─ Prompt = system (GC instructions) + full wiki index
│     ├─ Agent identifies duplicates to merge and weak links to strengthen
│     ├─ Same tool-calling loop (max 30 iterations)
│     └─ Stream to DreamLog
│
└─ 5. Write lastDreamed = now() to dream.json
```

**Entropy injection** selects pages from `cache.json` with the oldest `lastSeen` values, weighted toward pages not accessed in the longest time. This gives ispy a chance to reconnect with distant memories during each dream, making the system self-reinforcing without user-facing notifications.

**Max iterations** are a safety cap — the agent typically finishes in far fewer. If the cap is hit, the current memory is marked as a partial and the next dream picks it up.

---

## Dream Log UI

A `DreamView` tab (or sheet) showing a scrollable list of single-line log entries that stream in live:

```
[08:14:01] Dream started — 3 unprocessed captures
[08:14:02] Surfacing old memory: themes/solitude.md (unseen 4 days)
[08:14:05] → search_wiki("warm indoor lighting") → 1 match: places/coffee-shop.md
[08:14:07] → read_file("places/coffee-shop.md") → 412 chars
[08:14:09] → edit_file("places/coffee-shop.md", ...) → ok
[08:14:13] → write_file("objects/ceramic-mug.md", ...) → ok
[08:14:20] GC pass started
[08:14:23] → search_wiki("indoor warm cozy") → merging 2 pages
[08:14:28] Dream complete — 3 captures processed, 2 pages created, 1 merged
```

`DreamLog` is a `@Observable` class holding a `[DreamLogEntry]` array (timestamp + message string). Each tool execution appends a line. The log clears at the start of each new dream run.

---

## Trigger Mechanism

**Manual:** "Dream" button in `DreamView`, disabled while `dreamService.isRunning`. Available immediately for MVP.

**Scheduled:** `BGProcessingTask` registered with identifier `com.ispy.dream`. iOS fires it when the device is plugged in and idle, or on a nightly schedule. Requires `BGTaskSchedulerPermittedIdentifiers` in Info.plist and a `scheduleNextDream()` call after each run.

---

## Future Ideas (not in scope)

- **Unknown person labeling**: ispy surfaces photos of recurring unidentified faces and asks "who is this?" — user labels them, seeding a `wiki/people/` section.
- **Random memory surfacing to user**: occasional in-app banner showing a memory that hasn't been seen in a while.
- **Semantic search**: vector embeddings over wiki pages for similarity search beyond keyword matching.
