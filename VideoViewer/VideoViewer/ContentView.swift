import SwiftUI
import AVKit
import AppKit
import SQLite3

extension Notification.Name {
    static let refreshBrowser = Notification.Name("refreshBrowser")
    static let refreshThumbnails = Notification.Name("refreshThumbnails")
}

class FileItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    @Published var isReadable: Bool
    @Published var children: [FileItem] = []
    @Published var isExpanded: Bool = false
    @Published var hasLoadedChildren: Bool = false
    
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        var isDir: ObjCBool = false
        self.isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        
        // Check if we have a stored bookmark for this URL
        var isReadable = FileManager.default.isReadableFile(atPath: url.path)
        if !isReadable, let bookmarkData = UserDefaults.standard.data(forKey: "bookmark_\(url.path)") {
            do {
                var isStale = false
                let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if resolvedURL == url && !isStale {
                    _ = resolvedURL.startAccessingSecurityScopedResource()
                    isReadable = true
                }
            } catch {
                print("Failed to resolve bookmark for \(url.path): \(error)")
            }
        }
        
        self.isReadable = isReadable
    }
    
    func refreshReadability() {
        // Re-check readability and restore bookmark if needed
        print("🔄 Refreshing readability for: \(url.path)")
        var isReadable = FileManager.default.isReadableFile(atPath: url.path)
        print("  Initial isReadable: \(isReadable)")
        
        if !isReadable, let bookmarkData = UserDefaults.standard.data(forKey: "bookmark_\(url.path)") {
            print("  Found bookmark data, attempting to restore...")
            do {
                var isStale = false
                let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                print("  Resolved URL: \(resolvedURL.path), isStale: \(isStale)")
                if resolvedURL == url && !isStale {
                    let success = resolvedURL.startAccessingSecurityScopedResource()
                    print("  startAccessingSecurityScopedResource: \(success)")
                    isReadable = FileManager.default.isReadableFile(atPath: url.path)
                    print("  After bookmark: isReadable = \(isReadable)")
                }
            } catch {
                print("  ❌ Failed to resolve bookmark: \(error)")
            }
        }
        
        print("  Final isReadable: \(isReadable), was: \(self.isReadable)")
        if self.isReadable != isReadable {
            self.isReadable = isReadable
        }
    }
    
    func loadChildren() {
        guard isDirectory && !hasLoadedChildren else { return }
        hasLoadedChildren = true
        
        // Check if we can read the directory
        guard isReadable else {
            children = []
            return
        }
        
        // Load children asynchronously to prevent UI blocking
        Task {
            await loadChildrenAsync()
        }
    }
    
    @MainActor
    func loadChildrenAsync() async {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let loadedChildren = await withTaskGroup(of: FileItem?.self) { group in
                for childUrl in contents {
                    group.addTask {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: childUrl.path, isDirectory: &isDir) && isDir.boolValue {
                            return FileItem(url: childUrl)
                        }
                        return nil
                    }
                }
                
                var items: [FileItem] = []
                for await item in group {
                    if let item = item {
                        items.append(item)
                    }
                }
                return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            
            children = loadedChildren
        } catch let error as NSError {
            // Handle specific permission errors quietly for mounted volumes
            if error.domain == NSCocoaErrorDomain && error.code == 257 {
                // Permission denied - this is common for system directories and some mounted volumes
                children = []
            } else {
                print("Error loading children for \(url.path): \(error)")
                children = []
            }
        }
    }
}

enum NavigationTab {
    case videos
    case categories
    case cleanup
}

struct ContentView: View {
    @State private var selectedURL: URL?
    @State private var videoFiles: [URL] = []
    @State private var showingVideoPlayer = false
    @State private var videoToPlay: URL?
    @State private var currentTab: NavigationTab = .videos
    @State private var selectedFilterCategories: Set<Int> = []
    @State private var selectedResolutions: Set<String> = []
    @State private var showFilters = true
    @State private var videoMetadata: [URL: VideoMetadata] = [:]
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 16) {
                // Tab buttons
                HStack(spacing: 20) {
                    Button(action: { currentTab = .videos }) {
                        Label("Videos", systemImage: "play.rectangle")
                            .foregroundColor(currentTab == .videos ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { currentTab = .categories }) {
                        Label("Categories", systemImage: "tag")
                            .foregroundColor(currentTab == .categories ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { currentTab = .cleanup }) {
                        Label("Cleanup", systemImage: "wand.and.stars")
                            .foregroundColor(currentTab == .cleanup ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            // Content based on selected tab
            if currentTab == .videos {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        // File browser
                        SimpleBrowser(selectedURL: $selectedURL)
                            .frame(minHeight: 200)
                            .layoutPriority(showFilters ? 0.5 : 1)
                        
                        // Filter sidebar under file browser
                        if showFilters {
                            Divider()
                            
                            FilterSidebar(
                                selectedCategories: $selectedFilterCategories,
                                selectedResolutions: $selectedResolutions,
                                directoryURL: selectedURL,
                                videoMetadata: $videoMetadata
                            )
                            .frame(minHeight: 200)
                            .layoutPriority(0.5)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
                } detail: {
                    // Video list
                    if let selectedURL = selectedURL {
                        VideoListView(
                            directoryURL: selectedURL,
                            videoFiles: $videoFiles,
                            videoToPlay: $videoToPlay,
                            selectedCategories: $selectedFilterCategories,
                            selectedResolutions: $selectedResolutions,
                            showFilters: $showFilters,
                            videoMetadata: $videoMetadata
                        )
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            Text("Select a directory to view video files")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Click on any folder to navigate and view its contents")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if currentTab == .categories {
                CategoriesView()
            } else {
                CleanupView()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            loadLastSelectedDirectory()
        }
        .onChange(of: selectedURL) { oldValue, newValue in
            if let url = newValue {
                saveLastSelectedDirectory(url)
            }
        }
        .onChange(of: videoToPlay) { oldValue, newValue in
            print("=== onChange videoToPlay ===")
            print("Old: \(oldValue?.lastPathComponent ?? "nil") -> New: \(newValue?.lastPathComponent ?? "nil")")
            
            if newValue != nil {
                // Reset state to allow reopening same video
                showingVideoPlayer = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showingVideoPlayer = true
                }
            }
        }
        .background(
            // Hidden window opener
            Group {
                if showingVideoPlayer, let videoURL = videoToPlay {
                    WindowOpener(videoURL: videoURL, isPresented: $showingVideoPlayer, videoToPlay: $videoToPlay)
                }
            }
        )
    }
    
    private func saveLastSelectedDirectory(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "lastSelectedDirectory")
        } catch {
            // If we can't create a bookmark, just save the path
            UserDefaults.standard.set(url.path, forKey: "lastSelectedDirectoryPath")
        }
    }
    
    private func loadLastSelectedDirectory() {
        // Try to load from bookmark first (preserves permissions)
        if let bookmarkData = UserDefaults.standard.data(forKey: "lastSelectedDirectory") {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if !isStale {
                    _ = url.startAccessingSecurityScopedResource()
                    selectedURL = url
                    
                    // Also ensure we have the specific bookmark for this directory
                    if UserDefaults.standard.data(forKey: "bookmark_\(url.path)") == nil {
                        // Save a specific bookmark for this directory too
                        if let specificBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                            UserDefaults.standard.set(specificBookmark, forKey: "bookmark_\(url.path)")
                        }
                    }
                    
                    // Notify browser to refresh after bookmark restoration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: .refreshBrowser, object: nil)
                    }
                    
                    return
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        // Fallback to path if bookmark fails
        if let path = UserDefaults.standard.string(forKey: "lastSelectedDirectoryPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                selectedURL = url
            }
        }
    }
}

struct SimpleBrowser: View {
    @Binding var selectedURL: URL?
    @StateObject private var rootItem = FileItem(url: URL(fileURLWithPath: "/"))
    @State private var refreshTrigger = UUID()
    @State private var expandedPaths: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Directories")
                .font(.headline)
                .padding()
            
            List {
                // Add home directory
                DirectoryRow(
                    item: FileItem(url: FileManager.default.homeDirectoryForCurrentUser), 
                    selectedURL: $selectedURL,
                    expandedPaths: $expandedPaths
                )
                
                // Add system directories
                ForEach(["/Applications", "/System", "/Users", "/Volumes"], id: \.self) { path in
                    DirectoryRow(
                        item: FileItem(url: URL(fileURLWithPath: path)), 
                        selectedURL: $selectedURL,
                        expandedPaths: $expandedPaths
                    )
                }
            }
            .id(refreshTrigger)
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshBrowser)) { _ in
            refreshTrigger = UUID()
        }
        .onAppear {
            expandToSelectedURL()
        }
        .onChange(of: selectedURL) { _, _ in
            expandToSelectedURL()
        }
    }
    
    private func expandToSelectedURL() {
        guard let url = selectedURL else { return }
        
        // Get all parent paths that need to be expanded
        let pathComponents = url.pathComponents
        var pathsToExpand: [String] = []
        
        // Build paths from root to selected directory
        for i in 1..<pathComponents.count {
            let path = "/" + pathComponents[1...i].joined(separator: "/")
            pathsToExpand.append(path)
        }
        
        // Add all paths to expanded set
        expandedPaths.formUnion(pathsToExpand)
    }
    
}

struct DirectoryRow: View {
    @StateObject var item: FileItem
    @Binding var selectedURL: URL?
    @Binding var expandedPaths: Set<String>
    @State private var isExpanded = false
    
