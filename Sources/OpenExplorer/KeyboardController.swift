import AppKit

/// Windows Explorer–style keys that menus can't express safely (they must not fire while typing in a text field).
/// Only active when the file list or the folder tree has keyboard focus.
@MainActor
final class KeyboardController {
    static let shared = KeyboardController()

    private weak var model: ExplorerModel?
    private var monitor: Any?

    func attach(_ model: ExplorerModel) {
        guard self.model == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    private enum Key {
        static let f2: UInt16 = 120, f5: UInt16 = 96
        static let backspace: UInt16 = 51, forwardDelete: UInt16 = 117
        static let left: UInt16 = 123, right: UInt16 = 124, up: UInt16 = 126
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, let responder = event.window?.firstResponder,
              !(responder is NSText),                    // typing in the address/search field
              responder is NSTableView else { return false }  // the file list or the folder tree
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        switch (event.keyCode, modifiers) {
        case (Key.f2, []):                       // Rename
            model.promptRename(model.commandTargets.first)
        case (Key.f5, []):                       // Refresh
            model.refresh()
        case (Key.forwardDelete, []):            // Delete (fn-⌫ on laptops): move to Trash
            let targets = model.commandTargets
            guard !targets.isEmpty else { return false }
            model.moveToTrash(targets)
        case (Key.backspace, []):                // Backspace: back
            model.goBack()
        case (Key.left, [.option]):              // Alt+← / Alt+→ / Alt+↑
            model.goBack()
        case (Key.right, [.option]):
            model.goForward()
        case (Key.up, [.option]):
            model.goUp()
        default:
            return false
        }
        return true
    }
}
