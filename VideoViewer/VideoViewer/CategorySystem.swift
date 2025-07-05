import Foundation
import SwiftUI
import SQLite3

// MARK: - CategoryManager

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
        cleanupEmptyCategories()
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
    
    private func cleanupEmptyCategories() {
        let deleteString = "DELETE FROM categories WHERE name = '' OR name IS NULL"
        if sqlite3_exec(db, deleteString, nil, nil, nil) == SQLITE_OK {
            print("Cleaned up empty categories")
        }
    }
    
    func loadCategories() {
        var newCategories: [Category] = []
        
        let queryString = "SELECT id, name FROM categories ORDER BY LOWER(name)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                newCategories.append(Category(id: id, name: name))
                print("Loaded category: id=\(id), name=\(name)")
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
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, videoPath, -1, SQLITE_TRANSIENT)
            
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
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, videoPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 2, Int32(categoryId))
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
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

// MARK: - CategoriesView

struct CategoriesView: View {
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var newCategoryName = ""
    @State private var editingCategory: CategoryManager.Category?
    @State private var editingName = ""
    @State private var showingDeleteAlert = false
    @State private var categoryToDelete: CategoryManager.Category?
    
    var body: some View {
        let _ = print("CategoriesView body rendering, categories count: \(categoryManager.categories.count)")
        return VStack(spacing: 0) {
            // Header
            HStack {
                Text("Categories")
                    .font(.largeTitle)
                    .bold()
                
                Spacer()
            }
            .padding()
            
            // Add new category
            HStack {
                TextField("New category name", text: $newCategoryName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        addCategory()
                    }
                
                Button("Add") {
                    addCategory()
                }
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)
            
            // Categories list
            List {
                if categoryManager.categories.isEmpty {
                    Text("No categories yet")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(categoryManager.categories) { category in
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
                            Text(category.name)
                            
                            Spacer()
                            
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
                }
            }
            .listStyle(InsetListStyle())
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            print("CategoriesView appeared, loading categories...")
            categoryManager.loadCategories()
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
    }
    
    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if categoryManager.addCategory(name: trimmedName) {
                newCategoryName = ""
            } else {
                // Show error if category already exists or failed to add
                print("Failed to add category: \(trimmedName)")
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
}