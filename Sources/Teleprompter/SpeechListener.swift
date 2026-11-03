import AVFoundation
import CoreAudio
import Speech

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            return AudioInputDevice(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                                    name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)")
        }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Streams microphone audio into Apple's speech recogniser, restarting the
/// recognition task periodically so long recordings keep working.
final class SpeechListener {
    /// Called on the main queue with the transcript of the current recognition task.
    var onTranscript: ((String) -> Void)?
    /// Called on the main queue when a new recognition task starts (the previous transcript is done).
    var onTaskRestart: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onStatus: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private let requestLock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    /// Accessed from both the audio thread and the main thread.
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestLock.lock(); defer { requestLock.unlock() }; return _request }
        set { requestLock.lock(); _request = newValue; requestLock.unlock() }
    }
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var restartTimer: Timer?
    private(set) var isRunning = false
    var contextualStrings: [String] = []

    static func requestPermissions(_ completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    completion("Speech recognition permission was not granted. Enable it in System Settings › Privacy & Security › Speech Recognition.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? nil : "Microphone permission was not granted. Enable it in System Settings › Privacy & Security › Microphone.")
                }
            }
        }
    }

    func start(device: AudioDeviceID?, locale: Locale) throws {
        stop()
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Teleprompter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available for \(locale.identifier)."])
        }
        self.recognizer = recognizer

        let input = engine.inputNode
        if var deviceID = device, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { onStatus?("Couldn't switch microphone (error \(status)); using system default.") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Teleprompter", code: 3, userInfo: [NSLocalizedDescriptionKey: "The selected microphone has no usable input."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            if let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += data[i] * data[i] }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 55) / 50))
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        startTask()
        let mode = recognizer.supportsOnDeviceRecognition ? "on-device" : "server"
        onStatus?("Listening (\(recognizer.locale.identifier), \(mode))")
    }

    func stop() {
        restartTimer?.invalidate(); restartTimer = nil
        generation += 1
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        if isRunning { onStatus?("Stopped") }
        isRunning = false
        onLevel?(0)
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        generation += 1
        let gen = generation
        task?.cancel()
        request?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        onTaskRestart?()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result {
                    self.onTranscript?(result.bestTranscription.formattedString)
                    if result.isFinal { self.startTask() }
                } else if error != nil {
                    // Typically "no speech detected" after silence; just start over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if gen == self.generation { self.startTask() }
                    }
                }
            }
        }

        // Recognition tasks have a duration limit; recycle them regularly.
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self, gen == self.generation else { return }
            self.startTask()
        }
    }
}
