import Foundation
import SQLite3

class CleanupManager: ObservableObject {
    static let shared = CleanupManager()
    
    @Published var rules: [CleanupRule] = []
    private var db: OpaquePointer?
    
    struct CleanupRule: Identifiable, Equatable {
        let id: Int
        var searchText: String
        var replaceText: String
        var isEnabled: Bool = true
        
        // Display search text with visible spaces
        var displaySearchText: String {
            return searchText.replacingOccurrences(of: " ", with: "␣")
        }
        
        // Display replace text with visible spaces
        var displayReplaceText: String {
            return replaceText.replacingOccurrences(of: " ", with: "␣")
        }
    }
    
    private init() {
        openDatabase()
        createTables()
        loadRulesSync() // Use synchronous loading on init
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func getDatabasePath() -> String {
        // Store in user's home directory
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let appFolder = homeURL.appendingPathComponent(".VideoViewer")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        return appFolder.appendingPathComponent("cleanup_rules.db").path
    }
    
    private func openDatabase() {
        let dbPath = getDatabasePath()
        
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("Successfully opened cleanup database at \(dbPath)")
        } else {
            print("Unable to open cleanup database")
        }
    }
    
    private func createTables() {
        let createRulesTable = """
            CREATE TABLE IF NOT EXISTS cleanup_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                search_text TEXT NOT NULL,
                replace_text TEXT NOT NULL,
                is_enabled INTEGER DEFAULT 1,
                sort_order INTEGER DEFAULT 0
            )
        """
        
        if sqlite3_exec(db, createRulesTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating cleanup_rules table")
        }
        
        // Add sort_order column if it doesn't exist (for existing databases)
        let addSortOrderColumn = "ALTER TABLE cleanup_rules ADD COLUMN sort_order INTEGER DEFAULT 0"
        sqlite3_exec(db, addSortOrderColumn, nil, nil, nil)
        
        // Update existing rules to have sequential sort_order
        let updateSortOrder = """
            UPDATE cleanup_rules 
            SET sort_order = (SELECT COUNT(*) FROM cleanup_rules r2 WHERE r2.id <= cleanup_rules.id) - 1
            WHERE sort_order = 0
        """
        sqlite3_exec(db, updateSortOrder, nil, nil, nil)
    }
    
    // MARK: - Rule Management
    
