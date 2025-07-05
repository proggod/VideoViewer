import Foundation
import SQLite3

class CategoryManager: ObservableObject {
    static let shared = CategoryManager()
    
    @Published var categories: [Category] = []
    private var db: OpaquePointer?
    
    struct Category: Identifiable, Equatable {
        let id: Int
        var name: String
        var isSelected: Bool = false
    }
    
    private init() {
        openDatabase()
        createTables()
        loadCategories()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func getDatabasePath() -> String {
        // For now, use a global location in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("VideoViewer")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        return appFolder.appendingPathComponent("image_data.db").path
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
        
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("Successfully opened database at \(dbPath)")
        } else {
            print("Unable to open database")
        }
    }
    
    private func createTables() {
        // Create categories table
        let createCategoriesTable = """
            CREATE TABLE IF NOT EXISTS categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE
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
        
        if sqlite3_exec(db, createCategoriesTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating categories table")
        }
        
        if sqlite3_exec(db, createVideoCategoriesTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating video_categories table")
        }
    }
    
    // MARK: - Category Management
    
    func loadCategories() {
        categories.removeAll()
        
        let queryString = "SELECT id, name FROM categories ORDER BY name"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                categories.append(Category(id: id, name: name))
            }
        }
        
        sqlite3_finalize(statement)
    }
    
    func addCategory(name: String) -> Bool {
        let insertString = "INSERT INTO categories (name) VALUES (?)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, name, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadCategories()
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    func updateCategory(id: Int, newName: String) -> Bool {
        let updateString = "UPDATE categories SET name = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, newName, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadCategories()
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
                loadCategories()
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    // MARK: - Video Category Management
    
    func getCategoriesForVideo(videoPath: String) -> Set<Int> {
        var categoryIds = Set<Int>()
        
        let queryString = "SELECT category_id FROM video_categories WHERE video_path = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, videoPath, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let categoryId = Int(sqlite3_column_int(statement, 0))
                categoryIds.insert(categoryId)
            }
        }
        
        sqlite3_finalize(statement)
        return categoryIds
    }
    
    func setVideoCategory(videoPath: String, categoryId: Int, isSelected: Bool) {
        if isSelected {
            // Add category to video
            let insertString = "INSERT OR IGNORE INTO video_categories (video_path, category_id) VALUES (?, ?)"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, videoPath, -1, nil)
                sqlite3_bind_int(statement, 2, Int32(categoryId))
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
        } else {
            // Remove category from video
            let deleteString = "DELETE FROM video_categories WHERE video_path = ? AND category_id = ?"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, deleteString, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, videoPath, -1, nil)
                sqlite3_bind_int(statement, 2, Int32(categoryId))
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func getVideosForCategory(categoryId: Int) -> [String] {
        var videoPaths: [String] = []
        
        let queryString = "SELECT video_path FROM video_categories WHERE category_id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(categoryId))
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let videoPath = String(cString: sqlite3_column_text(statement, 0))
                videoPaths.append(videoPath)
            }
        }
        
        sqlite3_finalize(statement)
        return videoPaths
    }
}