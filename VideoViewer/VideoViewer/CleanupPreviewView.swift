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
                        
                        Text("Duplicate files with same size will be deleted")
                            .font(.caption)
                            .foregroundColor(.orange)
                        
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
            var duplicatesRemoved = 0
            var failureCount = 0
            var skipAllConflicts = false
            
            for (index, change) in previewChanges.enumerated() {
                if skipAllConflicts {
                    failureCount += 1
                    continue
                }
                // Update progress on main thread
                await MainActor.run {
                    currentFileName = change.original.lastPathComponent
                    processedCount = index
                }
                
                do {
                    print("\n=== RENAME ATTEMPT ===")
                    print("Original: \(change.original.path)")
                    print("Cleaned:  \(change.cleaned.path)")
                    
                    // Check if source file exists
                    if !FileManager.default.fileExists(atPath: change.original.path) {
                        print("❌ ERROR: Source file does not exist!")
                        failureCount += 1
                        continue
                    }
                    
                    // Check if destination already exists
                    if FileManager.default.fileExists(atPath: change.cleaned.path) {
                        print("⚠️ WARNING: Destination file already exists: \(change.cleaned.lastPathComponent)")
                        
                        // Compare file sizes
                        do {
                            let originalAttrs = try FileManager.default.attributesOfItem(atPath: change.original.path)
                            let destAttrs = try FileManager.default.attributesOfItem(atPath: change.cleaned.path)
                            
                            let originalSize = originalAttrs[.size] as? Int64 ?? 0
                            let destSize = destAttrs[.size] as? Int64 ?? 0
                            
                            print("Original size: \(originalSize) bytes")
                            print("Destination size: \(destSize) bytes")
                            
                            if originalSize == destSize && originalSize > 0 {
                                print("Files are same size - removing duplicate original file")
                                
                                // Delete the original file since it's a duplicate
                                try FileManager.default.removeItem(at: change.original)
                                print("✅ DUPLICATE REMOVED: Deleted \(change.original.lastPathComponent)")
                                
                                // Also remove its thumbnail if it exists
                                let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
                                let originalThumbName = change.original.deletingPathExtension().lastPathComponent.lowercased()
                                let originalThumbURL = videoInfoURL.appendingPathComponent("\(originalThumbName).png")
                                
                                if FileManager.default.fileExists(atPath: originalThumbURL.path) {
                                    try? FileManager.default.removeItem(at: originalThumbURL)
                                    print("Also removed duplicate thumbnail")
                                }
                                
                                duplicatesRemoved += 1
                            } else {
                                print("⚠️ Files have different sizes")
                                
                                // Format file sizes for display
                                let formatter = ByteCountFormatter()
                                formatter.allowedUnits = [.useAll]
                                formatter.countStyle = .file
                                let originalSizeStr = formatter.string(fromByteCount: originalSize)
                                let destSizeStr = formatter.string(fromByteCount: destSize)
                                
                                // Ask user what to do
                                let userChoice = await MainActor.run { () -> String in
                                    let alert = NSAlert()
                                    alert.messageText = "Duplicate files with different sizes"
                                    alert.informativeText = """
                                    Found two files with similar names but different sizes:
                                    
                                    Original: \(change.original.lastPathComponent)
                                    Size: \(originalSizeStr)
                                    
                                    Existing: \(change.cleaned.lastPathComponent)
                                    Size: \(destSizeStr)
                                    
                                    What would you like to do?
                                    """
                                    alert.alertStyle = .warning
                                    
                                    alert.addButton(withTitle: "Keep Both")
                                    alert.addButton(withTitle: "Delete Original (\(originalSizeStr))")
                                    alert.addButton(withTitle: "Delete Existing (\(destSizeStr))")
                                    alert.addButton(withTitle: "Skip All Similar")
                                    
                                    let response = alert.runModal()
                                    switch response {
                                    case .alertFirstButtonReturn:
                                        return "keep"
                                    case .alertSecondButtonReturn:
                                        return "delete_original"
                                    case .alertThirdButtonReturn:
                                        return "delete_existing"
                                    default:
                                        return "skip_all"
                                    }
                                }
                                
                                switch userChoice {
                                case "delete_original":
                                    // Delete the original file
                                    do {
                                        try FileManager.default.removeItem(at: change.original)
                                        print("✅ USER CHOICE: Deleted original \(change.original.lastPathComponent)")
                                        
                                        // Also remove its thumbnail
                                        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
                                        let originalThumbName = change.original.deletingPathExtension().lastPathComponent.lowercased()
                                        let originalThumbURL = videoInfoURL.appendingPathComponent("\(originalThumbName).png")
                                        
                                        if FileManager.default.fileExists(atPath: originalThumbURL.path) {
                                            try? FileManager.default.removeItem(at: originalThumbURL)
                                            print("Also removed original's thumbnail")
                                        }
                                        
                                        duplicatesRemoved += 1
                                    } catch {
                                        print("❌ ERROR deleting original: \(error)")
                                        failureCount += 1
                                    }
                                    
                                case "delete_existing":
                                    // Delete the existing file and then rename
                                    do {
                                        try FileManager.default.removeItem(at: change.cleaned)
                                        print("Deleted existing file")
                                        
                                        // Also remove its thumbnail
                                        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
                                        let cleanedThumbName = change.cleaned.deletingPathExtension().lastPathComponent.lowercased()
                                        let cleanedThumbURL = videoInfoURL.appendingPathComponent("\(cleanedThumbName).png")
                                        
                                        if FileManager.default.fileExists(atPath: cleanedThumbURL.path) {
                                            try? FileManager.default.removeItem(at: cleanedThumbURL)
                                            print("Also removed existing file's thumbnail")
                                        }
                                        
                                        // Now rename the original
                                        try FileManager.default.moveItem(at: change.original, to: change.cleaned)
                                        print("✅ USER CHOICE: Replaced with original")
                                        
                                        // Update thumbnail
                                        let originalThumbName = change.original.deletingPathExtension().lastPathComponent.lowercased()
                                        let originalThumbURL = videoInfoURL.appendingPathComponent("\(originalThumbName).png")
                                        
                                        if FileManager.default.fileExists(atPath: originalThumbURL.path) {
                                            try? FileManager.default.moveItem(at: originalThumbURL, to: cleanedThumbURL)
                                        }
                                        
                                        successCount += 1
                                    } catch {
                                        print("❌ ERROR replacing file: \(error)")
                                        failureCount += 1
                                    }
                                    
                                case "skip_all":
                                    // Skip all remaining files
                                    print("User chose to skip all remaining conflicts")
                                    skipAllConflicts = true
                                    failureCount += 1
                                    
                                default: // "keep"
                                    print("User chose to keep both files")
                                    failureCount += 1
                                }
                            }
                        } catch {
                            print("❌ ERROR comparing files: \(error)")
                            failureCount += 1
                        }
                        continue
                    }
                    
                    // Check permissions
                    let isWritable = FileManager.default.isWritableFile(atPath: change.original.path)
                    let parentDirWritable = FileManager.default.isWritableFile(atPath: change.original.deletingLastPathComponent().path)
                    print("Source file writable: \(isWritable)")
                    print("Parent directory writable: \(parentDirWritable)")
                    
                    // Rename the file
                    print("Attempting rename...")
                    try FileManager.default.moveItem(at: change.original, to: change.cleaned)
                    print("✅ SUCCESS: File renamed!")
                    
                    // Update thumbnail if it exists
                    let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
                    let originalThumbName = change.original.deletingPathExtension().lastPathComponent.lowercased()
                    let cleanedThumbName = change.cleaned.deletingPathExtension().lastPathComponent.lowercased()
                    
                    let originalThumbURL = videoInfoURL.appendingPathComponent("\(originalThumbName).png")
                    let cleanedThumbURL = videoInfoURL.appendingPathComponent("\(cleanedThumbName).png")
                    
                    if FileManager.default.fileExists(atPath: originalThumbURL.path) {
                        print("Renaming thumbnail: \(originalThumbName).png -> \(cleanedThumbName).png")
                        try? FileManager.default.moveItem(at: originalThumbURL, to: cleanedThumbURL)
                    }
                    
                    successCount += 1
                } catch {
                    print("❌ ERROR renaming file: \(error)")
                    print("Error type: \(type(of: error))")
                    print("Error localized: \(error.localizedDescription)")
                    if let nsError = error as NSError? {
                        print("Error code: \(nsError.code)")
                        print("Error domain: \(nsError.domain)")
                        print("Error userInfo: \(nsError.userInfo)")
                    }
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
                
                print("\n=== CLEANUP SUMMARY ===")
                print("Total files to process: \(previewChanges.count)")
                print("Successfully renamed: \(successCount)")
                print("Duplicates removed: \(duplicatesRemoved)")
                print("Failed to process: \(failureCount)")
                
                let totalSuccess = successCount + duplicatesRemoved
                
                if failureCount > 0 {
                    print("⚠️ Cleanup completed with errors: \(totalSuccess) succeeded (\(successCount) renamed, \(duplicatesRemoved) duplicates removed), \(failureCount) failed")
                    
                    // Show alert about failures
                    let alert = NSAlert()
                    alert.messageText = "Cleanup completed with some errors"
                    alert.informativeText = "• \(successCount) files renamed\n• \(duplicatesRemoved) duplicate files removed\n• \(failureCount) files failed\n\nCheck the console for details."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } else if totalSuccess == 0 {
                    print("⚠️ No files were processed")
                } else {
                    print("✅ Cleanup completed successfully!")
                    print("   - Files renamed: \(successCount)")
                    print("   - Duplicates removed: \(duplicatesRemoved)")
                    
                    // Show success alert
                    let alert = NSAlert()
                    alert.messageText = "Cleanup completed successfully"
                    alert.informativeText = "• \(successCount) files renamed\n• \(duplicatesRemoved) duplicate files removed"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}