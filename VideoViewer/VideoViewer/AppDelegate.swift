import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var saveWindowFrameTimer: Timer?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set up window frame saving for all windows
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: nil
        )
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
        guard let window = notification.object as? NSWindow,
              window.isVisible && window.title.contains("Video") else { return }
        debouncedSaveWindowFrame()
    }
    
    @objc private func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.isVisible && window.title.contains("Video") else { return }
        debouncedSaveWindowFrame()
    }
    
    private func debouncedSaveWindowFrame() {
        // Cancel any existing timer
        saveWindowFrameTimer?.invalidate()
        
        // Create a new timer to save after 0.5 seconds of inactivity
        saveWindowFrameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            self.saveWindowFrame()
        }
    }
    
    private func saveWindowFrame() {
        if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "MainWindowFrame")
            UserDefaults.standard.synchronize()
            print("Saved window frame: \(window.frame)")
        }
    }
}