    private func loadRulesSync() {
        var newRules: [CleanupRule] = []
        
        let queryString = "SELECT id, search_text, replace_text, is_enabled FROM cleanup_rules ORDER BY sort_order, id"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, queryString, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let searchText = String(cString: sqlite3_column_text(statement, 1))
                let replaceText = String(cString: sqlite3_column_text(statement, 2))
                let isEnabled = sqlite3_column_int(statement, 3) == 1
                
                newRules.append(CleanupRule(
                    id: id,
                    searchText: searchText,
                    replaceText: replaceText,
                    isEnabled: isEnabled
                ))
            }
        }
        
        sqlite3_finalize(statement)
        
        // Update rules synchronously
        self.rules = newRules
    }
    
    func loadRules() {
        loadRulesSync()
        
        // Notify UI of changes on main thread
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    func addRule(searchText: String, replaceText: String) -> Bool {
        // Get the current maximum sort_order
        var maxSortOrder = -1
        let maxQuery = "SELECT MAX(sort_order) FROM cleanup_rules"
        var maxStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, maxQuery, -1, &maxStatement, nil) == SQLITE_OK {
            if sqlite3_step(maxStatement) == SQLITE_ROW {
                maxSortOrder = Int(sqlite3_column_int(maxStatement, 0))
            }
        }
        sqlite3_finalize(maxStatement)
        
        let insertString = "INSERT INTO cleanup_rules (search_text, replace_text, sort_order) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        var success = false
        
        if sqlite3_prepare_v2(db, insertString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, searchText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, replaceText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 3, Int32(maxSortOrder + 1))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                success = true
                print("Successfully added cleanup rule")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("Failed to add cleanup rule: \(errorMessage)")
            }
        }
        
        sqlite3_finalize(statement)
        
        if success {
            loadRules()
        }
        
        return success
    }
    
    func updateRule(id: Int, searchText: String, replaceText: String) -> Bool {
        let updateString = "UPDATE cleanup_rules SET search_text = ?, replace_text = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, searchText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, replaceText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 3, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadRules()
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    func toggleRule(id: Int, isEnabled: Bool) -> Bool {
        let updateString = "UPDATE cleanup_rules SET is_enabled = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 2, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadRules()
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    func deleteRule(id: Int) -> Bool {
        let deleteString = "DELETE FROM cleanup_rules WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, deleteString, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(id))
            
            if sqlite3_step(statement) == SQLITE_DONE {
                sqlite3_finalize(statement)
                loadRules()
                return true
            }
        }
        
        sqlite3_finalize(statement)
        return false
    }
    
    func moveRule(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0 && sourceIndex < rules.count,
              destinationIndex >= 0 && destinationIndex < rules.count else { return }
        
        // Create a mutable copy of rules
        var reorderedRules = rules
        
        // Move the rule
        let movedRule = reorderedRules.remove(at: sourceIndex)
        reorderedRules.insert(movedRule, at: destinationIndex)
        
        // Update all rules with new order positions
        for (index, rule) in reorderedRules.enumerated() {
            let updateString = "UPDATE cleanup_rules SET sort_order = ? WHERE id = ?"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, updateString, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(index))
                sqlite3_bind_int(statement, 2, Int32(rule.id))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        
        // Reload to reflect new order
        loadRules()
    }
    
    // MARK: - Filename Processing
    
    func processFilename(_ filename: String) -> String {
        var result = filename
        
        // Apply only enabled rules in order
        for rule in rules where rule.isEnabled {
            // Check if the search text contains wildcards
            if rule.searchText.contains("*") || rule.searchText.contains("?") {
                // Convert wildcard pattern to regex pattern
                let pattern = wildcardToRegex(rule.searchText)
                
                do {
                    // Use case-insensitive regex matching
                    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    let range = NSRange(location: 0, length: result.utf16.count)
                    
                    // Find all matches and replace them
                    result = regex.stringByReplacingMatches(
                        in: result,
                        options: [],
                        range: range,
                        withTemplate: rule.replaceText
                    )
                } catch {
                    print("Error creating regex from wildcard pattern: \(error)")
                    // Fall back to case-insensitive literal replacement
                    result = result.replacingOccurrences(
                        of: rule.searchText,
                        with: rule.replaceText,
                        options: [.caseInsensitive]
                    )
                }
            } else {
                // No wildcards, use case-insensitive literal replacement
                result = result.replacingOccurrences(
                    of: rule.searchText,
                    with: rule.replaceText,
                    options: [.caseInsensitive]
                )
            }
        }
        
        // Clean up the result
        result = cleanupFilename(result)
        
        return result
    }
    
    // Clean up filename by removing leading/trailing spaces and spaces before extension
    private func cleanupFilename(_ filename: String) -> String {
        var result = filename
        
        // First trim all whitespace from beginning and end
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Collapse multiple spaces into single spaces
        let components = result.components(separatedBy: .whitespacesAndNewlines)
        result = components.filter { !$0.isEmpty }.joined(separator: " ")
        
        // Handle spaces before the extension
        if let lastDotIndex = result.lastIndex(of: ".") {
            let namePart = String(result[..<lastDotIndex])
            let extensionPart = String(result[lastDotIndex...])
            
            // Trim trailing spaces from the name part
            let cleanedNamePart = namePart.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Reconstruct the filename
            result = cleanedNamePart + extensionPart
        }
        
        return result
    }
    
    // Convert wildcard pattern to regex pattern
    private func wildcardToRegex(_ pattern: String) -> String {
        var regex = ""
        let characters = Array(pattern)
        
        for i in 0..<characters.count {
            let char = characters[i]
            
            switch char {
            case "*":
                // * matches any sequence of characters (including empty)
                regex += ".*"
            case "?":
                // ? matches any single character
                regex += "."
            case "[", "]", "(", ")", "{", "}", ".", "+", "^", "$", "|", "\\":
                // Escape special regex characters
                regex += "\\\(char)"
            default:
                regex += String(char)
            }
        }
        
        return regex
    }
    
    func previewChanges(for urls: [URL], limit: Int = 20) -> (changes: [(original: URL, cleaned: URL)], totalMatches: Int) {
        // Ensure rules are loaded
        if rules.isEmpty {
            loadRulesSync()
        }
        
        var allResults: [(original: URL, cleaned: URL)] = []
        
        print("\n=== Cleanup Preview ===")
        print("Total files to check: \(urls.count)")
        print("Total rules: \(rules.count)")
        print("Enabled rules: \(rules.filter { $0.isEnabled }.count)")
        
        // Print all enabled rules
        for (index, rule) in rules.enumerated() where rule.isEnabled {
            print("Rule \(index + 1): [\(rule.searchText)] -> [\(rule.replaceText)]")
        }
        
        for url in urls {
            let originalName = url.lastPathComponent
            let cleanedName = processFilename(originalName)
            
            // Only include if the name would change
            if originalName != cleanedName {
                print("✓ Changed: '\(originalName)' -> '\(cleanedName)'")
                let cleanedURL = url.deletingLastPathComponent().appendingPathComponent(cleanedName)
                allResults.append((original: url, cleaned: cleanedURL))
            }
        }
        
        print("Files that will change: \(allResults.count)")
        print("======================\n")
        
        // Return limited results but with total count
        let limitedResults = Array(allResults.prefix(limit))
        return (changes: limitedResults, totalMatches: allResults.count)
    }
    
    // Keep the old method for backward compatibility
    func previewChanges(for urls: [URL]) -> [(original: URL, cleaned: URL)] {
        return previewChanges(for: urls, limit: 20).changes
    }
}