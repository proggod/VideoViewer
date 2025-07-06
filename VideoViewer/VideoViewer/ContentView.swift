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
    
    func loadChildren() {
        guard isDirectory && !hasLoadedChildren else { return }
        hasLoadedChildren = true
        
        // Check if we can read the directory
        guard isReadable else {
            children = []
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            children = contents.compactMap { url in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                    return FileItem(url: url)
                }
                return nil
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
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
                                directoryURL: selectedURL
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
                            showFilters: $showFilters
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
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Directories")
                .font(.headline)
                .padding()
            
            List {
                // Add home directory
                DirectoryRow(item: FileItem(url: FileManager.default.homeDirectoryForCurrentUser), selectedURL: $selectedURL)
                
                // Add system directories
                ForEach(["/Applications", "/System", "/Users", "/Volumes"], id: \.self) { path in
                    DirectoryRow(item: FileItem(url: URL(fileURLWithPath: path)), selectedURL: $selectedURL)
                }
                
                // Add mounted volumes
                ForEach(getMountedVolumes(), id: \.url) { item in
                    DirectoryRow(item: item, selectedURL: $selectedURL)
                }
            }
            .id(refreshTrigger)
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshBrowser)) { _ in
            refreshTrigger = UUID()
        }
    }
    
    private func getMountedVolumes() -> [FileItem] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { $0.path != "/" }.map { FileItem(url: $0) }
    }
}

struct DirectoryRow: View {
    @StateObject var item: FileItem
    @Binding var selectedURL: URL?
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if item.isDirectory && item.isReadable {
                    Button(action: { 
                        if !item.hasLoadedChildren {
                            item.loadChildren()
                        }
                        isExpanded.toggle() 
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
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedURL = item.url
                if item.isDirectory && !item.isReadable {
                    // Request permission for this directory
                    requestAccessToDirectory()
                } else if item.isDirectory && item.isReadable {
                    if !item.hasLoadedChildren {
                        item.loadChildren()
                    }
                    isExpanded = true
                }
            }
            
            if isExpanded && item.isDirectory {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        DirectoryRow(item: child, selectedURL: $selectedURL)
                            .padding(.leading, 20)
                    }
                }
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
        // Show simple permission dialog first
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "This app needs permission to access \(item.url.lastPathComponent). Click 'Grant Access' to allow browsing this folder."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // User clicked "Grant Access" - now show file picker
            let openPanel = NSOpenPanel()
            openPanel.canChooseDirectories = true
            openPanel.canChooseFiles = false
            openPanel.allowsMultipleSelection = false
            openPanel.message = "Navigate to and select \(item.url.lastPathComponent) to grant access"
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
                                print("Updated item readability for: \(item.url.path)")
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
        } else {
            print("User cancelled permission request")
        }
    }
}

// Resolution cache manager
class ResolutionCache {
    static let shared = ResolutionCache()
    private let cacheKey = "videoResolutionCache"
    private var cache: [String: [String: String]] = [:] // [directoryPath: [videoPath: resolution]]
    
    private init() {
        loadCache()
    }
    
    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            cache = decoded
        }
    }
    
    private func saveCache() {
        if let encoded = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }
    
    func getResolution(for videoPath: String, in directoryPath: String) -> String? {
        return cache[directoryPath]?[videoPath]
    }
    
    func setResolution(_ resolution: String, for videoPath: String, in directoryPath: String) {
        if cache[directoryPath] == nil {
            cache[directoryPath] = [:]
        }
        cache[directoryPath]?[videoPath] = resolution
        saveCache()
    }
    
    func getResolutions(for directoryPath: String) -> [String: String]? {
        return cache[directoryPath]
    }
    
    func clearCache(for directoryPath: String) {
        cache.removeValue(forKey: directoryPath)
        saveCache()
    }
}

