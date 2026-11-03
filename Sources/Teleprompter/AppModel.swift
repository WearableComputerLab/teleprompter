import AppKit
import Combine
import UniformTypeIdentifiers

enum OverlayPosition: String, CaseIterable, Identifiable {
    case top, middle, bottom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String

    static func all() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            let size = screen.frame.size
            var name = "\(screen.localizedName) — \(Int(size.width))×\(Int(size.height))"
            if screen == NSScreen.screens.first { name += " (menu bar)" }
            return ScreenInfo(id: screen.displayID, name: name)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    // Script
    @Published private(set) var script = Script.empty
    @Published private(set) var fileURL: URL?
    @Published private(set) var position = 0
    @Published var loadError: String?

    // Display settings
    @Published var screenID: CGDirectDisplayID { didSet { defaults.set(Int(screenID), forKey: "screenID"); overlay.layout() } }
    @Published var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: "overlayPosition"); overlay.layout() } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var widthFraction: Double { didSet { defaults.set(widthFraction, forKey: "widthFraction"); overlay.layout() } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var upcomingCount: Int { didSet { defaults.set(upcomingCount, forKey: "upcomingCount") } }
    @Published var showDirections: Bool { didSet { defaults.set(showDirections, forKey: "showDirections") } }
    @Published var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "mirrored") } }
    @Published var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: "hideFromCapture"); overlay.layout() } }
    @Published var overlayVisible = true { didSet { overlay.layout() } }
    @Published var parseMode: ParseMode { didSet { defaults.set(parseMode.rawValue, forKey: "parseMode"); reload() } }

    @Published private(set) var screens: [ScreenInfo] = ScreenInfo.all()

    // Listening
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID"); if isListening { startListening() } } }
    @Published private(set) var inputDevices: [AudioInputDevice] = AudioInputDevice.all()
    @Published private(set) var isListening = false
    @Published private(set) var level: Float = 0
    @Published private(set) var status = "Not listening"
    @Published private(set) var lastHeard = ""

    private var tracker = Tracker(words: [])
    private let listener = SpeechListener()
    private(set) lazy var overlay = OverlayController(model: self)
    private let hotKeys = HotKeys()

    /// Words carried over from previous recognition tasks, so alignment has context right after a restart.
    private var carry: [String] = []
    private var taskWords: [String] = []
    /// Words of the current task to ignore (heard before a manual jump).
    private var ignoreCount = 0

    init() {
        defaults.register(defaults: [
            "fontSize": 40.0, "widthFraction": 0.7, "backgroundOpacity": 0.75, "upcomingCount": 1,
            "showDirections": true, "mirrored": false, "hideFromCapture": true,
            "overlayPosition": OverlayPosition.top.rawValue, "parseMode": ParseMode.auto.rawValue,
        ])
        let savedScreen = CGDirectDisplayID(defaults.integer(forKey: "screenID"))
        screenID = NSScreen.screens.contains { $0.displayID == savedScreen } ? savedScreen : (NSScreen.main?.displayID ?? 0)
        overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: "overlayPosition") ?? "") ?? .top
        fontSize = defaults.double(forKey: "fontSize")
        widthFraction = defaults.double(forKey: "widthFraction")
        backgroundOpacity = defaults.double(forKey: "backgroundOpacity")
        upcomingCount = defaults.integer(forKey: "upcomingCount")
        showDirections = defaults.bool(forKey: "showDirections")
        mirrored = defaults.bool(forKey: "mirrored")
        hideFromCapture = defaults.bool(forKey: "hideFromCapture")
        parseMode = ParseMode(rawValue: defaults.string(forKey: "parseMode") ?? "") ?? .auto
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""

        listener.onTranscript = { [weak self] text in self?.heard(text) }
        listener.onTaskRestart = { [weak self] in self?.taskRestarted() }
        listener.onLevel = { [weak self] level in self?.level = level }
        listener.onStatus = { [weak self] s in self?.status = s }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screens = ScreenInfo.all()
            self.overlay.layout()
        }

        hotKeys.register { [weak self] action in
            guard let self else { return }
            switch action {
            case .next: self.nextSentence()
            case .previous: self.previousSentence()
            case .toggleListening: self.toggleListening()
            case .toggleOverlay: self.overlayVisible.toggle()
            }
        }

        if let path = defaults.string(forKey: "lastFile"), FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
        }
        DispatchQueue.main.async { self.overlay.layout() }
    }

    // MARK: Script

    static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"), .rtf, .rtfd, .plainText, .pdf, .html,
        UTType(filenameExtension: "odt"), UTType(filenameExtension: "md"), UTType(filenameExtension: "fountain"),
    ].compactMap { $0 }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a script (Word, RTF, PDF, text, Fountain…)"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    func open(url: URL) {
        do {
            let loaded = try ScriptLoader.load(url: url, mode: parseMode)
            script = loaded
            fileURL = url
            loadError = loaded.sentences.isEmpty ? "No spoken text found. Try switching the parsing mode to “All text”." : nil
            defaults.set(url.path, forKey: "lastFile")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            tracker = Tracker(words: loaded.words.map(\.norm))
            listener.contextualStrings = loaded.vocabularyHints
            let saved = defaults.integer(forKey: positionKey(url))
            tracker.position = min(max(saved, 0), loaded.words.count)
            position = tracker.position
            resetHeard()
        } catch {
            loadError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reload() {
        if let fileURL { open(url: fileURL) }
    }

    private func positionKey(_ url: URL) -> String { "position:" + url.path }

    private func setPosition(_ p: Int) {
        tracker.position = p
        position = p
        if let fileURL { defaults.set(p, forKey: positionKey(fileURL)) }
    }

    // MARK: Navigation

    /// Index of the sentence the speaker is on (or about to start).
    var currentSentenceIndex: Int? {
        guard !script.sentences.isEmpty else { return nil }
        if position < script.words.count { return script.words[position].sentence }
        return script.sentences.count - 1
    }

    /// How many words of the current sentence have been spoken.
    var spokenWordsInCurrent: Int {
        guard let i = currentSentenceIndex else { return 0 }
        let range = script.sentences[i].wordRange
        return max(0, min(position, range.upperBound) - range.lowerBound)
    }

    func jump(toSentence index: Int) {
        guard script.sentences.indices.contains(index) else { return }
        setPosition(script.sentences[index].wordRange.lowerBound)
        resetHeard()
    }

    func nextSentence() {
        guard let i = currentSentenceIndex else { return }
        // Skip sentences without words (they'd map back onto the same position).
        var j = i + 1
        while j < script.sentences.count && script.sentences[j].wordRange.isEmpty { j += 1 }
        if j < script.sentences.count { jump(toSentence: j) } else { setPosition(script.words.count); resetHeard() }
    }

    func previousSentence() {
        guard let i = currentSentenceIndex else { return }
        // If partway through a sentence, go back to its start first.
        if spokenWordsInCurrent > 0 && position < script.words.count { jump(toSentence: i); return }
        var j = i - 1
        while j > 0 && script.sentences[j].wordRange.isEmpty { j -= 1 }
        jump(toSentence: max(j, 0))
    }

    func restart() { jump(toSentence: 0) }

    // MARK: Listening

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        SpeechListener.requestPermissions { [weak self] error in
            guard let self else { return }
            if let error { self.status = error; self.isListening = false; return }
            let device = self.inputDevices.first { $0.uid == self.inputDeviceUID }?.id
            do {
                try self.listener.start(device: device, locale: Locale.current)
                self.isListening = true
                self.resetHeard()
            } catch {
                self.status = error.localizedDescription
                self.isListening = false
            }
        }
    }

    func stopListening() {
        listener.stop()
        isListening = false
    }

    func refreshDevices() {
        inputDevices = AudioInputDevice.all()
        screens = ScreenInfo.all()
    }

    private func resetHeard() {
        carry = []
        ignoreCount = taskWords.count
    }

    private func taskRestarted() {
        carry = Array((carry + taskWords.dropFirst(min(ignoreCount, taskWords.count))).suffix(8))
        taskWords = []
        ignoreCount = 0
    }

    private func heard(_ text: String) {
        taskWords = ScriptLoader.transcriptWords(text)
        let fresh = taskWords.dropFirst(min(ignoreCount, taskWords.count))
        let words = carry + fresh
        lastHeard = words.suffix(12).joined(separator: " ")
        if tracker.update(heard: words) { setPosition(tracker.position) }
    }
}
