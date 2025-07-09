import Foundation
import AppKit

class BackupRestoreManager {
    static let shared = BackupRestoreManager()
    
    private init() {}
    
    struct BackupContent: Codable {
        let version: Int
        let date: Date
        let databases: [String: Data]
        let userDefaults: [String: Any]
        
        enum CodingKeys: String, CodingKey {
            case version, date, databases, userDefaults
        }
        
        init(version: Int, date: Date, databases: [String: Data], userDefaults: [String: Any]) {
            self.version = version
            self.date = date
            self.databases = databases
            self.userDefaults = userDefaults
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            date = try container.decode(Date.self, forKey: .date)
            databases = try container.decode([String: Data].self, forKey: .databases)
            
            let userDefaultsData = try container.decode(Data.self, forKey: .userDefaults)
            userDefaults = try JSONSerialization.jsonObject(with: userDefaultsData) as? [String: Any] ?? [:]
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(date, forKey: .date)
            try container.encode(databases, forKey: .databases)
            
            let userDefaultsData = try JSONSerialization.data(withJSONObject: userDefaults)
            try container.encode(userDefaultsData, forKey: .userDefaults)
        }
    }
    
    func createBackup() throws -> URL {
        let fileManager = FileManager.default
        
        // Collect all databases
        var databases: [String: Data] = [:]
        
        // Main category database - use configurable path
        let dbPath = SettingsManager.shared.getDatabasePath()
        if fileManager.fileExists(atPath: dbPath.path) {
            databases["image_data.db"] = try Data(contentsOf: dbPath)
        }
        
        // Video metadata database
        let metadataDbPath = dbPath.deletingLastPathComponent().appendingPathComponent("video_metadata.db")
        if fileManager.fileExists(atPath: metadataDbPath.path) {
            databases["video_metadata.db"] = try Data(contentsOf: metadataDbPath)
            print("✅ Backing up video metadata database")
        }
        
        // Cleanup rules database - use configurable path
        let cleanupDbPath = SettingsManager.shared.getCleanupRulesPath()
        if fileManager.fileExists(atPath: cleanupDbPath.path) {
            databases["cleanup_rules.db"] = try Data(contentsOf: cleanupDbPath)
        }
        
        // Collect relevant UserDefaults
        let defaults = UserDefaults.standard
        let keysToBackup = [
            "isGridView",
            "thumbnailSize",
            "videoWindowFrame",
            "lastVideoVolume",
            "lastVideoMuted",
            "lastSelectedDirectory",
            "lastSelectedDirectoryPath"
            // Removed videoMetadataCache as it may contain non-serializable data
        ]
        
        var userDefaultsData: [String: Any] = [:]
        for key in keysToBackup {
            if let value = defaults.object(forKey: key) {
                // Convert to JSON-compatible types
                if let data = value as? Data {
                    // Convert Data to base64 string
                    userDefaultsData[key] = data.base64EncodedString()
                } else if JSONSerialization.isValidJSONObject([value]) {
                    userDefaultsData[key] = value
                }
                // Skip non-serializable values
            }
        }
        
        // Also backup security bookmarks (as base64 strings)
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("bookmark_") {
                if let data = defaults.data(forKey: key) {
                    userDefaultsData[key] = data.base64EncodedString()
                }
            }
        }
        
        // Create backup
        let backup = BackupContent(
            version: 1,
            date: Date(),
            databases: databases,
            userDefaults: userDefaultsData
        )
        
        // Save to file
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(backup)
        
        // Create directory picker
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.message = "Choose a directory to save your VideoViewer backup"
        openPanel.prompt = "Select Directory"
        
