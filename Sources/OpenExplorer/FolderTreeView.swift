import AppKit
import SwiftUI

/// A node of the left-hand folder tree. Children are loaded lazily on first expansion.
@MainActor
final class FolderNode: NSObject {
    enum Kind { case folder, home, computer, volume, trash }

    let url: URL
    let kind: Kind
    var title: String
    var children: [FolderNode]?

    init(url: URL, kind: Kind = .folder, title: String? = nil) {
        self.url = url
        self.kind = kind
        self.title = title ?? url.lastPathComponent
    }

    func icon(expanded: Bool) -> NSImage {
        switch kind {
        case .computer:
            return Self.sized(NSImage(named: NSImage.computerName) ?? IconCache.icon(for: url))
        case .trash:
            let isEmpty = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                .allSatisfy { $0 == ".DS_Store" }
            return Self.sized(NSImage(named: isEmpty ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage())
        case .home, .volume:
            return IconCache.systemIcon(for: url)
        case .folder:
            return IconCache.icon(for: url, isFolder: true, expanded: expanded)
        }
    }

    private static func sized(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    func loadChildren(showHidden: Bool) {
        let existing = Dictionary((children ?? []).map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        children = FileSystem.listFolders(in: url, showHidden: showHidden).map {
            existing[$0.path] ?? FolderNode(url: $0)
        }
    }

    /// Re-reads every branch that was already loaded, keeping node identity (and expansion) where possible.
    func reloadLoadedBranches(showHidden: Bool) {
        guard children != nil else { return }
        loadChildren(showHidden: showHidden)
        children?.forEach { $0.reloadLoadedBranches(showHidden: showHidden) }
    }

    /// Path components from this node down to `path`, or nil if `path` is not inside this node.
    func components(to path: String) -> [String]? {
        let base = url.path
        if path == base { return [] }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}

final class FolderOutlineView: NSOutlineView {}

/// Tree cell: icon + name, plus an eject button for volumes.
final class FolderCellView: NSTableCellView {
    let ejectButton: NSButton = {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Eject"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(image)
        addSubview(text)
        addSubview(ejectButton)
        imageView = image
        textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
            ejectButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct FolderTreeView: NSViewRepresentable {
    @EnvironmentObject var model: ExplorerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FolderOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        menu.autoenablesItems = false
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        context.coordinator.outlineView = outline
        context.coordinator.rebuildRoots()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: ExplorerModel
        weak var outlineView: NSOutlineView?

        private let homeNode: FolderNode
        private let computerNode: FolderNode
        private let trashNode: FolderNode
        private(set) var roots: [FolderNode] = []

        private var isSyncing = false
        private var lastPath: String?
        private var lastReloadID = 0
        private var lastRevealID = 0
        private var lastVolumes: [VolumeInfo] = []
        private var lastIconTheme: FileIconTheme?
        private var appearanceObservation: NSKeyValueObservation?

        init(model: ExplorerModel) {
            self.model = model
            homeNode = FolderNode(url: model.home, kind: .home, title: "Home")
            computerNode = FolderNode(url: model.computer, kind: .computer, title: "This Mac")
            trashNode = FolderNode(url: model.trash, kind: .trash, title: "Trash")
            super.init()
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshIcons() }
            }
        }

        private func children(of node: FolderNode) -> [FolderNode] {
            if node.children == nil { node.loadChildren(showHidden: model.showHidden) }
            return node.children ?? []
        }

        /// Top level: Home, This Mac, mounted volumes, Trash.
        func rebuildRoots() {
            let existing = Dictionary(roots.filter { $0.kind == .volume }.map { ($0.url.path, $0) },
                                      uniquingKeysWith: { first, _ in first })
            let volumeNodes = model.volumes.map { volume -> FolderNode in
                let node = existing[volume.url.path] ?? FolderNode(url: volume.url, kind: .volume)
                node.title = volume.name
                return node
            }
            lastVolumes = model.volumes
            roots = [homeNode, computerNode] + volumeNodes + [trashNode]

            guard let outline = outlineView else { return }
            isSyncing = true
            let expanded = roots.filter { outline.isItemExpanded($0) }
            outline.reloadData()
            expanded.forEach { outline.expandItem($0) }
            if roots.allSatisfy({ !outline.isItemExpanded($0) }) { outline.expandItem(homeNode) }
            isSyncing = false
        }

        // MARK: Sync with the model (right panel navigation walks the tree)

        func sync() {
            if model.fileIconTheme != lastIconTheme {
                if lastIconTheme != nil { refreshIcons() }
                lastIconTheme = model.fileIconTheme
            }
            var needsReveal = false
            if model.volumes != lastVolumes {
                rebuildRoots()
                needsReveal = true
            }
            if model.treeReload.id != lastReloadID {
                lastReloadID = model.treeReload.id
                applyReload(model.treeReload)
                needsReveal = true
            }
            if needsReveal || model.currentURL.path != lastPath || model.revealID != lastRevealID {
                lastPath = model.currentURL.path
                lastRevealID = model.revealID
                reveal(model.currentURL)
            }
        }

        private func applyReload(_ request: TreeReloadRequest) {
            guard let outline = outlineView else { return }
            isSyncing = true
            defer { isSyncing = false }
            if let path = request.path {
                // The same folder can appear under several roots (e.g. Home and This Mac › Users).
                for node in loadedNodes(forPath: path) where node.children != nil {
                    node.loadChildren(showHidden: model.showHidden)
                    outline.reloadItem(node, reloadChildren: true)
                }
            } else {
                for root in roots {
                    root.reloadLoadedBranches(showHidden: model.showHidden)
                    outline.reloadItem(root, reloadChildren: true)
                }
            }
        }

        /// Already-loaded nodes for `path`, without touching the disk.
        private func loadedNodes(forPath path: String) -> [FolderNode] {
            roots.compactMap { root in
                guard let components = root.components(to: path) else { return nil }
                var node = root
                for name in components {
                    guard let next = node.children?.first(where: { $0.url.lastPathComponent == name }) else { return nil }
                    node = next
                }
                return node
            }
        }

        /// The most specific root containing `path` (Trash beats Home, Home beats This Mac, ...).
        private func bestRoot(for path: String) -> (FolderNode, [String])? {
            roots
                .compactMap { root in root.components(to: path).map { (root, $0) } }
                .max { $0.0.url.path.count < $1.0.url.path.count }
        }

        /// Expands the tree down to `url` and selects it.
        private func reveal(_ url: URL) {
            guard let outline = outlineView else { return }
            isSyncing = true
            defer { isSyncing = false }

            var target: FolderNode?
            if let (root, components) = bestRoot(for: url.path) {
                var node = root
                var found = true
                for name in components {
                    outline.expandItem(node)
                    guard let next = children(of: node).first(where: { $0.url.lastPathComponent == name }) else {
                        found = false
                        break
                    }
                    node = next
                }
                target = found ? node : nil
            }

            if let target, case let row = outline.row(forItem: target), row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FolderNode else { return roots.count }
            return children(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FolderNode else { return roots[index] }
            return children(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FolderNode else { return false }
            // Optimistic until loaded, so we don't touch every folder's contents up front.
            return node.children.map { !$0.isEmpty } ?? true
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FolderNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FolderCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FolderCellView)
                ?? FolderCellView(identifier: identifier)
            cell.textField?.stringValue = node.title
            cell.imageView?.image = node.icon(expanded: outlineView.isItemExpanded(node))
            cell.toolTip = node.url.path
            cell.ejectButton.isHidden = node.kind != .volume
            cell.ejectButton.target = self
            cell.ejectButton.action = #selector(ejectClicked(_:))
            return cell
        }

        @objc private func ejectClicked(_ sender: NSButton) {
            guard let outline = outlineView, case let row = outline.row(for: sender), row >= 0,
                  let node = outline.item(atRow: row) as? FolderNode else { return }
            model.eject(node.url)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline = outlineView, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
            lastPath = node.url.path  // avoid re-revealing what the user just clicked
            model.navigate(to: node.url)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
            updateIcon(of: node)  // open-folder icon
            // Remove the disclosure arrow from folders that turned out to be empty.
            guard node.children?.isEmpty == true else { return }
            DispatchQueue.main.async { [weak self] in
                self?.outlineView?.reloadItem(node)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
            updateIcon(of: node)
        }

        private func updateIcon(of node: FolderNode) {
            guard let outline = outlineView, case let row = outline.row(forItem: node), row >= 0,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
            cell.imageView?.image = node.icon(expanded: outline.isItemExpanded(node))
        }

        /// Redraws every visible icon (icon theme or light/dark appearance changed).
        func refreshIcons() {
            guard let outline = outlineView else { return }
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? FolderNode { updateIcon(of: node) }
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline = outlineView, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? FolderNode else { return }
            let url = node.url
            let model = self.model

            if node.kind == .volume {
                menu.addItem(ActionMenuItem("Eject “\(node.title)”") { model.eject(url) })
                menu.addItem(.separator())
            }
            if node.kind == .trash {
                menu.addItem(ActionMenuItem("Open Trash in Finder") { NSWorkspace.shared.open(url) })
                menu.addItem(.separator())
            }
            menu.addItem(ActionMenuItem("Open in Terminal") { model.openInTerminal(url) })
            menu.addItem(ActionMenuItem("Copy Path") { model.copyPaths([url]) })
            menu.addItem(.separator())
            if node.kind == .folder {
                menu.addItem(ActionMenuItem("Cut") { model.cut([url]) })
            }
            menu.addItem(ActionMenuItem("Copy") { model.copy([url]) })
            let paste = ActionMenuItem("Paste") { model.paste(into: url) }
            paste.isEnabled = model.canPaste
            menu.addItem(paste)
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("New File…") { model.promptNewItem(.file, in: url) })
            menu.addItem(ActionMenuItem("New Folder…") { model.promptNewItem(.folder, in: url) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Show in Finder") { model.revealInFinder([url]) })
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
