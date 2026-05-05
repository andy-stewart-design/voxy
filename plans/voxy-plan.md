# Voxy — Full Product Plan

## Context

Voxy is a macOS menu bar app for local, private speech-to-text transcription using WhisperKit (on-device Whisper models). The goal is fast, keyboard-driven dictation that stays out of the way. Three usage scenarios drive the product, implemented in phases of increasing complexity.

The app currently has a working foundation: a menu bar extra, a settings window, `AudioInputManager` for Bluetooth-aware input routing, AVAudioEngine for recording to a .caf file, and AVAudioPlayer for playback verification.

---

## Phase Overview

| Phase | Scenario                | Core addition                                             | New permissions                 |
| ----- | ----------------------- | --------------------------------------------------------- | ------------------------------- |
| **1** | Review window           | WhisperKit batch transcription, editable transcript, copy | None                            |
| **2** | Quick dictation overlay | Global shortcut, streaming transcription, auto-paste      | Input Monitoring, Accessibility |
| **3** | Hybrid promote          | Spacebar escalates overlay → review window mid-recording  | (inherits Phase 2)              |

---

## Phase 1 — Review Window + Batch Transcription

**Goal:** Record → see transcript → copy. Built in 5 independently verifiable steps.

---

### ~~1a — WhisperKit wired up, transcript appears after recording~~ ✅ DONE

**What was built:**

- WhisperKit added via Xcode SPM (File → Add Package Dependencies → `https://github.com/argmaxinc/argmax-oss-swift`, WhisperKit product only)
- `TranscriptionManager.swift`: app-level `@MainActor ObservableObject`, loads `small.en` on init
- `VoxyApp.swift`: `@StateObject private var transcription = TranscriptionManager()` + `.environmentObject(transcription)` on the Window scene
- `ContentView.swift`: calls `transcription.transcribe(audioURL:)` after `stopRecording()`, displays result in a plain `Text` view

**Key learnings / gotchas:**
- App sandbox requires `com.apple.security.network.client` entitlement — add via Signing & Capabilities or `Voxy.entitlements`
- `State.loading(Double)` was replaced with `State.loading(String)` — WhisperKit's progress callback can't be set before `init()` completes, so a determinate progress bar isn't possible without a custom download step. Indeterminate spinner + status text is the correct UX.
- Model cache path: `~/Library/Containers/art.andystew.Voxy/Data/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/`
- To reset for testing: `rm -rf ~/Library/Containers/art.andystew.Voxy/Data/Documents/huggingface`
- `import Combine` is required in `TranscriptionManager.swift` for `@Published` to compile

---

### 1b — Transcript accumulation + ⌘↩ to copy and close

**What changes:**

- `ContentView.swift`: replace single `Text` with `@State var accumulatedTranscript = ""`; append each new result as a new paragraph
- Each recording appends; transcript is editable in a `TextEditor` at any time
- ⌘↩ copies `accumulatedTranscript` to `NSPasteboard` and closes the window (disabled when transcript is empty)
- Opening the window always starts a fresh session (clear on `.onAppear`)

```swift
stopRecording()
if let url = recordingURL,
   let result = await transcription.transcribe(audioURL: url) {
    accumulatedTranscript += accumulatedTranscript.isEmpty ? result : "\n\n" + result
}
```

**Acceptance criteria:**

- [ ] Recording again appends a new paragraph to existing transcript
- [ ] Transcript is editable between recordings
- [ ] ⌘↩ copies full accumulated text to clipboard and closes the window
- [ ] ⌘↩ is disabled when transcript is empty
- [ ] Reopening the window shows an empty transcript (fresh session)

---

### 1c — Model switcher in menu bar

**What changes:**

- `TranscriptionManager.swift`: add `@Published var selectedModel: String` (persisted in `UserDefaults`, default `small.en`); add `switchModel(to:)` which tears down WhisperKit and reinitializes with the new model
- `VoxyApp.swift` / `MenuView`: add a `Model` submenu; tapping a model calls `transcription.switchModel(to:)` and shows a checkmark on the active selection; items disabled during `.loading`, `.transcribing`, and while recording

