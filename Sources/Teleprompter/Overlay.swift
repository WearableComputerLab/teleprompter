import AppKit
import SwiftUI

/// A click-through, always-on-top panel that shows the current and upcoming sentences on the chosen screen.
final class OverlayController {
    private unowned let model: AppModel
    private var panel: NSPanel?
    private var identifyPanels: [NSPanel] = []

    init(model: AppModel) {
        self.model = model
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == model.screenID }
    }

    func layout() {
        guard model.overlayVisible, let screen else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.sharingType = model.hideFromCapture ? .none : .readOnly
        let area = screen.visibleFrame
        let width = (area.width * model.widthFraction).rounded()
        let frame = NSRect(x: area.midX - width / 2, y: area.minY, width: width, height: area.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Briefly shows a large label on every screen so the user can tell them apart.
    func identifyScreens() {
        identifyPanels.forEach { $0.orderOut(nil) }
        identifyPanels = NSScreen.screens.enumerated().map { index, screen in
            let size = NSSize(width: 520, height: 220)
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let selected = screen.displayID == model.screenID
            p.contentView = NSHostingView(rootView:
                VStack(spacing: 8) {
                    Text("\(index + 1)").font(.system(size: 96, weight: .bold))
                    Text(screen.localizedName).font(.title2)
                    if selected { Text("Teleprompter screen").font(.headline).foregroundStyle(.yellow) }
                }
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.8)))
            )
            p.setFrame(frame, display: true)
            p.orderFrontRegardless()
            return p
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.identifyPanels.forEach { $0.orderOut(nil) }
            self?.identifyPanels = []
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.overlayPosition != .top { Spacer(minLength: 0) }
            card
            if model.overlayPosition != .bottom { Spacer(minLength: 0) }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var card: some View {
        if let index = model.currentSentenceIndex {
            let sentences = model.script.sentences
            let current = sentences[index]
            let atEnd = model.position >= model.script.words.count
            let upcoming = sentences[(index + 1)...].prefix(model.upcomingCount)

            VStack(alignment: .leading, spacing: model.fontSize * 0.3) {
                if model.showDirections, model.spokenWordsInCurrent == 0, let note = current.directionsBefore.last {
                    direction(note)
                }
                Text(currentText(current, atEnd: atEnd))
                    .font(.system(size: model.fontSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if atEnd {
                    Text("— End of script —").font(.system(size: model.fontSize * 0.5)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(upcoming)) { s in
                    if model.showDirections, let note = s.directionsBefore.last { direction(note) }
                    Text(s.text)
                        .font(.system(size: model.fontSize * 0.7, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, model.fontSize * 0.6)
            .padding(.vertical, model.fontSize * 0.45)
            .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(model.backgroundOpacity)))
            .overlay(alignment: .topTrailing) {
                Circle().fill(model.isListening ? Color.red : Color.gray.opacity(0.6))
                    .frame(width: 10, height: 10).padding(10)
            }
            .scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
            .animation(.easeOut(duration: 0.2), value: model.position)
        }
    }

    private func direction(_ note: String) -> some View {
        Text("▸ " + note)
            .font(.system(size: max(13, model.fontSize * 0.42)).italic())
            .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.4).opacity(0.85))
            .lineLimit(2)
    }

    private func currentText(_ sentence: Sentence, atEnd: Bool) -> AttributedString {
        var text = AttributedString(sentence.text)
        text.foregroundColor = .white
        let words = model.script.words
        let spoken = atEnd ? sentence.wordRange.count : model.spokenWordsInCurrent
        let s = sentence.text
        if spoken > 0 {
            let end = words[sentence.wordRange.lowerBound + spoken - 1].range.upperBound
            if let r = Range(NSRange(s.startIndex..<end, in: s), in: text) {
                text[r].foregroundColor = .white.opacity(0.35)
            }
        }
        if !atEnd, spoken < sentence.wordRange.count {
            let next = words[sentence.wordRange.lowerBound + spoken].range
            if let r = Range(NSRange(next, in: s), in: text) {
                text[r].foregroundColor = Color(red: 1, green: 0.85, blue: 0.3)
            }
        }
        return text
    }
}
