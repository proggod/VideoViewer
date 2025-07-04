import SwiftUI
import AVKit
import AppKit

extension Notification.Name {
    static let refreshBrowser = Notification.Name("refreshBrowser")
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

struct ContentView: View {
    @State private var selectedURL: URL?
    @State private var videoFiles: [URL] = []
    @State private var showingVideoPlayer = false
    @State private var videoToPlay: URL?
    
    var body: some View {
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
        .onChange(of: videoToPlay) { oldValue, newValue in
            if newValue != nil {
                showingVideoPlayer = true
            }
        }
        .background(
            // Hidden window opener
            Group {
                if showingVideoPlayer, let videoURL = videoToPlay {
                    WindowOpener(videoURL: videoURL, isPresented: $showingVideoPlayer)
                }
            }
        )
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
    
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(getDisplayName(for: directoryURL))
                .font(.title2)
                .padding()
            
            if localVideoFiles.isEmpty {
                Spacer()
                Text("No video files in this directory")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(localVideoFiles, id: \.self) { videoURL in
                    HStack {
                        Image(systemName: "film")
                            .foregroundColor(.blue)
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
        .onAppear {
            loadVideoFiles()
        }
        .onChange(of: directoryURL) { _, _ in
            loadVideoFiles()
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
}

struct WindowOpener: NSViewRepresentable {
    let videoURL: URL
    @Binding var isPresented: Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.openVideoWindow()
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private func openVideoWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = videoURL.lastPathComponent
        window.contentView = NSHostingView(rootView: VideoPlayerContent(videoURL: videoURL, window: window))
        window.makeKeyAndOrderFront(nil)
        
        // Reset the state when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            self.isPresented = false
        }
    }
}

struct VideoPlayerContent: View {
    let videoURL: URL
    let window: NSWindow?
    @State private var player: AVPlayer?
    
    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player = AVPlayer(url: videoURL)
                player?.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .background(Color.black)
    }
}