```
Model ▶   tiny.en
          base.en
          small.en  ✓
          medium.en
─────────────
Quit Voxy
```

**Model reference:**

| Model       | Size   | Notes                         |
| ----------- | ------ | ----------------------------- |
| `tiny.en`   | ~39MB  | Fastest, lowest accuracy      |
| `base.en`   | ~74MB  | Good balance                  |
| `small.en`  | ~244MB | Better accuracy — **default** |
| `medium.en` | ~769MB | Best accuracy, slower         |

**Acceptance criteria:**

- [ ] Switching model triggers a load (download if not cached, fast if cached)
- [ ] Checkmark reflects active model
- [ ] Model submenu items are disabled during loading/transcribing/recording
- [ ] Selected model persists across app restarts

---

### 1d — Waveform in bottom bar

**Layout (from mockup):**

The bottom of the window is a single dark bar containing two things:

- **Left**: compact mini-waveform — ~8–12 thin vertical capsule bars, small and tight, white on dark
- **Right**: shortcut hint text — `Record  ⌘→ + ⌥  |  Copy Transcription  ⌘ + Enter`

The transcript `TextEditor` fills the entire main body above this bar. There is no separate waveform section.

```
┌─────────────────────────────────────────────┐
│                                             │
│   [transcript text / placeholder]           │
│                                             │
├─────────────────────────────────────────────┤
│ |||||||   Record ⌘→+⌥  |  Copy  ⌘↩         │
└─────────────────────────────────────────────┘
```

**What changes:**

- `ContentView.swift`: add `@State var amplitudeSamples: [Float]` (ring buffer, ~12 values)
- In the AVAudioEngine tap callback: compute RMS, dispatch to MainActor to append to ring buffer
- Mini waveform view: ~12 thin `Capsule` bars, compact width (~60pt total), heights proportional to amplitude
- Waveform shows only while recording; replaced with nothing (or a static mic icon) when idle

> **⚠️ Threading.** The tap runs on the audio thread. Never write to `@State` directly. Use `Task { @MainActor in amplitudeSamples.append(rms) }`.

**Acceptance criteria:**

- [ ] Bars animate in real time while speaking, visible in the bottom-left corner
- [ ] Bar heights visibly respond to volume changes
- [ ] Waveform disappears (or becomes static) when not recording
- [ ] No audio glitches or threading warnings introduced

---

### 1e — Raycast-style UI polish

**What changes (based on mockup):**

- Dark near-black background, large rounded corners, standard macOS traffic lights (close/minimize/maximize) — the window IS a normal window, just dark-styled
- Main body: `TextEditor` fills the space with no chrome; placeholder text when empty
- Bottom bar: fixed-height strip, slightly lighter than the background, containing the mini waveform (left) and shortcut hints (right) — plain text style, not pill badges
- Window size: `minWidth: 560, minHeight: 440`
- Transcribing state: subtle inline spinner or progress indicator; record action disabled

**Full UI state table:**

| State                       | Bottom-left                            | Bottom-right                              |
| --------------------------- | -------------------------------------- | ----------------------------------------- |
| `.loading(fraction)`        | Progress bar + "Downloading small.en…" | —                                         |
| `.ready`, no transcript     | — (or static mic icon)                 | `Record  ⌘→ + ⌥`                          |
| Recording                   | Animated mini waveform                 | `Record  ⌘→ + ⌥`                          |
| `.transcribing`             | Spinner                                | — (record disabled)                       |
| `.ready`, transcript exists | —                                      | `Record ⌘→+⌥  \|  Copy Transcription  ⌘↩` |
| `.failed(message)`          | Error text                             | Retry button                              |

**Acceptance criteria:**

- [ ] Window matches the mockup: dark, rounded, traffic lights, transcript fills the body
- [ ] Bottom bar is a single strip with waveform left, hints right
- [ ] No layout shift when waveform appears/disappears
- [ ] Placeholder text visible when transcript is empty and not recording

