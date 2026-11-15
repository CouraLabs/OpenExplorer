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
                Button("Open in Terminal") { model.openInTerminal(targetURLs.first ?? model.currentURL) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }

            // Cut / Copy / Paste act on files, unless a text field is being edited.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    if !forwardToTextEditor(#selector(NSText.cut(_:))) { model.cut(targetURLs) }
                }
                .keyboardShortcut("x")
                Button("Copy") {
                    if !forwardToTextEditor(#selector(NSText.copy(_:))) { model.copy(targetURLs) }
                }
                .keyboardShortcut("c")
                Button("Paste") {
                    if !forwardToTextEditor(#selector(NSText.paste(_:))) { model.paste(into: model.currentURL) }
                }
                .keyboardShortcut("v")
                Button("Copy Path") { model.copyPaths(targetURLs.isEmpty ? [model.currentURL] : targetURLs) }
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
                Button("Home") { model.navigate(to: model.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }

    /// Files the keyboard commands act on: the tree's folder when the tree has focus, otherwise the list selection.
    @MainActor
    private var targetURLs: [URL] {
        if NSApp.keyWindow?.firstResponder is FolderOutlineView {
            return model.currentURL.path == model.home.path ? [] : [model.currentURL]
        }
        return model.selectedURLs
    }

    /// If a text field is being edited, send it the standard edit action and return true.
    @MainActor
    private func forwardToTextEditor(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }
}
