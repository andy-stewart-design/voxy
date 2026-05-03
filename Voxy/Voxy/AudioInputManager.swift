import AVFoundation
import CoreAudio
import Combine

/// Manages audio input routing and readiness on macOS, with correct handling
/// of Bluetooth HFP/A2DP mode transitions.
///
/// macOS does not have AVAudioSession. Routing is observed via:
///   - AVCaptureDevice connect/disconnect notifications
///   - Core Audio default input device changes (AudioObjectAddPropertyListenerBlock)
///   - Targeted polling during Bluetooth mode negotiation (no system notification
///     exists for the A2DP → HFP switch; polling is the correct approach here)
@MainActor
final class AudioInputManager: ObservableObject {

    // MARK: - Types

    enum InputReadiness: Equatable {
        /// No input device found, or microphone permission not yet granted.
        case unknown
        /// Bluetooth headset connected but still negotiating HFP (mic) mode.
        case waitingForBluetooth
        /// Input is active and ready to record.
        case ready
        /// Microphone access denied by the user.
        case permissionDenied
    }

    // MARK: - Published State

    @Published private(set) var readiness: InputReadiness = .unknown
    @Published private(set) var currentDeviceName: String?

    var isInputReady: Bool { readiness == .ready }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var bluetoothPollingTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        observeDeviceConnectivity()
        observeDefaultInputDevice()
        evaluateInput()
    }

    // MARK: - Public API

    /// Races readiness observation against `timeout`.
    ///
    /// Returns `true` if input becomes ready before the timeout.
    /// Returns `false` on timeout, permission denial, or Task cancellation.
    func waitUntilReady(timeout: TimeInterval = 2.0) async -> Bool {
        if readiness == .ready { return true }
        if Task.isCancelled { return false }

        // Captured while on MainActor — safe to pass into child tasks.
        let readinessStream = $readiness.values

        return await withTaskGroup(of: Bool.self) { group in

            // Leg 1: observe readiness reactively.
            group.addTask {
                for await state in readinessStream {
                    if state == .ready { return true }
                    if state == .permissionDenied { return false }
                }
                return false
            }

            // Leg 2: timeout. try? absorbs CancellationError when the group
            // cancels this task after the other leg resolves first.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - Observation

    private func observeDeviceConnectivity() {
        // Covers physical connect/disconnect of audio devices.
        NotificationCenter.default
            .publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: NotificationCenter.default
                .publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .sink { [weak self] _ in self?.scheduleEvaluation() }
            .store(in: &cancellables)
    }

    private func observeDefaultInputDevice() {
        // Covers the user changing their default input in System Settings,
        // and some (but not all) Bluetooth mode transitions.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.scheduleEvaluation()
        }
    }

    private func scheduleEvaluation() {
        debounceTask?.cancel()
        debounceTask = Task {
            // 300ms debounce — rapid notifications fire during device transitions.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            evaluateInput()
        }
    }

    // MARK: - Evaluation

    /// Call after a permission change (grant or denial) to force re-evaluation.
    func refresh() {
        evaluateInput()
    }

    private func evaluateInput() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Dialog hasn't been shown yet — not denied, just unknown.
            readiness = .unknown
            return
        default:
            readiness = .permissionDenied
            stopBluetoothPolling()
            return
        }

        let deviceID = defaultInputDeviceID()

        guard deviceID != kAudioObjectUnknown else {
            readiness = .unknown
            currentDeviceName = nil
            stopBluetoothPolling()
            return
        }

        currentDeviceName = deviceName(for: deviceID)

        let transport = transportType(for: deviceID)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth ||
                          transport == kAudioDeviceTransportTypeBluetoothLE

        if isBluetooth {
            // A Bluetooth device only exposes input streams when in HFP mode.
            // No input streams means it's still in A2DP (stereo output, no mic).
            if hasInputStreams(deviceID: deviceID) {
                readiness = .ready
                stopBluetoothPolling()
            } else {
                readiness = .waitingForBluetooth
                startBluetoothPolling()
            }
        } else {
            readiness = .ready
            stopBluetoothPolling()
        }
    }

    // MARK: - Bluetooth Mode Polling
    //
    // macOS fires no system notification when a Bluetooth device switches from
    // A2DP to HFP mode. Targeted polling (500ms interval) runs only while
    // waiting for this transition, then stops automatically.

    private func startBluetoothPolling() {
        guard bluetoothPollingTask?.isCancelled != false else { return }
        bluetoothPollingTask = Task {
            while !Task.isCancelled && readiness == .waitingForBluetooth {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard !Task.isCancelled else { break }
                evaluateInput()
            }
        }
    }

    private func stopBluetoothPolling() {
        bluetoothPollingTask?.cancel()
        bluetoothPollingTask = nil
    }

    // MARK: - Permission (removed — logic moved inline to evaluateInput)

    // MARK: - Core Audio Helpers

    private func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        return status == noErr ? nameRef?.takeRetainedValue() as String? : nil
    }
}