---

## Phase 2 — Quick Dictation Overlay + Streaming

### What it does

A global keyboard shortcut (e.g. `⌘⇧V`) triggers recording from anywhere on the system. A minimal floating overlay appears showing a live waveform and elapsed time. When the user presses the shortcut again (or a dedicated stop key), transcription completes and the text is pasted directly into the text field that was focused before the shortcut fired.

### New permissions required

**Input Monitoring** — required for `NSEvent.addGlobalMonitorForEvents`. macOS will prompt the user on first use; the app must handle the case where it's denied gracefully.

**Accessibility** — required for two things:

1. Reading `AXFocusedUIElement` to capture which text field was active
2. Simulating `Cmd+V` via `CGEvent` to paste into another app

> **⚠️ Critical sequence:** When the global shortcut fires, the frontmost app is still the _other_ app. You must capture `AXFocusedApplication` and `AXFocusedUIElement` **before** calling `openWindow` or activating Voxy — the moment Voxy takes focus, those references become invalid.

### Architecture changes

**Extract recording state from ContentView → new `RecordingSession` (app-level `@MainActor ObservableObject`)**

Phase 2 requires the overlay and the review window to share recording state. ContentView currently owns `engine`, `isRecording`, `recordingURL`, etc. These need to move to an app-level model.

`RecordingSession` owns:

- `AVAudioEngine`
- Recording state machine: `idle → waitingForInput → recording → transcribing → ready`
- `recordingURL: URL?`
- `transcript: String?` (from `TranscriptionManager`)
- Reference to `AudioInputManager` (or inject it)
- `focusedApp: NSRunningApplication?` — captured at shortcut time
- `focusedElement: AXUIElement?` — captured at shortcut time

ContentView and the new OverlayView both read from `RecordingSession` via `.environmentObject`.

---

### New: Overlay Window

A floating `NSPanel` (not a regular `NSWindow`) that:

- Appears centered on screen or near the cursor
- Has no title bar, rounded corners, vibrancy background
- Is not activating (`.nonactivatingPanel`) — doesn't steal focus from the source app
- Shows: live waveform + elapsed time counter + shortcut hint to stop

In SwiftUI terms, add a second `Window` scene in `VoxyApp` with `.windowStyle(.plain)` and present it via `openWindow(id: "overlay")`.

**Waveform visualization:**

- The `AVAudioEngine` tap callback captures RMS amplitude from each buffer
- Feed amplitude values to a `@Published var amplitudeSamples: [Float]` on `RecordingSession` (ring buffer, ~50 values)
- Render with SwiftUI `Canvas` or `TimelineView` — a scrolling bar or wave shape

> **⚠️ Threading:** The tap callback runs on the audio thread. Do not write to `@Published` properties directly from the tap. Dispatch to MainActor: `Task { @MainActor in self.amplitudeSamples.append(rms) }`.

---

### Streaming transcription

Replace the post-recording batch call with WhisperKit's streaming API (`AudioStreamTranscriber`) for the overlay flow. The review window (Phase 1) keeps batch — streaming's incremental updates would be distracting in an edit context.

**Streaming produces two output streams:**

- **Hypothesis text** (~0.45s latency per word) — shown live in the overlay as the user speaks
- **Confirmed text** (~1.7s latency) — the stable final result

Show hypothesis text dimmed/italic in the overlay, confirmed text at full opacity.

> **⚠️ Sample rate:** `AudioStreamTranscriber` likely expects 16kHz audio fed directly. If feeding raw buffers from the tap (which may be 24kHz or 48kHz), use `AudioProcessor.resampleAudio(fromBuffer:toSampleRate:)` before passing to the transcriber. Validate this against the WhisperKit source when implementing.

---

### Auto-paste flow

```
shortcut fires
  → capture AXFocusedApplication + AXFocusedUIElement
  → start recording (overlay appears)
shortcut fires again (or dedicated stop key)
  → stop recording
  → streaming transcription finalizes
  → write transcript to NSPasteboard
  → reactivate stored app: storedApp.activate(ignoringOtherApps: true)
  → post CGEvent Cmd+V keypress
  → overlay dismisses
```

