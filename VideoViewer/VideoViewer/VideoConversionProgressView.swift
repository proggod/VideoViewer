import SwiftUI
import AVKit
import FFmpegKit

struct VideoConversionProgressView: View {
    let directoryURL: URL
    let videosToConvert: [URL]
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var currentFileName = ""
    @State private var currentProgress: Double = 0.0
    @State private var currentVideoURL: URL?
    @State private var conversionTask: Task<Void, Never>?
    @State private var results: [ConversionResult] = []
    @State private var showResults = false
    @State private var estimatedTimeRemaining: String = ""
    @State private var startTime: Date?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Convert Videos to MP4")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                Button("Close") {
                    if !isProcessing {
                        isPresented = false
                    }
                }
                .disabled(isProcessing)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            if !isProcessing && !showResults {
                // Start screen
                VStack(spacing: 20) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Convert \(videosToConvert.count) video\(videosToConvert.count == 1 ? "" : "s") to MP4")
                        .font(.title3)
                    
                    Text("Compatible MKV files will be remuxed quickly.\nOther formats will be converted with high quality.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Text("Original files will be saved with .bak extension")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: startConversion) {
                        Label("Start Conversion", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if isProcessing {
                // Processing view
                VStack(spacing: 16) {
                    // Video preview
                    if let videoURL = currentVideoURL {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(height: 200)
                            .cornerRadius(8)
                            .padding(.horizontal)
                    }
                    
                    // Current file info
                    VStack(spacing: 8) {
                        Text(currentFileName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        // Progress bar
                        ProgressView(value: currentProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 400)
                        
                        HStack {
                            Text("\(Int(currentProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if !estimatedTimeRemaining.isEmpty {
                                Text(estimatedTimeRemaining)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 400)
                    }
                    
                    // Overall progress
                    Text("\(processedCount) of \(videosToConvert.count) files converted")
                        .font(.title3)
                        .fontWeight(.medium)
                    
                    // Stop button
                    Button(action: stopConversion) {
                        Label("Stop", systemImage: "stop.fill")
                            .foregroundColor(.white)
                            .frame(width: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showResults {
                // Results view
                VStack(alignment: .leading, spacing: 16) {
                    Text("Conversion Complete")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                                HStack {
                                    switch result {
                                    case .success(let original, _, let method):
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text(original.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(method == .remuxed ? "Remuxed" : "Converted")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                        
                                    case .failure(let original, let error):
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                        VStack(alignment: .leading) {
                                            Text(original.lastPathComponent)
                                                .font(.caption)
                                            Text(error.localizedDescription)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        
                                    case .cancelled(let original):
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.orange)
                                        Text(original.lastPathComponent)
                                            .font(.caption)
                                        Spacer()
                                        Text("Cancelled")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    
                    HStack {
                        let successCount = results.filter { if case .success = $0 { return true } else { return false } }.count
                        let failureCount = results.filter { if case .failure = $0 { return true } else { return false } }.count
                        let cancelledCount = results.filter { if case .cancelled = $0 { return true } else { return false } }.count
                        
                        VStack(alignment: .leading, spacing: 4) {
                            if successCount > 0 {
                                Text("\(successCount) converted successfully")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            if failureCount > 0 {
                                Text("\(failureCount) failed")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            if cancelledCount > 0 {
                                Text("\(cancelledCount) cancelled")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        Spacer()
                        
                        Button("Done") {
                            onComplete()
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                }
                .frame(width: 600, maxHeight: 500)
            }
        }
        .frame(width: 600, height: 600)
    }
    
    private func startConversion() {
        isProcessing = true
        processedCount = 0
        results = []
        startTime = Date()
        
        conversionTask = Task {
            for (index, videoURL) in videosToConvert.enumerated() {
                if Task.isCancelled { break }
                
                await MainActor.run {
                    currentFileName = videoURL.lastPathComponent
                    currentVideoURL = videoURL
                    currentProgress = 0.0
                }
                
                do {
                    // Try MKVRemuxer first for compatible MKV files
                    if videoURL.pathExtension.lowercased() == "mkv" && await MKVRemuxer.shared.canRemux(url: videoURL) {
                        print("🎬 Using fast remux for: \(videoURL.lastPathComponent)")
                        
                        let outputURL = try await MKVRemuxer.shared.remux(url: videoURL) { progress in
                            Task { @MainActor in
                                self.currentProgress = Double(progress)
                                self.updateTimeEstimate(progress: Double(progress), currentIndex: index)
                            }
                        }
                        
                        results.append(.success(original: videoURL, output: outputURL, method: .remuxed))
                    } else {
                        // Use SwiftFFmpeg for full conversion
                        print("🎬 Using FFmpeg conversion for: \(videoURL.lastPathComponent)")
                        
                        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("mp4")
                        try await convertWithFFmpeg(from: videoURL, to: outputURL) { progress in
                            Task { @MainActor in
                                self.currentProgress = progress
                                self.updateTimeEstimate(progress: progress, currentIndex: index)
                            }
                        }
                        
                        // Rename original to .bak
                        let backupURL = videoURL.appendingPathExtension("bak")
                        try FileManager.default.moveItem(at: videoURL, to: backupURL)
                        
                        results.append(.success(original: videoURL, output: outputURL, method: .converted))
                    }
                } catch {
                    if Task.isCancelled {
                        results.append(.cancelled(original: videoURL))
                    } else {
                        results.append(.failure(original: videoURL, error: error))
                    }
                }
                
                await MainActor.run {
                    processedCount = index + 1
                }
            }
            
            await MainActor.run {
                isProcessing = false
                showResults = true
                
                // Refresh the file browser
                NotificationCenter.default.post(name: .refreshBrowser, object: nil)
            }
        }
    }
    
    private func stopConversion() {
        conversionTask?.cancel()
        conversionTask = nil
        
        // Mark remaining files as cancelled
        for i in processedCount..<videosToConvert.count {
            results.append(.cancelled(original: videosToConvert[i]))
        }
        
        isProcessing = false
        showResults = true
    }
    
    private func convertWithFFmpeg(from input: URL, to output: URL, progress: @escaping (Double) -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            var cancelled = false
            
            // Build FFmpeg command
            let command = buildFFmpegCommand(input: input, output: output)
            
            // Execute FFmpeg session
            let session = FFmpegKit.executeAsync(command, withCompleteCallback: { session in
                guard let session = session else {
                    continuation.resume(throwing: ConversionError.ffmpegNotAvailable)
                    return
                }
                
                let returnCode = session.getReturnCode()
                
                if cancelled {
                    continuation.resume(throwing: ConversionError.cancelled)
                } else if ReturnCode.isSuccess(returnCode) {
                    continuation.resume()
                } else if ReturnCode.isCancel(returnCode) {
                    continuation.resume(throwing: ConversionError.cancelled)
                } else {
                    let output = session.getOutput() ?? "Unknown error"
                    print("FFmpeg conversion failed: \(output)")
                    continuation.resume(throwing: ConversionError.ffmpegNotAvailable)
                }
            }, withLogCallback: { logs in
                // Parse logs for progress if needed
            }, withStatisticsCallback: { statistics in
                guard let statistics = statistics else { return }
                
                // Get progress from statistics
                let currentTime = statistics.getTime()
                if let session = FFmpegKit.listSessions().last,
                   let duration = session.getDuration(),
                   duration > 0 {
                    let progressValue = min(Double(currentTime) / Double(duration * 1000), 1.0)
                    progress(progressValue)
                }
            })
            
            // Handle cancellation
            Task {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 100_000_000) // Check every 0.1 seconds
                }
                cancelled = true
                FFmpegKit.cancel(session.getSessionId())
            }
        }
    }
    
    private func buildFFmpegCommand(input: URL, output: URL) -> String {
        // Try hardware acceleration first
        let useHardwareAccel = ProcessInfo.processInfo.environment["DISABLE_HW_ACCEL"] == nil
        
        if useHardwareAccel {
            // VideoToolbox hardware acceleration for macOS
            return "-i \"\(input.path)\" -c:v h264_videotoolbox -b:v 6M -c:a aac -b:a 192k -movflags +faststart -y \"\(output.path)\""
        } else {
            // Software encoding with high quality
            return "-i \"\(input.path)\" -c:v libx264 -preset medium -crf 18 -c:a aac -b:a 192k -movflags +faststart -y \"\(output.path)\""
        }
    }
    
    
    private func updateTimeEstimate(progress: Double, currentIndex: Int) {
        guard let startTime = startTime, progress > 0 else { return }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let totalFiles = Double(videosToConvert.count)
        let filesComplete = Double(currentIndex) + progress
        let totalProgress = filesComplete / totalFiles
        
        if totalProgress > 0 {
            let estimatedTotal = elapsed / totalProgress
            let remaining = estimatedTotal - elapsed
            
            if remaining > 0 {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute, .second]
                formatter.unitsStyle = .abbreviated
                estimatedTimeRemaining = "~\(formatter.string(from: remaining) ?? "")"
            }
        }
    }
}

enum ConversionResult {
    case success(original: URL, output: URL, method: ConversionMethod)
    case failure(original: URL, error: Error)
    case cancelled(original: URL)
}

enum ConversionMethod {
    case remuxed
    case converted
}

enum ConversionError: LocalizedError {
    case ffmpegNotAvailable
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .ffmpegNotAvailable:
            return "Full video conversion not yet available. Only MKV files with compatible codecs can be converted."
        case .cancelled:
            return "Conversion was cancelled"
        }
    }
}

// Extension to safely access array elements
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