    private func requestAccessToDirectory(for url: URL) {
        // Try to trigger system permission dialog by attempting to read the directory
        Task {
            do {
                // This should trigger the system's permission dialog
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                
                // If we get here, we have access - refresh the item
                await MainActor.run {
                    item.refreshReadability()
                    if item.isReadable {
                        if !item.hasLoadedChildren {
                            item.loadChildren()
                        }
                        isExpanded = true
                        expandedPaths.insert(url.path)
                    }
                }
            } catch {
                // If that didn't work, fall back to the open panel
                await MainActor.run {
                    let openPanel = NSOpenPanel()
                    openPanel.canChooseDirectories = true
                    openPanel.canChooseFiles = false
                    openPanel.allowsMultipleSelection = false
                    openPanel.message = "Grant access to '\(url.lastPathComponent)'"
                    openPanel.prompt = "Grant Access"
                    openPanel.directoryURL = url
                    
                    if openPanel.runModal() == .OK, let selectedUrl = openPanel.url {
                        // Save bookmark for persistent access
                        do {
                            let bookmarkData = try selectedUrl.bookmarkData(
                                options: .withSecurityScope,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                            UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(selectedUrl.path)")
                            print("✅ Saved bookmark for: \(selectedUrl.path)")
                            
                            // Start accessing the resource immediately
                            let success = selectedUrl.startAccessingSecurityScopedResource()
                            print("🔓 Started accessing security scoped resource: \(success)")
                            
                            // Refresh the item's readability status
                            item.refreshReadability()
                            
                            // If now readable, expand it but don't change selection
                            print("📁 Item readable after refresh: \(item.isReadable)")
                            if item.isReadable {
                                // Don't change the selection - user might have a subdirectory selected
                                // Just expand this directory to show its contents
                                if !item.hasLoadedChildren {
                                    item.loadChildren()
                                }
                                isExpanded = true
                                expandedPaths.insert(selectedUrl.path)
                            }
                        } catch {
                            print("❌ Failed to save bookmark: \(error)")
                        }
                    }
                }
            }
        }
    }
    
    var body: some View {
        let isSelected = selectedURL == item.url
        let isInSelectedPath = selectedURL?.path.hasPrefix(item.url.path) ?? false
        
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if item.isDirectory && item.isReadable {
                    Button(action: { 
                        if !item.hasLoadedChildren {
                            item.loadChildren()
                        }
                        isExpanded.toggle()
                        
                        // Update expanded paths set
                        if isExpanded {
                            expandedPaths.insert(item.url.path)
                        } else {
                            expandedPaths.remove(item.url.path)
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                } else if item.isDirectory && !item.isReadable {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: getIcon(for: item.url))
                    .foregroundColor(getIconColor(for: item.url))
                
                Text(getDisplayName(for: item.url))
                    .foregroundColor(item.isReadable ? .primary : .secondary)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : (isInSelectedPath ? Color.accentColor.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Always set as selected URL
                selectedURL = item.url
                
                if item.isDirectory && item.isReadable {
                    // If readable, expand it
                    if !item.hasLoadedChildren {
                        item.loadChildren()
                    }
                    isExpanded = true
                    expandedPaths.insert(item.url.path)
                }
                // If not readable, the main content view will handle requesting permission
            }
            
            if isExpanded && item.isDirectory {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        DirectoryRow(
                            item: child, 
                            selectedURL: $selectedURL,
                            expandedPaths: $expandedPaths
                        )
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .onAppear {
            // Check if this path should be expanded
            if expandedPaths.contains(item.url.path) && !isExpanded {
                if !item.hasLoadedChildren {
                    item.loadChildren()
                }
                isExpanded = true
            }
        }
    }
    
    private func getDisplayName(for url: URL) -> String {
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "Home"
        } else if url.path == "/" {
            return "Root"
        } else {
            return url.lastPathComponent
        }
    }
    
    private func getIcon(for url: URL) -> String {
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "house.fill"
        } else if url.path == "/Applications" {
            return "app.fill"
        } else if url.path == "/System" {
            return "gear.circle.fill"
        } else if url.path == "/Users" {
            return "person.2.fill"
        } else if url.path.starts(with: "/Volumes/") {
            return "externaldrive.fill"
        } else {
            return "folder.fill"
        }
    }
    
    private func getIconColor(for url: URL) -> Color {
        if url.path.starts(with: "/Volumes/") {
            return .orange
        } else {
            return .blue
        }
    }
    
    private func requestAccessToDirectory() {
        // Show file picker directly - no need for two dialogs
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Grant access to '\(item.url.lastPathComponent)' by selecting it"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = []
        
        // Try to navigate to the parent directory if possible
        if let parent = item.url.deletingLastPathComponent().path.isEmpty ? nil : item.url.deletingLastPathComponent() {
            openPanel.directoryURL = parent
        }
            
            openPanel.begin { panelResponse in
                if panelResponse == .OK, let selectedURL = openPanel.url {
                    print("User selected: \(selectedURL.path)")
                    
                    do {
                        // Create security-scoped bookmark
                        let bookmarkData = try selectedURL.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        
                        // Save bookmark
                        UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(selectedURL.path)")
                        print("Saved bookmark for: \(selectedURL.path)")
                        
                        // Update UI on main thread
                        DispatchQueue.main.async {
                            // Update this specific item if it matches
                            if selectedURL.path == item.url.path {
                                item.isReadable = true
                                item.hasLoadedChildren = false
                                item.loadChildren()
                                isExpanded = true
                                self.selectedURL = item.url  // Now select the folder
                                print("Updated item readability and selected: \(item.url.path)")
                            }
                            
                            // Force full refresh
                            NotificationCenter.default.post(name: .refreshBrowser, object: nil)
                        }
                    } catch {
                        print("Failed to create security-scoped bookmark: \(error)")
                    }
                } else {
                    print("User cancelled folder selection")
                }
            }
    }
}

// Video metadata structure
struct VideoMetadata: Codable, Equatable {
    let resolution: String
    let duration: TimeInterval?
    let fileSize: Int64?
}

struct FilterSidebar: View {
    @Binding var selectedCategories: Set<Int>
    @Binding var selectedResolutions: Set<String>
    let directoryURL: URL?
    @Binding var videoMetadata: [URL: VideoMetadata]
    
    @StateObject private var categoryManager = CategoryManager.shared
    @State var availableResolutions: Set<String> = []
    @State var videoResolutions: [URL: String] = [:]
    @State var isLoadingResolutions = false
    @State var scanningStatus = ""
    @State var cachedCount = 0
    @State var scanningCount = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear all button
            HStack {
                Text("Filters")
                    .font(.headline)
                
                Spacer()
                
                if !selectedCategories.isEmpty || !selectedResolutions.isEmpty {
                    Button("Clear All") {
                        selectedCategories.removeAll()
                        selectedResolutions.removeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .padding()
            
            // Side by side sections
            HStack(alignment: .top, spacing: 0) {
                // Categories section
                if !categoryManager.categories.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Categories")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 4)
                            
                            // Show ungrouped categories first
                            let ungroupedCategories = categoryManager.getUngroupedCategories()
                            if !ungroupedCategories.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Ungrouped")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                    
                                    ForEach(ungroupedCategories) { category in
                                        categoryFilterToggle(category: category)
                                    }
                                }
                            }
                            
                            // Show grouped categories
                            ForEach(categoryManager.categoryGroups) { group in
                                let groupCategories = categoryManager.getCategoriesInGroup(groupId: group.id)
                                if !groupCategories.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: group.allowMultiple ? "folder.badge.plus" : "folder.badge.minus")
                                                .foregroundColor(group.allowMultiple ? .blue : .orange)
                                                .font(.caption)
                                            
                                            Text(group.name)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            
                                            Text(group.allowMultiple ? "(Multiple)" : "(Single)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .italic()
                                        }
                                        .padding(.top, 4)
                                        
                                        ForEach(groupCategories) { category in
                                            categoryFilterToggle(category: category)
                                        }
                                    }
                                }
                            }
                            
                            // Add separator before Non-categorized option
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Non-categorized filter
                            Toggle(isOn: Binding(
                                get: { selectedCategories.contains(-1) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedCategories.insert(-1)
                                    } else {
                                        selectedCategories.remove(-1)
                                    }
                                }
                            )) {
                                HStack {
                                    Image(systemName: "questionmark.folder")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                    Text("Non-categorized")
                                        .lineLimit(1)
                                        .font(.caption)
                                        .italic()
                                }
                            }
                            .toggleStyle(CheckboxToggleStyle())
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                    
                    if !availableResolutions.isEmpty {
                        Divider()
                            .padding(.vertical, 8)
                    }
                }
                
