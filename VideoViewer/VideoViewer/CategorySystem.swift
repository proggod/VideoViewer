import Foundation
import SwiftUI
import SQLite3

extension Notification.Name {
    static let databaseRestored = Notification.Name("databaseRestored")
}

// MARK: - CategoryManager

class CategoryManager: ObservableObject {
    static let shared = CategoryManager()
    
    @Published var categories: [Category] = []
    @Published var categoryGroups: [CategoryGroup] = []
    private var db: OpaquePointer?
    private var videoCategoryCache: [String: Set<Int>] = [:]
    
    struct Category: Identifiable, Equatable {
        let id: Int
        var name: String
        var groupId: Int?
        var isSelected: Bool = false
    }
    
    struct CategoryGroup: Identifiable, Equatable {
        let id: Int
        var name: String
        var allowMultiple: Bool // If false, only one category in this group can be selected
        var isExpanded: Bool = true
    }
    
    private init() {
        // Check if database is on network drive
        let dbPath = SettingsManager.shared.getDatabasePath()
        if dbPath.path.hasPrefix("/Volumes/") {
            print("📁 Network database detected for categories, enabling local cache")
            // Defer the published property change to avoid SwiftUI update conflicts
            DispatchQueue.main.async {
                SettingsManager.shared.useLocalDatabaseCache = true
            }
            syncFromNetworkToLocal()
        }
        
        openDatabase()
        createTables()
        cleanupEmptyCategories()
        loadCategoryGroups()
        loadCategories()
        loadAllVideoCategoryMappings()
        
        // Listen for database restore notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDatabaseRestored),
            name: .databaseRestored,
            object: nil
        )
        
