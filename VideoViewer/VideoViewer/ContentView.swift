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
}

struct ContentView: View {
    @State private var selectedURL: URL?
    @State private var videoFiles: [URL] = []
    @State private var showingVideoPlayer = false
    @State private var videoToPlay: URL?
    @State private var currentTab: NavigationTab = .videos
    
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
                
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            // Content based on selected tab
            if currentTab == .videos {
                NavigationSplitView {
                    SimpleBrowser(selectedURL: $selectedURL)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
                } detail: {
                    if let selectedURL = selectedURL {
                        VideoListView(directoryURL: selectedURL, videoFiles: $videoFiles, videoToPlay: $videoToPlay)
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
                    }
                }
            } else {
                CategoriesView()
            }
        }
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

struct VideoListView: View {
    let directoryURL: URL
    @Binding var videoFiles: [URL]
    @Binding var videoToPlay: URL?
    @State private var localVideoFiles: [URL] = []
    @State private var isGridView = UserDefaults.standard.bool(forKey: "isGridView")
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailSize: Double = UserDefaults.standard.double(forKey: "thumbnailSize") == 0 ? 150 : UserDefaults.standard.double(forKey: "thumbnailSize")
    
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and view toggle
            HStack {
                Text(getDisplayName(for: directoryURL))
                    .font(.title2)
                Spacer()
                
                // View toggle button
                Button(action: { 
                    isGridView.toggle()
                    UserDefaults.standard.set(isGridView, forKey: "isGridView")
                }) {
                    Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(isGridView ? "Switch to List View" : "Switch to Grid View")
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
            
            if localVideoFiles.isEmpty {
                Spacer()
                Text("No video files in this directory")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                if isGridView {
                    // Grid view
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 50))], spacing: 20) {
                            ForEach(localVideoFiles, id: \.self) { videoURL in
                                VideoGridItem(videoURL: videoURL, thumbnail: thumbnails[videoURL], size: thumbnailSize)
                                    .onTapGesture(count: 2) {
                                        videoToPlay = videoURL
                                    }
                            }
                        }
                        .padding()
                    }
                } else {
                    // List view
                    List(localVideoFiles, id: \.self) { videoURL in
                        HStack {
                            if let thumbnail = thumbnails[videoURL] {
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
                            Text(videoURL.lastPathComponent)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            videoToPlay = videoURL
                        }
                    }
                }
            }
        }
        .onAppear {
            loadVideoFiles()
            loadThumbnails()
        }
        .onChange(of: directoryURL) { _, _ in
            loadVideoFiles()
            loadThumbnails()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshThumbnails)) { _ in
            loadThumbnails()
        }
    }
    
    private func loadVideoFiles() {
        localVideoFiles = getVideoFiles()
        videoFiles = localVideoFiles
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
        } catch {
            print("Error reading directory: \(error)")
            return []
        }
    }
    
    private func loadThumbnails() {
        thumbnails.removeAll()
        
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        guard FileManager.default.fileExists(atPath: videoInfoURL.path) else { return }
        
        for videoURL in localVideoFiles {
            let videoName = videoURL.deletingPathExtension().lastPathComponent.lowercased()
            let thumbnailURL = videoInfoURL.appendingPathComponent("\(videoName).png")
            
            if FileManager.default.fileExists(atPath: thumbnailURL.path),
               let image = NSImage(contentsOf: thumbnailURL) {
                thumbnails[videoURL] = image
            }
        }
    }
}

struct VideoGridItem: View {
    let videoURL: URL
    let thumbnail: NSImage?
    let size: Double
    
    var body: some View {
        VStack(spacing: 8) {
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
            
            Text(videoURL.lastPathComponent)
                .font(.system(size: min(12, size * 0.08)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

// Window controller to properly manage window lifecycle
class VideoWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let id = UUID()
    
    convenience init(videoURL: URL, onClose: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
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
        
        // Force clear the content view to trigger cleanup
        window?.contentView = nil
        
        onClose?()
        print("Window close complete")
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
                if !categoryManager.categories.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Categories")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.bottom, 4)
                            
                            ForEach(categoryManager.categories) { category in
                                HStack {
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
                                        }
                                    )) {
                                        Text(category.name)
                                            .foregroundColor(.white)
                                    }
                                    .toggleStyle(CheckboxToggleStyle())
                                    
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(Color.black.opacity(0.6))
                }
                
                // Capture button
                HStack {
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
                            .scaleEffect(isCapturing ? 0.8 : 1.0)
                            .opacity(isCapturing ? 0.6 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .help("Generate Thumbnail")
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
}