import Foundation
import SQLite3
import AVFoundation

class VideoMetadataManager: ObservableObject {
    static let shared = VideoMetadataManager()
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let dbQueue = DispatchQueue(label: "com.videoviewer.dbqueue", qos: .userInitiated)
    private var metadataCache: [String: CachedMetadata] = [:]
    
    struct CachedMetadata {
        let path: String
        let resolution: String
        let duration: Double
        let fileSize: Int64
        let lastModified: Date
        let lastScanned: Date
    }
    
    private init() {
        print("🚀 VideoMetadataManager.init() called")
        
        // Check if database is on network drive
        let networkDbPath = getNetworkDatabasePath()
        if networkDbPath.hasPrefix("/Volumes/") {
            print("📁 Network database detected, enabling local cache")
            // Defer the published property change to avoid SwiftUI update conflicts
            DispatchQueue.main.async {
                SettingsManager.shared.useLocalDatabaseCache = true
            }
            syncFromNetworkToLocal()
        }
        
        openDatabase()  // This will now delete corrupted databases
        createTables()
        
        // Clean up any corrupted resolution strings
        cleanupCorruptedResolutions()
        
        // Load all metadata into memory
        loadAllMetadataIntoMemory()
        
        // Listen for database restore notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDatabaseRestored),
            name: .databaseRestored,
            object: nil
        )
        
        print("🚀 VideoMetadataManager initialized with db: \(db != nil ? "✅" : "❌")")
        
