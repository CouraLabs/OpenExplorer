import AppKit
import Combine
import Quartz

/// Finder-style Quick Look for the right-hand file list.
///
/// - Space (while the list has focus) toggles the preview panel.
/// - The list stays key, so arrow keys keep moving the selection and the preview follows it.
/// - The controller is inserted into the window's responder chain so `QLPreviewPanel` can find it.
@MainActor
final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private weak var model: ExplorerModel?
    private weak var tableView: NSTableView?
    private var keyMonitor: Any?
    private var selectionObserver: AnyCancellable?
    private var previewURLs: [URL] = []
    private var isControlling = false

    func attach(_ model: ExplorerModel) {
        guard self.model == nil else { return }
        self.model = model

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) } ? nil : event
        }

        // @Published emits before the value is stored, so read the model on the next run loop pass.
        selectionObserver = model.$selection.sink { [weak self] _ in
            DispatchQueue.main.async { self?.selectionDidChange() }
        }
    }

    private var panelIsOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    // MARK: Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard event.keyCode == 49 /* space */, modifiers.isEmpty else { return false }

        if panelIsOpen && isControlling {
            QLPreviewPanel.shared().orderOut(nil)
            return true
        }
        guard let window = event.window,
              let table = window.firstResponder as? NSTableView,
              !(table is FolderOutlineView) else { return false }
        tableView = table
        return open(in: window)
    }

    /// Opens the preview for the current selection. Returns false if there is nothing to preview.
    @discardableResult
    func open(in window: NSWindow?) -> Bool {
        guard let window, let model, !model.selectedURLs.isEmpty else { return false }
        installInResponderChain(of: window)
        previewURLs = model.selectedURLs
        let panel = QLPreviewPanel.shared()!
        panel.updateController()
        panel.orderFront(nil)  // don't steal key status: arrows keep driving the list
        panel.reloadData()
        return true
    }

    func toggle(in window: NSWindow?) {
        if panelIsOpen && isControlling {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            open(in: window)
        }
    }

    private func installInResponderChain(of window: NSWindow) {
        var responder: NSResponder? = window
        while let current = responder {
            if current === self { return }
            responder = current.nextResponder
        }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    private func selectionDidChange() {
        guard isControlling, panelIsOpen, let model else { return }
        let urls = model.selectedURLs
        guard !urls.isEmpty else {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard urls != previewURLs else { return }
        previewURLs = urls
        let panel = QLPreviewPanel.shared()!
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    // MARK: QLPreviewPanelController (informal protocol)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        isControlling = true
        panel.dataSource = self
        panel.delegate = self
        previewURLs = model?.selectedURLs ?? []
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        isControlling = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
        }
    }

    // MARK: QLPreviewPanelDelegate

    /// If the panel becomes key (e.g. the user clicked it), keep arrow keys moving the list selection.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, let table = tableView else { return false }
            switch event.keyCode {
            case 123, 124, 125, 126:  // ← → ↓ ↑
                table.keyDown(with: event)
                return true
            default:
                return false
            }
        }
    }

    /// Zoom the panel in/out of the row's icon, like Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard let url = item.previewItemURL, let model, let table = tableView, let window = table.window,
                  let row = model.items.firstIndex(where: { $0.url == url }), row < table.numberOfRows else {
                return .zero
            }
            let rowRect = table.rect(ofRow: row)
            guard table.visibleRect.intersects(rowRect) else { return .zero }
            let iconRect = NSRect(x: rowRect.minX + 8, y: rowRect.midY - 8, width: 16, height: 16)
            return window.convertToScreen(table.convert(iconRect, to: nil))
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated {
            guard let url = item.previewItemURL else { return nil }
            return IconCache.icon(for: url)
        }
    }
}
