import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
            scriptPane
                .frame(minWidth: 420)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url: url)
            return true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Form {
            Section("Script") {
                HStack {
                    Text(model.fileURL?.lastPathComponent ?? "None — drop a file here")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.fileURL == nil ? .secondary : .primary)
                    Spacer()
                    Button("Open…") { model.showOpenPanel() }
                }
                Picker("Spoken text", selection: $model.parseMode) {
                    ForEach(ParseMode.allCases) { Text($0.label).tag($0) }
                }
                if model.parseMode == .auto, model.fileURL != nil {
                    Text(model.script.detectedScreenplay ? "Screenplay detected: only dialogue is tracked." : "Treating all text as spoken.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Listening") {
                Picker("Microphone", selection: $model.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
                }
                HStack {
                    Button(model.isListening ? "Stop Listening" : "Start Listening") { model.toggleListening() }
                        .buttonStyle(.borderedProminent)
                        .tint(model.isListening ? .red : .accentColor)
                        .disabled(model.script.sentences.isEmpty)
                    ProgressView(value: Double(model.level)).progressViewStyle(.linear)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                if !model.lastHeard.isEmpty {
                    Text("Heard: “…\(model.lastHeard)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Section("Overlay") {
                Toggle("Show overlay", isOn: $model.overlayVisible)
                HStack {
                    Picker("Screen", selection: $model.screenID) {
                        ForEach(model.screens) { Text($0.name).tag($0.id) }
                    }
                    Button { model.overlay.identifyScreens() } label: { Image(systemName: "rectangle.on.rectangle") }
                        .help("Identify screens")
                }
                Picker("Position", selection: $model.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Text size") {
                    Slider(value: $model.fontSize, in: 18...96)
                }
                LabeledContent("Width") {
                    Slider(value: $model.widthFraction, in: 0.3...1)
                }
                LabeledContent("Background") {
                    Slider(value: $model.backgroundOpacity, in: 0...1)
                }
                Stepper("Upcoming sentences: \(model.upcomingCount)", value: $model.upcomingCount, in: 0...4)
                Toggle("Show stage directions", isOn: $model.showDirections)
                Toggle("Mirror text (for teleprompter glass)", isOn: $model.mirrored)
                Toggle("Try to hide from screen recordings", isOn: $model.hideFromCapture)
                    .help("Asks macOS to exclude the overlay from screen capture. Not every recorder honours this, so also put the overlay on a screen you aren't recording.")
            }

            Section("Shortcuts (work from any app)") {
                shortcut("Next sentence", "→")
                shortcut("Previous sentence", "←")
                shortcut("Start / stop listening", "L")
                shortcut("Show / hide overlay", "H")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshDevices() }
    }

    private func shortcut(_ label: String, _ key: String) -> some View {
        LabeledContent(label) {
            Text(HotKeys.modifierSymbol + key).monospaced().foregroundStyle(.secondary)
        }
    }

    // MARK: Script

    private var scriptPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.script.title).font(.headline).lineLimit(1)
                Spacer()
                if let i = model.currentSentenceIndex {
                    Text("Sentence \(i + 1) of \(model.script.sentences.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Button { model.restart() } label: { Image(systemName: "backward.end.fill") }.help("Back to start")
                Button { model.previousSentence() } label: { Image(systemName: "chevron.left") }.help("Previous sentence")
                Button { model.nextSentence() } label: { Image(systemName: "chevron.right") }.help("Next sentence")
            }
            .padding(10)
            Divider()
            if model.script.rows.isEmpty {
                ContentUnavailableView("Open a script", systemImage: "doc.text",
                                       description: Text("Word (.docx), RTF, PDF, plain text or Fountain. You can also drop a file here."))
            } else {
                scriptList
            }
        }
    }

    private var scriptList: some View {
        let current = model.currentSentenceIndex
        return ScrollViewReader { proxy in
            List(model.script.rows) { row in
                rowView(row, current: current)
                    .id(row.id)
            }
            .listStyle(.plain)
            .onChange(of: current) { _, _ in scrollToCurrent(proxy) }
            .onAppear { scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = model.currentSentenceIndex,
              let row = model.script.rows.first(where: { if case .sentence(_, let s) = $0 { return s.id == current }; return false })
        else { return }
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(row.id, anchor: .center) }
    }

    @ViewBuilder
    private func rowView(_ row: ScriptRow, current: Int?) -> some View {
        switch row {
        case .heading(_, let text):
            Text(text).font(.headline).padding(.top, 8)
        case .cue(_, let text):
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 40)
        case .direction(_, let text):
            Text(text).font(.callout.italic()).foregroundStyle(.secondary)
        case .sentence(_, let sentence):
            let isCurrent = sentence.id == current
            let isDone = current.map { sentence.id < $0 } ?? false
            Text(sentence.text)
                .font(.body)
                .foregroundStyle(isDone ? .secondary : .primary)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.25) : .clear))
                .padding(.leading, 20)
                .contentShape(Rectangle())
                .onTapGesture { model.jump(toSentence: sentence.id) }
                .help("Click to jump here")
        }
    }
}
