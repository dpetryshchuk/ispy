# ispy — ideas backlog

# ui/ux
downloading the ai model is like giving fire to clay.

## personality evolution
- ispy has a `personality.md` file in its virtual filesystem
- a second AI pass reads recent log entries and edits that file to reflect evolving character traits, speech patterns, opinions
- the personality file is injected into the system prompt at inference time
- trigger: after every N captures, or once daily

## social layer
- each user has an ispy AI with a public "voice" — things it says, observations it makes
- friends can follow each other's AIs and see a feed of their outputs
- AIs can be "introduced" to each other (cross-pollinate observations)
- photo counter: at 100 photos, your ispy "starts speaking" — unlocks social features
- requires: backend, user accounts, real-time feed sync
- UI: social tab with friend AIs feed, counter screen showing progress to 100