                // Resolutions section
                if !availableResolutions.isEmpty || isLoadingResolutions {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            // Status indicators at the top
                            VStack(alignment: .leading, spacing: 2) {
                                if cachedCount > 0 {
                                    Text("\(cachedCount) cached")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .bold()
                                }
                                if scanningCount > 0 {
                                    Text("\(scanningCount) scanning")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .bold()
                                }
                            }
                            
                            // Small divider line
                            Divider()
                                .padding(.vertical, 2)
                            
                            HStack(spacing: 4) {
                                Text("Resolution")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if isLoadingResolutions {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .frame(width: 12, height: 12)
                                }
                            }
                            .padding(.bottom, 4)
                            
                            ForEach(Array(availableResolutions).sorted { res1, res2 in
                                let height1 = getResolutionHeight(res1)
                                let height2 = getResolutionHeight(res2)
                                return height1 > height2
                            }, id: \.self) { resolution in
                                Toggle(isOn: Binding(
                                    get: { selectedResolutions.contains(resolution) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedResolutions.insert(resolution)
                                        } else {
                                            selectedResolutions.remove(resolution)
                                        }
                                    }
                                )) {
                                    Text(resolution)
                                        .font(.caption)
                                }
                                .toggleStyle(CheckboxToggleStyle())
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            updateAvailableResolutions()
        }
        .onChange(of: directoryURL) { oldValue, newValue in
            if oldValue != newValue {
                print("🔄 Directory changed from \(oldValue?.lastPathComponent ?? "nil") to \(newValue?.lastPathComponent ?? "nil")")
                updateAvailableResolutions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("videoMetadataLoaded"))) { _ in
            updateAvailableResolutions()
        }
    }
    
    private func updateAvailableResolutions() {
        // Get unique resolutions from the video metadata that's already loaded
        let resolutions = Set(videoMetadata.values.compactMap { $0.resolution })
        // Only update if changed to prevent excessive updates
        if availableResolutions != resolutions {
            availableResolutions = resolutions
        }
    }
    
    private func loadVideoResolutions() {
        guard let directoryURL = directoryURL else { return }
        
        print("🔄 loadVideoResolutions called for: \(directoryURL.lastPathComponent)")
        
        // Set loading state immediately
        isLoadingResolutions = true
        
        // Load everything asynchronously to prevent UI blocking
        Task {
            let directoryPath = directoryURL.path
                
                // First, try to restore bookmark access if we have one
                if let bookmarkData = UserDefaults.standard.data(forKey: "bookmark_\(directoryURL.path)") {
                    do {
                        var isStale = false
                        let restoredURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                        if restoredURL == directoryURL && !isStale {
                            _ = restoredURL.startAccessingSecurityScopedResource()
                            print("✅ Restored security-scoped access from bookmark for: \(directoryURL.lastPathComponent)")
                        }
                    } catch {
                        print("Failed to restore bookmark for \(directoryURL.path): \(error)")
                    }
                }
                
                // Load directory contents in background thread to avoid blocking
                let contents: [URL]
                do {
                    contents = try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                    }.value
                } catch {
                    print("Error loading video files: \(error)")
                    // Handle permission errors
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain && (nsError.code == 256 || nsError.code == 257) {
                        // Don't prompt here - let getVideoFilesAsync handle it
                        // Just exit early
                        self.isLoadingResolutions = false
                    }
                    return
                }
                
                let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
                let videoFiles = contents.filter { url in
                    videoExtensions.contains(url.pathExtension.lowercased())
                }
            
            print("📁 Found \(videoFiles.count) video files in directory")
            
            // For large directories, just get unique resolutions from database
            if videoFiles.count > 500 {
                print("📊 Large directory - getting unique resolutions from database")
                
                // Get unique resolutions directly from database - much faster!
                Task.detached(priority: .userInitiated) {
                    let uniqueResolutions = VideoMetadataManager.shared.getUniqueResolutions(for: directoryPath)
                    
                    await MainActor.run {
                        self.availableResolutions = Set(uniqueResolutions)
                        self.isLoadingResolutions = false
                        print("✅ Found \(uniqueResolutions.count) unique resolutions: \(uniqueResolutions.sorted())")
                    }
                }
                
                return // Exit early, we don't need the file mappings for the filter
            }
            
            // For smaller directories, process normally
            var newResolutions: Set<String> = []
            var newVideoResolutions: [URL: String] = [:]
            
            for videoFile in videoFiles {
                if let metadata = VideoMetadataManager.shared.getCachedMetadata(for: videoFile.path) {
                    newVideoResolutions[videoFile] = metadata.resolution
                    newResolutions.insert(metadata.resolution)
                }
            }
            
            // Final update and notification
            await MainActor.run {
                if !newResolutions.isEmpty {
                    // Notify with cached data
                    let unsupported = newVideoResolutions.filter { $0.value == "Unsupported" }.map { $0.key }
                    NotificationCenter.default.post(
                        name: Notification.Name("videoResolutionsUpdated"),
                        object: nil,
                        userInfo: [
                            "resolutions": newVideoResolutions,
                            "unsupported": Set(unsupported)
                        ]
                    )
                    
                    print("✅ Loaded \(newVideoResolutions.count) metadata entries from cache for \(directoryPath)")
                }
            }
            
            // Continue with loading any missing resolutions
            // Identify files that need scanning
            var uncachedFiles: [URL] = []
            for videoFile in videoFiles {
                if newVideoResolutions[videoFile] == nil {
                    uncachedFiles.append(videoFile)
                }
            }
            
            // Update scanning count
            await MainActor.run {
                self.scanningCount = uncachedFiles.count
            }
            
            print("📊 Resolution status - Cached: \(newVideoResolutions.count), Need scanning: \(uncachedFiles.count)")
            if uncachedFiles.count > 0 {
                print("📊 First few files needing scan: \(uncachedFiles.prefix(5).map { $0.lastPathComponent })")
            }
            
            // Second pass: load uncached files in parallel (limit concurrency)
            if !uncachedFiles.isEmpty {
                    // Process in smaller batches of 3 for network drives to reduce load
                    let batchSize = directoryURL.path.hasPrefix("/Volumes/") ? 3 : 5
                    for i in stride(from: 0, to: uncachedFiles.count, by: batchSize) {
                        let batch = Array(uncachedFiles[i..<min(i + batchSize, uncachedFiles.count)])
                        
                        await withTaskGroup(of: (URL, VideoMetadata?).self) { group in
                            for videoFile in batch {
                                group.addTask {
                                    let metadata = await self.getVideoMetadataAsync(for: videoFile)
                                    return (videoFile, metadata)
                                }
                            }
                            
                            // Update UI immediately as each file completes
                            for await (videoFile, metadata) in group {
                                if let metadata = metadata {
                                    newVideoResolutions[videoFile] = metadata.resolution
                                    newResolutions.insert(metadata.resolution)
                                    // Cache the result with correct file modification date
                                    let fileAttributes = try? FileManager.default.attributesOfItem(atPath: videoFile.path)
                                    let modDate = fileAttributes?[.modificationDate] as? Date ?? Date()
                                    let cachedMetadata = VideoMetadataManager.CachedMetadata(
                                        path: videoFile.path,
                                        resolution: metadata.resolution,
                                        duration: metadata.duration ?? 0,
                                        fileSize: metadata.fileSize ?? 0,
                                        lastModified: modDate,
                                        lastScanned: Date()
                                    )
                                    VideoMetadataManager.shared.cacheMetadata(cachedMetadata)
                                } else {
                                    // Mark failed files as "Unsupported" so they don't get rescanned every time
                                    newVideoResolutions[videoFile] = "Unsupported"
                                    newResolutions.insert("Unsupported")
                                    let fileAttributes = try? FileManager.default.attributesOfItem(atPath: videoFile.path)
                                    let modDate = fileAttributes?[.modificationDate] as? Date ?? Date()
                                    let failedMetadata = VideoMetadataManager.CachedMetadata(
                                        path: videoFile.path,
                                        resolution: "Unsupported",
                                        duration: 0,
                                        fileSize: 0,
                                        lastModified: modDate,
                                        lastScanned: Date()
                                    )
                                    VideoMetadataManager.shared.cacheMetadata(failedMetadata)
                                    print("❌ Failed to scan: \(videoFile.lastPathComponent)")
                                }
                                
                                // Update UI immediately after each file
                                await MainActor.run {
                                    self.availableResolutions = newResolutions
                                    self.videoResolutions = newVideoResolutions
                                    self.scanningCount = max(0, self.scanningCount - 1)
                                    self.cachedCount = self.cachedCount + 1  // Increment cached count as each file completes
                                    
                                    // Also send notification with current unsupported files
                                    let unsupported = newVideoResolutions.filter { $0.value == "Unsupported" }.map { $0.key }
                                    NotificationCenter.default.post(
                                        name: Notification.Name("videoResolutionsUpdated"),
                                        object: nil,
                                        userInfo: [
                                            "resolutions": newVideoResolutions,
                                            "unsupported": Set(unsupported)
                                        ]
                                    )
                                }
                            }
                        }
                        
                        // Add small delay between batches for network drives
                        if directoryURL.path.hasPrefix("/Volumes/") && i + batchSize < uncachedFiles.count {
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        }
                    }
                }
                
                // Update on main thread
                await MainActor.run {
                    self.isLoadingResolutions = false
                    self.availableResolutions = newResolutions
                    self.videoResolutions = newVideoResolutions
                    
                    // Store resolutions for use in VideoListView
                    let unsupported = newVideoResolutions.filter { $0.value == "Unsupported" }.map { $0.key }
                    NotificationCenter.default.post(
                        name: Notification.Name("videoResolutionsUpdated"),
                        object: nil,
                        userInfo: [
                            "resolutions": newVideoResolutions,
                            "unsupported": Set(unsupported)
                        ]
                    )
                }
        }
    }
    
    // Removed synchronous version - use getVideoResolutionAsync instead
    
    private func getVideoResolutionAsync(for url: URL) async -> String? {
        let metadata = await getVideoMetadataAsync(for: url)
        return metadata?.resolution
    }
    
    private func getVideoMetadataAsync(for url: URL) async -> VideoMetadata? {
        // First check if we have cached metadata in the database
        let cachedMetadata = VideoMetadataManager.shared.getCachedMetadata(for: url.path)
        
        if let cachedMetadata = cachedMetadata {
            // Check if file has been modified since last scan
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let currentModDate = attributes?[.modificationDate] as? Date ?? Date()
            
            // Debug logging commented out to reduce console spam
            // if url.lastPathComponent.hasPrefix("!!") {
            //     let formatter = DateFormatter()
            //     formatter.dateStyle = .short
            //     formatter.timeStyle = .medium
            //     print("🔍 File: \(url.lastPathComponent)")
            //     print("   📅 File mod date: \(formatter.string(from: currentModDate))")
            //     print("   💾 Cached date:   \(formatter.string(from: cachedMetadata.lastModified))")
            //     print("   ⚖️ Use cache? \(cachedMetadata.lastModified >= currentModDate)")
            // }
            
            // If file hasn't been modified since last scan, use cache
            if cachedMetadata.lastModified >= currentModDate {
                return VideoMetadata(
                    resolution: cachedMetadata.resolution,
                    duration: cachedMetadata.duration,
                    fileSize: cachedMetadata.fileSize
                )
            }
        }
        
        // Scan the video file for metadata
        let result = await VideoMetadataManager.shared.getVideoMetadataAsyncInternal(for: url)
        
        if let result = result {
            // Get file size and cache the metadata
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes?[.size] as? Int64 ?? 0
            let modDate = fileAttributes?[.modificationDate] as? Date ?? Date()
            
            // Cache the metadata
            let cachedMetadata = VideoMetadataManager.CachedMetadata(
                path: url.path,
                resolution: result.resolution,
                duration: result.duration,
                fileSize: fileSize,
                lastModified: modDate,
                lastScanned: Date()
            )
            VideoMetadataManager.shared.cacheMetadata(cachedMetadata)
            
            return VideoMetadata(
                resolution: result.resolution,
                duration: result.duration,
                fileSize: fileSize
            )
        }
        
        return nil
    }
    
    
    private func getResolutionHeight(_ resolution: String) -> Int {
        switch resolution {
        case "8K+": return 4320
        case "4K": return 2160
        case "1440p": return 1440
        case "1080p": return 1080
        case "720p": return 720
        case "480p": return 480
        case "360p": return 360
        default:
            // Extract number from format like "1234p"
            let numStr = resolution.replacingOccurrences(of: "p", with: "")
            return Int(numStr) ?? 0
        }
    }
    
    private func categoryFilterToggle(category: CategoryManager.Category) -> some View {
        Toggle(isOn: Binding(
            get: { selectedCategories.contains(category.id) },
            set: { isSelected in
                if isSelected {
                    // Check if this category is in a single-selection group
                    let categoryObj = categoryManager.categories.first(where: { $0.id == category.id })
                    if let categoryObj = categoryObj,
                       let groupId = categoryObj.groupId {
                        let group = categoryManager.categoryGroups.first(where: { $0.id == groupId })
                        if let group = group, !group.allowMultiple {
                            // For single-selection groups, clear other selections in the same group
                            let categoriesInSameGroup = categoryManager.getCategoriesInGroup(groupId: groupId).map { $0.id }
                            for categoryId in categoriesInSameGroup {
                                if categoryId != category.id {
                                    selectedCategories.remove(categoryId)
                                }
                            }
                        }
                    }
                    
                    selectedCategories.insert(category.id)
                } else {
                    selectedCategories.remove(category.id)
                }
            }
        )) {
            Text(category.name)
                .lineLimit(1)
                .font(.caption)
        }
        .toggleStyle(CheckboxToggleStyle())
    }
}

// Helper functions for formatting
extension ContentView {
    static func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds = seconds, !seconds.isNaN && !seconds.isInfinite && seconds > 0 else { return "" }
        
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    static func formatFileSize(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "" }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        return formatter.string(fromByteCount: bytes)
    }
}

struct VideoListView: View {
    let directoryURL: URL
    @Binding var videoFiles: [URL]
    @Binding var videoToPlay: URL?
    @Binding var selectedCategories: Set<Int>
    @Binding var selectedResolutions: Set<String>
    @Binding var showFilters: Bool
    @Binding var videoMetadata: [URL: VideoMetadata]
    
    @State private var localVideoFiles: [URL] = []
    @State private var filteredVideoFiles: [URL] = []
    @State private var isGridView = UserDefaults.standard.bool(forKey: "isGridView")
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailSize: Double = UserDefaults.standard.double(forKey: "thumbnailSize") == 0 ? 150 : UserDefaults.standard.double(forKey: "thumbnailSize")
    @State private var videoResolutions: [URL: String] = [:]
    @State private var unsupportedFiles: Set<URL> = []
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var searchText: String = ""
    @State private var showingDeleteAlert = false
    @State private var videoToDelete: URL?
    @State private var showingCleanupPreview = false
    @State private var editingVideo: URL?
    @State private var editingText: String = ""
    @State private var showingScreenshotProgress = false
    @State private var isGeneratingScreenshots = false
    @State private var screenshotProgress = 0
    @State private var screenshotTotal = 0
    @State private var currentScreenshotFile: String = ""
    @State private var screenshotTask: Task<Void, Never>?
    @State private var showingMKVRemux = false
    @State private var showingVideoConversion = false
    @State private var videosToConvert: [URL] = []
    @State private var sortOrder: SortOrder = .name
    @State private var sortAscending: Bool = true
    
    // Multi-selection state variables
    @State private var selectedVideos: Set<URL> = []
    @State private var lastSelectedVideo: URL?
    @State private var singleTapTimer: Timer?
    @State private var isLoadingData = false
    
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
    
    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case duration = "Duration"
        case size = "Size"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and view toggle
            // Top bar with all controls
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Directory name and network indicator
                    HStack(spacing: 8) {
                        Text(getDisplayName(for: directoryURL))
                            .font(.headline)
                        
                        if isNetworkPath(directoryURL) {
                            Image(systemName: "network")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .tooltip("Network drive")
                        }
                    }
                    
