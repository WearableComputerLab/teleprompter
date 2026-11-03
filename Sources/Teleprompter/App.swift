import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--parse" || args[1] == "--simulate" {
            DevTools.run(command: args[1], path: args[2])
            return
        }
        TeleprompterApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURL: URL?
    var model: AppModel? {
        didSet {
            if let url = pendingURL { model?.open(url: url); pendingURL = nil }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(url: url) } else { pendingURL = url }
    }
}

struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Teleprompter", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { delegate.model = model; DevTools.scheduleSnapshotsIfRequested() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Script…") { model.showOpenPanel() }.keyboardShortcut("o")
                Button("Reload Script") { model.reload() }.keyboardShortcut("r")
            }
            CommandMenu("Prompter") {
                Button(model.isListening ? "Stop Listening" : "Start Listening") { model.toggleListening() }
                    .keyboardShortcut("l")
                Button("Next Sentence") { model.nextSentence() }.keyboardShortcut("]")
                Button("Previous Sentence") { model.previousSentence() }.keyboardShortcut("[")
                Button("Back to Start") { model.restart() }
                Divider()
                Button(model.overlayVisible ? "Hide Overlay" : "Show Overlay") { model.overlayVisible.toggle() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Identify Screens") { model.overlay.identifyScreens() }
            }
        }
    }
}
