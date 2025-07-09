import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Restore window frame if saved
        if let window = NSApplication.shared.windows.first {
            if let frameString = UserDefaults.standard.string(forKey: "MainWindowFrame"),
               let frame = NSRectFromString(frameString) as NSRect? {
                window.setFrame(frame, display: true)
            }
            
            // Observe window frame changes to save them
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidMove(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Save window frame on quit
        saveWindowFrame()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    @objc private func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }
    
    @objc private func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }
    
    private func saveWindowFrame() {
        if let window = NSApplication.shared.windows.first {
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "MainWindowFrame")
        }
    }
}