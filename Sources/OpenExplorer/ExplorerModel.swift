import AppKit
import Quartz
import SwiftUI

enum NewItemKind { case file, folder }

struct NamePrompt: Identifiable {
    let id = UUID()
    let kind: NewItemKind
    let directory: URL
    let suggestedName: String
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, modified, created, kind, size
    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .kind: "Kind"
        case .size: "Size"
        }
    }

    var keyPath: PartialKeyPath<FileItem> {
        switch self {
        case .name: \FileItem.name
        case .modified: \FileItem.modified
        case .created: \FileItem.created
        case .kind: \FileItem.kind
        case .size: \FileItem.sizeSortKey
        }
    }

    func comparator(_ order: SortOrder) -> KeyPathComparator<FileItem> {
        switch self {
        case .name: KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)
        case .modified: KeyPathComparator(\FileItem.modified, order: order)
        case .created: KeyPathComparator(\FileItem.created, order: order)
        case .kind: KeyPathComparator(\FileItem.kind, comparator: .localizedStandard, order: order)
        case .size: KeyPathComparator(\FileItem.sizeSortKey, order: order)
        }
    }
}

/// A mounted, browsable volume other than the startup disk (disk images, ISOs, USB drives, ...).
struct VolumeInfo: Equatable {
    let url: URL
    let name: String
}

/// Asks the folder tree to re-read folders from disk. `path == nil` means "everything loaded".
struct TreeReloadRequest: Equatable {
    var id = 0
    var path: String?
}

