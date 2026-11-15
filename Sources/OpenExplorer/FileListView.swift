import SwiftUI

/// Local text-field state. (`@State` is a macro in this SDK and the Command Line Tools lack its plugin.)
final class FileListTextState: ObservableObject {
    @Published var address = ""
    @Published var newItemName = ""
}

struct FileListView: View {
    @EnvironmentObject var model: ExplorerModel
    @StateObject private var text = FileListTextState()
    @FocusState private var searchFocused: Bool
    @FocusState private var addressFocused: Bool
    /// Re-render icons when switching light/dark (vscode-icons has light variants).
    @Environment(\.colorScheme) private var colorScheme

    private static let dateFormat = Date.FormatStyle()
        .month(.twoDigits).day(.twoDigits).year()
        .hour().minute()

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            searchBar
            Divider()
            table
            Divider()
            statusBar
        }
        .alert(
            model.namePrompt?.title ?? "",
            isPresented: Binding(
                get: { model.namePrompt != nil },
                set: { if !$0 { model.namePrompt = nil } }
            ),
            presenting: model.namePrompt
        ) { prompt in
            TextField("Name", text: $text.newItemName)
            Button(prompt.renaming == nil ? "Create" : "Rename") { model.commitNamePrompt(prompt, name: text.newItemName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.renaming == nil ? "Create in \(prompt.directory.path)" : "Enter a new name for “\(prompt.suggestedName)”.")
        }
        .onChange(of: model.namePrompt?.id) {
            text.newItemName = model.namePrompt?.suggestedName ?? ""
        }
        .onChange(of: model.focusSearchID) { searchFocused = true }
        .onChange(of: model.focusAddressID) { addressFocused = true }
    }

    private var searchPlaceholder: String {
        switch model.search.mode {
        case .name: "Search names in “\(model.title)” (glob: *.swift; report*)"
        case .contents: model.search.regex ? "Regular expression to find in files" : "Text to find in files"
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("Search", selection: $model.search.mode) {
                ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Name: match file names with glob patterns. Contents: search inside files with grep.")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $model.search.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { model.clearSearch() }
                if model.isSearchRunning {
                    ProgressView().controlSize(.small)
                }
                if !model.search.query.isEmpty {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            if model.search.mode == .contents {
                TextField("Files: *.swift; *.md", text: $model.search.fileGlobs)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .help("Only search files whose names match these globs")
            }
            Toggle("Subfolders", isOn: $model.search.recursive)
                .toggleStyle(.checkbox)
                .help("Also search inside subfolders")
            Toggle(isOn: $model.search.caseSensitive) { Text("Aa") }
                .toggleStyle(.button)
                .help("Match case")
            if model.search.mode == .contents {
                Toggle(isOn: $model.search.regex) { Text(".*").monospaced() }
                    .toggleStyle(.button)
                    .help("Regular expression (grep -E)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: model.currentURL, isFolder: true))
            TextField("Path", text: $text.address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { model.goToPath(text.address) }
                .onExitCommand { text.address = model.currentURL.path }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear { text.address = model.currentURL.path }
        .onChange(of: model.currentURL) { text.address = model.currentURL.path }
    }

    private var table: some View {
        Table(model.items, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                let _ = (colorScheme, model.fileIconTheme)
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item))
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(item.isHidden || model.isCut(item) ? 0.5 : 1)
                .help(item.url.path)
            }
            .width(min: 180, ideal: 320)

            if model.isSearchActive {
                TableColumn("Folder", value: \.location, comparator: .localizedStandard) { item in
                    Text(item.location.isEmpty ? "." : item.location)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(item.url.deletingLastPathComponent().path)
                }
                .width(min: 100, ideal: 200)
            }

            if model.isSearchActive && model.search.mode == .contents {
                TableColumn("Match") { (item: FileItem) in
                    Text(item.match ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.match ?? "")
                }
                .width(min: 120, ideal: 300)
            }

            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified, format: Self.dateFormat).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Date Created", value: \.created) { item in
                Text(item.created, format: Self.dateFormat).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Size", value: \.sizeSortKey) { item in
                Text(item.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            contextMenu(for: urls)
        } primaryAction: { urls in
            model.open(Array(urls))
        }
    }

    @ViewBuilder
    private func contextMenu(for urls: Set<URL>) -> some View {
        let list = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if list.isEmpty {
            // Right-click on empty space: acts on the current folder.
            Button("Open in Terminal") { model.openInTerminal(model.currentURL) }
            Button("Copy Path") { model.copyPaths([model.currentURL]) }
            Divider()
            Button("Paste") { model.paste(into: model.currentURL) }
                .disabled(!model.canPaste)
            Divider()
            Button("New File…") { model.promptNewItem(.file) }
            Button("New Folder…") { model.promptNewItem(.folder) }
            Divider()
            Button("Refresh") { model.refresh() }
        } else {
            Button("Open") { model.open(list) }
            Button("Quick Look") { QuickLookController.shared.toggle(in: NSApp.keyWindow) }
            Button("Open in Terminal") { model.openInTerminal(list[0]) }
            Button(list.count > 1 ? "Copy Paths" : "Copy Path") { model.copyPaths(list) }
            Divider()
            Button("Rename…") { model.promptRename(list[0]) }
                .disabled(list.count != 1)
            Button("Duplicate") { model.duplicate(list) }
            Divider()
            Button("Cut") { model.cut(list) }
            Button("Copy") { model.copy(list) }
            if list.count == 1, FileSystem.isFolder(list[0]) {
                Button("Paste Into Folder") { model.paste(into: list[0]) }
                    .disabled(!model.canPaste)
            } else {
                Button("Paste") { model.paste(into: model.currentURL) }
                    .disabled(!model.canPaste)
            }
            Divider()
            Button("New File…") { model.promptNewItem(.file) }
            Button("New Folder…") { model.promptNewItem(.folder) }
            Divider()
            Button("Show in Finder") { model.revealInFinder(list) }
            Button("Move to Trash") { model.moveToTrash(list) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isSearchActive {
                Text("\(model.items.count) result\(model.items.count == 1 ? "" : "s")")
                if model.isSearchRunning { Text("Searching…") }
                if let status = model.searchStatus { Text(status).lineLimit(1) }
            } else {
                Text("\(model.items.count) item\(model.items.count == 1 ? "" : "s")")
            }
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
            }
            Spacer()
            if model.showHidden {
                Text("Hidden files shown")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