                    Divider()
                        .frame(height: 20)
                    
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search videos...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onChange(of: searchText) { _, _ in
                                applyFilters()
                            }
                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    // Thumbnail slider (only in grid view)
                    if isGridView {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Slider(value: $thumbnailSize, in: 100...480, step: 10)
                                .frame(width: 120)
                                .onChange(of: thumbnailSize) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "thumbnailSize")
                                }
                            
                            Text("\(Int(thumbnailSize))px")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                    }
                    
                    // Control buttons
                    HStack(spacing: 8) {
                        // View toggle
                        Button(action: { 
                            isGridView.toggle()
                            UserDefaults.standard.set(isGridView, forKey: "isGridView")
                        }) {
                            Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip(isGridView ? "Switch to List View" : "Switch to Grid View")
                        
                        // Filter toggle
                        Button(action: { 
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showFilters.toggle()
                            }
                        }) {
                            Image(systemName: "line.horizontal.3.decrease.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip(showFilters ? "Hide Filters" : "Show Filters")
                        
                        // Sort menu
                        Menu {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Button(action: {
                                    if sortOrder == order {
                                        sortAscending.toggle()
                                    } else {
                                        sortOrder = order
                                        sortAscending = true
                                    }
                                    applyFilters()
                                }) {
                                    HStack {
                                        Text(order.rawValue)
                                        if sortOrder == order {
                                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.title3)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .tooltip("Sort by: \(sortOrder.rawValue)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                // Status bar with counts and action buttons
                HStack {
                    // File counts and status
                    HStack(spacing: 12) {
                        Text("\(filteredVideoFiles.count) of \(localVideoFiles.count) videos")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if !selectedVideos.isEmpty {
                            Text("• \(selectedVideos.count) selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if !unsupportedFiles.isEmpty {
                            Text("• \(unsupportedFiles.count) unsupported")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    Spacer()
                    
                    // Action buttons
                    HStack(spacing: 8) {
                        // Clear selection
                        if !selectedVideos.isEmpty {
                            Button(action: {
                                selectedVideos.removeAll()
                                lastSelectedVideo = nil
                            }) {
                                Image(systemName: "xmark.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .tooltip("Clear Selection")
                        }
                        
                        // Refresh
                        Button(action: { refreshDirectory() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip("Refresh Directory")
                        
                        // Cleanup
                        Button(action: { showingCleanupPreview = true }) {
                            Image(systemName: "wand.and.stars")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip("Cleanup Filenames")
                        
                        // Screenshots
                        Button(action: { generateScreenshots() }) {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundColor(isGeneratingScreenshots ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .tooltip("Generate Screenshots")
                        .disabled(isGeneratingScreenshots)
                        
                        // Convert MKV
                        Button(action: { prepareVideoConversion() }) {
                            Image(systemName: "film.stack")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip("Convert MKV Files")
                        
                        // Folder access
                        Button(action: {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.message = "Grant access to a folder"
                            
                            if panel.runModal() == .OK {
                                if let url = panel.url {
                                    saveBookmark(for: url)
                                }
                            }
                        }) {
                            Image(systemName: "folder.badge.plus")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .tooltip("Grant access to protected folders")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                
                Divider()
            }
            .background(Color.gray.opacity(0.05))
                    
            
            if filteredVideoFiles.isEmpty {
                Spacer()
                if localVideoFiles.isEmpty {
                    Text("No video files in this directory")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "line.horizontal.3.decrease.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No videos match the selected filters")
                            .foregroundColor(.secondary)
                        Button("Clear Filters") {
                            selectedCategories.removeAll()
                            selectedResolutions.removeAll()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                if isGridView {
                    // Grid view
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 50))], spacing: 20) {
                            ForEach(filteredVideoFiles, id: \.self) { videoURL in
                                VideoGridItem(
                                    videoURL: videoURL,
                                    thumbnail: thumbnailForVideo(videoURL),
                                    size: thumbnailSize,
                                    editingVideo: $editingVideo,
                                    editingText: $editingText,
                                    onRename: renameVideo,
                                    isUnsupported: unsupportedFiles.contains(videoURL),
                                    metadata: videoMetadata[videoURL]
                                )
                                .onTapGesture(count: 2) {
                                    if editingVideo == nil {
                                        videoToPlay = videoURL
                                    }
                                }
                                .contextMenu {
                                    Button(action: {
                                        showDeleteConfirmation(for: videoURL)
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    // List view
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 12) {
                            Text("")
                                .frame(width: 40) // Space for thumbnail
                            
                            Button(action: {
                                if sortOrder == .name {
                                    sortAscending.toggle()
                                } else {
                                    sortOrder = .name
                                    sortAscending = true
                                }
                                applyFilters()
                            }) {
                                HStack(spacing: 4) {
                                    Text("Name")
                                        .font(.system(size: 11))
                                        .fontWeight(sortOrder == .name ? .bold : .medium)
                                    if sortOrder == .name {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9))
                                    }
                                }
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Click to sort by name")
                            
                            Button(action: {
                                if sortOrder == .duration {
                                    sortAscending.toggle()
                                } else {
                                    sortOrder = .duration
                                    sortAscending = true
                                }
                                applyFilters()
                            }) {
                                HStack(spacing: 4) {
                                    Text("Duration")
                                        .font(.system(size: 11))
                                        .fontWeight(sortOrder == .duration ? .bold : .medium)
                                    if sortOrder == .duration {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9))
                                    }
                                }
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Click to sort by duration")
                            
                            Button(action: {
                                if sortOrder == .size {
                                    sortAscending.toggle()
                                } else {
                                    sortOrder = .size
                                    sortAscending = true
                                }
                                applyFilters()
                            }) {
                                HStack(spacing: 4) {
                                    Text("Size")
                                        .font(.system(size: 11))
                                        .fontWeight(sortOrder == .size ? .bold : .medium)
                                    if sortOrder == .size {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9))
                                    }
                                }
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Click to sort by file size")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.1))
                        
                        Divider()
                        
                        List(filteredVideoFiles, id: \.self, selection: $selectedVideos) { videoURL in
                            VideoListRow(
                                videoURL: videoURL,
                                thumbnail: thumbnailForVideo(videoURL),
                                editingVideo: $editingVideo,
                                editingText: $editingText,
                                onRename: renameVideo,
                                isUnsupported: unsupportedFiles.contains(videoURL),
                                metadata: videoMetadata[videoURL],
                                isSelected: selectedVideos.contains(videoURL)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                singleTapTimer?.invalidate()
                                singleTapTimer = nil
                                if editingVideo == nil {
                                    videoToPlay = videoURL
                                }
                            }
                            .onTapGesture(count: 1) {
                                singleTapTimer?.invalidate()
                                singleTapTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                                    handleVideoSelection(videoURL)
                                }
                            }
                            .contextMenu {
                                if selectedVideos.contains(videoURL) && selectedVideos.count > 1 {
                                    Button(action: {
                                        showBatchDeleteConfirmation()
                                    }) {
                                        Label("Delete \(selectedVideos.count) files", systemImage: "trash")
                                    }
                                } else {
                                    Button(action: {
                                        showDeleteConfirmation(for: videoURL)
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert("Delete Video", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let video = videoToDelete {
                    deleteVideo(video)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(videoToDelete?.lastPathComponent ?? "")'? This action cannot be undone.")
        }
        .sheet(isPresented: $showingCleanupPreview) {
            CleanupPreviewView(
                videoFiles: filteredVideoFiles,
                directoryURL: directoryURL,
                isPresented: $showingCleanupPreview,
                onComplete: {
                    // Reload files after cleanup
                    Task {
                        await initializeVideoList()
                    }
                }
            )
        }
        .sheet(isPresented: $showingScreenshotProgress) {
            ScreenshotProgressView(
                videoFiles: localVideoFiles,
                directoryURL: directoryURL,
                isPresented: $showingScreenshotProgress,
                onComplete: {
                    // Reload thumbnails after screenshot generation
                    loadThumbnails()
                }
            )
        }
        .sheet(isPresented: $showingMKVRemux) {
            MKVRemuxProgressView(
                directoryURL: directoryURL,
                isPresented: $showingMKVRemux,
                onComplete: {
                    // Reload files after conversion
                    loadVideoFiles()
                    loadThumbnails()
                    applyFilters()
                }
            )
        }
        .sheet(isPresented: $showingVideoConversion) {
            VideoConversionProgressView(
                directoryURL: directoryURL,
                allVideoFiles: videoFiles,
                isPresented: $showingVideoConversion,
                onComplete: {
                    // Refresh to show converted files
                    loadVideoFiles()
                    loadThumbnails()
                    applyFilters()
                }
            )
        }
        .onAppear {
            print("🎬 VideoListView onAppear")
            Task {
                await initializeVideoList()
            }
        }
        .onChange(of: directoryURL) { _, _ in
            // Clear metadata when switching directories
            videoMetadata.removeAll()
            Task {
                await initializeVideoList()
            }
        }
        .onChange(of: selectedCategories) { _, _ in
            applyFilters()
        }
        .onChange(of: selectedResolutions) { _, _ in
            applyFilters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshThumbnails)) { notification in
            if let userInfo = notification.userInfo,
               let videoURL = userInfo["videoURL"] as? URL,
               let thumbnail = userInfo["thumbnail"] as? NSImage {
                // Update just this single thumbnail
                thumbnails[videoURL] = thumbnail
                
                // Also cache it locally if on network drive
                if isNetworkPath(directoryURL) {
                    cacheThumbnail(thumbnail, for: videoURL)
                }
            } else {
                // Full reload only if no specific thumbnail provided
                loadThumbnails()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("videoResolutionsUpdated"))) { notification in
            if let resolutions = notification.userInfo?["resolutions"] as? [URL: String] {
                videoResolutions = resolutions
                if let unsupported = notification.userInfo?["unsupported"] as? Set<URL> {
                    unsupportedFiles = unsupported
                }
                applyFilters()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshBrowser)) { _ in
            videoMetadata.removeAll()
            Task {
                await initializeVideoList()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("categoriesUpdated"))) { _ in
            // Refresh the filtered list when categories are updated
            applyFilters()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("thumbnailCreated"))) { notification in
            // Update just the specific thumbnail that was created
            if let videoURL = notification.userInfo?["videoURL"] as? URL,
               let thumbnail = notification.userInfo?["thumbnail"] as? NSImage {
                // Update the UI immediately
                thumbnails[videoURL] = thumbnail
                
                // Cache it locally if it's a network drive (in background)
                if isNetworkPath(directoryURL) {
                    DispatchQueue.global(qos: .background).async {
                        self.cacheThumbnail(thumbnail, for: videoURL)
                    }
                }
                
                print("✅ Updated thumbnail for: \(videoURL.lastPathComponent)")
            }
        }
    }
    
    private func initializeVideoList() async {
        // Prevent concurrent loads
        guard !isLoadingData else { return }
        isLoadingData = true
        
        defer { 
            Task { @MainActor in
                isLoadingData = false
            }
        }
        
        // Load files first
        await loadVideoFilesAsync()
        // Then load thumbnails
        await loadThumbnailsAsync()
        // Finally apply filters
        await MainActor.run {
            applyFilters()
        }
    }
    
    private func loadVideoFiles() {
        print("📂 loadVideoFiles() called")
        Task {
            await loadVideoFilesAsync()
        }
    }
    
    @MainActor
    private func loadVideoFilesAsync() async {
        localVideoFiles = await getVideoFilesAsync()
        videoFiles = localVideoFiles
        print("📂 Found \(localVideoFiles.count) video files")
        
        // Load metadata for all video files from cache
        await loadMetadataFromCache()
    }
    
    @MainActor
    private func loadMetadataFromCache() async {
        var loadedCount = 0
        
        // Create a local copy to avoid concurrent modification issues
        let videoFiles = Array(localVideoFiles)
        
        print("📊 Starting metadata load for \(videoFiles.count) files...")
        
        // For large directories, load metadata in background
        if videoFiles.count > 100 {
            // Load first 100 immediately for quick display
            let initialBatch = Array(videoFiles.prefix(100))
            var tempMetadata: [URL: VideoMetadata] = [:]
            
            for videoFile in initialBatch {
                if let cachedMetadata = VideoMetadataManager.shared.getCachedMetadata(for: videoFile.path) {
                    tempMetadata[videoFile] = VideoMetadata(
                        resolution: cachedMetadata.resolution,
                        duration: cachedMetadata.duration,
                        fileSize: cachedMetadata.fileSize
                    )
                    loadedCount += 1
                }
            }
            
            // Update the binding all at once
            videoMetadata.merge(tempMetadata) { _, new in new }
            
            print("📊 Loaded initial \(loadedCount) metadata entries")
            
            // Apply filters to show initial results immediately
            applyFilters()
            
            // Force the binding to update by posting notification with a small delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: Notification.Name("videoMetadataLoaded"), object: nil)
            }
            
            // Load the rest in background
            Task.detached(priority: .background) {
                
                for i in 100..<videoFiles.count {
                    if let cachedMetadata = VideoMetadataManager.shared.getCachedMetadata(for: videoFiles[i].path) {
                        await MainActor.run {
                            self.videoMetadata[videoFiles[i]] = VideoMetadata(
                                resolution: cachedMetadata.resolution,
                                duration: cachedMetadata.duration,
                                fileSize: cachedMetadata.fileSize
                            )
                        }
                    }
                    
                    // Yield frequently
                    if i % 50 == 0 {
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    }
                }
                
                print("📊 Background metadata load complete")
                
                // Notify that metadata loading is complete
                await MainActor.run {
                    NotificationCenter.default.post(name: Notification.Name("videoMetadataLoaded"), object: nil)
                }
            }
        } else {
            // For small directories, load all at once
            for videoFile in videoFiles {
                if let cachedMetadata = VideoMetadataManager.shared.getCachedMetadata(for: videoFile.path) {
                    videoMetadata[videoFile] = VideoMetadata(
                        resolution: cachedMetadata.resolution,
                        duration: cachedMetadata.duration,
                        fileSize: cachedMetadata.fileSize
                    )
                    loadedCount += 1
                }
            }
            print("📊 Loaded \(loadedCount) metadata entries from cache")
        }
        
        // Notify that metadata loading is complete
        NotificationCenter.default.post(name: Notification.Name("videoMetadataLoaded"), object: nil)
    }
    
    private func applyFilters() {
        // Start with all video files
        var filtered = localVideoFiles
        
        // Filter by categories
        if !selectedCategories.isEmpty {
            // Check if non-categorized filter is selected
            let includeNonCategorized = selectedCategories.contains(-1)
            let regularCategories = selectedCategories.filter { $0 != -1 }
            
            filtered = filtered.filter { videoURL in
                let videoCategories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
                
                // If only non-categorized is selected
                if regularCategories.isEmpty && includeNonCategorized {
                    return videoCategories.isEmpty
                }
                
                // If non-categorized is selected along with other categories
                if includeNonCategorized && videoCategories.isEmpty {
                    return true
                }
                
                // Check if video has ALL of the selected regular categories (AND logic)
                if !regularCategories.isEmpty {
                    return regularCategories.isSubset(of: videoCategories)
                }
                
                return false
            }
        }
        
        // Filter by resolution
        if !selectedResolutions.isEmpty {
            filtered = filtered.filter { videoURL in
                if let resolution = videoMetadata[videoURL]?.resolution {
                    return selectedResolutions.contains(resolution)
                }
                return false
            }
        }
        
        // Filter by search text
        if !searchText.isEmpty {
            filtered = filtered.filter { videoURL in
                videoURL.lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Final deduplication step to ensure no duplicates make it to ForEach
        let uniqueFiltered = Array(Set(filtered))
        
        // Apply sorting
        filteredVideoFiles = uniqueFiltered.sorted { file1, file2 in
            switch sortOrder {
            case .name:
                let result = file1.lastPathComponent.localizedCaseInsensitiveCompare(file2.lastPathComponent)
                return sortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
                
            case .duration:
                let duration1 = videoMetadata[file1]?.duration ?? 0
                let duration2 = videoMetadata[file2]?.duration ?? 0
                return sortAscending ? (duration1 < duration2) : (duration1 > duration2)
                
            case .size:
                let size1 = videoMetadata[file1]?.fileSize ?? 0
                let size2 = videoMetadata[file2]?.fileSize ?? 0
                return sortAscending ? (size1 < size2) : (size1 > size2)
            }
        }
    }
    
    private func getDisplayName(for url: URL) -> String {
        if url.path == "/" {
            return "Root"
        } else if url.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "Home"
        } else {
            return url.lastPathComponent
        }
    }
    
    private func getVideoFiles() -> [URL] {
        // Synchronous version kept for compatibility, but should not be used
        // Use getVideoFilesAsync instead
        return []
    }
    
    private func getVideoFilesAsync() async -> [URL] {
        let fileManager = FileManager.default
        
        // First, try to restore bookmark access if we have one
        if let bookmarkData = UserDefaults.standard.data(forKey: "bookmark_\(directoryURL.path)") {
            do {
                var isStale = false
                let restoredURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if restoredURL == directoryURL && !isStale {
                    _ = restoredURL.startAccessingSecurityScopedResource()
                    print("✅ Restored security-scoped access from bookmark for: \(directoryURL.lastPathComponent)")
                }
            } catch {
                print("Failed to restore bookmark for \(directoryURL.path): \(error)")
            }
        }
        
        // Run directory listing on background thread to avoid blocking
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
            do {
                let contents = try fileManager.contentsOfDirectory(at: self.directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                return .success(contents)
            } catch {
                print("Error reading directory: \(error)")
                return .failure(error)
            }
        }.value
        
        // Handle the result
        let contents: [URL]
        switch result {
        case .success(let files):
            contents = files
            print("📁 Directory contents loaded: \(contents.count) items")
        case .failure(let error):
            // Handle permission errors
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && (nsError.code == 256 || nsError.code == 257) {
                await MainActor.run {
                    self.promptForDirectoryAccess()
                }
            }
            return []
        }
        
        // Process filtering and deduplication async
        let processedFiles = await Task.detached(priority: .userInitiated) { [contents] in
            // Filter for video files
            let videoFiles = contents.filter { url in
                self.videoExtensions.contains(url.pathExtension.lowercased())
            }
            
            print("📹 Filtered to \(videoFiles.count) video files")
            
            // Remove duplicates by preferring MP4 versions over originals
            var deduplicatedFiles: [URL] = []
            var fileBasenames: Set<String> = []
            
            // First pass: Add all MP4 files
            for url in videoFiles where url.pathExtension.lowercased() == "mp4" {
                let basename = url.deletingPathExtension().lastPathComponent
                deduplicatedFiles.append(url)
                fileBasenames.insert(basename)
            }
            
            // Second pass: Add non-MP4 files only if no MP4 version exists
            for url in videoFiles where url.pathExtension.lowercased() != "mp4" {
                let basename = url.deletingPathExtension().lastPathComponent
                if !fileBasenames.contains(basename) {
                    deduplicatedFiles.append(url)
                    fileBasenames.insert(basename)
                }
            }
            
            return deduplicatedFiles.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }.value
        
        return processedFiles
    }
    
    private func promptForDirectoryAccess() {
        // Show file picker directly - no need for two dialogs
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Grant access to '\(directoryURL.lastPathComponent)' by selecting it"
        openPanel.prompt = "Grant Access"
        
        // Try to set the directory to the parent, but handle cases where we might not have access
        var startingDirectory = directoryURL.deletingLastPathComponent()
        
        // If the parent is also not accessible, go up until we find one that is
        while !FileManager.default.isReadableFile(atPath: startingDirectory.path) && startingDirectory.path != "/" {
            startingDirectory = startingDirectory.deletingLastPathComponent()
        }
        
        openPanel.directoryURL = startingDirectory
        
        // Also set the directory we want them to select as the filename for convenience
        openPanel.nameFieldStringValue = directoryURL.lastPathComponent
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
                // Save bookmark for persistent access
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(url.path)")
                    
                    // Refresh the view and browser
                    Task {
                        await initializeVideoList()
                        // Notify browser to refresh so it shows unlocked directories
                        NotificationCenter.default.post(name: .refreshBrowser, object: nil)
                    }
                } catch {
                    print("Failed to save bookmark: \(error)")
                }
            }
    }
    
    private func loadThumbnails() {
        // Always load thumbnails asynchronously to prevent UI blocking
        Task {
            await loadThumbnailsAsync()
        }
    }
    
    private func thumbnailForVideo(_ videoURL: URL) -> NSImage? {
        // Return cached thumbnail if available
        if let thumbnail = thumbnails[videoURL] {
            return thumbnail
        }
        
        // For large directories, load thumbnail on demand
        if localVideoFiles.count > 500 {
            Task {
                if let thumbnail = await loadSingleThumbnail(for: videoURL) {
                    await MainActor.run {
                        self.thumbnails[videoURL] = thumbnail
                    }
                }
            }
        }
        
        return nil
    }
    
    @MainActor
    private func loadThumbnailsAsync() async {
        thumbnails.removeAll()
        
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        
        // Check if thumbnail directory exists asynchronously to avoid blocking
        let thumbnailDirExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: videoInfoURL.path)
        }.value
        
        guard thumbnailDirExists else { 
            print("No .video_info directory found")
            return 
        }
        
        // Check if this is a network drive
        let isNetworkDrive = isNetworkPath(directoryURL)
        
        if isNetworkDrive {
            print("Loading thumbnails from network drive: \(directoryURL.path)")
        } else {
            print("Loading thumbnails from local drive: \(directoryURL.path)")
        }
        
        var cachedCount = 0
        var loadedCount = 0
        
        // Create a local copy to avoid concurrent modification issues
        let videoFiles = Array(localVideoFiles)
        
        // For very large directories, load thumbnails on demand
        if videoFiles.count > 500 {
            print("📸 Large directory - loading visible thumbnails only")
            // Load thumbnails as they become visible in the LazyVGrid
            // The grid view will request thumbnails as needed
            return
        }
        
        // Process thumbnails in batches to keep UI responsive
        let batchSize = isNetworkDrive ? 5 : 20
        
        for i in stride(from: 0, to: videoFiles.count, by: batchSize) {
            let endIndex = min(i + batchSize, videoFiles.count)
            guard i < endIndex else { continue }
            let batch = Array(videoFiles[i..<endIndex])
            
            await withTaskGroup(of: (URL, Data?).self) { group in
                for videoURL in batch {
                    group.addTask {
                        // Load thumbnail data instead of NSImage to avoid Sendable issues
                        let thumbnailData = await self.loadSingleThumbnailData(for: videoURL)
                        return (videoURL, thumbnailData)
                    }
                }
                
                for await (videoURL, thumbnailData) in group {
                    if let thumbnailData = thumbnailData,
                       let thumbnail = NSImage(data: thumbnailData) {
                        self.thumbnails[videoURL] = thumbnail
                        if self.loadCachedThumbnail(for: videoURL) != nil {
                            cachedCount += 1
                        } else {
                            loadedCount += 1
                        }
                    }
                }
            }
            
            // Small delay between batches to keep UI responsive
            if i + batchSize < localVideoFiles.count {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
        
        if cachedCount > 0 || loadedCount > 0 {
            print("Thumbnails loaded - Cached: \(cachedCount), Generated: \(loadedCount)")
        }
    }
    
    private func loadSingleThumbnail(for videoURL: URL) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let thumbnail = self.loadSingleThumbnailSync(for: videoURL)
                continuation.resume(returning: thumbnail)
            }
        }
    }
    
    private func loadSingleThumbnailData(for videoURL: URL) async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let videoInfoURL = self.directoryURL.appendingPathComponent(".video_info")
                let videoName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
                let thumbnailURL = videoInfoURL.appendingPathComponent("\(videoName).png")
                
                // Try to load thumbnail data
                if let data = try? Data(contentsOf: thumbnailURL) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func loadSingleThumbnailSync(for videoURL: URL) -> NSImage? {
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        let videoName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        let thumbnailURL = videoInfoURL.appendingPathComponent("\(videoName).png")
        
        let isNetworkDrive = isNetworkPath(directoryURL)
        
        if isNetworkDrive {
            // For network drives, try to load from local cache first
            if let cachedImage = loadCachedThumbnail(for: videoURL) {
                return cachedImage
            } else if FileManager.default.fileExists(atPath: thumbnailURL.path),
                      let image = NSImage(contentsOf: thumbnailURL) {
                // Load from network and cache locally
                cacheThumbnail(image, for: videoURL)
                return image
            }
        } else {
            // For local drives, load directly
            if FileManager.default.fileExists(atPath: thumbnailURL.path),
               let image = NSImage(contentsOf: thumbnailURL) {
                return image
            }
        }
        
        return nil
    }
    
    private func isNetworkPath(_ url: URL) -> Bool {
        // Check if the path is a network mount
        if url.path.hasPrefix("/Volumes/") {
            // On macOS, network drives are typically mounted under /Volumes/
            // Check if it's not a local disk
            do {
                let resourceValues = try url.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeIsLocalKey])
                
                // If volumeIsLocalKey is false, it's a network drive
                if let isLocal = resourceValues.volumeIsLocal {
                    return !isLocal
                } else if resourceValues.volumeURLForRemounting != nil {
                    return true
                }
            } catch {
                // Silently handle errors
            }
        }
        
        // Check for common network path patterns
        return url.path.hasPrefix("/Volumes/") && 
               !url.path.hasPrefix("/Volumes/Macintosh")
    }
    
    private func getCacheDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let appCacheDir = cacheDir.appendingPathComponent("VideoViewer/thumbnails")
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: appCacheDir.path) {
            try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        }
        
        return appCacheDir
    }
    
    private func getCachedThumbnailURL(for videoURL: URL) -> URL? {
        guard let cacheDir = getCacheDirectory() else { return nil }
        
        // Create a unique filename based on the full path
        let pathHash = videoURL.path.data(using: .utf8)?.base64EncodedString() ?? ""
        let safeHash = pathHash.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        
        return cacheDir.appendingPathComponent("\(safeHash).png")
    }
    
    private func loadCachedThumbnail(for videoURL: URL) -> NSImage? {
        guard let cachedURL = getCachedThumbnailURL(for: videoURL) else { return nil }
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            // Check if cache is still valid (e.g., not older than 7 days)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                let age = Date().timeIntervalSince(modificationDate)
                if age < 7 * 24 * 60 * 60 { // 7 days
                    return NSImage(contentsOf: cachedURL)
                }
            }
        }
        
        return nil
    }
    
    private func cacheThumbnail(_ image: NSImage, for videoURL: URL) {
        guard let cachedURL = getCachedThumbnailURL(for: videoURL) else { return }
        
        // Save thumbnail to cache in background
        DispatchQueue.global(qos: .background).async {
            if let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: cachedURL)
            }
        }
    }
    
    private func showDeleteConfirmation(for videoURL: URL) {
        videoToDelete = videoURL
        showingDeleteAlert = true
    }
    
    private func deleteVideo(_ videoURL: URL) {
        do {
            // Delete the video file
            try FileManager.default.removeItem(at: videoURL)
            
            // Delete thumbnail if it exists
            let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
            let videoName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
            let thumbnailURL = videoInfoURL.appendingPathComponent("\(videoName).png")
            
            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
            
            // Remove from database (all category associations)
            // This happens automatically due to the video path no longer existing
            
            // Remove from metadata database
            VideoMetadataManager.shared.removeMetadata(for: videoURL.path)
            
            // Remove just this file from the local state - no need to reload everything
            localVideoFiles.removeAll { $0 == videoURL }
            videoFiles = localVideoFiles
            thumbnails.removeValue(forKey: videoURL)
            videoResolutions.removeValue(forKey: videoURL)
            
            // Apply filters to update the view
            applyFilters()
            
            // Post notification to reload resolutions in the filter sidebar
            NotificationCenter.default.post(name: Notification.Name("reloadResolutions"), object: nil)
            
            // Clear the deletion reference
            videoToDelete = nil
        } catch {
            print("Error deleting video: \(error)")
            // Could show an error alert here if needed
        }
    }
    
    private func renameVideo(_ videoURL: URL, _ newName: String) {
        // Validate the new name
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Create new URL with the same extension
        let newURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(trimmedName)
            .appendingPathExtension(videoURL.pathExtension)
        
        // Check if destination already exists
        if FileManager.default.fileExists(atPath: newURL.path) && newURL != videoURL {
            print("File with name '\(newURL.lastPathComponent)' already exists")
            // Could show an alert here
            return
        }
        
        do {
            // Rename the video file
            try FileManager.default.moveItem(at: videoURL, to: newURL)
            
            // Rename thumbnail if it exists
            let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
            let oldThumbName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
            let newThumbName = newURL.deletingPathExtension().lastPathComponent.lowercased()
            
            let oldThumbURL = videoInfoURL.appendingPathComponent("\(oldThumbName).png")
            let newThumbURL = videoInfoURL.appendingPathComponent("\(newThumbName).png")
            
            if FileManager.default.fileExists(atPath: oldThumbURL.path) {
                try? FileManager.default.moveItem(at: oldThumbURL, to: newThumbURL)
            }
            
            // Update category associations in database
            categoryManager.updateVideoPath(from: videoURL.path, to: newURL.path)
            
            // Update the resolution cache for just this file (don't clear everything!)
            if videoResolutions[videoURL] != nil {
                // Add the new file to cache with the same resolution
                // Resolution is already cached by VideoMetadataManager during scan
                // Note: The old entry will remain but won't matter since the file no longer exists
            }
            
            // Update local state efficiently
            if let index = localVideoFiles.firstIndex(of: videoURL) {
                localVideoFiles[index] = newURL
            }
            
            // Move resolution and thumbnail to new URL
            if let resolution = videoResolutions[videoURL] {
                videoResolutions[newURL] = resolution
                videoResolutions.removeValue(forKey: videoURL)
            }
            
            if let thumbnail = thumbnails[videoURL] {
                thumbnails[newURL] = thumbnail
                thumbnails.removeValue(forKey: videoURL)
            }
            
            // Apply filters to update the view
            videoFiles = localVideoFiles
            applyFilters()
            
            print("Successfully renamed '\(videoURL.lastPathComponent)' to '\(newURL.lastPathComponent)'")
        } catch {
            print("Error renaming video: \(error)")
            // Could show an error alert here
        }
    }
    
    private func refreshDirectory() {
        // Clear any editing state
        editingVideo = nil
        editingText = ""
        
        // Don't clear the cache - just reload to find new files
        // No need to clear cache - database is used directly
        
        // Reload all data
        Task {
            await initializeVideoList()
        }
        
        // The resolution loading will happen automatically via the existing
        // Database lookup when the view refreshes
        // It will only scan new files that aren't in the cache
        
        print("Directory refreshed: \(directoryURL.path)")
    }
    
    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(url.path)")
            print("Saved bookmark for: \(url.path)")
            
            // Try to access the URL to establish permission
            _ = url.startAccessingSecurityScopedResource()
            
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    private func generateScreenshots() {
        showingScreenshotProgress = true
    }
    
    private func prepareVideoConversion() {
        // Just show the conversion dialog - it will filter the files itself
        showingVideoConversion = true
    }
    
    private func loadVideoMetadata() {
        // This function is now deprecated - metadata is loaded in loadVideoResolutions()
        // Only check for missing metadata
        print("📊 Checking for missing metadata...")
        
        var missingCount = 0
        for videoFile in localVideoFiles {
            if videoMetadata[videoFile] == nil {
                missingCount += 1
            }
        }
        
        if missingCount > 0 {
            print("📊 Found \(missingCount) files without metadata")
        } else {
            print("📊 All metadata already loaded from loadVideoResolutions()")
            return
        }
        
        // Then load any missing metadata asynchronously
        Task {
            var missingFiles: [URL] = []
            
            // Find files without metadata or with incomplete metadata
            for videoFile in localVideoFiles {
                if let metadata = videoMetadata[videoFile] {
                    // Check if existing metadata is incomplete
                    if metadata.duration == nil || metadata.fileSize == nil {
                        missingFiles.append(videoFile)
                    }
                } else {
                    // No metadata at all
                    missingFiles.append(videoFile)
                }
            }
            
            // Note: Incomplete metadata files are now handled in loadVideoResolutions()
            
            if !missingFiles.isEmpty {
                print("📊 Loading metadata for \(missingFiles.count) files without cached data")
                // Process in batches
                let batchSize = directoryURL.path.hasPrefix("/Volumes/") ? 3 : 5
                var loadedCount = 0
                
                for i in stride(from: 0, to: missingFiles.count, by: batchSize) {
                    let batch = Array(missingFiles[i..<min(i + batchSize, missingFiles.count)])
                    
                    await withTaskGroup(of: (URL, VideoMetadata?).self) { group in
                        for videoFile in batch {
                            group.addTask {
                                let metadata = await self.getVideoMetadataAsync(for: videoFile)
                                return (videoFile, metadata)
                            }
                        }
                        
                        for await (videoFile, metadata) in group {
                            if let metadata = metadata {
                                // Cache the result
                                // Metadata is already cached by VideoMetadataManager
                                
                                // Update UI
                                await MainActor.run {
                                    self.videoMetadata[videoFile] = metadata
                                    loadedCount += 1
                                    // Commented out to reduce console spam
                                    // print("📊 Loaded metadata for \(videoFile.lastPathComponent): duration=\(metadata.duration ?? 0)s, size=\(metadata.fileSize ?? 0)")
                                }
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    print("📊 Finished loading metadata. Total: \(self.videoMetadata.count)")
                }
            }
        }
    }
    
    private func getVideoMetadataAsync(for url: URL) async -> VideoMetadata? {
        // First check if we have cached metadata in the database
        let cachedMetadata = VideoMetadataManager.shared.getCachedMetadata(for: url.path)
        
        if let cachedMetadata = cachedMetadata {
            // Check if file has been modified since last scan
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let currentModDate = attributes?[.modificationDate] as? Date ?? Date()
            
            // Debug logging commented out to reduce console spam
            // if url.lastPathComponent.hasPrefix("!!") {
            //     let formatter = DateFormatter()
            //     formatter.dateStyle = .short
            //     formatter.timeStyle = .medium
            //     print("🔍 File: \(url.lastPathComponent)")
            //     print("   📅 File mod date: \(formatter.string(from: currentModDate))")
            //     print("   💾 Cached date:   \(formatter.string(from: cachedMetadata.lastModified))")
            //     print("   ⚖️ Use cache? \(cachedMetadata.lastModified >= currentModDate)")
            // }
            
            // If file hasn't been modified since last scan, use cache
            if cachedMetadata.lastModified >= currentModDate {
                return VideoMetadata(
                    resolution: cachedMetadata.resolution,
                    duration: cachedMetadata.duration,
                    fileSize: cachedMetadata.fileSize
                )
            }
        }
        
        // Scan the video file for metadata
        let result = await VideoMetadataManager.shared.getVideoMetadataAsyncInternal(for: url)
        
        if let result = result {
            // Get file size and cache the metadata
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes?[.size] as? Int64 ?? 0
            let modDate = fileAttributes?[.modificationDate] as? Date ?? Date()
            
            // Cache the metadata
            let cachedMetadata = VideoMetadataManager.CachedMetadata(
                path: url.path,
                resolution: result.resolution,
                duration: result.duration,
                fileSize: fileSize,
                lastModified: modDate,
                lastScanned: Date()
            )
            VideoMetadataManager.shared.cacheMetadata(cachedMetadata)
            
            return VideoMetadata(
                resolution: result.resolution,
                duration: result.duration,
                fileSize: fileSize
            )
        }
        
        return nil
    }
    
    
    // MARK: - Multi-Selection Functions
    
    private func handleVideoSelection(_ videoURL: URL) {
        let isCommandPressed = NSEvent.modifierFlags.contains(.command)
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)
        
        if isShiftPressed && lastSelectedVideo != nil {
            // Shift selection - select range
            selectVideoRange(from: lastSelectedVideo!, to: videoURL)
        } else if isCommandPressed {
            // Command selection - toggle individual
            if selectedVideos.contains(videoURL) {
                selectedVideos.remove(videoURL)
            } else {
                selectedVideos.insert(videoURL)
                lastSelectedVideo = videoURL
            }
        } else {
            // Normal click - select only this video
            selectedVideos = [videoURL]
            lastSelectedVideo = videoURL
        }
    }
    
    private func selectVideoRange(from startURL: URL, to endURL: URL) {
        guard let startIndex = filteredVideoFiles.firstIndex(of: startURL),
              let endIndex = filteredVideoFiles.firstIndex(of: endURL) else { return }
        
        let minIndex = min(startIndex, endIndex)
        let maxIndex = max(startIndex, endIndex)
        
        // Add all videos in range to selection
        for index in minIndex...maxIndex {
            selectedVideos.insert(filteredVideoFiles[index])
        }
    }
    
    private func showBatchDeleteConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Delete \(selectedVideos.count) videos?"
        alert.informativeText = "Are you sure you want to delete these \(selectedVideos.count) videos? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            batchDeleteVideos()
        }
    }
    
    private func batchDeleteVideos() {
        let videosToDelete = Array(selectedVideos)
        selectedVideos.removeAll()
        
        for videoURL in videosToDelete {
            deleteVideo(videoURL)
        }
    }
}

struct VideoListRow: View {
    let videoURL: URL
    let thumbnail: NSImage?
    @Binding var editingVideo: URL?
    @Binding var editingText: String
    let onRename: (URL, String) -> Void
    let isUnsupported: Bool
    let metadata: VideoMetadata?
    let isSelected: Bool
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var hasCategories: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail with overlays
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 30)
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 40, height: 30)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundColor(.gray)
                                .font(.system(size: 16))
                        )
                }
                
                // Red X overlay for unsupported files
                if isUnsupported {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                                .font(.system(size: 8, weight: .bold))
                        )
                        .offset(x: 15, y: -8)
                }
                
                // Green checkmark if video has categories
                if hasCategories {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Image(systemName: "checkmark")
                                .foregroundColor(.white)
                                .font(.system(size: 8, weight: .bold))
                        )
                        .offset(x: 15, y: 8)
                }
            }
            .frame(width: 40, height: 30)
            
            // Filename (left-aligned, takes remaining space)
            if editingVideo == videoURL {
                // Edit mode
                HStack(spacing: 0) {
                    TextField("Filename", text: $editingText, onCommit: {
                        if !editingText.isEmpty {
                            onRename(videoURL, editingText)
                        }
                        editingVideo = nil
                        isTextFieldFocused = false
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: .infinity)
                    .focused($isTextFieldFocused)
                    .onExitCommand {
                        // Cancel edit on Escape key
                        editingVideo = nil
                        editingText = ""
                        isTextFieldFocused = false
                    }
                    .onAppear {
                        // Focus the text field when it appears
                        isTextFieldFocused = true
                    }
                    
                    Text(".\(videoURL.pathExtension)")
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            } else {
                // Display mode
                Text(videoURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        editingVideo = videoURL
                        editingText = videoURL.deletingPathExtension().lastPathComponent
                    }
            }
            
            // Duration column
            if let duration = metadata?.duration, duration > 0 {
                Text(ContentView.formatDuration(duration))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            } else {
                Text("--:--")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary.opacity(0.5))
                    .frame(width: 70, alignment: .trailing)
            }
            
            // File size column
            if let fileSize = metadata?.fileSize, fileSize > 0 {
                Text(ContentView.formatFileSize(fileSize))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .trailing)
            } else {
                Text("--")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary.opacity(0.5))
                    .frame(width: 90, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        .onAppear {
            checkCategories()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("categoriesUpdated"))) { _ in
            checkCategories()
        }
    }
    
    private func checkCategories() {
        // Check if this video has any categories assigned
        let categories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
        hasCategories = !categories.isEmpty
    }
}

struct VideoGridItem: View {
    let videoURL: URL
    let thumbnail: NSImage?
    let size: Double
    @Binding var editingVideo: URL?
    @Binding var editingText: String
    let onRename: (URL, String) -> Void
    let isUnsupported: Bool
    let metadata: VideoMetadata?
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var hasCategories: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: size * 0.75) // Maintain 16:9 aspect ratio approximately
                        .cornerRadius(8)
                        .shadow(radius: 2)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: size * 0.75)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: size * 0.25))
                                .foregroundColor(.gray)
                        )
                }
                
                // Red X overlay for unsupported files
                if isUnsupported {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                
                // Green checkmark if video has categories (bottom right)
                if hasCategories {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .fill(Color.green)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: 12, weight: .bold))
                                )
                                .padding(8)
                        }
                    }
                }
            }
            
            if editingVideo == videoURL {
                // Edit mode
                HStack(spacing: 2) {
                    TextField("Filename", text: $editingText, onCommit: {
                        if !editingText.isEmpty {
                            onRename(videoURL, editingText)
                        }
                        editingVideo = nil
                        isTextFieldFocused = false
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: min(12, size * 0.08)))
                    .focused($isTextFieldFocused)
                    .onExitCommand {
                        // Cancel edit on Escape key
                        editingVideo = nil
                        editingText = ""
                        isTextFieldFocused = false
                    }
                    .onAppear {
                        // Focus the text field when it appears
                        isTextFieldFocused = true
                    }
                    
                    Text(".\(videoURL.pathExtension)")
                        .font(.system(size: min(12, size * 0.08)))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Display mode
                VStack(spacing: 2) {
                    Text(videoURL.lastPathComponent)
                        .font(.system(size: min(12, size * 0.08)))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .onTapGesture {
                            editingVideo = videoURL
                            editingText = videoURL.deletingPathExtension().lastPathComponent
                        }
                    
                    // Duration
                    if let duration = metadata?.duration, duration > 0 {
                        Text(ContentView.formatDuration(duration))
                            .font(.system(size: min(10, size * 0.065)))
                            .foregroundColor(.secondary)
                    } else {
                        Text("--:--")
                            .font(.system(size: min(10, size * 0.065)))
                            .foregroundColor(Color.secondary.opacity(0.5))
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .onAppear {
            checkCategories()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("categoriesUpdated"))) { _ in
            checkCategories()
        }
    }
    
    private func checkCategories() {
        // Check if this video has any categories assigned
        let categories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
        hasCategories = !categories.isEmpty
    }
}

// Separate view for category selection to avoid constraint update loops
struct CategorySelectionView: View {
    let videoPath: String
    @Binding var selectedCategories: Set<Int>
    let categoryManager: CategoryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Categories")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.bottom, 2)
                
                // Use FlowLayout for all groups and categories
                FlowLayout(spacing: 12) {
                    // Show ungrouped categories first
                    let ungroupedCategories = categoryManager.getUngroupedCategories()
                    if !ungroupedCategories.isEmpty {
                        CategoryGroupView(
                            title: "Ungrouped",
                            categories: ungroupedCategories,
                            selectedCategories: selectedCategories,
                            toggleAction: toggleCategory
                        )
                    }
                    
                    // Show grouped categories
                    ForEach(categoryManager.categoryGroups) { group in
                        let groupCategories = categoryManager.getCategoriesInGroup(groupId: group.id)
                        if !groupCategories.isEmpty {
                            CategoryGroupView(
                                title: group.name,
                                categories: groupCategories,
                                selectedCategories: selectedCategories,
                                toggleAction: toggleCategory,
                                icon: group.allowMultiple ? "folder.badge.plus" : "folder.badge.minus",
                                iconColor: group.allowMultiple ? .blue : .orange,
                                subtitle: group.allowMultiple ? "(Multi)" : "(Single)"
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private func toggleCategory(_ category: CategoryManager.Category) {
        let isSelected = !selectedCategories.contains(category.id)
        
        print("🔄 Toggling category '\(category.name)' to \(isSelected)")
        
        // Enforce group selection rules
        let updatedCategories = categoryManager.enforceGroupSelectionRules(
            for: videoPath,
            selectedCategoryId: category.id,
            isSelected: isSelected
        )
        
        // Update the binding
        selectedCategories = updatedCategories
        
        // Apply changes to database
        categoryManager.applyCategoriesToVideo(
            videoPath: videoPath,
            categories: updatedCategories
        )
        
        // Notify views
        NotificationCenter.default.post(
            name: Notification.Name("categoriesUpdated"),
            object: nil
        )
    }
}

// Group view that contains categories
struct CategoryGroupView: View {
    let title: String
    let categories: [CategoryManager.Category]
    let selectedCategories: Set<Int>
    let toggleAction: (CategoryManager.Category) -> Void
    var icon: String? = nil
    var iconColor: Color? = nil
    var subtitle: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Group header
            HStack(spacing: 4) {
                if let icon = icon, let iconColor = iconColor {
                    Image(systemName: icon)
                        .foregroundColor(iconColor)
                        .font(.caption)
                }
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .italic()
                }
            }
            
            // Categories in this group
            FlowLayout(spacing: 6) {
                ForEach(categories) { category in
                    CategoryToggleItem(
                        category: category,
                        isSelected: selectedCategories.contains(category.id),
                        action: {
                            toggleAction(category)
                        }
                    )
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

// Simple toggle item without complex bindings
struct CategoryToggleItem: View {
    let category: CategoryManager.Category
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(.white)
                    .font(.system(size: 14))
                
                Text(category.name)
                    .foregroundColor(.white)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Color.white.opacity(0.2) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// Simple flow layout to replace LazyVGrid
struct FlowLayout: Layout {
    let spacing: CGFloat
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                    y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > (proposal.width ?? .infinity) && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}

// Window controller to properly manage window lifecycle
class VideoWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let id = UUID()
    
    convenience init(videoURL: URL, onClose: @escaping () -> Void) {
        // Load saved window frame or use defaults
        let savedFrame = UserDefaults.standard.string(forKey: "videoWindowFrame")
        let defaultRect = NSRect(x: 100, y: 100, width: 800, height: 600)
        let windowRect: NSRect
        
        if let savedFrame = savedFrame,
           let frame = NSRectFromString(savedFrame) as NSRect?,
           frame.width > 0 && frame.height > 0 {
            // Ensure the saved frame is still visible on current screen configuration
            let screens = NSScreen.screens
            
            // Find the screen that contains the window or use main screen
            let targetScreen = screens.first { screen in
                screen.frame.intersects(frame)
            } ?? NSScreen.main ?? screens.first
            
            if let screen = targetScreen {
                let screenFrame = screen.visibleFrame // Use visibleFrame to account for menu bar and dock
                
                // Constrain the window size to fit within the screen
                var constrainedFrame = frame
                
                // Ensure window doesn't exceed screen height (leave some margin)
                let maxHeight = screenFrame.height - 50 // Leave 50pt margin
                if constrainedFrame.height > maxHeight {
                    constrainedFrame.size.height = maxHeight
                }
                
                // Ensure window doesn't exceed screen width
                let maxWidth = screenFrame.width - 50
                if constrainedFrame.width > maxWidth {
                    constrainedFrame.size.width = maxWidth
                }
                
                // Ensure window is positioned within screen bounds
                if constrainedFrame.minX < screenFrame.minX {
                    constrainedFrame.origin.x = screenFrame.minX + 20
                }
                if constrainedFrame.minY < screenFrame.minY {
                    constrainedFrame.origin.y = screenFrame.minY + 20
                }
                if constrainedFrame.maxX > screenFrame.maxX {
                    constrainedFrame.origin.x = screenFrame.maxX - constrainedFrame.width - 20
                }
                if constrainedFrame.maxY > screenFrame.maxY {
                    constrainedFrame.origin.y = screenFrame.maxY - constrainedFrame.height - 20
                }
                
                windowRect = constrainedFrame
                print("Window frame constrained - Original: \(frame), Constrained: \(constrainedFrame), Screen: \(screenFrame)")
            } else {
                windowRect = defaultRect
            }
        } else {
            windowRect = defaultRect
        }
        
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = videoURL.lastPathComponent
        
        self.init(window: window)
        self.onClose = onClose
        
        let playerContent = VideoPlayerContent(videoURL: videoURL)
        window.contentView = NSHostingView(rootView: playerContent)
        window.delegate = self
    }
    
    func windowWillClose(_ notification: Notification) {
        print("=== VideoWindowController windowWillClose ===")
        
        // Save window frame before closing
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "videoWindowFrame")
        }
        
        // Force clear the content view to trigger cleanup
        window?.contentView = nil
        
        onClose?()
        print("Window close complete")
    }
    
    func windowDidResize(_ notification: Notification) {
        // Save window frame when resized
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "videoWindowFrame")
        }
    }
    
    func windowDidMove(_ notification: Notification) {
        // Save window frame when moved
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "videoWindowFrame")
        }
    }
}

// Keep window controllers alive
private var activeWindowControllers = [VideoWindowController]()

struct WindowOpener: NSViewRepresentable {
    let videoURL: URL
    @Binding var isPresented: Bool
    @Binding var videoToPlay: URL?
    
    func makeNSView(context: Context) -> NSView {
        print("=== WindowOpener makeNSView for \(videoURL.lastPathComponent) ===")
        let view = NSView()
        DispatchQueue.main.async {
            self.openVideoWindow()
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private func openVideoWindow() {
        print("=== Opening window for \(videoURL.lastPathComponent) ===")
        
        var windowController: VideoWindowController?
        
        let controller = VideoWindowController(videoURL: videoURL) { [self] in
            print("=== Window closed, resetting state ===")
            self.isPresented = false
            self.videoToPlay = nil  // This is the key - reset to nil so we can reopen
            
            // Also remove from active controllers using the stored reference
            if let wc = windowController {
                activeWindowControllers.removeAll { $0.id == wc.id }
            }
        }
        
        windowController = controller
        
        // Keep controller alive
        activeWindowControllers.append(controller)
        
        controller.showWindow(nil)
        print("Window shown, controller count: \(activeWindowControllers.count)")
    }
}

// Simple wrapper to track last known volume and mute state
class PlayerObserver: NSObject, ObservableObject {
    private var lastKnownVolume: Float = 1.0
    
    func saveCurrentState(volume: Float, isMuted: Bool) {
        UserDefaults.standard.set(volume, forKey: "lastVideoVolume")
        UserDefaults.standard.set(isMuted, forKey: "lastVideoMuted")
        print("Saved volume: \(volume), muted: \(isMuted)")
    }
    
    func getLastVolume() -> Float {
        // Check if we have a saved value (including 0 for mute)
        if UserDefaults.standard.object(forKey: "lastVideoVolume") != nil {
            return UserDefaults.standard.float(forKey: "lastVideoVolume")
        }
        // Default to 1.0 if nothing saved
        return 1.0
    }
    
    func getLastMuted() -> Bool {
        return UserDefaults.standard.bool(forKey: "lastVideoMuted")
    }
}

// Track active timers for debugging
private var activeTimerCount = 0

// Wrapper class to track VideoPlayerContent lifecycle
class VideoPlayerContentTracker: ObservableObject {
    let id = UUID()
    
    init() {
        print("=== VideoPlayerContentTracker init \(id) ===")
    }
    
    deinit {
        print("=== VideoPlayerContentTracker deinit \(id) ===")
    }
}

struct VideoPlayerContent: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var isCapturing: Bool = false
    @StateObject private var playerObserver = PlayerObserver()
    @State private var volumeCheckTimer: Timer?
    @StateObject private var tracker = VideoPlayerContentTracker()
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var selectedCategories: Set<Int> = []
    @State private var showCategories: Bool = false
    @State private var isPlayerReady: Bool = false
    @State private var isUpdatingCategories: Bool = false
    
    init(videoURL: URL) {
        self.videoURL = videoURL
        // Don't create player in init - wait for onAppear to avoid metadata race conditions
        self._player = State(initialValue: nil)
        print("VideoPlayerContent init for: \(videoURL.lastPathComponent)")
    }
    
    private func createPlayer() {
        guard player == nil else { return }
        
        // Create player on main queue to avoid threading issues
        DispatchQueue.main.async {
            let newPlayer = AVPlayer(url: videoURL)
            
            // Restore last saved volume and mute state
            if UserDefaults.standard.object(forKey: "lastVideoVolume") != nil {
                newPlayer.volume = UserDefaults.standard.float(forKey: "lastVideoVolume")
            } else {
                newPlayer.volume = 1.0
            }
        
            // Restore mute state
            newPlayer.isMuted = UserDefaults.standard.bool(forKey: "lastVideoMuted")
            
            self.player = newPlayer
            self.isPlayerReady = true
            print("Created player with volume: \(newPlayer.volume), muted: \(newPlayer.isMuted)")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let player = player, isPlayerReady {
                SafeVideoPlayer(player: player)
                    .onAppear {
                        player.play()
                        
                        // Load categories for this video after a delay to avoid constraint issues
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            selectedCategories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
                        }
                        
                        // Start a timer to periodically check volume and mute state
                        activeTimerCount += 1
                        print("Starting timer, active count: \(activeTimerCount)")
                        
                        volumeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                            let currentVolume = player.volume
                            let currentMuted = player.isMuted
                            
                            // Check if volume or mute state changed
                            if currentVolume != UserDefaults.standard.float(forKey: "lastVideoVolume") ||
                               currentMuted != UserDefaults.standard.bool(forKey: "lastVideoMuted") {
                                // Only log state changes, not every timer tick
                                playerObserver.saveCurrentState(volume: currentVolume, isMuted: currentMuted)
                            }
                        }
                    }
            } else {
                // Loading state while player is being created
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Loading video...")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
            
            // Bottom toolbar
            VStack(spacing: 0) {
                // Category checkboxes
                if !categoryManager.categories.isEmpty && showCategories {
                    CategorySelectionView(
                        videoPath: videoURL.path,
                        selectedCategories: $selectedCategories,
                        categoryManager: categoryManager
                    )
                    .frame(maxHeight: 200)
                    .background(Color.black.opacity(0.6))
                }
                
                // Bottom controls
                HStack {
                    // Categories toggle button
                    if !categoryManager.categories.isEmpty {
                        Button(action: {
                            print("🏷️ Categories button clicked, current state: \(showCategories)")
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCategories.toggle()
                                print("🏷️ Categories now: \(showCategories)")
                            }
                        }) {
                            Image(systemName: showCategories ? "tag.fill" : "tag")
                                .foregroundColor(.white)
                                .font(.system(size: 28))
                                .frame(width: 60, height: 60)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.2))
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(showCategories ? "Hide Categories" : "Show Categories")
                        .padding()
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isCapturing = true
                        }
                        generateThumbnail()
                        
                        // Reset animation after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isCapturing = false
                            }
                        }
                    }) {
                        Image(systemName: "camera.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 28))
                            .frame(width: 60, height: 60)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                    )
                            )
                            .scaleEffect(isCapturing ? 0.8 : 1.0)
                            .opacity(isCapturing ? 0.6 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .help("Capture Screenshot")
                    .padding()
                }
                .background(Color.black.opacity(0.8))
            }
        }
        .background(Color.black)
        .onAppear {
            // Create player safely on main thread when view appears
            createPlayer()
        }
        .onDisappear {
            print("=== VideoPlayer onDisappear START ===")
            
            // Stop timer immediately
            if let timer = volumeCheckTimer {
                timer.invalidate()
                volumeCheckTimer = nil
                activeTimerCount -= 1
                print("Timer invalidated, active count: \(activeTimerCount)")
            } else {
                print("No timer to invalidate")
            }
            
            // Only cleanup player if it exists
            if let player = player {
                // Save current state before closing
                playerObserver.saveCurrentState(volume: player.volume, isMuted: player.isMuted)
                print("Final volume: \(player.volume), muted: \(player.isMuted)")
                
                // Force stop playback
                print("Stopping playback...")
                player.pause()
                player.seek(to: .zero)
                player.rate = 0
                player.replaceCurrentItem(with: nil)
            }
            
            // Clear all player references
            print("Clearing player references")
            self.player = nil
            self.isPlayerReady = false
            
            print("=== VideoPlayer onDisappear END ===")
        }
    }
    
    
    private func generateThumbnail() {
        guard let player = player, let currentItem = player.currentItem else { return }
        
        let asset = currentItem.asset
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Force exact frame capture - don't seek to nearest keyframe
        imageGenerator.requestedTimeToleranceBefore = CMTime.zero
        imageGenerator.requestedTimeToleranceAfter = CMTime.zero
        
        // Get exact current playback time
        let currentTime = player.currentTime()
        
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: currentTime)]) { _, cgImage, _, _, error in
            if let error = error {
                print("Error generating thumbnail: \(error)")
                return
            }
            
            guard let cgImage = cgImage else { return }
            
            DispatchQueue.main.async {
                saveThumbnail(cgImage: cgImage, for: videoURL)
            }
        }
    }
    
    private func aspectFitSize(originalSize: NSSize, maxSize: NSSize) -> NSSize {
        let widthRatio = maxSize.width / originalSize.width
        let heightRatio = maxSize.height / originalSize.height
        let ratio = min(widthRatio, heightRatio)
        
        return NSSize(width: originalSize.width * ratio, height: originalSize.height * ratio)
    }
    
    private func saveThumbnail(cgImage: CGImage, for videoURL: URL) {
        let directoryURL = videoURL.deletingLastPathComponent()
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        
        print("Video file: \(videoURL.path)")
        print("Video directory: \(directoryURL.path)")
        print("Thumbnail directory: \(videoInfoURL.path)")
        
        // Create .video_info directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: videoInfoURL, withIntermediateDirectories: true, attributes: nil)
            print("Successfully created directory: \(videoInfoURL.path)")
        } catch {
            print("Error creating .video_info directory: \(error)")
            
            // Show error alert
            let alert = NSAlert()
            alert.messageText = "Error Creating Directory"
            alert.informativeText = "Failed to create .video_info directory: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Create thumbnail filename
        let videoName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        let thumbnailURL = videoInfoURL.appendingPathComponent("\(videoName).png")
        
        // Calculate thumbnail size (max 480x270, maintaining aspect ratio)
        let originalSize = NSSize(width: cgImage.width, height: cgImage.height)
        let maxSize = NSSize(width: 480, height: 270)
        let thumbnailSize = aspectFitSize(originalSize: originalSize, maxSize: maxSize)
        
        // Create resized NSImage
        let nsImage = NSImage(size: thumbnailSize)
        nsImage.lockFocus()
        let originalImage = NSImage(cgImage: cgImage, size: originalSize)
        originalImage.draw(in: NSRect(origin: .zero, size: thumbnailSize))
        nsImage.unlockFocus()
        
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Error converting image to PNG")
            return
        }
        
        do {
            try pngData.write(to: thumbnailURL)
            print("Thumbnail saved: \(thumbnailURL.path)")
            print("Directory exists: \(FileManager.default.fileExists(atPath: videoInfoURL.path))")
            
            // Update just this thumbnail in the list
            if let image = NSImage(contentsOf: thumbnailURL) {
                NotificationCenter.default.post(name: .refreshThumbnails, object: nil, userInfo: ["videoURL": videoURL, "thumbnail": image])
            }
            
            // Play camera sound - use simple beep for reliability
            NSSound.beep()
            print("Camera sound played (system beep)")
            
            // Update thumbnail in UI directly using our new notification system
            let thumbnail = nsImage
            NotificationCenter.default.post(
                name: Notification.Name("thumbnailCreated"),
                object: nil,
                userInfo: ["videoURL": videoURL, "thumbnail": thumbnail]
            )
            print("📸 Posted thumbnailCreated notification for: \(videoURL.lastPathComponent)")
        } catch {
            print("Error saving thumbnail: \(error)")
            
            // Show error alert
            let alert = NSAlert()
            alert.messageText = "Error Creating Thumbnail"
            alert.informativeText = "Failed to save thumbnail: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func getCacheDirectory() -> URL? {
        let fileManager = FileManager.default
        
        guard let appCacheDir = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VideoViewer").appendingPathComponent("thumbnails") else {
            return nil
        }
        
        // Create the directory if it doesn't exist
        if !fileManager.fileExists(atPath: appCacheDir.path) {
            try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        }
        
        return appCacheDir
    }
    
    private func getCachedThumbnailURL(for videoURL: URL) -> URL? {
        guard let cacheDir = getCacheDirectory() else { return nil }
        
        // Create a unique filename based on the full path
        let pathHash = videoURL.path.data(using: .utf8)?.base64EncodedString() ?? ""
        let safeHash = pathHash.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        
        return cacheDir.appendingPathComponent("\(safeHash).png")
    }
    
}