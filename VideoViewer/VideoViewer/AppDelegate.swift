import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var saveWindowFrameTimer: Timer?
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Delay window frame restoration to ensure SwiftUI has created the window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupWindowFrameRestoration()
        }
    }
    
    private func setupWindowFrameRestoration() {
        // Find the main window
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            // Try again after a short delay if window isn't ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.setupWindowFrameRestoration()
            }
            return
        }
        
        // Restore window frame if saved
        if let frameString = UserDefaults.standard.string(forKey: "MainWindowFrame"),
           let frame = NSRectFromString(frameString) as NSRect? {
            // Ensure the frame is valid and on screen
            let screenFrame = NSScreen.main?.frame ?? NSRect.zero
            if screenFrame.intersects(frame) {
                window.setFrame(frame, display: true, animate: false)
                print("Restored window frame: \(frame)")
            }
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
        debouncedSaveWindowFrame()
    }
    
    @objc private func windowDidMove(_ notification: Notification) {
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