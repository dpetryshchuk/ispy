# ispy Ideas

## Apple Developer Account ($99/year)
Get a paid Apple Developer account and add the `com.apple.developer.kernel.increased-memory-limit` entitlement. This raises the process memory ceiling to ~15GB, which would let E2B + vision encoder coexist in memory and unblock the current vision `bad_alloc` crash with the existing MediaPipe architecture.

## Two-Stage Model Architecture ("Dream Mode")
Instead of keeping the 2GB E2B model resident all the time, run a small vision-only model (e.g. FastVLM 0.5B, moondream 0.5B, or Apple Vision framework) for real-time capture. When ispy needs deeper reasoning — writing to the wiki, making connections, agent tool calling — it loads E2B as a "dream" stage, runs the heavy inference, then releases the model. The vision model stays lightweight and always-on; E2B is a deliberate, async background process the user understands as "ispy thinking."

For now, a "Dream" button in CaptureView kicks off the dream stage manually: loads E2B, runs deeper analysis on the current photo/description, unloads E2B. Later this can be triggered automatically (e.g. after saving, on a schedule, or when connected to power).
