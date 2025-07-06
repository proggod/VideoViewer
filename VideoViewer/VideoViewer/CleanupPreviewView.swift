import SwiftUI

struct CleanupPreviewView: View {
    let videoFiles: [URL]
    let directoryURL: URL
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @StateObject private var cleanupManager = CleanupManager.shared
    @State private var previewChanges: [(original: URL, cleaned: URL)] = []
    @State private var totalMatches = 0
    @State private var isProcessing = false
    @State private var selectedLimit = 20
    @State private var processedCount = 0
    @State private var currentFileName = ""
    
    let limitOptions = [20, 50, 100, 200, -1] // -1 represents "All"
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Cleanup Preview")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                // Limit picker
                HStack(spacing: 8) {
                    Text("Process:")
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $selectedLimit) {
                        ForEach(limitOptions, id: \.self) { limit in
                            if limit == -1 {
                                Text("All").tag(-1)
                            } else {
                                Text("\(limit)").tag(limit)
                            }
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 80)
                    .onChange(of: selectedLimit) { _, _ in
                        loadPreview()
                    }
                    
                    Text("files")
                        .foregroundColor(.secondary)
                }
                
                Button("Cancel") {
                    isPresented = false
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            if previewChanges.isEmpty {
                // No changes
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("All filenames are already clean")
                        .font(.title3)
                    
                    Text("No changes needed based on current cleanup rules")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show changes
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if selectedLimit == -1 || totalMatches <= selectedLimit {
                            Text("\(previewChanges.count) files will be renamed:")
                                .font(.headline)
                        } else {
                            Text("Showing first \(selectedLimit) of \(totalMatches) files to rename:")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(previewChanges, id: \.original) { change in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "doc")
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(change.original.lastPathComponent)
                                                .font(.system(.body, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .strikethrough()
                                            
                                            HStack {
                                                Image(systemName: "arrow.down")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                                
                                                Text(change.cleaned.lastPathComponent)
                                                    .font(.system(.body, design: .monospaced))
                                                    .foregroundColor(.green)
                                            }
                                        }
                                        
                                        Spacer()
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxHeight: .infinity)
                
                // Action buttons
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This action cannot be undone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if selectedLimit != -1 && totalMatches > selectedLimit {
                            Text("Process remaining \(totalMatches - selectedLimit) files after these")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    Button("Cancel") {
                        isPresented = false
                    }
                    
                    Button(action: {
                        performCleanup()
                    }) {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Apply Changes")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
            }
        }
        .frame(width: 600, height: 500)
        .overlay(
            // Processing overlay
            Group {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                            
                            Text("Processing files...")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Text("\(processedCount) / \(previewChanges.count)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            if !currentFileName.isEmpty {
                                Text(currentFileName)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 400)
                            }
                            
                            Text("\(previewChanges.count - processedCount) files remaining")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(40)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(20)
                    }
                }
            }
        )
        .onAppear {
            loadPreview()
        }
    }
    
    private func loadPreview() {
        let limit = selectedLimit == -1 ? Int.max : selectedLimit
        let result = cleanupManager.previewChanges(for: videoFiles, limit: limit)
        previewChanges = result.changes
        totalMatches = result.totalMatches
    }
    
    private func performCleanup() {
        isProcessing = true
        processedCount = 0
        currentFileName = ""
        
        Task {
            var successCount = 0
            var failureCount = 0
            
            for (index, change) in previewChanges.enumerated() {
                // Update progress on main thread
                await MainActor.run {
                    currentFileName = change.original.lastPathComponent
                    processedCount = index
                }
                
                do {
                    // Check if destination already exists
                    if FileManager.default.fileExists(atPath: change.cleaned.path) {
                        print("Destination file already exists: \(change.cleaned.lastPathComponent)")
                        failureCount += 1
                        continue
                    }
                    
                    // Rename the file
                    try FileManager.default.moveItem(at: change.original, to: change.cleaned)
                    
                    // Update thumbnail if it exists
                    let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
                    let originalThumbName = change.original.deletingPathExtension().lastPathComponent.lowercased()
                    let cleanedThumbName = change.cleaned.deletingPathExtension().lastPathComponent.lowercased()
                    
                    let originalThumbURL = videoInfoURL.appendingPathComponent("\(originalThumbName).png")
                    let cleanedThumbURL = videoInfoURL.appendingPathComponent("\(cleanedThumbName).png")
                    
                    if FileManager.default.fileExists(atPath: originalThumbURL.path) {
                        try? FileManager.default.moveItem(at: originalThumbURL, to: cleanedThumbURL)
                    }
                    
                    successCount += 1
                } catch {
                    print("Error renaming file: \(error)")
                    failureCount += 1
                }
                
                // Final update for this file
                await MainActor.run {
                    processedCount = index + 1
                }
            }
            
            // Don't clear the entire cache - the resolution doesn't change when renaming
            // The old cache entries will be ignored since those files no longer exist
            
            await MainActor.run {
                isProcessing = false
                
                // Notify the file browser to refresh
                NotificationCenter.default.post(name: .refreshBrowser, object: nil)
                
                onComplete()
                isPresented = false
                
                if failureCount > 0 {
                    print("Cleanup completed: \(successCount) succeeded, \(failureCount) failed")
                } else {
                    print("Cleanup completed: \(successCount) files renamed successfully")
                }
            }
        }
    }
}