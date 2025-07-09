import Foundation
import AppKit

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var databaseDirectory: URL?
    @Published var isFirstRun: Bool = true
    @Published var useLocalDatabaseCache: Bool = false
    
    private let userDefaults = UserDefaults.standard
    private let databaseDirectoryKey = "customDatabaseDirectory"
    private let databaseBookmarkKey = "customDatabaseDirectoryBookmark"
    private let firstRunKey = "hasCompletedFirstRun"
    
    private init() {
        loadSettings()
    }
    
    private func loadSettings() {
        isFirstRun = !userDefaults.bool(forKey: firstRunKey)
        
        // Try to restore database directory from bookmark
        if let bookmarkData = userDefaults.data(forKey: databaseBookmarkKey) {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                
                if !isStale && url.startAccessingSecurityScopedResource() {
                    databaseDirectory = url
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
    }
    
    func setDatabaseDirectory(_ url: URL) {
        // Save security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
            userDefaults.set(bookmarkData, forKey: databaseBookmarkKey)
            userDefaults.set(url.path, forKey: databaseDirectoryKey)
            databaseDirectory = url
        } catch {
            print("Failed to create bookmark: \(error)")
        }
    }
    
    func completeFirstRun() {
        userDefaults.set(true, forKey: firstRunKey)
        isFirstRun = false
    }
    
    func getDatabasePath() -> URL {
        if let customPath = databaseDirectory {
            return customPath.appendingPathComponent("VideoViewer").appendingPathComponent("image_data.db")
        } else {
            // Default to Application Support
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("VideoViewer").appendingPathComponent("image_data.db")
        }
    }
    
    func getCleanupRulesPath() -> URL {
        if let customPath = databaseDirectory {
            return customPath.appendingPathComponent("VideoViewer").appendingPathComponent("cleanup_rules.db")
        } else {
            // Default to home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            return homeDir.appendingPathComponent(".VideoViewer").appendingPathComponent("cleanup_rules.db")
        }
    }
    
    func showFirstRunDialog(completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Welcome to Video Library Manager"
        alert.informativeText = "Would you like to choose a custom location for storing your database and settings? This allows you to share them across multiple machines via network drive."
        alert.addButton(withTitle: "Choose Location")
        alert.addButton(withTitle: "Use Default")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            showDatabaseDirectoryPicker { [weak self] in
                self?.completeFirstRun()
                completion()
            }
        } else {
            completeFirstRun()
            completion()
        }
    }
    
    func showDatabaseDirectoryPicker(completion: @escaping () -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.message = "Choose a directory to store the VideoViewer database and settings"
        openPanel.prompt = "Select"
        
        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            completion()
            return
        }
        
        setDatabaseDirectory(url)
        
        // Create VideoViewer subdirectory if needed
        let videoViewerDir = url.appendingPathComponent("VideoViewer")
        try? FileManager.default.createDirectory(at: videoViewerDir, withIntermediateDirectories: true, attributes: nil)
        
        completion()
    }
}