import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ExplorerModel

    private var deleteQuestion: String {
        let urls = model.pendingPermanentDelete ?? []
        return urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete these \(urls.count) items?"
    }

    var body: some View {
        NavigationSplitView {
            FolderTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            FileListView()
        }
        .navigationTitle(model.windowTitle)
        .onAppear {
            QuickLookController.shared.attach(model)
            KeyboardController.shared.attach(model)
            ListScrollController.shared.attach(model)
        }
        .sheet(isPresented: $model.showShortcuts) {
            ShortcutsView().environmentObject(model)
        }
        .confirmationDialog(
            deleteQuestion,
            isPresented: Binding(
                get: { model.pendingPermanentDelete != nil },
                set: { if !$0 { model.pendingPermanentDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { model.confirmPermanentDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This item will be deleted immediately. You can’t undo this action.")
        }
        .confirmationDialog("Are you sure you want to permanently erase the items in the Trash?",
                            isPresented: $model.confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can’t undo this action.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                Button { model.goUp() } label: { Label("Up", systemImage: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Up to enclosing folder")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: Binding(
                        get: { model.sortKey },
                        set: { model.setSort($0, ascending: model.sortAscending) }
                    )) {
                        ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Order", selection: Binding(
                        get: { model.sortAscending },
                        set: { model.setSort(model.sortKey, ascending: $0) }
                    )) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort items")

                Toggle(isOn: $model.showHidden) {
                    Label("Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
                }
                .help(model.showHidden ? "Hide hidden files" : "Show hidden files")

                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
        .alert(
            "Open Explorer",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil; model.errorNeedsFullDiskAccess = false } }
            )
        ) {
            if model.errorNeedsFullDiskAccess {
                Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                Button("Show Trash in Finder") { NSWorkspace.shared.open(model.trash) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
