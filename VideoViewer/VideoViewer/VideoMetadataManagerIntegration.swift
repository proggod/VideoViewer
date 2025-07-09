// Extension to integrate VideoMetadataManager into ContentView
import Foundation
import SwiftUI
import Combine

extension FilterSidebar {
    func loadVideoResolutionsOptimized() {
        guard let directoryURL = directoryURL else { return }
        
        print("🔄 Loading video resolutions for: \(directoryURL.lastPathComponent)")
        
        // Use the metadata manager directly with simpler approach
        let metadataManager = VideoMetadataManager.shared
        let hasScanned = metadataManager.hasScannedDirectory(directoryURL.path)
        
        // Set loading state
        isLoadingResolutions = true
        
        Task {
            // Load cached data immediately
            await loadCachedData(directoryURL: directoryURL, metadataManager: metadataManager)
            
            // Set loading to false to prevent beach ball
            isLoadingResolutions = false
            
            // Scan in background if needed
            if !hasScanned {
                await scanInBackground(directoryURL: directoryURL, metadataManager: metadataManager)
            }
        }
    }
    
    @MainActor
    private func loadCachedData(directoryURL: URL, metadataManager: VideoMetadataManager) async {
        let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            let videoFiles = contents.filter { url in
                videoExtensions.contains(url.pathExtension.lowercased())
            }
            
            var newResolutions: Set<String> = []
            var newVideoResolutions: [URL: String] = [:]
            
            // Load only cached data - no blocking
            for videoFile in videoFiles {
                if let cached = metadataManager.getCachedMetadata(for: videoFile.path) {
                    newVideoResolutions[videoFile] = cached.resolution
                    newResolutions.insert(cached.resolution)
                }
            }
            
            // Update UI
            self.availableResolutions = newResolutions
            self.videoResolutions = newVideoResolutions
            self.cachedCount = newVideoResolutions.count
            
            print("📊 Loaded \(newVideoResolutions.count) cached entries")
        } catch {
            print("Error loading video files: \(error)")
        }
    }
    
    @MainActor
    private func scanInBackground(directoryURL: URL, metadataManager: VideoMetadataManager) async {
        let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv", "wmv", "mpg", "mpeg"]
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            let videoFiles = contents.filter { url in
                videoExtensions.contains(url.pathExtension.lowercased())
            }
            
            var needsScanning: [URL] = []
            
            // Find files that need scanning
            for videoFile in videoFiles {
                if metadataManager.getCachedMetadata(for: videoFile.path) == nil {
                    needsScanning.append(videoFile)
                }
            }
            
            if needsScanning.isEmpty { return }
            
            print("📊 Starting background scan of \(needsScanning.count) videos")
            scanningCount = needsScanning.count
            
            // Process in small batches
            let batchSize = directoryURL.path.hasPrefix("/Volumes/") ? 2 : 5
            
            for batch in needsScanning.chunked(into: batchSize) {
                await withTaskGroup(of: (URL, (resolution: String, duration: Double)?).self) { group in
                    for video in batch {
                        group.addTask {
                            let result = await metadataManager.getVideoMetadataAsyncInternal(for: video)
                            return (video, result)
                        }
                    }
                    
                    for await (video, metadata) in group {
                        if let metadata = metadata {
                            // Cache it
                            let attributes = try? FileManager.default.attributesOfItem(atPath: video.path)
                            let fileSize = attributes?[.size] as? Int64 ?? 0
                            let modDate = attributes?[.modificationDate] as? Date ?? Date()
                            
                            let cachedMetadata = VideoMetadataManager.CachedMetadata(
                                path: video.path,
                                resolution: metadata.resolution,
                                duration: metadata.duration,
                                fileSize: fileSize,
                                lastModified: modDate,
                                lastScanned: Date()
                            )
                            
                            metadataManager.cacheMetadata(cachedMetadata)
                            
                            // Update UI
                            videoResolutions[video] = metadata.resolution
                            availableResolutions.insert(metadata.resolution)
                            scanningCount -= 1
                        }
                    }
                }
                
                // Small delay between batches for network drives
                if directoryURL.path.hasPrefix("/Volumes/") {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            
            // Mark directory as scanned
            metadataManager.markDirectoryAsScanned(directoryURL.path, videoCount: videoFiles.count)
            
            // Final notification
            let unsupported = videoResolutions.filter { $0.value == "Unsupported" }.map { $0.key }
            NotificationCenter.default.post(
                name: Notification.Name("videoResolutionsUpdated"),
                object: nil,
                userInfo: [
                    "resolutions": videoResolutions,
                    "unsupported": Set(unsupported)
                ]
            )
            
            print("✅ Background scan completed")
        } catch {
            print("Error scanning videos: \(error)")
        }
    }
}

// Helper extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}