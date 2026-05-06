import Combine
import Foundation
import WhisperKit

@MainActor
final class TranscriptionManager: ObservableObject {

    // MARK: - Types

    enum State: Equatable {
        case loading(String)   // associated value is the status message
        case ready
        case transcribing
        case failed(String)
    }

    // MARK: - Published

    @Published private(set) var state: State = .loading("Initializing…")

    // MARK: - Private

    private static let modelName = "small.en"
    private var whisperKit: WhisperKit?

    // MARK: - Init

    init() {
        Task { await loadModel() }
    }

    // MARK: - Public API

    func transcribe(audioURL: URL) async -> String? {
        guard case .ready = state else { return nil }
        state = .transcribing

        do {
            guard let wk = whisperKit else {
                state = .failed("Model not loaded")
                return nil
            }
            let results = try await wk.transcribe(audioPath: audioURL.path)
            state = .ready
            let text = results.compactMap(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    func retry() {
        Task { await loadModel() }
    }

    // MARK: - Private

    private func loadModel() async {
        whisperKit = nil
        let message = isCached ? "Loading model…" : "Downloading model (small.en, ~244 MB)…"
        state = .loading(message)

        // Attempt up to 2 times — first launches can fail transiently while
        // the model is being written to disk. A single automatic retry covers
        // this without surfacing a confusing error to the user.
        for attempt in 1...2 {
            do {
                whisperKit = try await WhisperKit(
                    model: Self.modelName,
                    verbose: false,
                    prewarm: true
                )
                state = .ready
                return
            } catch {
                if attempt == 2 {
                    state = .failed(error.localizedDescription)
                } else {
                    state = .loading("Retrying…")
                }
            }
        }
    }

    /// Returns true if the WhisperKit model files are already on disk.
    ///
    /// WhisperKit caches to Documents/huggingface/models/argmaxinc/whisperkit-coreml/
    /// within the app sandbox container.
    private var isCached: Bool {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return false }

        let modelDir = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(Self.modelName)")

        return FileManager.default.fileExists(atPath: modelDir.path)
    }
}