        guard openPanel.runModal() == .OK, let directory = openPanel.url else {
            throw NSError(domain: "BackupError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save cancelled"])
        }
        
        // Create filename with timestamp
        let filename = "VideoViewer_Backup_\(Date().ISO8601Format()).json"
        let url = directory.appendingPathComponent(filename)
        
        try data.write(to: url)
        return url
    }
    
    func restoreBackup(from url: URL) throws {
        let fileManager = FileManager.default
        
        // Read backup file
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let backup = try decoder.decode(BackupContent.self, from: data)
        
        // Verify version compatibility
        guard backup.version == 1 else {
            throw NSError(domain: "RestoreError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Incompatible backup version"])
        }
        
        // Restore databases using configurable paths
        
        // Restore main database
        if let imageData = backup.databases["image_data.db"] {
            let dbPath = SettingsManager.shared.getDatabasePath()
            let dbDir = dbPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true, attributes: nil)
            try imageData.write(to: dbPath)
        }
        
        // Restore video metadata database
        if let metadataData = backup.databases["video_metadata.db"] {
            let dbPath = SettingsManager.shared.getDatabasePath()
            let metadataDbPath = dbPath.deletingLastPathComponent().appendingPathComponent("video_metadata.db")
            try metadataData.write(to: metadataDbPath)
            print("✅ Restored video metadata database")
        }
        
        // Restore cleanup rules database
        if let cleanupData = backup.databases["cleanup_rules.db"] {
            let cleanupDbPath = SettingsManager.shared.getCleanupRulesPath()
            let cleanupDir = cleanupDbPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: cleanupDir, withIntermediateDirectories: true, attributes: nil)
            try cleanupData.write(to: cleanupDbPath)
        }
        
        // Restore UserDefaults
        let defaults = UserDefaults.standard
        for (key, value) in backup.userDefaults {
            if key.hasPrefix("bookmark_"), let base64String = value as? String {
                // Restore security bookmarks from base64
                if let data = Data(base64Encoded: base64String) {
                    defaults.set(data, forKey: key)
                }
            } else if let base64String = value as? String,
                      let data = Data(base64Encoded: base64String) {
                // Try to restore as Data if it's a valid base64 string
                defaults.set(data, forKey: key)
            } else {
                // Regular value
                defaults.set(value, forKey: key)
            }
        }
        defaults.synchronize()
    }
    
    func showBackupDialog() {
        do {
            let url = try createBackup()
            showAlert(title: "Backup Successful", 
                     message: "Your settings have been backed up to:\n\(url.path)", 
                     style: .informational)
        } catch {
            showAlert(title: "Backup Failed", 
                     message: error.localizedDescription, 
                     style: .critical)
        }
    }
    
    func showRestoreDialog() {
        // First, let user choose directory
        let dirPanel = NSOpenPanel()
        dirPanel.canChooseFiles = false
        dirPanel.canChooseDirectories = true
        dirPanel.message = "Select the directory containing VideoViewer backup files"
        dirPanel.prompt = "Select Directory"
        
        guard dirPanel.runModal() == .OK, let directory = dirPanel.url else { return }
        
        // Find backup files in directory
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, 
                                                           includingPropertiesForKeys: nil,
                                                           options: .skipsHiddenFiles)
            let backupFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("VideoViewer_Backup") }
            
            if backupFiles.isEmpty {
                showAlert(title: "No Backups Found", 
                         message: "No VideoViewer backup files found in the selected directory.", 
                         style: .warning)
                return
            }
            
            // If multiple backups, let user choose
            let filePanel = NSOpenPanel()
            filePanel.canChooseDirectories = false
            filePanel.allowedContentTypes = [.json]
            filePanel.directoryURL = directory
            filePanel.message = "Select a VideoViewer backup file to restore"
            filePanel.prompt = "Restore"
            
            guard filePanel.runModal() == .OK, let url = filePanel.url else { return }
            
            restoreFromFile(url)
        } catch {
            showAlert(title: "Error", 
                     message: "Failed to read directory: \(error.localizedDescription)", 
                     style: .critical)
        }
    }
    
    private func restoreFromFile(_ url: URL) {
        
        // Confirm restoration
        let alert = NSAlert()
        alert.messageText = "Restore Backup?"
        alert.informativeText = "This will replace your current settings with the backup. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        do {
            try restoreBackup(from: url)
            
            // Post notification to reload UI
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .databaseRestored, object: nil)
            }
            
            showAlert(title: "Restore Successful", 
                     message: "Your settings have been restored successfully.", 
                     style: .informational)
        } catch {
            showAlert(title: "Restore Failed", 
                     message: error.localizedDescription, 
                     style: .critical)
        }
    }
    
    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}