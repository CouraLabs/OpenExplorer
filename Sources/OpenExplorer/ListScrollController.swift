import AppKit
import Combine

extension NSTableView {
    /// Scrolls so `row` sits in the vertical middle of the visible area (clamped at the top and bottom).
    func scrollRowToCenter(_ row: Int) {
        guard row >= 0, row < numberOfRows, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let insets = clip.contentInsets  // header / toolbar overlap
        let visibleHeight = clip.bounds.height - insets.top - insets.bottom
        let rowRect = rect(ofRow: row)
        setScrollOffset(rowRect.midY - insets.top - visibleHeight / 2)
    }

    /// Vertical scroll position (document coordinates of the top of the visible content).
    var scrollOffset: CGFloat {
        guard let clip = enclosingScrollView?.contentView else { return 0 }
        return clip.bounds.origin.y + clip.contentInsets.top
    }

    func setScrollOffset(_ offset: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let minY = -insets.top
        let maxY = max(minY, frame.height - clip.bounds.height + insets.bottom)
        let y = min(max(offset - insets.top, minY), maxY)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Scroll behaviour of the right-hand file list:
/// - remembers scroll position and selection per folder, restoring them on Back/Forward/Up/tree navigation;
/// - keeps the selected row centred when the selection moves by keyboard or programmatically
///   (mouse clicks are left alone so double-clicks don't land on a different row).
@MainActor
final class ListScrollController {
    static let shared = ListScrollController()

    private struct SavedState {
        let offset: CGFloat
        let selection: Set<URL>
    }

    private weak var model: ExplorerModel?
    private weak var cachedTable: NSTableView?
    private var saved: [String: SavedState] = [:]
    private var savedOrder: [String] = []
    private var cancellables = Set<AnyCancellable>()
    private var isRestoring = false
    private var pendingCenter = false
    private static let maxSavedFolders = 300

    func attach(_ model: ExplorerModel) {
        guard self.model == nil else { return }
        self.model = model

        // @Published fires *before* the new value is stored, so the model still describes the old folder here.
        model.$currentURL
            .sink { [weak self] newURL in self?.folderWillChange(to: newURL) }
            .store(in: &cancellables)

        model.$selection
            .sink { [weak self] _ in self?.selectionWillChange() }
            .store(in: &cancellables)

        // Re-sorting moves the selected rows: keep them centred.
        model.$sortOrder
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleCenter() }
            .store(in: &cancellables)
    }

    // MARK: Folder changes

    private func folderWillChange(to newURL: URL) {
        guard let model, newURL.path != model.currentURL.path else { return }
        if let table = fileTable(), !model.isSearchActive {
            remember(model.currentURL.path, SavedState(offset: table.scrollOffset, selection: model.selection))
        }
        let path = newURL.path
        afterTableUpdates { [weak self] table in
            self?.restore(path, in: table)
        }
    }

    private func restore(_ path: String, in table: NSTableView) {
        guard let model, model.currentURL.path == path else { return }
        if !model.selection.isEmpty {
            // e.g. "Up" selected the folder we came from.
            centerSelection(in: table)
        } else if let state = saved[path] {
            let ids = Set(model.items.map(\.id))
            isRestoring = true
            model.selection = state.selection.intersection(ids)
            isRestoring = false
            table.setScrollOffset(state.offset)
        } else {
            table.setScrollOffset(0)  // a folder we haven't visited starts at the top
        }
    }

    private func remember(_ path: String, _ state: SavedState) {
        saved[path] = state
        savedOrder.removeAll { $0 == path }
        savedOrder.append(path)
        if savedOrder.count > Self.maxSavedFolders {
            saved.removeValue(forKey: savedOrder.removeFirst())
        }
    }

    // MARK: Selection centring

    private func selectionWillChange() {
        guard !isRestoring else { return }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown:
            return  // clicked rows stay under the pointer
        default:
            scheduleCenter()
        }
    }

    private func scheduleCenter() {
        guard !pendingCenter else { return }
        pendingCenter = true
        afterTableUpdates { [weak self] table in
            self?.pendingCenter = false
            self?.centerSelection(in: table)
        }
    }

    private func centerSelection(in table: NSTableView) {
        guard let model, !model.selection.isEmpty else { return }
        // Prefer the row the keyboard just moved to; otherwise the first selected row.
        let row: Int
        if table.selectedRow >= 0, table.selectedRow < model.items.count,
           model.selection.contains(model.items[table.selectedRow].id) {
            row = table.selectedRow
        } else if let index = model.items.firstIndex(where: { model.selection.contains($0.id) }) {
            row = index
        } else {
            return
        }
        table.scrollRowToCenter(row)
    }

    // MARK: Helpers

    /// Runs `body` once SwiftUI has pushed the model's rows into the table.
    private func afterTableUpdates(attempt: Int = 0, _ body: @escaping (NSTableView) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model, let table = self.fileTable() else { return }
            if table.numberOfRows == model.items.count || attempt >= 20 {
                body(table)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self.afterTableUpdates(attempt: attempt + 1, body)
                }
            }
        }
    }

    /// The NSTableView behind the SwiftUI Table (the only table in the window that isn't the folder tree).
    private func fileTable() -> NSTableView? {
        if let table = cachedTable, table.window != nil { return table }
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
        cachedTable = window?.contentView.flatMap(findTable)
        return cachedTable
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !(table is FolderOutlineView) { return table }
        for subview in view.subviews {
            if let found = findTable(in: subview) { return found }
        }
        return nil
    }
}