        // Start background sync if using local cache
        if SettingsManager.shared.useLocalDatabaseCache {
            startBackgroundSync()
        }
    }
    
    private func cleanupCorruptedResolutions() {
        // Check for truly corrupted data - not just non-standard resolutions
        let checkQuery = """
            SELECT COUNT(*) as total, 
                   SUM(CASE WHEN resolution GLOB '[0-9][0-9][0-9]*p' OR resolution IN ('4K','SD','Unsupported') THEN 1 ELSE 0 END) as valid 
            FROM video_metadata
        """
        var statement: OpaquePointer?
        
        var totalCount = 0
        var validCount = 0
        
        if sqlite3_prepare_v2(db, checkQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                totalCount = Int(sqlite3_column_int(statement, 0))
                validCount = Int(sqlite3_column_int(statement, 1))
            }
            sqlite3_finalize(statement)
        }
        
        // If more than 5% of entries are corrupted, rebuild the entire database
        if totalCount > 0 && (Double(validCount) / Double(totalCount)) < 0.95 {
            print("🚨 Detected significant corruption: \(totalCount - validCount)/\(totalCount) entries are invalid")
            print("   Valid: \(validCount), Invalid: \(totalCount - validCount)")
            print("🔧 Rebuilding resolution database from scratch...")
            
            // Close current database
            sqlite3_close(db)
            db = nil
            
            // Delete the corrupted database
            let dbPath = getDatabasePath()
            try? FileManager.default.removeItem(atPath: dbPath)
            
            // Reopen and recreate
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                print("✅ Created fresh resolution database")
                createTables()
            }
            
            return
        }
        
        // Otherwise, just clean up individual bad entries
        if validCount < totalCount {
            print("🧹 Cleaning up \(totalCount - validCount) corrupted entries...")
            
            // Show some examples of corrupted data
            let exampleQuery = """
                SELECT resolution, COUNT(*) as count 
                FROM video_metadata 
                WHERE NOT (resolution GLOB '[0-9][0-9][0-9]*p' OR resolution IN ('4K','SD','Unsupported'))
                GROUP BY resolution 
                LIMIT 10
            """
            if sqlite3_prepare_v2(db, exampleQuery, -1, &statement, nil) == SQLITE_OK {
                print("🗑️ Examples of corrupted resolutions:")
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let resCStr = sqlite3_column_text(statement, 0) {
                        let resolution = String(cString: resCStr)
                        let count = sqlite3_column_int(statement, 1)
                        
                        // Show the corruption
                        if resolution.count > 20 || resolution.contains("\0") || resolution.unicodeScalars.contains(where: { $0.value > 127 }) {
                            let hexDump = resolution.prefix(20).map { String(format: "%02X", $0.asciiValue ?? 0) }.joined(separator: " ")
                            print("  ❌ Binary garbage: '\(resolution.prefix(20))...' (hex: \(hexDump), count: \(count))")
                        } else {
                            print("  ❌ Invalid format: '\(resolution)' (count: \(count))")
                        }
                    }
                }
                sqlite3_finalize(statement)
            }
            
            // Delete only truly invalid entries (not legitimate resolutions like 1084p)
            let deleteQuery = """
                DELETE FROM video_metadata 
                WHERE NOT (resolution GLOB '[0-9]*p' OR resolution IN ('4K','8K+','SD','Unsupported','Unknown'))
            """
            if sqlite3_exec(db, deleteQuery, nil, nil, nil) == SQLITE_OK {
                let deleted = sqlite3_changes(db)
                print("✅ Deleted \(deleted) corrupted entries")
            }
        }
    }
    
    @objc private func handleDatabaseRestored() {
        print("🔄 VideoMetadataManager: Reloading after database restore")
        // Close and reopen database
        sqlite3_close(db)
        db = nil
        openDatabase()
        createTables()
        
        // Reload all metadata into memory
        loadAllMetadataIntoMemory()
    }
    
    
    private func getDatabasePath() -> String {
        // Check if we should use local cache
        if SettingsManager.shared.useLocalDatabaseCache {
            return getLocalCachePath()
        }
        
        let dbPath = SettingsManager.shared.getDatabasePath()
        let dbDir = dbPath.deletingLastPathComponent()
        
        // Use same directory as categories database but different file
        let metadataDbPath = dbDir.appendingPathComponent("video_metadata.db")
        
        print("📁 VideoMetadataManager database path: \(metadataDbPath.path)")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        
        return metadataDbPath.path
    }
    
    private func getLocalCachePath() -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let cacheDir = tempDir.appendingPathComponent("VideoViewer_Cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("video_metadata.db").path
    }
    
    private func getNetworkDatabasePath() -> String {
        let dbPath = SettingsManager.shared.getDatabasePath()
        let dbDir = dbPath.deletingLastPathComponent()
        let metadataDbPath = dbDir.appendingPathComponent("video_metadata.db")
        return metadataDbPath.path
    }
    
    private func openDatabase() {
        let dbPath = getDatabasePath()
        let fileManager = FileManager.default
        
        // Debug: Check database file size and existence
        if fileManager.fileExists(atPath: dbPath) {
            let attributes = try? fileManager.attributesOfItem(atPath: dbPath)
            let fileSize = attributes?[.size] as? Int64 ?? 0
            print("📊 Database exists: \(dbPath)")
            print("📊 Database size: \(fileSize) bytes")
        } else {
            print("📊 Database does not exist: \(dbPath)")
        }
        
        // Check if database exists and is corrupted
        if fileManager.fileExists(atPath: dbPath) {
            // Try to open and check integrity
            var tempDb: OpaquePointer?
            if sqlite3_open(dbPath, &tempDb) == SQLITE_OK {
                var isCorrupted = false
                
                // Quick integrity check
                let result = sqlite3_exec(tempDb, "PRAGMA quick_check", nil, nil, nil)
                if result != SQLITE_OK {
                    isCorrupted = true
                    print("❌ Video metadata database is corrupted")
                }
                
                sqlite3_close(tempDb)
                
                if isCorrupted {
                    print("🔧 Deleting corrupted video metadata database...")
                    try? fileManager.removeItem(atPath: dbPath)
                    print("✅ Corrupted database removed. Will recreate fresh database.")
                }
            }
        }
        
        // Now open the database (will create new one if we deleted it)
        let openResult = sqlite3_open(dbPath, &db)
        if openResult != SQLITE_OK {
            print("❌ Error opening metadata database")
            print("   Path: \(dbPath)")
            print("   Error code: \(openResult)")
            if let db = db {
                print("   Error: \(String(cString: sqlite3_errmsg(db)))")
            }
            return
        } else {
            print("✅ Successfully opened database at: \(dbPath)")
        }
        
        // Use DELETE mode for maximum compatibility and safety
        var resultPtr: UnsafeMutablePointer<Int8>?
        sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, &resultPtr)
        if let result = resultPtr {
            print("📊 Journal mode set to: \(String(cString: result))")
            sqlite3_free(resultPtr)
        }
        
        // Use FULL synchronous mode for maximum data integrity
        sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, nil)
        
        // Run integrity check
        var integrityResult: UnsafeMutablePointer<Int8>?
        let integrityCheck = sqlite3_exec(db, "PRAGMA integrity_check", nil, nil, &integrityResult)
        if integrityCheck == SQLITE_OK {
            if let result = integrityResult {
                let integrityStatus = String(cString: result)
                if integrityStatus != "ok" {
                    print("⚠️ Database integrity check failed: \(integrityStatus)")
                }
                sqlite3_free(integrityResult)
            }
        }
    }
    
    private func loadAllMetadataIntoMemory() {
        print("📚 Loading all video metadata into memory...")
        let startTime = Date()
        
        let query = "SELECT path, resolution, duration, file_size, last_modified, last_scanned FROM video_metadata"
        var statement: OpaquePointer?
        
        metadataCache.removeAll()
        var count = 0
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let pathCStr = sqlite3_column_text(statement, 0),
                   let resCStr = sqlite3_column_text(statement, 1) {
                    let path = String(cString: pathCStr)
                    let resolution = String(cString: resCStr)
                    let duration = sqlite3_column_double(statement, 2)
                    let fileSize = sqlite3_column_int64(statement, 3)
                    let lastModified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                    let lastScanned = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    
                    metadataCache[path] = CachedMetadata(
                        path: path,
                        resolution: resolution,
                        duration: duration,
                        fileSize: fileSize,
                        lastModified: lastModified,
                        lastScanned: lastScanned
                    )
                    count += 1
                }
            }
        }
        
        sqlite3_finalize(statement)
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("✅ Loaded \(count) video metadata entries in \(String(format: "%.2f", elapsed))s")
    }
    
    private func createTables() {
        let createVideoMetadataTable = """
            CREATE TABLE IF NOT EXISTS video_metadata (
                path TEXT PRIMARY KEY,
                resolution TEXT NOT NULL,
                duration REAL NOT NULL,
                file_size INTEGER NOT NULL,
                last_modified REAL NOT NULL,
                last_scanned REAL NOT NULL
            )
        """
        
        let createDirectoryScanTable = """
            CREATE TABLE IF NOT EXISTS directory_scans (
                path TEXT PRIMARY KEY,
                last_full_scan REAL NOT NULL,
                video_count INTEGER NOT NULL
            )
        """
        
        sqlite3_exec(db, createVideoMetadataTable, nil, nil, nil)
        sqlite3_exec(db, createDirectoryScanTable, nil, nil, nil)
        
        // Create index for faster lookups
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_video_path ON video_metadata(path)", nil, nil, nil)
        
        // Debug: Count entries in database
        let countQuery = "SELECT COUNT(*) FROM video_metadata"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, countQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                let count = sqlite3_column_int(statement, 0)
                print("📊 Database contains \(count) metadata entries")
            }
            sqlite3_finalize(statement)
        }
    }
    
    func getUniqueResolutions(for directoryPath: String) -> [String] {
        // Everything is already loaded in memory
        var resolutionSet = Set<String>()
        
        for (path, metadata) in metadataCache {
            if path.hasPrefix(directoryPath + "/") {
                resolutionSet.insert(metadata.resolution)
            }
        }
        
        return resolutionSet.sorted()
    }
    
    func getCachedMetadata(for path: String) -> CachedMetadata? {
        // Everything is already loaded in memory
        return metadataCache[path]
    }
    
    func cacheMetadata(_ metadata: CachedMetadata) {
        // Update memory cache immediately
        metadataCache[metadata.path] = metadata
        
        // Write to database asynchronously
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if database is initialized
            guard let db = self.db else {
                print("❌ Database not initialized when trying to cache")
                return
            }
        
        // Validate resolution before caching - check if it's a valid pattern
        let validPattern = metadata.resolution.range(of: "^(4K|8K\\+|\\d+p|SD|Unsupported|Unknown)$", options: .regularExpression) != nil
        guard validPattern else {
            print("⚠️ Invalid resolution format '\(metadata.resolution)' for \(metadata.path)")
            return
        }
        
        let query = """
            INSERT OR REPLACE INTO video_metadata 
            (path, resolution, duration, file_size, last_modified, last_scanned)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            print("❌ Failed to prepare cache statement")
            print("   Error: \(String(cString: sqlite3_errmsg(db)))")
            print("   Result code: \(prepareResult)")
            print("   Query: \(query)")
            return
        }
        
        // Use SQLITE_TRANSIENT to ensure strings are copied
        sqlite3_bind_text(statement, 1, metadata.path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, metadata.resolution, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, metadata.duration)
        sqlite3_bind_int64(statement, 4, metadata.fileSize)
        sqlite3_bind_double(statement, 5, metadata.lastModified.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, metadata.lastScanned.timeIntervalSince1970)
        
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("❌ Failed to cache metadata: \(String(cString: sqlite3_errmsg(db)))")
            print("   Step result: \(stepResult)")
        } else {
            // Debug logging commented out to reduce console spam
            // let filename = URL(fileURLWithPath: metadata.path).lastPathComponent
            // if filename.hasPrefix("!!") {
            //     print("✅ INSERT executed successfully: \(filename)")
            //     print("   Path: \(metadata.path)")
            //     print("   Resolution: \(metadata.resolution)")
            //     print("   Rows changed: \(sqlite3_changes(db))")
            // }
            }
            
            sqlite3_finalize(statement)
            
            // Verify the write was successful - commented out to reduce console spam
            // let filename = URL(fileURLWithPath: metadata.path).lastPathComponent
            // if filename.hasPrefix("!!") {
            //     // Immediately try to read it back
            //     if let verifyMetadata = getCachedMetadata(for: metadata.path) {
            //         print("✅ Verified write: \(filename) is now in database")
            //     } else {
            //         print("❌ Write verification failed: \(filename) not found after caching")
            //     }
            // }
        }
    }
    
    func getVideoMetadata(for url: URL, forceRefresh: Bool = false) -> (resolution: String, duration: Double)? {
        let path = url.path
        
        // Check if we need to refresh
        if !forceRefresh {
            // Get file modification date
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let currentModDate = attributes?[.modificationDate] as? Date ?? Date()
            
            // Check cache
            if let cached = getCachedMetadata(for: path) {
                // If file hasn't been modified since last scan, use cache
                if cached.lastModified >= currentModDate {
                    return (cached.resolution, cached.duration)
                }
            }
        }
        
        // Return nil for now - async scanning will update later
        // This prevents blocking the UI
        return nil
    }
    
    func getVideoMetadataAsync(for url: URL, completion: @escaping ((resolution: String, duration: Double)?) -> Void) {
        Task {
            let result = await getVideoMetadataAsyncInternal(for: url)
            
            if let result = result {
                // Cache the metadata
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes?[.size] as? Int64 ?? 0
                let modDate = attributes?[.modificationDate] as? Date ?? Date()
                
                let metadata = CachedMetadata(
                    path: url.path,
                    resolution: result.resolution,
                    duration: result.duration,
                    fileSize: fileSize,
                    lastModified: modDate,
                    lastScanned: Date()
                )
                
                cacheMetadata(metadata)
            }
            
            await MainActor.run {
                completion(result)
            }
        }
    }
    
    func getVideoMetadataAsyncInternal(for url: URL) async -> (resolution: String, duration: Double)? {
        let asset = AVAsset(url: url)
        
        do {
            // Get duration
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite && durationSeconds > 0 else {
                return nil
            }
            
            // Get video tracks
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                return nil
            }
            
            // Get resolution
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            
            let size = naturalSize.applying(preferredTransform)
            let width = abs(size.width)
            let height = abs(size.height)
            
            // Make sure we have valid dimensions
            guard width > 0 && height > 0 else {
                print("⚠️ Invalid dimensions for \(url.lastPathComponent): \(width)x\(height)")
                return nil
            }
            
            // Use the larger dimension to determine resolution
            // This handles both landscape and portrait videos correctly
            let maxDimension = max(width, height)
            let minDimension = min(width, height)
            
            let resolution: String
            if maxDimension >= 3840 {
                resolution = "4K"
            } else if maxDimension >= 2560 {
                resolution = "1440p"
            } else if maxDimension >= 1920 {
                // Check if it's closer to 1080p or a non-standard resolution
                if minDimension >= 1080 || abs(maxDimension - 1920) <= 40 {
                    resolution = "1080p"
                } else {
                    // Non-standard like 1920x1084
                    resolution = "\(Int(maxDimension))p"
                }
            } else if maxDimension >= 1280 {
                resolution = "720p"
            } else if maxDimension >= 854 {
                resolution = "480p"
            } else if maxDimension >= 640 {
                resolution = "360p"
            } else {
                resolution = "SD"
            }
            
            // Commented out to reduce console spam
            // print("📹 Video: \(url.lastPathComponent) - Dimensions: \(Int(width))x\(Int(height)) -> Resolution: \(resolution)")
            
            return (resolution, durationSeconds)
        } catch {
            print("Error loading video metadata: \(error)")
            return nil
        }
    }
    
    // Batch processing for better performance - fully async
    func getVideoMetadataBatchAsync(for urls: [URL], 
                                   batchSize: Int = 3,
                                   progress: @escaping (Int, Int) -> Void,
                                   completion: @escaping ([URL: (resolution: String, duration: Double)]) -> Void) {
        
        Task {
            await withTaskGroup(of: (URL, (resolution: String, duration: Double)?).self) { group in
                var results: [URL: (resolution: String, duration: Double)] = [:]
                var completed = 0
                let totalCount = urls.count
                
                // Add tasks in batches
                for (index, url) in urls.enumerated() {
                    // Limit concurrent tasks
                    if index > 0 && index % batchSize == 0 {
                        // Process current batch
                        for await (url, metadata) in group {
                            if let metadata = metadata {
                                results[url] = metadata
                                
                                // Cache the result
                                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                                let fileSize = attributes?[.size] as? Int64 ?? 0
                                let modDate = attributes?[.modificationDate] as? Date ?? Date()
                                
                                let cachedMetadata = CachedMetadata(
                                    path: url.path,
                                    resolution: metadata.resolution,
                                    duration: metadata.duration,
                                    fileSize: fileSize,
                                    lastModified: modDate,
                                    lastScanned: Date()
                                )
                                
                                self.cacheMetadata(cachedMetadata)
                            }
                            
                            completed += 1
                            let currentCompleted = completed
                            await MainActor.run {
                                progress(currentCompleted, totalCount)
                            }
                        }
                        
                        // Small delay between batches for network drives
                        if url.path.hasPrefix("/Volumes/") {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        }
                    }
                    
                    group.addTask {
                        let result = await self.getVideoMetadataAsyncInternal(for: url)
                        return (url, result)
                    }
                }
                
                // Process remaining tasks
                for await (url, metadata) in group {
                    if let metadata = metadata {
                        results[url] = metadata
                        
                        // Cache the result
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        let fileSize = attributes?[.size] as? Int64 ?? 0
                        let modDate = attributes?[.modificationDate] as? Date ?? Date()
                        
                        let cachedMetadata = CachedMetadata(
                            path: url.path,
                            resolution: metadata.resolution,
                            duration: metadata.duration,
                            fileSize: fileSize,
                            lastModified: modDate,
                            lastScanned: Date()
                        )
                        
                        self.cacheMetadata(cachedMetadata)
                    }
                    
                    completed += 1
                    let currentCompleted = completed
                    await MainActor.run {
                        progress(currentCompleted, totalCount)
                    }
                }
                
                // No checkpoint needed in DELETE mode
                
                let finalResults = results
                await MainActor.run {
                    completion(finalResults)
                }
            }
        }
    }
    
    // Directory scan tracking
    func hasScannedDirectory(_ path: String) -> Bool {
        let query = "SELECT last_full_scan FROM directory_scans WHERE path = ?"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let lastScan = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            // Consider directory scanned if it was scanned within the last 24 hours
            return Date().timeIntervalSince(lastScan) < 86400
        }
        
        return false
    }
    
    func markDirectoryAsScanned(_ path: String, videoCount: Int) {
        let query = """
            INSERT OR REPLACE INTO directory_scans
            (path, last_full_scan, video_count)
            VALUES (?, ?, ?)
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(videoCount))
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    // Clean up old entries
    func cleanupOldEntries(olderThan days: Int = 30) {
        let cutoffDate = Date().addingTimeInterval(-Double(days * 86400))
        let query = "DELETE FROM video_metadata WHERE last_scanned < ?"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    // Export all metadata to a backup file
    func exportMetadataBackup() -> Bool {
        let timestamp = Date().ISO8601Format()
        let backupPath = getDatabasePath() + ".recovery_\(timestamp).json"
        print("📦 Exporting metadata backup to: \(backupPath)")
        
        let query = "SELECT path, resolution, duration, file_size, last_modified, last_scanned FROM video_metadata"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("❌ Failed to prepare export query")
            return false
        }
        
        var count = 0
        var backupData: [[String: Any]] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pathCStr = sqlite3_column_text(statement, 0),
               let resCStr = sqlite3_column_text(statement, 1) {
                let path = String(cString: pathCStr)
                let resolution = String(cString: resCStr)
                let duration = sqlite3_column_double(statement, 2)
                let fileSize = sqlite3_column_int64(statement, 3)
                let lastModified = sqlite3_column_double(statement, 4)
                let lastScanned = sqlite3_column_double(statement, 5)
                
                backupData.append([
                    "path": path,
                    "resolution": resolution,
                    "duration": duration,
                    "fileSize": fileSize,
                    "lastModified": lastModified,
                    "lastScanned": lastScanned
                ])
                count += 1
            }
        }
        
        sqlite3_finalize(statement)
        
        // Save backup as JSON
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: backupData, options: .prettyPrinted)
            try jsonData.write(to: URL(fileURLWithPath: backupPath))
            print("✅ Exported \(count) metadata entries to backup")
            return true
        } catch {
            print("❌ Failed to save backup: \(error)")
            return false
        }
    }
    
    // Clean up invalid resolutions
    func cleanupInvalidResolutions() {
        let validResolutions = ["4K", "1440p", "1080p", "720p", "480p", "360p", "SD", "Unsupported"]
        let placeholders = validResolutions.map { _ in "?" }.joined(separator: ",")
        let query = "DELETE FROM video_metadata WHERE resolution NOT IN (\(placeholders))"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Failed to prepare cleanup query")
            return
        }
        
        for (index, resolution) in validResolutions.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), resolution, -1, nil)
        }
        
        if sqlite3_step(statement) == SQLITE_DONE {
            let deletedCount = sqlite3_changes(db)
            if deletedCount > 0 {
                print("🧹 Cleaned up \(deletedCount) entries with invalid resolutions")
            }
        }
        
        sqlite3_finalize(statement)
    }
    
    func removeMetadata(for path: String) {
        // Remove from memory cache immediately
        metadataCache.removeValue(forKey: path)
        
        // Remove from database
        let query = "DELETE FROM video_metadata WHERE path = ?"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Failed to prepare remove metadata query")
            return
        }
        
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            print("Failed to remove metadata for path: \(path)")
        }
        
        sqlite3_finalize(statement)
    }
    
    // MARK: - Database Sync
    
    private func syncFromNetworkToLocal() {
        let networkPath = getNetworkDatabasePath()
        let localPath = getLocalCachePath()
        
        // Check if network database exists
        guard FileManager.default.fileExists(atPath: networkPath) else {
            print("📁 No network database to sync from")
            return
        }
        
        print("🔄 Syncing database from network to local cache...")
        print("  From: \(networkPath)")
        print("  To: \(localPath)")
        
        do {
            // Remove old local cache if exists
            if FileManager.default.fileExists(atPath: localPath) {
                try FileManager.default.removeItem(atPath: localPath)
            }
            
            // Copy network database to local
            try FileManager.default.copyItem(atPath: networkPath, toPath: localPath)
            print("✅ Database synced to local cache")
        } catch {
            print("❌ Failed to sync database: \(error)")
        }
    }
    
    private func syncFromLocalToNetwork() {
        guard SettingsManager.shared.useLocalDatabaseCache else { return }
        
        let networkPath = getNetworkDatabasePath()
        let localPath = getLocalCachePath()
        
        // Only sync if local database exists
        guard FileManager.default.fileExists(atPath: localPath) else { return }
        
        do {
            // Create backup of network database
            let backupPath = networkPath + ".backup"
            if FileManager.default.fileExists(atPath: networkPath) {
                try? FileManager.default.removeItem(atPath: backupPath)
                try FileManager.default.copyItem(atPath: networkPath, toPath: backupPath)
            }
            
            // Copy local database to network
            try FileManager.default.removeItem(atPath: networkPath)
            try FileManager.default.copyItem(atPath: localPath, toPath: networkPath)
            // Removed sync logging to reduce console spam
        } catch {
            print("❌ Failed to sync to network: \(error)")
        }
    }
    
    private var syncTimer: Timer?
    private var lastSyncTime = Date()
    
    private func startBackgroundSync() {
        // Sync every 30 seconds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            self.dbQueue.async {
                self.performSync()
            }
        }
    }
    
    private func performSync() {
        // Only sync if at least 30 seconds have passed
        let now = Date()
        if now.timeIntervalSince(lastSyncTime) >= 30.0 {
            syncFromLocalToNetwork()
            lastSyncTime = now
        }
    }
    
    deinit {
        syncTimer?.invalidate()
        // Final sync before closing
        if SettingsManager.shared.useLocalDatabaseCache {
            syncFromLocalToNetwork()
        }
        sqlite3_close(db)
    }
}