        // Start background sync if using local cache
        if SettingsManager.shared.useLocalDatabaseCache {
            startBackgroundSync()
        }
    }
    
    @objc private func handleDatabaseRestored() {
        // Close and reopen database
        sqlite3_close(db)
        db = nil
        openDatabase()
        createTables()
        
        // Clear cache
        videoCategoryCache.removeAll()
        
        // Reload all data
        loadCategoryGroups()
        loadCategories()
        loadAllVideoCategoryMappings()
        
        // Post update notification
        NotificationCenter.default.post(
            name: Notification.Name("categoriesUpdated"),
            object: nil
        )
    }
    
    private func getDatabasePath() -> String {
        // Check if we should use local cache
        if SettingsManager.shared.useLocalDatabaseCache {
            return getLocalCachePath()
        }
        
        // Use configurable path from SettingsManager
        let dbPath = SettingsManager.shared.getDatabasePath()
        let dbDir = dbPath.deletingLastPathComponent()
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        
        return dbPath.path
    }
    
    private func getLocalCachePath() -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let cacheDir = tempDir.appendingPathComponent("VideoViewer_Cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("categories.db").path
    }
    
    private func getNetworkDatabasePath() -> String {
        let dbPath = SettingsManager.shared.getDatabasePath()
        return dbPath.path
    }
    
    func getDatabasePath(for directoryURL: URL) -> String {
        // Get database path relative to a specific directory
        let videoInfoPath = directoryURL.appendingPathComponent(".video_info")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: videoInfoPath, withIntermediateDirectories: true)
        
        return videoInfoPath.appendingPathComponent("image_data.db").path
    }
    
    private func openDatabase() {
        let dbPath = getDatabasePath()
        
        // Check if database file exists
        let fileExists = FileManager.default.fileExists(atPath: dbPath)
        print("Database path: \(dbPath)")
        print("Database exists: \(fileExists)")
        
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("Successfully opened database at \(dbPath)")
            // Enable foreign key constraints
            sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        } else {
            print("Unable to open database")
        }
    }
    
    private func createTables() {
        // Create category groups table
        let createGroupsTable = """
            CREATE TABLE IF NOT EXISTS category_groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                allow_multiple INTEGER DEFAULT 1,
                is_expanded INTEGER DEFAULT 1
            )
        """
        
        // Create categories table (updated to include group reference)
        let createCategoriesTable = """
            CREATE TABLE IF NOT EXISTS categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                group_id INTEGER,
                FOREIGN KEY (group_id) REFERENCES category_groups(id) ON DELETE SET NULL
            )
        """
        
        // Create video_categories junction table
        let createVideoCategoriesTable = """
            CREATE TABLE IF NOT EXISTS video_categories (
                video_path TEXT NOT NULL,
                category_id INTEGER NOT NULL,
                PRIMARY KEY (video_path, category_id),
                FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
            )
        """
        
        if sqlite3_exec(db, createGroupsTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating category_groups table")
        }
        
        if sqlite3_exec(db, createCategoriesTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating categories table")
        }
        
        if sqlite3_exec(db, createVideoCategoriesTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating video_categories table")
        }
        
        // Add group_id column to existing categories table if it doesn't exist
        let addGroupIdColumn = "ALTER TABLE categories ADD COLUMN group_id INTEGER REFERENCES category_groups(id)"
        sqlite3_exec(db, addGroupIdColumn, nil, nil, nil) // Ignore errors if column already exists
    }
    
    // MARK: - Category Management
    
    private func cleanupEmptyCategories() {
        let deleteString = "DELETE FROM categories WHERE name = '' OR name IS NULL"
        if sqlite3_exec(db, deleteString, nil, nil, nil) == SQLITE_OK {
            print("Cleaned up empty categories")
        }
    }
    
    func loadCategoryGroups() {
        var newGroups: [CategoryGroup] = []
        
        let queryString = "SELECT id, name, allow_multiple, is_expanded FROM category_groups ORDER BY LOWER(name)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                let allowMultiple = sqlite3_column_int(statement, 2) == 1
                let isExpanded = sqlite3_column_int(statement, 3) == 1
                newGroups.append(CategoryGroup(id: id, name: name, allowMultiple: allowMultiple, isExpanded: isExpanded))
            }
        }
        
        sqlite3_finalize(statement)
        
        // Update on main thread
        DispatchQueue.main.async {
            self.categoryGroups = newGroups
        }
    }

    func loadCategories() {
        var newCategories: [Category] = []
        
        let queryString = "SELECT id, name, group_id FROM categories ORDER BY LOWER(name)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                let groupId = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2))
                newCategories.append(Category(id: id, name: name, groupId: groupId))
                print("Loaded category: id=\(id), name=\(name), groupId=\(groupId?.description ?? "nil")")
            }
        }
        
        sqlite3_finalize(statement)
        
        print("Total categories loaded: \(newCategories.count)")
        
        // Update on main thread to avoid UI issues
        DispatchQueue.main.async {
            self.categories = newCategories
            print("Categories array updated, count: \(self.categories.count)")
        }
    }
    
    func addCategory(name: String) -> Bool {
        let insertString = "INSERT INTO categories (name) VALUES (?)"
        var statement: OpaquePointer?
        var success = false
        
        if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
            // Use unsafeBitCast to get SQLITE_TRANSIENT
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully added category: \(name)")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("Failed to add category: \(errorMessage)")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadCategories()
            // Notify that categories have been updated
            NotificationCenter.default.post(
                name: Notification.Name("categoriesUpdated"),
                object: nil
            )
        }
        
        return success
    }
    
    func updateCategory(id: Int, newName: String) -> Bool {
        let updateString = "UPDATE categories SET name = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, newName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadCategories()
                // Notify that categories have been updated
                NotificationCenter.default.post(
                    name: Notification.Name("categoriesUpdated"),
                    object: nil
                )
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    func deleteCategory(id: Int) -> Bool {
        let deleteString = "DELETE FROM categories WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, deleteString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                
                // Clear cache entries that contain this category
                for (path, categories) in videoCategoryCache {
                    if categories.contains(id) {
                        var updatedCategories = categories
                        updatedCategories.remove(id)
                        videoCategoryCache[path] = updatedCategories
                    }
                }
                
                loadCategories()
                // Notify that categories have been updated
                NotificationCenter.default.post(
                    name: Notification.Name("categoriesUpdated"),
                    object: nil
                )
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    // MARK: - Video Category Management
    
    private func loadAllVideoCategoryMappings() {
        print("📚 Loading all video-category mappings into memory...")
        let startTime = Date()
        
        let queryString = "SELECT video_path, category_id FROM video_categories"
        var statement: OpaquePointer?
        
        videoCategoryCache.removeAll()
        var count = 0
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let pathCStr = sqlite3_column_text(statement, 0) {
                    let videoPath = String(cString: pathCStr)
                    let categoryId = Int(sqlite3_column_int(statement, 1))
                    
                    if videoCategoryCache[videoPath] != nil {
                        videoCategoryCache[videoPath]!.insert(categoryId)
                    } else {
                        videoCategoryCache[videoPath] = [categoryId]
                    }
                    count += 1
                }
            }
        }
        
        sqlite3_finalize(statement)
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("✅ Loaded \(count) video-category mappings for \(videoCategoryCache.count) videos in \(String(format: "%.2f", elapsed))s")
    }
    
    // No longer needed - everything is loaded at startup
    // func preloadCategoriesForVideos(videoPaths: [String]) { }
    
    func getCategoriesForVideo(videoPath: String) -> Set<Int> {
        // Everything is already loaded in memory
        return videoCategoryCache[videoPath] ?? []
    }
    
    func setVideoCategory(videoPath: String, categoryId: Int, isSelected: Bool) {
        if isSelected {
            // Add category to video
            let insertString = "INSERT OR IGNORE INTO video_categories (video_path, category_id) VALUES (?, ?)"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, videoPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 2, Int32(categoryId))
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
            
            // Update cache
            if var cached = videoCategoryCache[videoPath] {
                cached.insert(categoryId)
                videoCategoryCache[videoPath] = cached
            } else {
                videoCategoryCache[videoPath] = [categoryId]
            }
        } else {
            // Remove category from video
            let deleteString = "DELETE FROM video_categories WHERE video_path = ? AND category_id = ?"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, deleteString, -1, &statement, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, videoPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 2, Int32(categoryId))
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
            
            // Update cache
            if var cached = videoCategoryCache[videoPath] {
                cached.remove(categoryId)
                videoCategoryCache[videoPath] = cached
            }
        }
    }
    
    func getVideosForCategory(categoryId: Int) -> [String] {
        // Everything is already loaded in memory
        var videoPaths: [String] = []
        
        for (videoPath, categories) in videoCategoryCache {
            if categories.contains(categoryId) {
                videoPaths.append(videoPath)
            }
        }
        
        return videoPaths
    }
    
    func updateVideoPath(from oldPath: String, to newPath: String) {
        let updateString = "UPDATE video_categories SET video_path = ? WHERE video_path = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, newPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, oldPath, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(statement) == SQLITE_DONE {
                print("Successfully updated video path from '\(oldPath)' to '\(newPath)'")
                
                // Update cache
                if let cachedCategories = videoCategoryCache[oldPath] {
                    videoCategoryCache[newPath] = cachedCategories
                    videoCategoryCache.removeValue(forKey: oldPath)
                }
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("Failed to update video path: \(errorMessage)")
            }
        }
        
        sqlite3_finalize(statement)
    }
    
    // MARK: - Group Management
    
    func addCategoryGroup(name: String, allowMultiple: Bool = true) -> Bool {
        let insertString = "INSERT INTO category_groups (name, allow_multiple) VALUES (?, ?)"
        var statement: OpaquePointer?
        var success = false
        
        if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, allowMultiple ? 1 : 0)
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully added category group: \(name)")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("Failed to add category group: \(errorMessage)")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadCategoryGroups()
        }
        
        return success
    }
    
    func updateCategoryGroup(id: Int, name: String, allowMultiple: Bool) -> Bool {
        let updateString = "UPDATE category_groups SET name = ?, allow_multiple = ? WHERE id = ?"
        var statement: OpaquePointer?
        var success = false
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, allowMultiple ? 1 : 0)
            sqlite3_bind_int(statement, 3, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully updated category group: \(name)")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadCategoryGroups()
        }
        
        return success
    }
    
    func deleteCategoryGroup(id: Int) -> Bool {
        // First, set all categories in this group to have no group
        let updateCategoriesString = "UPDATE categories SET group_id = NULL WHERE group_id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateCategoriesString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(id))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        
        // Then delete the group
        let deleteString = "DELETE FROM category_groups WHERE id = ?"
        var success = false
        
        if sqlite3_prepare_v2(db, deleteString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully deleted category group with id: \(id)")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadCategoryGroups()
            loadCategories()
        }
        
        return success
    }
    
    func assignCategoryToGroup(categoryId: Int, groupId: Int?) -> Bool {
        let updateString = "UPDATE categories SET group_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        var success = false
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            if let groupId = groupId {
                sqlite3_bind_int(statement, 1, Int32(groupId))
            } else {
                sqlite3_bind_null(statement, 1)
            }
            sqlite3_bind_int(statement, 2, Int32(categoryId))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully assigned category \(categoryId) to group \(groupId?.description ?? "none")")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadCategories()
        }
        
        return success
    }
    
    func toggleGroupExpanded(groupId: Int) {
        let updateString = "UPDATE category_groups SET is_expanded = NOT is_expanded WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(groupId))
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
        loadCategoryGroups()
    }
    
    func getCategoriesInGroup(groupId: Int?) -> [Category] {
        return categories.filter { $0.groupId == groupId }
    }
    
    func getUngroupedCategories() -> [Category] {
        return categories.filter { $0.groupId == nil }
    }
    
    // MARK: - Group Selection Enforcement
    
    func enforceGroupSelectionRules(for videoPath: String, selectedCategoryId: Int, isSelected: Bool) -> Set<Int> {
        // Get current video categories
        var currentCategories = getCategoriesForVideo(videoPath: videoPath)
        
        if isSelected {
            // Adding a category
            currentCategories.insert(selectedCategoryId)
            
            // Check if this category belongs to a single-selection group
            if let category = categories.first(where: { $0.id == selectedCategoryId }),
               let groupId = category.groupId,
               let group = categoryGroups.first(where: { $0.id == groupId }),
               !group.allowMultiple {
                
                // This is a single-selection group, remove other categories from the same group
                let categoriesInSameGroup = getCategoriesInGroup(groupId: groupId).map { $0.id }
                for categoryId in categoriesInSameGroup {
                    if categoryId != selectedCategoryId && currentCategories.contains(categoryId) {
                        currentCategories.remove(categoryId)
                        // Don't call setVideoCategory here - let the caller handle all updates
                    }
                }
            }
        } else {
            // Removing a category
            currentCategories.remove(selectedCategoryId)
        }
        
        return currentCategories
    }
    
    func applyCategoriesToVideo(videoPath: String, categories: Set<Int>) {
        // Get current categories
        let currentCategories = getCategoriesForVideo(videoPath: videoPath)
        
        // Remove categories that are no longer selected
        for categoryId in currentCategories {
            if !categories.contains(categoryId) {
                setVideoCategory(videoPath: videoPath, categoryId: categoryId, isSelected: false)
            }
        }
        
        // Add new categories
        for categoryId in categories {
            if !currentCategories.contains(categoryId) {
                setVideoCategory(videoPath: videoPath, categoryId: categoryId, isSelected: true)
            }
        }
    }
    
    func validateCategorySelection(for videoPath: String, categoryId: Int, isSelected: Bool) -> (allowed: Bool, reason: String?) {
        // Check if this would violate group rules
        if isSelected {
            if let category = categories.first(where: { $0.id == categoryId }),
               let groupId = category.groupId,
               let group = categoryGroups.first(where: { $0.id == groupId }),
               !group.allowMultiple {
                
                // Check if another category in this group is already selected
                let currentCategories = getCategoriesForVideo(videoPath: videoPath)
                let categoriesInSameGroup = getCategoriesInGroup(groupId: groupId).map { $0.id }
                
                let alreadySelectedInGroup = categoriesInSameGroup.filter { currentCategories.contains($0) }
                if !alreadySelectedInGroup.isEmpty && !alreadySelectedInGroup.contains(categoryId) {
                    if let selectedCategory = categories.first(where: { $0.id == alreadySelectedInGroup.first! }) {
                        return (false, "Only one category allowed in '\(group.name)' group. '\(selectedCategory.name)' is already selected.")
                    }
                }
            }
        }
        
        return (true, nil)
    }
    
    // MARK: - Database Sync
    
    private var syncTimer: Timer?
    private var lastSyncTime = Date()
    
    private func syncFromNetworkToLocal() {
        let networkPath = getNetworkDatabasePath()
        let localPath = getLocalCachePath()
        
        // Check if network database exists
        guard FileManager.default.fileExists(atPath: networkPath) else {
            print("📁 No network category database to sync from")
            return
        }
        
        print("🔄 Syncing category database from network to local cache...")
        print("  From: \(networkPath)")
        print("  To: \(localPath)")
        
        do {
            // Remove old local cache if exists
            if FileManager.default.fileExists(atPath: localPath) {
                try FileManager.default.removeItem(atPath: localPath)
            }
            
            // Copy network database to local
            try FileManager.default.copyItem(atPath: networkPath, toPath: localPath)
            print("✅ Category database synced to local cache")
        } catch {
            print("❌ Failed to sync category database: \(error)")
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
            print("❌ Failed to sync categories to network: \(error)")
        }
    }
    
    private func startBackgroundSync() {
        // Sync every 30 seconds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            self.performSync()
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

// MARK: - CategoriesView

struct CategoriesView: View {
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var newCategoryName = ""
    @State private var newGroupName = ""
    @State private var newGroupAllowMultiple = true
    @State private var editingCategory: CategoryManager.Category?
    @State private var editingGroup: CategoryManager.CategoryGroup?
    @State private var editingName = ""
    @State private var editingGroupAllowMultiple = true
    @State private var showingDeleteAlert = false
    @State private var showingDeleteGroupAlert = false
    @State private var categoryToDelete: CategoryManager.Category?
    @State private var groupToDelete: CategoryManager.CategoryGroup?
    @State private var selectedTab = 0
    
    var body: some View {
        let _ = print("CategoriesView body rendering, categories count: \(categoryManager.categories.count)")
        return VStack(spacing: 0) {
            // Header
            HStack {
                Text("Categories & Groups")
                    .font(.largeTitle)
                    .bold()
                
                Spacer()
            }
            .padding()
            
            // Tab selection
            Picker("", selection: $selectedTab) {
                Text("Categories").tag(0)
                Text("Groups").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            
            if selectedTab == 0 {
                categoriesTab
            } else {
                groupsTab
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            print("CategoriesView appeared, loading data...")
            categoryManager.loadCategories()
            categoryManager.loadCategoryGroups()
        }
        .alert("Delete Category", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let category = categoryToDelete {
                    _ = categoryManager.deleteCategory(id: category.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(categoryToDelete?.name ?? "")'? This will remove it from all videos.")
        }
        .alert("Delete Group", isPresented: $showingDeleteGroupAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    _ = categoryManager.deleteCategoryGroup(id: group.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(groupToDelete?.name ?? "")'? Categories in this group will become ungrouped.")
        }
    }
    
    // MARK: - Categories Tab
    private var categoriesTab: some View {
        VStack(spacing: 0) {
            // Add new category
            HStack {
                TextField("New category name", text: $newCategoryName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        addCategory()
                    }
                
                Button("Add Category") {
                    addCategory()
                }
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)
            
            // Categories list with group assignment dropdowns
            List {
                if categoryManager.categories.isEmpty {
                    Text("No categories yet")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(categoryManager.categories) { category in
                        categoryRow(category)
                    }
                }
            }
            .listStyle(InsetListStyle())
        }
    }
    
    // MARK: - Groups Tab
    private var groupsTab: some View {
        VStack(spacing: 0) {
            // Add new group
            VStack(spacing: 12) {
                HStack {
                    TextField("New group name", text: $newGroupName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit {
                            addGroup()
                        }
                    
                    Button("Add Group") {
                        addGroup()
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                HStack {
                    Toggle("Allow multiple categories in group", isOn: $newGroupAllowMultiple)
                    Spacer()
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.bottom)
            
            // Groups list
            List {
                if categoryManager.categoryGroups.isEmpty {
                    Text("No groups yet")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(categoryManager.categoryGroups) { group in
                        groupRow(group)
                    }
                }
            }
            .listStyle(InsetListStyle())
        }
    }
    
    
    // MARK: - Helper Functions
    
    private var maxGroupDropdownWidth: CGFloat {
        let groupNames = categoryManager.categoryGroups.map { $0.name } + ["No Group"]
        let maxLength = groupNames.map { $0.count }.max() ?? 8
        // Estimate width: ~8 points per character + padding for icon and margins
        return CGFloat(max(maxLength * 8 + 40, 120))
    }
    
    private func categoryRow(_ category: CategoryManager.Category) -> some View {
        HStack {
            if editingCategory?.id == category.id {
                TextField("Category name", text: $editingName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        saveEdit()
                    }
                
                Button("Save") {
                    saveEdit()
                }
                
                Button("Cancel") {
                    editingCategory = nil
                    editingName = ""
                }
            } else {
                HStack {
                    if let groupId = category.groupId {
                        if let group = categoryManager.categoryGroups.first(where: { $0.id == groupId }) {
                            Image(systemName: group.allowMultiple ? "tag.fill" : "tag")
                                .foregroundColor(group.allowMultiple ? .blue : .orange)
                                .font(.caption)
                        }
                    }
                    
                    Text(category.name)
                        .frame(minWidth: 100, alignment: .leading)
                }
                
                Spacer()
                
                // Group assignment dropdown
                HStack(spacing: 8) {
                    Text("Group:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: Binding(
                        get: { category.groupId ?? -1 },
                        set: { newGroupId in
                            let groupId = newGroupId == -1 ? nil : newGroupId
                            _ = categoryManager.assignCategoryToGroup(categoryId: category.id, groupId: groupId)
                        }
                    )) {
                        Text("No Group").tag(-1)
                        ForEach(categoryManager.categoryGroups) { group in
                            HStack {
                                Image(systemName: group.allowMultiple ? "folder.badge.plus" : "folder.badge.minus")
                                Text(group.name)
                            }.tag(group.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: maxGroupDropdownWidth)
                }
                
                Button(action: {
                    editingCategory = category
                    editingName = category.name
                }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(BorderlessButtonStyle())
                
                Button(action: {
                    categoryToDelete = category
                    showingDeleteAlert = true
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }
    
    private func groupRow(_ group: CategoryManager.CategoryGroup) -> some View {
        HStack {
            if editingGroup?.id == group.id {
                VStack(spacing: 8) {
                    TextField("Group name", text: $editingName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Toggle("Allow multiple categories", isOn: $editingGroupAllowMultiple)
                        .font(.caption)
                    
                    HStack {
                        Button("Save") {
                            saveGroupEdit()
                        }
                        
                        Button("Cancel") {
                            editingGroup = nil
                            editingName = ""
                        }
                    }
                }
            } else {
                HStack {
                    Image(systemName: group.allowMultiple ? "folder.badge.plus" : "folder.badge.minus")
                        .foregroundColor(group.allowMultiple ? .blue : .orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.body)
                        
                        let categoryCount = categoryManager.getCategoriesInGroup(groupId: group.id).count
                        Text("\(categoryCount) categories • \(group.allowMultiple ? "Multiple allowed" : "Single only")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        editingGroup = group
                        editingName = group.name
                        editingGroupAllowMultiple = group.allowMultiple
                    }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    
                    Button(action: {
                        groupToDelete = group
                        showingDeleteGroupAlert = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    
    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if categoryManager.addCategory(name: trimmedName) {
                newCategoryName = ""
            } else {
                print("Failed to add category: \(trimmedName)")
            }
        }
    }
    
    private func addGroup() {
        let trimmedName = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if categoryManager.addCategoryGroup(name: trimmedName, allowMultiple: newGroupAllowMultiple) {
                newGroupName = ""
                newGroupAllowMultiple = true
            } else {
                print("Failed to add group: \(trimmedName)")
            }
        }
    }
    
    private func saveEdit() {
        if let category = editingCategory {
            let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty && trimmedName != category.name {
                _ = categoryManager.updateCategory(id: category.id, newName: trimmedName)
            }
        }
        editingCategory = nil
        editingName = ""
    }
    
    private func saveGroupEdit() {
        if let group = editingGroup {
            let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                _ = categoryManager.updateCategoryGroup(id: group.id, name: trimmedName, allowMultiple: editingGroupAllowMultiple)
            }
        }
        editingGroup = nil
        editingName = ""
    }
}