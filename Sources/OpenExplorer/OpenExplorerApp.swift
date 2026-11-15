import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppIconManager.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OpenExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ExplorerModel()

    var body: some Scene {
        Window("Open Explorer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 400)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New File…") { model.promptNewItem(.file) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Folder…") { model.promptNewItem(.folder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open") { model.open(model.commandTargets) }
                    .keyboardShortcut("o")
                Button("Quick Look") { QuickLookController.shared.toggle(in: NSApp.keyWindow) }
                    .keyboardShortcut("y")
                Button("Open in Terminal") { model.openInTerminal(model.commandTargets.first ?? model.currentURL) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Show in Finder") {
                    let targets = model.commandTargets
                    model.revealInFinder(targets.isEmpty ? [model.currentURL] : targets)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Rename…") { model.promptRename(model.commandTargets.first) }
                Button("Duplicate") { model.duplicate(model.commandTargets) }
                    .keyboardShortcut("d")
                Button("Move to Trash") {
                    if !forwardToTextEditor(#selector(NSResponder.deleteToBeginningOfLine(_:))) {
                        model.moveToTrash(model.commandTargets)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Button("Delete Immediately…") { model.requestPermanentDelete(model.commandTargets) }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                Button("Empty Trash…") { model.confirmEmptyTrash = true }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Button("Eject") { model.ejectCurrentVolume() }
                    .keyboardShortcut("e")
            }

            // Cut / Copy / Paste act on files, unless a text field is being edited.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    if !forwardToTextEditor(#selector(NSText.cut(_:))) { model.cut(model.commandTargets) }
                }
                .keyboardShortcut("x")
                Button("Copy") {
                    if !forwardToTextEditor(#selector(NSText.copy(_:))) { model.copy(model.commandTargets) }
                }
                .keyboardShortcut("c")
                Button("Paste") {
                    if !forwardToTextEditor(#selector(NSText.paste(_:))) { model.paste(into: model.currentURL) }
                }
                .keyboardShortcut("v")
                Button("Move Item Here") { model.paste(into: model.currentURL, forceMove: true) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Copy Path") {
                    let targets = model.commandTargets
                    model.copyPaths(targets.isEmpty ? [model.currentURL] : targets)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Select All") {
                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a")
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find…") { model.focusSearch() }
                    .keyboardShortcut("f")
            }

            CommandGroup(after: .sidebar) {
                Picker("File Icons", selection: $model.fileIconTheme) {
                    ForEach(FileIconTheme.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Divider()
            }

            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.canGoForward)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Button("Open Selection") { model.open(model.selectedURLs) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("This Mac") { model.navigate(to: model.computer) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Home") { model.navigate(to: model.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Desktop") { model.navigate(toStandard: .desktopDirectory) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Documents") { model.navigate(toStandard: .documentDirectory) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Downloads") { model.navigate(toStandard: .downloadsDirectory) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Applications") { model.navigate(toStandard: .applicationDirectory) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Utilities") { model.navigate(to: URL(fileURLWithPath: "/Applications/Utilities")) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Trash") { model.navigate(to: model.trash) }
                Divider()
                Button("Go to Folder…") { model.focusAddressBar() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Edit Address") { model.focusAddressBar() }
                    .keyboardShortcut("l")
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showShortcuts = true }
                    .keyboardShortcut("/")
            }
        }
    }

    /// If a text field is being edited, send it the standard edit action and return true.
    @MainActor
    private func forwardToTextEditor(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }
}
