import SwiftUI
import AppKit

// Helper to access the NSWindow from SwiftUI
struct WindowAccessor: NSViewRepresentable {
    let onWindowFound: (NSWindow) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                self.onWindowFound(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                self.onWindowFound(window)
            }
        }
    }
}

// View modifier to restore window frame
struct WindowFrameRestorer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                WindowAccessor { window in
                    // Only restore frame once when window is first found
                    if window.isVisible {
                        restoreWindowFrame(for: window)
                    }
                }
                .frame(width: 0, height: 0)
                .opacity(0)
            )
    }
    
    private func restoreWindowFrame(for window: NSWindow) {
        // Check if we've already restored for this window
        let restoredKey = "WindowFrameRestored_\(window.hash)"
        if UserDefaults.standard.bool(forKey: restoredKey) {
            return
        }
        
        // Mark as restored
        UserDefaults.standard.set(true, forKey: restoredKey)
        
        // Restore the frame
        if let frameString = UserDefaults.standard.string(forKey: "MainWindowFrame"),
           let frame = NSRectFromString(frameString) as NSRect? {
            // Ensure the frame is valid and on screen
            var adjustedFrame = frame
            var foundValidScreen = false
            
            for screen in NSScreen.screens {
                if screen.frame.intersects(frame) {
                    foundValidScreen = true
                    break
                }
            }
            
            // If not on any screen, center on main screen
            if !foundValidScreen, let mainScreen = NSScreen.main {
                adjustedFrame.origin = CGPoint(
                    x: (mainScreen.frame.width - frame.width) / 2,
                    y: (mainScreen.frame.height - frame.height) / 2
                )
            }
            
            // Apply the frame
            window.setFrame(adjustedFrame, display: false, animate: false)
            print("✅ Restored window frame: \(adjustedFrame)")
        } else {
            print("⚠️ No saved window frame found")
        }
        
        // Clean up the restoration flag when app terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            UserDefaults.standard.removeObject(forKey: restoredKey)
        }
    }
}

extension View {
    func restoreWindowFrame() -> some View {
        self.modifier(WindowFrameRestorer())
    }
}