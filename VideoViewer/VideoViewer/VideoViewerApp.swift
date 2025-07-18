import SwiftUI

@main
struct VideoViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var showingSettings = false
    @State private var hasShownFirstRun = false
    @State private var showStartupProgress = true
    @State private var startupComplete = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .restoreWindowFrame()
                .onAppear {
                    if settingsManager.isFirstRun && !hasShownFirstRun {
                        hasShownFirstRun = true
                        settingsManager.showFirstRunDialog {}
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
                .sheet(isPresented: $showStartupProgress) {
                    StartupProgressView {
                        startupComplete = true
                        showStartupProgress = false
                    }
                    .frame(width: 600, height: 400)
                    .interactiveDismissDisabled()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    showingSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
                
                Divider()
                
                Button("Backup Settings...") {
                    BackupRestoreManager.shared.showBackupDialog()
                }
                .keyboardShortcut("B", modifiers: [.command, .shift])
                
                Button("Restore Settings...") {
                    BackupRestoreManager.shared.showRestoreDialog()
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                
                Divider()
            }
        }
    }
}