# Voxy — Full Product Plan

## Context

Voxy is a macOS menu bar app for local, private speech-to-text transcription using WhisperKit (on-device Whisper models). The goal is fast, keyboard-driven dictation that stays out of the way. Three usage scenarios drive the product, implemented in phases of increasing complexity.

The app currently has a working foundation: a menu bar extra, a settings window, `AudioInputManager` for Bluetooth-aware input routing, AVAudioEngine for recording to a .caf file, and AVAudioPlayer for playback verification.

---

## Phase Overview

| Phase | Scenario | Core addition | New permissions |
|---|---|---|---|
| **1** | Review window | WhisperKit batch transcription, editable transcript, copy | None |
| **2** | Quick dictation overlay | Global shortcut, streaming transcription, auto-paste | Input Monitoring, Accessibility |
| **3** | Hybrid promote | Spacebar escalates overlay → review window mid-recording | (inherits Phase 2) |

---

## Phase 1 — Review Window + Batch Transcription

### What it does
User opens Settings, records, stops — transcript appears automatically. They can read, edit, and copy it. Play button lets them re-listen while editing.

### Files affected
- **New**: `Voxy/Voxy/TranscriptionManager.swift`
- **Modified**: `Voxy/Voxy/VoxyApp.swift`
- **Modified**: `Voxy/Voxy/ContentView.swift`

---

### Step 0: Add WhisperKit (manual, in Xcode)
File → Add Package Dependencies → `https://github.com/argmaxinc/argmax-oss-swift`
Select the **WhisperKit** product only.

> **⚠️ Do this in Xcode**, not by editing the pbxproj manually. The project uses `PBXFileSystemSynchronizedRootGroup` which handles Swift source files automatically, but SPM dependencies still require Xcode to wire up correctly.

---

### TranscriptionManager.swift (new)

App-level `@MainActor ObservableObject` that owns the WhisperKit instance for the lifetime of the app.

**State machine:**
```
.loading(Double)  →  .ready  →  .transcribing  →  .ready
                                                ↘  .failed(String)
```

**Key design:**
- `init()` kicks off model loading immediately in a `Task` — by the time the user opens Settings and records, the model is likely already warmed up
- `loadModel()` initializes `WhisperKit` with a progress callback that updates `.loading(fraction)`
- `transcribe(audioURL: URL) async` — calls `whisperKit.transcribe(audioPath: url.path)`, joins result segments, publishes to `@Published var transcript: String?`
- `retry()` — re-runs `loadModel()` from `.failed` state

**On audio format:** WhisperKit requires 16kHz mono but automatically resamples from any input rate. The .caf files recorded at 24kHz (Bluetooth HFP) or 48kHz (built-in mic) will be handled correctly with no manual conversion.

**On model size:** Default WhisperKit model is ~150MB and downloads on first launch. It caches to the app's Caches directory — subsequent launches load from cache in seconds.

> **⚠️ Callout:** Do not create `WhisperKit` inside `ContentView` or any view. Model initialization is expensive (~2-5s + download). If it lived in `ContentView`, it would reinitialize every time the settings window is opened.

---

### VoxyApp.swift changes

```swift
@StateObject private var transcription = TranscriptionManager()
// inject into Window scene:
.environmentObject(transcription)
```

This keeps the `WhisperKit` instance alive even when the settings window is closed.

---

### ContentView.swift changes

**Recording flow update:**
`stopRecording()` removes the tap (which flushes and closes the AVAudioFile), then immediately triggers transcription:

```swift
stopRecording()                          // tap removed → file closed
if let url = recordingURL {
    await transcription.transcribe(audioURL: url)
}
```

> **⚠️ Order matters:** `transcription.transcribe()` must be called **after** `stopRecording()`, which removes the tap and closes the file. Calling it before will result in an incomplete or locked file.

**New UI states:**

| Transcription state | What shows |
|---|---|
| `.loading(fraction)` | `ProgressView(value: fraction)` + "Downloading model…" (first launch only) |
| `.ready` (no transcript yet) | Normal record/play buttons |
| `.transcribing` | Spinner + "Transcribing…", record button disabled |
| `.ready` (transcript exists) | TextEditor (editable) + Copy button + Play button |
| `.failed(message)` | Error text + Retry button |

**TextEditor binding:** Use a local `@State var editableTranscript = ""` populated via `.onChange(of: transcription.transcript)`. This lets the user edit without mutating the manager.

**Copy button:** `NSPasteboard.general.clearContents()` then `NSPasteboard.general.setString(editableTranscript, forType: .string)`.

**Window size:** Expand to `minWidth: 500, minHeight: 420` to accommodate the text editor.

### Acceptance criteria
- [ ] First launch: model download progress visible, app remains usable
- [ ] Record + stop → transcript appears automatically without user action
- [ ] Transcript is editable in the text field before copying
- [ ] Copy button puts edited text on clipboard
- [ ] Play button still works while reading/editing transcript
- [ ] Close and reopen settings window → model is still loaded, no re-download
- [ ] Works correctly with both built-in mic (48kHz) and Bluetooth HFP (24kHz)
- [ ] `.failed` state shows a Retry button that works

---

## Phase 2 — Quick Dictation Overlay + Streaming

### What it does
A global keyboard shortcut (e.g. `⌘⇧V`) triggers recording from anywhere on the system. A minimal floating overlay appears showing a live waveform and elapsed time. When the user presses the shortcut again (or a dedicated stop key), transcription completes and the text is pasted directly into the text field that was focused before the shortcut fired.

### New permissions required

**Input Monitoring** — required for `NSEvent.addGlobalMonitorForEvents`. macOS will prompt the user on first use; the app must handle the case where it's denied gracefully.

**Accessibility** — required for two things:
1. Reading `AXFocusedUIElement` to capture which text field was active
2. Simulating `Cmd+V` via `CGEvent` to paste into another app

> **⚠️ Critical sequence:** When the global shortcut fires, the frontmost app is still the *other* app. You must capture `AXFocusedApplication` and `AXFocusedUIElement` **before** calling `openWindow` or activating Voxy — the moment Voxy takes focus, those references become invalid.

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
Each new permission (Input Monitoring, Accessibility) needs a first-run prompt explaining *why* it's needed, with a button to open System Settings to the right pane. Never ask for permissions until the user first tries to use the feature that requires them.

**`RecordingSession` state machine (Phase 2+)**
Once extracted from ContentView, this becomes the single source of truth. Ensure it handles interruptions gracefully: incoming calls, system audio interruptions, Bluetooth disconnects mid-recording. `AudioInputManager` already observes device changes — `RecordingSession` should listen for `.failed` readiness and abort cleanly.

**Memory and model lifecycle**
WhisperKit holds the model weights in memory (~150–500MB depending on model). For a menu bar app that runs continuously, this is a permanent cost. If memory pressure becomes an issue, implement a timeout that unloads the model after N minutes of inactivity and reloads on next use.

**Model configurability (Phase 1 follow-on)**
Exposing model choice (tiny/base/small/large) in Settings is a natural addition. `tiny.en` is fastest (~39MB), `large-v3` is most accurate (~1.5GB). The right default for most users is probably `base.en`.

**Temp file cleanup**
Recording creates a `.caf` file in `FileManager.default.temporaryDirectory`. These accumulate if not cleaned up. Add cleanup on app launch (delete any .caf files older than 24h) and on each new recording start.