struct FilterSidebar: View {
    @Binding var selectedCategories: Set<Int>
    @Binding var selectedResolutions: Set<String>
    let directoryURL: URL?
    
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var availableResolutions: Set<String> = []
    @State private var videoResolutions: [URL: String] = [:]
    @State private var isLoadingResolutions = false
    @State private var scanningStatus = ""
    @State private var cachedCount = 0
    @State private var scanningCount = 0
    
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
                            
                            ForEach(categoryManager.categories) { category in
                                Toggle(isOn: Binding(
                                    get: { selectedCategories.contains(category.id) },
                                    set: { isSelected in
                                        if isSelected {
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
            loadVideoResolutions()
        }
        .onChange(of: directoryURL) { oldValue, newValue in
            if oldValue != newValue {
                print("🔄 Directory changed from \(oldValue?.lastPathComponent ?? "nil") to \(newValue?.lastPathComponent ?? "nil")")
                loadVideoResolutions()
            }
        }
    }
    
    private func loadVideoResolutions() {
        guard let directoryURL = directoryURL else { return }
        
        print("🔄 loadVideoResolutions called for: \(directoryURL.lastPathComponent)")
        
        // First, load from cache
        let directoryPath = directoryURL.path
        
        // Clean up any "Unknown" entries in the cache - these should be rescanned as "Unsupported"
        var hasUnknownEntries = false
        if let cachedResolutions = ResolutionCache.shared.getResolutions(for: directoryPath) {
            for (path, resolution) in cachedResolutions {
                if resolution == "Unknown" {
                    hasUnknownEntries = true
                    print("🧹 Found 'Unknown' cache entry that needs cleanup: \(URL(fileURLWithPath: path).lastPathComponent)")
                }
            }
        }
        
        // If we found "Unknown" entries, clear the entire cache for this directory to force a rescan
        if hasUnknownEntries {
            print("🧹 Clearing resolution cache for directory to remove 'Unknown' entries")
            ResolutionCache.shared.clearCache(for: directoryPath)
        }
        
        if let cachedResolutions = ResolutionCache.shared.getResolutions(for: directoryPath) {
            var newResolutions: Set<String> = []
            var newVideoResolutions: [URL: String] = [:]
            
            for (videoPath, resolution) in cachedResolutions {
                let videoURL = URL(fileURLWithPath: videoPath)
                newVideoResolutions[videoURL] = resolution
                newResolutions.insert(resolution)
            }
            
            if !newResolutions.isEmpty {
                self.availableResolutions = newResolutions
                self.videoResolutions = newVideoResolutions
                
                // Notify immediately with cached data
                let unsupported = newVideoResolutions.filter { $0.value == "Unsupported" }.map { $0.key }
                NotificationCenter.default.post(
                    name: Notification.Name("videoResolutionsUpdated"),
                    object: nil,
                    userInfo: [
                        "resolutions": newVideoResolutions,
                        "unsupported": Set(unsupported)
                    ]
                )
                
                self.cachedCount = newVideoResolutions.count
                
                print("✅ Loaded \(newVideoResolutions.count) resolutions from cache for \(directoryPath)")
            }
        }
        
        // Then load any missing resolutions asynchronously
        isLoadingResolutions = true
        
        Task {
            // Get all video files in directory
            let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                let videoFiles = contents.filter { url in
                    videoExtensions.contains(url.pathExtension.lowercased())
                }
                
                var newResolutions: Set<String> = []
                var newVideoResolutions: [URL: String] = [:]
                
                // First pass: collect all cached resolutions immediately
                var uncachedFiles: [URL] = []
                for videoFile in videoFiles {
                    let videoPath = videoFile.path
                    
                    if let cachedResolution = ResolutionCache.shared.getResolution(for: videoPath, in: directoryPath) {
                        newVideoResolutions[videoFile] = cachedResolution
                        newResolutions.insert(cachedResolution)
                    } else {
                        uncachedFiles.append(videoFile)
                    }
                }
                
                // Update UI with cached data immediately
                let initialCachedCount = newVideoResolutions.count
                await MainActor.run {
                    self.availableResolutions = newResolutions
                    self.videoResolutions = newVideoResolutions
                    self.cachedCount = initialCachedCount
                    self.scanningCount = uncachedFiles.count
                }
                
                print("📊 Resolution status - Cached: \(newVideoResolutions.count), Need scanning: \(uncachedFiles.count)")
                if uncachedFiles.count > 0 {
                    print("📊 Files needing scan: \(uncachedFiles.map { $0.lastPathComponent })")
                }
                
                // Second pass: load uncached files in parallel (limit concurrency)
                if !uncachedFiles.isEmpty {
                    // Process in smaller batches of 3 for network drives to reduce load
                    let batchSize = directoryURL.path.hasPrefix("/Volumes/") ? 3 : 5
                    for i in stride(from: 0, to: uncachedFiles.count, by: batchSize) {
                        let batch = Array(uncachedFiles[i..<min(i + batchSize, uncachedFiles.count)])
                        
                        await withTaskGroup(of: (URL, String?).self) { group in
                            for videoFile in batch {
                                group.addTask {
                                    let resolution = await self.getVideoResolutionAsync(for: videoFile)
                                    return (videoFile, resolution)
                                }
                            }
                            
                            // Update UI immediately as each file completes
                            for await (videoFile, resolution) in group {
                                if let resolution = resolution {
                                    newVideoResolutions[videoFile] = resolution
                                    newResolutions.insert(resolution)
                                    // Cache the result
                                    ResolutionCache.shared.setResolution(resolution, for: videoFile.path, in: directoryPath)
                                    print("✅ Scanned: \(videoFile.lastPathComponent) -> \(resolution)")
                                } else {
                                    // Mark failed files as "Unsupported" so they don't get rescanned every time
                                    newVideoResolutions[videoFile] = "Unsupported"
                                    newResolutions.insert("Unsupported")
                                    ResolutionCache.shared.setResolution("Unsupported", for: videoFile.path, in: directoryPath)
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
            } catch {
                print("Error loading video files: \(error)")
                await MainActor.run {
                    self.isLoadingResolutions = false
                }
            }
        }
    }
    
    private func getVideoResolution(for url: URL) -> String? {
        let asset = AVAsset(url: url)
        
        // Use synchronous loading for now to maintain compatibility
        let semaphore = DispatchSemaphore(value: 0)
        var resolution: String?
        
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    semaphore.signal()
                    return
                }
                
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                
                let size = naturalSize.applying(preferredTransform)
                let height = Int(abs(size.height))
                
                // Common resolutions
                switch height {
                case 2160: resolution = "4K"
                case 1440: resolution = "1440p"
                case 1080: resolution = "1080p"
                case 720: resolution = "720p"
                case 480: resolution = "480p"
                case 360: resolution = "360p"
                default:
                    if height > 2160 {
                        resolution = "8K+"
                    } else if height > 0 {
                        resolution = "\(height)p"
                    }
                }
            } catch {
                print("Error loading video resolution: \(error)")
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        return resolution
    }
    
    private func getVideoResolutionAsync(for url: URL) async -> String? {
        let asset = AVAsset(url: url)
        
        do {
            // Shorter timeout for network files to fail faster
            let timeoutSeconds: TimeInterval = url.path.hasPrefix("/Volumes/") ? 3 : 5
            let tracks = try await withTimeout(seconds: timeoutSeconds) {
                try await asset.loadTracks(withMediaType: .video)
            }
            guard let track = tracks.first else { return nil }
            
            let naturalSize = try await withTimeout(seconds: timeoutSeconds) {
                try await track.load(.naturalSize)
            }
            let preferredTransform = try await withTimeout(seconds: timeoutSeconds) {
                try await track.load(.preferredTransform)
            }
            
            let size = naturalSize.applying(preferredTransform)
            let height = Int(abs(size.height))
            
            // Common resolutions
            switch height {
            case 2160: return "4K"
            case 1440: return "1440p"
            case 1080: return "1080p"
            case 720: return "720p"
            case 480: return "480p"
            case 360: return "360p"
            default:
                if height > 2160 {
                    return "8K+"
                } else if height > 0 {
                    return "\(height)p"
                }
                return nil
            }
        } catch {
            // Check if it's an unsupported format error
            if let avError = error as? AVError {
                switch avError.code {
                case .fileFormatNotRecognized:
                    print("Unsupported format: \(url.lastPathComponent)")
                    return "Unsupported"
                default:
                    print("Error loading video resolution for \(url.lastPathComponent): \(error)")
                }
            } else {
                print("Error loading video resolution for \(url.lastPathComponent): \(error)")
            }
            return nil
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            
            group.cancelAll()
            return result
        }
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
}

struct TimeoutError: Error {}

struct VideoListView: View {
    let directoryURL: URL
    @Binding var videoFiles: [URL]
    @Binding var videoToPlay: URL?
    @Binding var selectedCategories: Set<Int>
    @Binding var selectedResolutions: Set<String>
    @Binding var showFilters: Bool
    
    @State private var localVideoFiles: [URL] = []
    @State private var filteredVideoFiles: [URL] = []
    @State private var isGridView = UserDefaults.standard.bool(forKey: "isGridView")
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailSize: Double = UserDefaults.standard.double(forKey: "thumbnailSize") == 0 ? 150 : UserDefaults.standard.double(forKey: "thumbnailSize")
    @State private var videoResolutions: [URL: String] = [:]
    @State private var unsupportedFiles: Set<URL> = []
    @StateObject private var categoryManager = CategoryManager.shared
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
    
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and view toggle
            HStack {
                // Left side - title and indicators
                HStack {
                    Text(getDisplayName(for: directoryURL))
                        .font(.title2)
                    
                    // Add folder access button for permission issues
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Grant access to a folder"
                        
                        if panel.runModal() == .OK {
                            if let url = panel.url {
                                // Save bookmark for persistent access
                                saveBookmark(for: url)
                            }
                        }
                    }) {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Grant access to protected folders")
                    
                    // Network drive indicator
                    if isNetworkPath(directoryURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text("Network Drive")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .tooltip("Network drive - Performance may be slower")
                    }
                    
                    // Unsupported files indicator
                    if !unsupportedFiles.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("\(unsupportedFiles.count) Unsupported")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                        .tooltip("\(unsupportedFiles.count) files with unsupported codecs")
                    }
                }
                
                Spacer()
                
                // Right side - action buttons
                HStack {
                    // Refresh button
                    Button(action: { 
                        refreshDirectory()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Refresh Directory - Rescan for new files")
                    
                    // Cleanup button
                    Button(action: { 
                        showingCleanupPreview = true
                    }) {
                        Image(systemName: "wand.and.stars")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Cleanup Filenames - Batch rename with rules")
                    
                    // Screenshot generation button
                    Button(action: {
                        generateScreenshots()
                    }) {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundColor(isGeneratingScreenshots ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Generate Screenshots - Create missing thumbnails")
                    .disabled(isGeneratingScreenshots)
                    
                    // MKV conversion button
                    Button(action: {
                        showingMKVRemux = true
                    }) {
                        Image(systemName: "film.stack")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .tooltip("Convert MKV Files - Convert to MP4")
                    
                    // Filter toggle button
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
                    
                    // View toggle button
                    Button(action: { 
                        isGridView.toggle()
                        UserDefaults.standard.set(isGridView, forKey: "isGridView")
                    }) {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .tooltip(isGridView ? "Switch to List View" : "Switch to Grid View")
                }
            }
            .padding()
            
            // Thumbnail size slider (only in grid view)
            if isGridView && !localVideoFiles.isEmpty {
                HStack {
                    Image(systemName: "photo.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(value: $thumbnailSize, in: 100...480, step: 10) {
                        Text("Thumbnail Size")
                    }
                    .frame(width: 200)
                    .onChange(of: thumbnailSize) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "thumbnailSize")
                    }
                    
                    Text("\(Int(thumbnailSize))px")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            
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
                                    thumbnail: thumbnails[videoURL],
                                    size: thumbnailSize,
                                    editingVideo: $editingVideo,
                                    editingText: $editingText,
                                    onRename: renameVideo,
                                    isUnsupported: unsupportedFiles.contains(videoURL)
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
                    List(filteredVideoFiles, id: \.self) { videoURL in
                        VideoListRow(
                            videoURL: videoURL,
                            thumbnail: thumbnails[videoURL],
                            editingVideo: $editingVideo,
                            editingText: $editingText,
                            onRename: renameVideo,
                            isUnsupported: unsupportedFiles.contains(videoURL)
                        )
                        .contentShape(Rectangle())
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
                    loadVideoFiles()
                    loadThumbnails()
                    applyFilters()
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
        .onAppear {
            loadVideoFiles()
            loadThumbnails()
            applyFilters()
        }
        .onChange(of: directoryURL) { _, _ in
            loadVideoFiles()
            loadThumbnails()
            applyFilters()
        }
        .onChange(of: selectedCategories) { _, _ in
            applyFilters()
        }
        .onChange(of: selectedResolutions) { _, _ in
            applyFilters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshThumbnails)) { _ in
            // Only reload thumbnails if we don't have any loaded yet
            if thumbnails.isEmpty {
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
            loadVideoFiles()
            loadThumbnails()
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
    
    private func loadVideoFiles() {
        localVideoFiles = getVideoFiles()
        videoFiles = localVideoFiles
    }
    
    private func applyFilters() {
        // Start with all video files
        var filtered = localVideoFiles
        
        // Filter by categories
        if !selectedCategories.isEmpty {
            filtered = filtered.filter { videoURL in
                let videoCategories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
                // Check if video has any of the selected categories
                return !selectedCategories.isDisjoint(with: videoCategories)
            }
        }
        
        // Filter by resolution
        if !selectedResolutions.isEmpty {
            filtered = filtered.filter { videoURL in
                if let resolution = videoResolutions[videoURL] {
                    return selectedResolutions.contains(resolution)
                }
                return false
            }
        }
        
        filteredVideoFiles = filtered
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
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return contents.filter { url in
                videoExtensions.contains(url.pathExtension.lowercased())
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch let error as NSError {
            print("Error reading directory: \(error)")
            
            // If it's a permission error, automatically prompt for access
            if error.domain == NSCocoaErrorDomain && (error.code == 256 || error.code == 257) {
                DispatchQueue.main.async {
                    self.promptForDirectoryAccess()
                }
            }
            return []
        }
    }
    
    private func promptForDirectoryAccess() {
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "VideoViewer needs permission to access '\(directoryURL.lastPathComponent)'. Would you like to grant access?"
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        
        if alert.runModal() == .alertFirstButtonReturn {
            let openPanel = NSOpenPanel()
            openPanel.canChooseDirectories = true
            openPanel.canChooseFiles = false
            openPanel.allowsMultipleSelection = false
            openPanel.message = "Select '\(directoryURL.lastPathComponent)' to grant access"
            openPanel.prompt = "Grant Access"
            openPanel.directoryURL = directoryURL.deletingLastPathComponent()
            
            if openPanel.runModal() == .OK, let url = openPanel.url {
                // Save bookmark for persistent access
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(url.path)")
                    
                    // Refresh the view
                    loadVideoFiles()
                    loadThumbnails()
                    applyFilters()
                } catch {
                    print("Failed to save bookmark: \(error)")
                }
            }
        }
    }
    
    private func loadThumbnails() {
        thumbnails.removeAll()
        
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        guard FileManager.default.fileExists(atPath: videoInfoURL.path) else { return }
        
        // Check if this is a network drive
        let isNetworkDrive = isNetworkPath(directoryURL)
        
        if isNetworkDrive {
            print("Loading thumbnails from network drive: \(directoryURL.path)")
            // For network drives, load thumbnails asynchronously to avoid beach ball
            Task {
                var cachedCount = 0
                var networkLoadCount = 0
                
                for videoURL in localVideoFiles {
                    if let thumbnail = await loadSingleThumbnail(for: videoURL) {
                        await MainActor.run {
                            self.thumbnails[videoURL] = thumbnail
                        }
                        if loadCachedThumbnail(for: videoURL) != nil {
                            cachedCount += 1
                        } else {
                            networkLoadCount += 1
                        }
                    }
                }
                
                if cachedCount > 0 || networkLoadCount > 0 {
                    print("Network drive thumbnails - Cached: \(cachedCount), Loaded from network: \(networkLoadCount)")
                }
            }
        } else {
            // For local drives, load synchronously (fast)
            for videoURL in localVideoFiles {
                if let thumbnail = loadSingleThumbnailSync(for: videoURL) {
                    thumbnails[videoURL] = thumbnail
                }
            }
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
                
                // Log the detection results
                print("Checking path: \(url.path)")
                print("  - volumeIsLocal: \(resourceValues.volumeIsLocal ?? false)")
                print("  - volumeURLForRemounting: \(resourceValues.volumeURLForRemounting?.absoluteString ?? "none")")
                
                // If volumeIsLocalKey is false, it's a network drive
                if let isLocal = resourceValues.volumeIsLocal {
                    let isNetwork = !isLocal
                    print("  - Detected as: \(isNetwork ? "Network Drive" : "Local Drive")")
                    return isNetwork
                }
                
                // Alternative check: if it has a remounting URL, it's likely network
                if resourceValues.volumeURLForRemounting != nil {
                    print("  - Detected as: Network Drive (has remounting URL)")
                    return true
                }
            } catch {
                print("Error checking if path is network: \(error)")
            }
        }
        
        // Check for common network path patterns
        let isNetwork = url.path.hasPrefix("/Volumes/") && 
                       !url.path.hasPrefix("/Volumes/Macintosh")
        
        if isNetwork {
            print("Path \(url.path) detected as network drive by pattern matching")
        }
        
        return isNetwork
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
            
            // Remove just this file from the local state - no need to reload everything
            localVideoFiles.removeAll { $0 == videoURL }
            videoFiles = localVideoFiles
            thumbnails.removeValue(forKey: videoURL)
            videoResolutions.removeValue(forKey: videoURL)
            
            // Apply filters to update the view
            applyFilters()
            
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
            
            // Clear resolution cache for the directory
            ResolutionCache.shared.clearCache(for: directoryURL.path)
            
            // Reload files and update UI
            loadVideoFiles()
            loadThumbnails()
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
        // ResolutionCache.shared.clearCache(for: directoryURL.path)
        
        // Reload all data
        loadVideoFiles()
        loadThumbnails()
        applyFilters()
        
        // The resolution loading will happen automatically via the existing
        // ResolutionCache mechanism when the view refreshes
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
}

struct VideoListRow: View {
    let videoURL: URL
    let thumbnail: NSImage?
    @Binding var editingVideo: URL?
    @Binding var editingText: String
    let onRename: (URL, String) -> Void
    let isUnsupported: Bool
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var hasCategories: Bool = false
    
    var body: some View {
        HStack {
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 34)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "film")
                        .foregroundColor(.blue)
                        .frame(width: 60, height: 34)
                }
                
                // Red X overlay for unsupported files
                if isUnsupported {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .font(.system(size: 10, weight: .bold))
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
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: 8, weight: .bold))
                                )
                                .offset(x: 5, y: 5)
                        }
                    }
                }
            }
            
            if editingVideo == videoURL {
                // Edit mode
                TextField("Filename", text: $editingText, onCommit: {
                    if !editingText.isEmpty {
                        onRename(videoURL, editingText)
                    }
                    editingVideo = nil
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onAppear {
                    // Focus the text field when it appears
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
                
                Text(".\(videoURL.pathExtension)")
                    .foregroundColor(.secondary)
            } else {
                // Display mode
                Text(videoURL.lastPathComponent)
                    .onTapGesture {
                        editingVideo = videoURL
                        editingText = videoURL.deletingPathExtension().lastPathComponent
                    }
            }
            
            Spacer()
        }
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
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var hasCategories: Bool = false
    
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
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: min(12, size * 0.08)))
                    
                    Text(".\(videoURL.pathExtension)")
                        .font(.system(size: min(12, size * 0.08)))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Display mode
                Text(videoURL.lastPathComponent)
                    .font(.system(size: min(12, size * 0.08)))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        editingVideo = videoURL
                        editingText = videoURL.deletingPathExtension().lastPathComponent
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
    @State private var player: AVPlayer
    @State private var isCapturing: Bool = false
    @StateObject private var playerObserver = PlayerObserver()
    @State private var volumeCheckTimer: Timer?
    @StateObject private var tracker = VideoPlayerContentTracker()
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var selectedCategories: Set<Int> = []
    @State private var showCategories: Bool = false
    
    init(videoURL: URL) {
        self.videoURL = videoURL
        // Initialize player in init instead of onAppear
        let newPlayer = AVPlayer(url: videoURL)
        self._player = State(initialValue: newPlayer)
        
        // Restore last saved volume and mute state
        if UserDefaults.standard.object(forKey: "lastVideoVolume") != nil {
            newPlayer.volume = UserDefaults.standard.float(forKey: "lastVideoVolume")
        } else {
            newPlayer.volume = 1.0
        }
        
        // Restore mute state
        newPlayer.isMuted = UserDefaults.standard.bool(forKey: "lastVideoMuted")
        
        print("Initialized player with volume: \(newPlayer.volume), muted: \(newPlayer.isMuted)")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .onAppear {
                    player.play()
                    
                    // Load categories for this video
                    selectedCategories = categoryManager.getCategoriesForVideo(videoPath: videoURL.path)
                    
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
                    
                    // Save current state before closing
                    playerObserver.saveCurrentState(volume: player.volume, isMuted: player.isMuted)
                    print("Final volume: \(player.volume), muted: \(player.isMuted)")
                    
                    // Force stop playback
                    print("Stopping playback...")
                    player.pause()
                    player.seek(to: .zero)
                    player.rate = 0
                    player.replaceCurrentItem(with: nil)
                    
                    // Clear all player references
                    print("Clearing player references")
                    
                    print("=== VideoPlayer onDisappear END ===")
                }
            
            // Bottom toolbar
            VStack(spacing: 0) {
                // Category checkboxes
                if !categoryManager.categories.isEmpty && showCategories {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Categories")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.bottom, 4)
                            
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 12)
                            ], spacing: 8) {
                                ForEach(categoryManager.categories) { category in
                                    Toggle(isOn: Binding(
                                        get: { selectedCategories.contains(category.id) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedCategories.insert(category.id)
                                            } else {
                                                selectedCategories.remove(category.id)
                                            }
                                            categoryManager.setVideoCategory(
                                                videoPath: videoURL.path,
                                                categoryId: category.id,
                                                isSelected: isSelected
                                            )
                                            // Notify views to update checkmarks
                                            NotificationCenter.default.post(
                                                name: Notification.Name("categoriesUpdated"),
                                                object: nil
                                            )
                                        }
                                    )) {
                                        Text(category.name)
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .toggleStyle(CheckboxToggleStyle())
                                }
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(Color.black.opacity(0.6))
                }
                
                // Bottom controls
                HStack {
                    // Categories toggle button
                    if !categoryManager.categories.isEmpty {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCategories.toggle()
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
    }
    
    
    private func generateThumbnail() {
        guard let currentItem = player.currentItem else { return }
        
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
            
            // Play camera sound - use simple beep for reliability
            NSSound.beep()
            print("Camera sound played (system beep)")
            
            // Invalidate the cached thumbnail for this specific video
            if let cachedURL = getCachedThumbnailURL(for: videoURL) {
                try? FileManager.default.removeItem(at: cachedURL)
                print("Invalidated cached thumbnail for: \(videoURL.lastPathComponent)")
            }
            
            // Notify to refresh thumbnails
            NotificationCenter.default.post(name: .refreshThumbnails, object: nil)
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