If Accessibility permission is denied, fall back to: write to clipboard + show a brief "Copied — paste with ⌘V" notification in the overlay before it dismisses.

> **⚠️ Shortcut choice:** The shortcut must be one that (a) doesn't conflict with common app shortcuts and (b) the user can customize. Consider making it user-configurable in Settings from the start rather than hardcoding. `⌘⇧V` is a reasonable default.

### Acceptance criteria

- [ ] Shortcut triggers recording from any app without switching focus
- [ ] Overlay appears with live waveform and elapsed time counter
- [ ] Streaming hypothesis text is visible in the overlay while speaking
- [ ] Second shortcut press (or designated stop key) stops recording and pastes
- [ ] Text pastes into the correct field without the user doing anything
- [ ] If Accessibility denied: clipboard fallback with user-visible message
- [ ] If Input Monitoring denied: graceful error, prompt to enable in System Settings
- [ ] Overlay dismisses cleanly after paste

---

## Phase 3 — Hybrid Promote

### What it does

While the overlay is active (recording in progress), the user presses `Space` to "promote" to the full review window. Recording continues. The review window opens, inherits the focused element reference so Cmd+Enter can still paste back to the original field.

### Key behaviors

- `Space` during overlay recording → open review window, overlay stays visible (or fades) until recording stops
- If recording is still active when promoted: review window shows streaming hypothesis text live
- When recording stops: batch or streaming finalizes, transcript appears in the editable text field
- `Cmd+Enter` in the review window → pastes to the original focused element (same auto-paste flow as Phase 2)
- `Copy` button still available as fallback

### Architecture notes

Because `RecordingSession` is app-level by Phase 2, both the overlay and the review window already share the same recording state and `focusedElement` reference. "Promote" is mostly a UI event:

1. Open the review window (`openWindow(id: "settings")`)
2. Optionally dismiss or fade the overlay
3. The review window reads `RecordingSession` state and shows transcript as it arrives

The review window needs one new thing: a `Cmd+Enter` handler that triggers the same auto-paste logic from Phase 2.

> **⚠️ Edge case:** If the user promotes and then the review window loses focus (they click away), the `focusedElement` reference should still be held by `RecordingSession` — do not clear it when the review window loses focus.

> **⚠️ Edge case:** If the user promotes but then closes the review window without pasting, decide what happens: dismiss silently? Offer a "paste now" notification? Plan for this UX explicitly.

### Acceptance criteria

- [ ] Space during overlay recording opens review window without interrupting recording
- [ ] Live streaming text appears in review window while still recording
- [ ] Stop recording from either overlay or review window
- [ ] Cmd+Enter in review window pastes to original focused field
- [ ] Copy button still works as fallback
- [ ] Closing review window without pasting is handled gracefully

---

## Cross-cutting concerns (all phases)

**Onboarding for new permissions (Phase 2+)**
Each new permission (Input Monitoring, Accessibility) needs a first-run prompt explaining _why_ it's needed, with a button to open System Settings to the right pane. Never ask for permissions until the user first tries to use the feature that requires them.

**`RecordingSession` state machine (Phase 2+)**
Once extracted from ContentView, this becomes the single source of truth. Ensure it handles interruptions gracefully: incoming calls, system audio interruptions, Bluetooth disconnects mid-recording. `AudioInputManager` already observes device changes — `RecordingSession` should listen for `.failed` readiness and abort cleanly.

**Memory and model lifecycle**
WhisperKit holds the model weights in memory (~150–500MB depending on model). For a menu bar app that runs continuously, this is a permanent cost. If memory pressure becomes an issue, implement a timeout that unloads the model after N minutes of inactivity and reloads on next use.

**Temp file cleanup**
Recording creates a `.caf` file in `FileManager.default.temporaryDirectory`. These accumulate if not cleaned up. Add cleanup on app launch (delete any .caf files older than 24h) and on each new recording start.
