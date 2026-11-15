import SwiftUI

/// Every keyboard shortcut, shown from Help › Keyboard Shortcuts (⌘/).
enum Shortcuts {
    struct Entry: Identifiable {
        let keys: String
        let action: String
        var id: String { action }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Files", entries: [
            Entry(keys: "Return / ⌘O / ⌘↓", action: "Open"),
            Entry(keys: "F2", action: "Rename"),
            Entry(keys: "⌘D", action: "Duplicate"),
            Entry(keys: "⌘⌫ / Delete (fn-⌫)", action: "Move to Trash"),
            Entry(keys: "⌥⌘⌫", action: "Delete Immediately…"),
            Entry(keys: "⇧⌘⌫", action: "Empty Trash…"),
            Entry(keys: "⇧⌘N", action: "New Folder"),
            Entry(keys: "⌥⌘N", action: "New File"),
            Entry(keys: "Space / ⌘Y", action: "Quick Look"),
            Entry(keys: "⌥⌘T", action: "Open in Terminal"),
            Entry(keys: "⌥⌘R", action: "Show in Finder"),
            Entry(keys: "⌘E", action: "Eject"),
        ]),
        Section(title: "Edit", entries: [
            Entry(keys: "⌘C / ⌘X / ⌘V", action: "Copy / Cut / Paste"),
            Entry(keys: "⌥⌘V", action: "Move Item Here"),
            Entry(keys: "⌥⌘C", action: "Copy Path"),
            Entry(keys: "⌘A", action: "Select All"),
            Entry(keys: "⌘F", action: "Find (Esc clears)"),
        ]),
        Section(title: "Go", entries: [
            Entry(keys: "⌘[ / ⌫ / ⌥←", action: "Back"),
            Entry(keys: "⌘] / ⌥→", action: "Forward"),
            Entry(keys: "⌘↑ / ⌥↑", action: "Enclosing Folder"),
            Entry(keys: "⌘L / ⇧⌘G", action: "Go to Folder (address bar)"),
            Entry(keys: "⇧⌘H", action: "Home"),
            Entry(keys: "⇧⌘C", action: "This Mac"),
            Entry(keys: "⇧⌘D", action: "Desktop"),
            Entry(keys: "⇧⌘O", action: "Documents"),
            Entry(keys: "⌥⌘L", action: "Downloads"),
            Entry(keys: "⇧⌘A", action: "Applications"),
            Entry(keys: "⇧⌘U", action: "Utilities"),
        ]),
        Section(title: "View", entries: [
            Entry(keys: "⇧⌘.", action: "Show Hidden Files"),
            Entry(keys: "⌘R / F5", action: "Refresh"),
            Entry(keys: "⌘/", action: "Keyboard Shortcuts"),
        ]),
    ]
}

struct ShortcutsView: View {
    @EnvironmentObject var model: ExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    column(Array(Shortcuts.sections.prefix(2)))
                    column(Array(Shortcuts.sections.dropFirst(2)))
                }
            }
            Text("F2, F5, Delete, ⌫ and ⌥-arrows work when the file list or folder tree has focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { model.showShortcuts = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private func column(_ sections: [Shortcuts.Section]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title).font(.headline)
                    ForEach(section.entries) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.action)
                            Spacer(minLength: 12)
                            Text(entry.keys)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
