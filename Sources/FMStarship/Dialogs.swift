import AppKit

/// Alerts as sheets on whichever window asked, so that they work from profile and compare windows as well.
@MainActor
enum Dialogs {
    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// Save and open panels, as a sheet when there is a window to hang them on.
    static func present(_ panel: NSSavePanel, then: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { then(url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    static func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert) { _ in }
    }

    static func confirm(_ title: String, _ message: String, yes: String = "Yes", no: String = "No", then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        present(alert) { response in
            if response == .alertFirstButtonReturn { then() }
        }
    }

    static func ask(_ title: String, _ message: String, initial: String, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert) { response in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !text.isEmpty { then(text) }
        }
    }
}
