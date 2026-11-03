import AppKit

/// Command-line helpers for checking parsing and tracking without a microphone:
///   Teleprompter --parse <file>      print how the script was classified
///   Teleprompter --simulate <file>   feed a noisy fake transcript through the tracker
enum DevTools {
    static func run(command: String, path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let script = try? ScriptLoader.load(url: url, mode: .auto) else {
            print("Could not load \(url.path)"); exit(1)
        }
        if command == "--parse" {
            for row in script.rows {
                switch row {
                case .heading(_, let t): print("# \(t)")
                case .cue(_, let t): print("    [\(t)]")
                case .direction(_, let t): print("  ~ \(t)")
                case .sentence(_, let s): print("  \(s.id): \(s.text)")
                }
            }
            print("\nScreenplay: \(script.detectedScreenplay), sentences: \(script.sentences.count), words: \(script.words.count)")
            print("Vocabulary hints: \(script.vocabularyHints.joined(separator: ", "))")
        } else {
            simulate(script)
        }
    }

    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func simulate(_ script: Script) {
        // Retakes and skips: say sentences 0-20, redo sentence 15, then jump ahead to sentence 40.
        var t = Tracker(words: script.words.map(\.norm))
        var heard: [String] = []
        func say(_ s: Int) -> Int {
            for w in script.words[script.sentences[s].wordRange] { heard.append(w.norm); t.update(heard: heard) }
            return t.position < script.words.count ? script.words[t.position].sentence : -1
        }
        for s in 0...20 { _ = say(s) }
        let words15 = Array(script.words[script.sentences[15].wordRange.prefix(5)].map(\.norm))
        for w in words15 { heard.append(w); t.update(heard: heard) }
        print("Retake of 15 → tracking sentence \(script.words[t.position].sentence) (expected 15), word \(t.position - script.sentences[15].wordRange.lowerBound)/\(script.sentences[15].wordRange.count)")
        let afterSkip = say(40)
        print("Skip to 40 → now at sentence \(afterSkip) (expected 41)")

        for noise in [0.0, 0.1, 0.2, 0.3] {
            var rng = SeededRNG(state: 42)
            var tracker = Tracker(words: script.words.map(\.norm))
            let fillers = ["um", "uh", "so", "the", "and", "like"]
            var task: [String] = []
            var carry: [String] = []
            var lagSum = 0, samples = 0, wrongSentence = 0, maxLag = 0
            for (i, w) in script.words.enumerated() {
                let r = Double.random(in: 0..<1, using: &rng)
                if r < noise * 0.4 { /* dropped */ }
                else if r < noise * 0.8 { task.append(fillers.randomElement(using: &rng)!) }
                else { task.append(w.norm) }
                if Double.random(in: 0..<1, using: &rng) < noise * 0.2 { task.append(fillers.randomElement(using: &rng)!) }
                // Restart the "recognition task" every ~120 words.
                if task.count > 120 { carry = Array((carry + task).suffix(8)); task = [] }
                tracker.update(heard: carry + task)
                let truth = i + 1
                let lag = truth - tracker.position
                lagSum += abs(lag); samples += 1; maxLag = max(maxLag, abs(lag))
                let trackedSentence = tracker.position < script.words.count ? script.words[tracker.position].sentence : script.sentences.count - 1
                let trueSentence = truth < script.words.count ? script.words[truth].sentence : script.sentences.count - 1
                if trackedSentence != trueSentence { wrongSentence += 1 }
            }
            print(String(format: "noise %.0f%%: mean lag %.2f words, max lag %d, wrong sentence %.1f%% of words, final %d/%d",
                         noise * 100, Double(lagSum) / Double(samples), maxLag,
                         100 * Double(wrongSentence) / Double(samples), tracker.position, script.words.count))
        }
    }
}

extension DevTools {
    /// When TELEPROMPTER_SNAPSHOT_DIR is set, writes PNGs of the app's windows there a few seconds after launch.
    static func scheduleSnapshotsIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TELEPROMPTER_SNAPSHOT_DIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView, view.bounds.width > 0,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("window\(i)-\(type(of: window)).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
