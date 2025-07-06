import SwiftUI
import AVKit

struct ScreenshotProgressView: View {
    let videoFiles: [URL]
    let directoryURL: URL
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var videosToProcess: [URL] = []
    @State private var totalVideos = 0
    @State private var processedCount = 0
    @State private var currentFileName = ""
    @State private var isProcessing = false
    @State private var currentScreenshot: NSImage?
    @State private var screenshotTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Generate Screenshots")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                Button("Cancel") {
                    stopGeneration()
                }
                .disabled(isProcessing)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            if videosToProcess.isEmpty && !isProcessing {
                // No videos need screenshots
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("All videos have screenshots")
                        .font(.title3)
                    
                    Text("No screenshots need to be generated")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show progress
                VStack(spacing: 20) {
                    if !isProcessing {
                        // Preview
                        VStack(spacing: 16) {
                            Text("\(videosToProcess.count) videos need screenshots")
                                .font(.headline)
                            
                            Text("Screenshots will be taken at random times between 1-2 minutes into each video")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        
                        // Start button
                        Button(action: {
                            startGeneration()
                        }) {
                            Text("Start Generation")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding()
                    } else {
                        // Processing view
                        VStack(spacing: 20) {
                            // Progress indicator
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                            
                            Text("Generating screenshots...")
                                .font(.headline)
                            
                            Text("\(processedCount) / \(totalVideos)")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            if !currentFileName.isEmpty {
                                Text(currentFileName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 400)
                            }
                            
                            Text("\(totalVideos - processedCount) videos remaining")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            // Current screenshot preview
                            if let screenshot = currentScreenshot {
                                VStack(spacing: 8) {
                                    Text("Current Screenshot:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Image(nsImage: screenshot)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: 200, maxHeight: 150)
                                        .cornerRadius(8)
                                        .shadow(radius: 4)
                                }
                            }
                            
                            // Stop button
                            Button("Stop Generation") {
                                stopGeneration()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        .padding(40)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadVideosNeedingScreenshots()
        }
    }
    
    private func loadVideosNeedingScreenshots() {
        videosToProcess = []
        
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        
        for videoFile in videoFiles {
            let thumbnailName = videoFile.deletingPathExtension().lastPathComponent.lowercased()
            let thumbnailURL = videoInfoURL.appendingPathComponent("\(thumbnailName).png")
            
            if !FileManager.default.fileExists(atPath: thumbnailURL.path) {
                videosToProcess.append(videoFile)
            }
        }
        
        totalVideos = videosToProcess.count
    }
    
    private func startGeneration() {
        isProcessing = true
        processedCount = 0
        currentFileName = ""
        currentScreenshot = nil
        
        screenshotTask = Task {
            await generateScreenshots()
        }
    }
    
    private func stopGeneration() {
        screenshotTask?.cancel()
        screenshotTask = nil
        
        if isProcessing {
            isProcessing = false
            
            // Refresh thumbnails
            NotificationCenter.default.post(name: .refreshThumbnails, object: nil)
            
            onComplete()
        }
        
        isPresented = false
    }
    
    private func generateScreenshots() async {
        let videoInfoURL = directoryURL.appendingPathComponent(".video_info")
        
        // Create .video_info directory if it doesn't exist
        try? FileManager.default.createDirectory(at: videoInfoURL, withIntermediateDirectories: true)
        
        for (index, videoFile) in videosToProcess.enumerated() {
            // Check if task was cancelled
            if Task.isCancelled {
                break
            }
            
            await MainActor.run {
                currentFileName = videoFile.lastPathComponent
                processedCount = index
            }
            
            // Generate random time between 1-2 minutes (60-120 seconds)
            let randomSeconds = Double.random(in: 60...120)
            let time = CMTime(seconds: randomSeconds, preferredTimescale: 600)
            
            let screenshot = await generateScreenshot(for: videoFile, at: time)
            
            if let screenshot = screenshot {
                await MainActor.run {
                    self.currentScreenshot = screenshot
                }
                
                // Save screenshot
                let thumbnailName = videoFile.deletingPathExtension().lastPathComponent.lowercased()
                let thumbnailURL = videoInfoURL.appendingPathComponent("\(thumbnailName).png")
                
                if let tiffData = screenshot.tiffRepresentation,
                   let bitmapImage = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapImage.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: thumbnailURL)
                    
                    // Post notification for just this specific video file
                    print("📸 Posting thumbnailCreated notification for: \(videoFile.lastPathComponent)")
                    NotificationCenter.default.post(
                        name: Notification.Name("thumbnailCreated"),
                        object: nil,
                        userInfo: ["videoURL": videoFile, "thumbnail": screenshot]
                    )
                }
            }
            
            // Update progress
            await MainActor.run {
                processedCount = index + 1
            }
        }
        
        await MainActor.run {
            isProcessing = false
            
            // Don't post any refresh notifications - individual thumbnails are already
            // updated via the thumbnailCreated notification
            
            onComplete()
            isPresented = false
        }
    }
    
    private func generateScreenshot(for videoURL: URL, at time: CMTime) async -> NSImage? {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 480, height: 480)
        
        // Force exact frame capture - don't seek to nearest keyframe
        imageGenerator.requestedTimeToleranceBefore = CMTime.zero
        imageGenerator.requestedTimeToleranceAfter = CMTime.zero
        
        do {
            let cgImage = try await imageGenerator.image(at: time).image
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            print("Error generating screenshot for \(videoURL.lastPathComponent): \(error)")
            return nil
        }
    }
}