@MainActor
final class ExplorerModel: ObservableObject {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let computer = URL(fileURLWithPath: "/", isDirectory: true)
    let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".Trash", isDirectory: true)

    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [SortKey.name.comparator(.forward)] {
        didSet { updateItems() }
    }
    @Published var showHidden: Bool {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            reload()
            requestTreeReload(path: nil)
            if isSearchActive { scheduleSearch() }
        }
    }
    @Published var fileIconTheme = FileIconTheme.current {
        didSet { FileIconTheme.current = fileIconTheme }
    }
    @Published private(set) var treeReload = TreeReloadRequest()
    /// Bumped when the tree should re-select the current folder even though it did not change.
    @Published private(set) var revealID = 0
    @Published var errorMessage: String?
    /// The last error was macOS blocking the Trash; the alert offers a Full Disk Access shortcut.
    @Published var errorNeedsFullDiskAccess = false
    @Published private(set) var volumes: [VolumeInfo] = []

    // Search (results replace the list while the query is non-empty)
    @Published var search = SearchOptions() {
        didSet { if search != oldValue && !isResettingSearch { scheduleSearch() } }
    }
    @Published private(set) var isSearchRunning = false
    @Published private(set) var searchStatus: String?
    /// Bumped by ⌘F to focus the search field.
    @Published private(set) var focusSearchID = 0
    private var folderItems: [FileItem] = []
    private var searchResults: [FileItem] = []
    private var searchToken: SearchToken?
    private var searchDebounce: DispatchWorkItem?
    private var isResettingSearch = false
    @Published var namePrompt: NamePrompt?
    @Published private(set) var cutPaths: Set<String> = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var backStack: [URL] = [] { didSet { canGoBack = !backStack.isEmpty } }
    private var forwardStack: [URL] = [] { didSet { canGoForward = !forwardStack.isEmpty } }
    private var cutChangeCount: Int?
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    private var mountObservers: [NSObjectProtocol] = []

    init() {
        showHidden = UserDefaults.standard.bool(forKey: "showHidden")
        currentURL = home
        reload()
        watchCurrentFolder()
        refreshVolumes()
        observeMounts()
    }

    // MARK: - Display helpers

    var title: String {
        if currentURL.path == home.path { return "Home" }
        if currentURL.path == "/" { return "This Mac" }
        if currentURL.path == trash.path { return "Trash" }
        if let volume = volumes.first(where: { $0.url.path == currentURL.path }) { return volume.name }
        return currentURL.lastPathComponent
    }

    var windowTitle: String {
        isSearchActive ? "Search Results in \(title)" : title
    }

    var canGoUp: Bool { currentURL.path != "/" }

    var sortKey: SortKey {
        SortKey.allCases.first { $0.keyPath == sortOrder.first?.keyPath } ?? .name
    }

    var sortAscending: Bool { (sortOrder.first?.order ?? .forward) == .forward }

    func setSort(_ key: SortKey, ascending: Bool) {
        sortOrder = [key.comparator(ascending ? .forward : .reverse)]
    }

    func isCut(_ item: FileItem) -> Bool {
        cutChangeCount == NSPasteboard.general.changeCount && cutPaths.contains(item.url.path)
    }

    var selectedURLs: [URL] {
        items.filter { selection.contains($0.id) }.map(\.url)
    }

    // MARK: - Navigation

    func navigate(to url: URL, addToHistory: Bool = true, select childPath: String? = nil) {
        let target = URL(fileURLWithPath: (url.path as NSString).standardizingPath, isDirectory: true)
        guard target.path != currentURL.path else {
            revealID += 1
            return
        }
        let list: [FileItem]
        do {
            list = try FileSystem.listItems(in: target, showHidden: showHidden)
        } catch {
            if target.path == trash.path {
                errorMessage = "macOS only lets apps read the Trash with Full Disk Access.\n\nTurn on Open Explorer in System Settings › Privacy & Security › Full Disk Access, then reopen the app."
                errorNeedsFullDiskAccess = true
            } else {
                errorMessage = "Can’t open “\(target.lastPathComponent)”.\n\(error.localizedDescription)"
            }
            revealID += 1  // put the tree selection back where it was
            return
        }
        if addToHistory {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = target
        folderItems = list
        resetSearch()
        updateItems()
        selection = Set(items.filter { $0.url.path == childPath }.map(\.id))
        watchCurrentFolder()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        navigate(to: previous, addToHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        navigate(to: next, addToHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = currentURL.path
        navigate(to: currentURL.deletingLastPathComponent(), select: child)
    }

    /// Handles text typed into the address bar.
    func goToPath(_ text: String) {
        let path = (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            errorMessage = "Can’t find “\(text)”. Check the spelling and try again."
            revealID += 1
            return
        }
        let url = URL(fileURLWithPath: path)
        if FileSystem.isFolder(url) {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent(), select: url.path)
        }
    }

    /// Double-click / Return: enter a folder, or open files with their default app.
    func open(_ urls: [URL]) {
        if urls.count == 1, FileSystem.isFolder(urls[0]) {
            navigate(to: urls[0])
            return
        }
        for url in urls where !FileSystem.isFolder(url) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Loading

    func refresh() {
        reload()
        requestTreeReload(path: nil)
        if isSearchActive { scheduleSearch() }
    }

    func reload() {
        do {
            let list = try FileSystem.listItems(in: currentURL, showHidden: showHidden)
            folderItems = list
            if !isSearchActive {
                updateItems()
                selection = selection.intersection(list.map(\.id))
            }
        } catch {
            if !FileManager.default.fileExists(atPath: currentURL.path) {
                // Current folder was deleted or moved away: walk up to the nearest existing parent.
                var parent = currentURL.deletingLastPathComponent()
                while !FileManager.default.fileExists(atPath: parent.path) && parent.path != "/" {
                    parent = parent.deletingLastPathComponent()
                }
                navigate(to: parent, addToHistory: false)
                requestTreeReload(path: nil)
            } else {
                folderItems = []; updateItems()
                errorMessage = "Can’t read “\(currentURL.lastPathComponent)”.\n\(error.localizedDescription)"
            }
        }
    }

    private func updateItems() {
        items = sorted(isSearchActive ? searchResults : folderItems)
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        let ordered = list.sorted(using: sortOrder)
        // Windows Explorer style: folders always grouped before files.
        return ordered.filter(\.isFolder) + ordered.filter { !$0.isFolder }
    }

    private func requestTreeReload(path: String?) {
        treeReload = TreeReloadRequest(id: treeReload.id + 1, path: path)
    }

    private func watchCurrentFolder() {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(currentURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefreshFromDisk() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRefreshFromDisk() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                self.requestTreeReload(path: self.currentURL.path)
            }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Search

    var isSearchActive: Bool {
        !search.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func focusSearch() { focusSearchID += 1 }

    func clearSearch() {
        search.query = ""
    }

    /// Clears the query without triggering a new search (used when navigating).
    private func resetSearch() {
        searchDebounce?.cancel()
        searchToken?.cancel()
        searchToken = nil
        searchResults = []
        isSearchRunning = false
        searchStatus = nil
        if !search.query.isEmpty {
            isResettingSearch = true
            search.query = ""
            isResettingSearch = false
        }
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        searchToken?.cancel()
        searchToken = nil
        guard isSearchActive else {
            resetSearch()
            updateItems()
            return
        }
        isSearchRunning = true
        searchStatus = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startSearch() }
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startSearch() {
        let token = SearchToken()
        searchToken = token
        var options = search
        options.showHidden = showHidden
        if options.mode == .name { options.query = options.query.trimmingCharacters(in: .whitespaces) }
        searchResults = []
        selection = []
        isSearchRunning = true
        updateItems()

        SearchEngine.run(in: currentURL, options: options, token: token, deliver: { [weak self] batch in
            MainActor.assumeIsolated {
                guard let self, self.searchToken === token else { return }
                self.searchResults += batch
                self.updateItems()
            }
        }, finish: { [weak self] truncated, error in
            MainActor.assumeIsolated {
                guard let self, self.searchToken === token else { return }
                self.isSearchRunning = false
                if let error {
                    self.searchStatus = error
                } else if truncated {
                    self.searchStatus = "Showing the first \(SearchEngine.resultLimit) results"
                }
            }
        })
    }

    // MARK: - Volumes

    func refreshVolumes(excluding gone: String? = nil) {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let found: [VolumeInfo] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard url.path.hasPrefix("/Volumes/"), url.path != gone,
                  FileManager.default.fileExists(atPath: url.path),
                  values?.volumeIsRootFileSystem != true,
                  values?.volumeIsBrowsable != false else { return nil }
            return VolumeInfo(
                url: URL(fileURLWithPath: url.path, isDirectory: true),
                name: values?.volumeLocalizedName ?? url.lastPathComponent
            )
        }
        let sortedVolumes = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sortedVolumes != volumes { volumes = sortedVolumes }
    }

    func isVolume(_ url: URL) -> Bool {
        volumes.contains { $0.url.path == url.path }
    }

    /// Unmounts (and detaches, for disk images) a volume, like Finder's eject button.
    func eject(_ volumeURL: URL) {
        let path = volumeURL.path
        let name = volumes.first { $0.url.path == path }?.name ?? volumeURL.lastPathComponent
        // Release our own handles on the volume first, or the unmount fails with "in use".
        if currentURL.path == path || currentURL.path.hasPrefix(path + "/") {
            navigate(to: home, addToHistory: false)
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            } catch {
                await MainActor.run {
                    self.errorMessage = "Couldn’t eject “\(name)”.\n\(error.localizedDescription)"
                }
            }
        }
    }

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification,
        ]
        mountObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.volumesDidChange(note) }
            }
        }
    }

    private func volumesDidChange(_ note: Notification) {
        let unmounted = note.name == NSWorkspace.didUnmountNotification
            ? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            : nil
        // The mounted-volume list can lag behind the notification, so drop the unmounted volume
        // explicitly and check again shortly after.
        refreshVolumes(excluding: unmounted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.refreshVolumes(excluding: unmounted) }
        }
        if let path = unmounted {
            if currentURL.path == path || currentURL.path.hasPrefix(path + "/") {
                navigate(to: home, addToHistory: false)
            }
            backStack.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            forwardStack.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        }
        requestTreeReload(path: nil)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Context menu actions

    func openInTerminal(_ url: URL) {
        let directory = FileSystem.isFolder(url) ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            errorMessage = "Terminal.app was not found."
            return
        }
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        clearCutState()
    }

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeFileURLs(urls)
        clearCutState()
    }

    func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeFileURLs(urls)
        cutChangeCount = NSPasteboard.general.changeCount
        cutPaths = Set(urls.map(\.path))
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func paste(into directory: URL) {
        let pb = NSPasteboard.general
        guard let sources = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !sources.isEmpty else { return }
        let isMove = cutChangeCount == pb.changeCount
        if isMove {
            pb.clearContents()
            clearCutState()
        }
        let destinationDir = directory

        Task.detached(priority: .userInitiated) {
            let fm = FileManager()
            var errors: [String] = []
            var created: [String] = []
            for source in sources {
                let sourcePath = source.standardizedFileURL.path
                if destinationDir.path == sourcePath || destinationDir.path.hasPrefix(sourcePath + "/") {
                    errors.append("“\(source.lastPathComponent)”: can’t paste a folder into itself.")
                    continue
                }
                if isMove && source.deletingLastPathComponent().path == destinationDir.path { continue }
                let destination = isMove
                    ? destinationDir.appendingPathComponent(source.lastPathComponent)
                    : FileSystem.availableCopyURL(for: source.lastPathComponent, in: destinationDir)
                do {
                    if isMove {
                        if fm.fileExists(atPath: destination.path) {
                            errors.append("“\(source.lastPathComponent)” already exists in the destination.")
                            continue
                        }
                        try fm.moveItem(at: source, to: destination)
                    } else {
                        try fm.copyItem(at: source, to: destination)
                    }
                    created.append(destination.path)
                } catch {
                    errors.append("“\(source.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            await MainActor.run { [errors, created] in
                self.finishFileOperation(in: destinationDir, select: created, errors: errors, treeAll: isMove)
            }
        }
    }

    func promptNewItem(_ kind: NewItemKind, in directory: URL? = nil) {
        let dir = directory ?? currentURL
        let url = kind == .folder
            ? FileSystem.availableNewURL(stem: "New Folder", ext: "", in: dir)
            : FileSystem.availableNewURL(stem: "New File", ext: "txt", in: dir)
        namePrompt = NamePrompt(kind: kind, directory: dir, suggestedName: url.lastPathComponent)
    }

    func createItem(_ kind: NewItemKind, named rawName: String, in directory: URL) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            errorMessage = "“\(rawName)” is not a valid name."
            return
        }
        let url = directory.appendingPathComponent(name, isDirectory: kind == .folder)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "An item named “\(name)” already exists in this location."
            return
        }
        do {
            if kind == .folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                throw CocoaError(.fileWriteUnknown)
            }
            finishFileOperation(in: directory, select: [url.path], errors: [], treeAll: false)
        } catch {
            errorMessage = "Couldn’t create “\(name)”.\n\(error.localizedDescription)"
        }
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func moveToTrash(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
        }
        finishFileOperation(in: currentURL, select: [], errors: errors, treeAll: false)
    }

    private func finishFileOperation(in directory: URL, select paths: [String], errors: [String], treeAll: Bool) {
        if directory.path == currentURL.path {
            reload()
            if !paths.isEmpty {
                selection = Set(items.filter { paths.contains($0.url.path) }.map(\.id))
            }
        } else {
            reload()
        }
        requestTreeReload(path: treeAll ? nil : directory.path)
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    private func writeFileURLs(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    private func clearCutState() {
        cutChangeCount = nil
        cutPaths = []
    }
}
