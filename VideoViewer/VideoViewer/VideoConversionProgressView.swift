import SwiftUI
import AVKit
// Using FFmpegManager to handle both bundled and system FFmpeg

struct VideoConversionProgressView: View {
    let directoryURL: URL
    let allVideoFiles: [URL]
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var videosToConvert: [URL] = []
    
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var currentFileName = ""
    @State private var currentProgress: Double = 0.0
    @State private var currentVideoURL: URL?
    @State private var conversionTask: Task<Void, Never>?
    @State private var currentFFmpegProcess: Process?
    @State private var hasLoggedInitialOutput = false
    @State private var results: [ConversionResult] = []
    @State private var showResults = false
    @State private var estimatedTimeRemaining: String = ""
    @State private var startTime: Date?
    @State private var currentFileStartTime: Date?
    @State private var debugOutput = ""
    
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
                if videosToConvert.isEmpty {
                    // No videos to convert
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)
                        
                        Text("No Videos to Convert")
                            .font(.title3)
                        
                        Text("No convertible video files found. Supported formats: MKV, WMV, AVI, MOV, MPG, MPEG, M4V, 3GP.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
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
                }
            } else if isProcessing {
                // Processing view
                VStack(spacing: 16) {
                    // Debug output terminal
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("FFmpeg Output")
                                .font(.headline)
                                .foregroundColor(.green)
                            Spacer()
                            if !debugOutput.isEmpty {
                                Button("Clear") {
                                    debugOutput = ""
                                }
                                .font(.caption)
                            }
                        }
                        
                        ScrollView {
                            ScrollViewReader { proxy in
                                Text(debugOutput.isEmpty ? "Starting FFmpeg..." : debugOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.green)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id("bottom")
                                    .onChange(of: debugOutput) { _, _ in
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }
                            }
                        }
                        .frame(height: 200)
                        .background(Color.black)
                        .cornerRadius(8)
                    }
                    .padding(.horizontal)
                    
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
                .frame(width: 600)
                .frame(maxHeight: 500)
            }
        }
        .frame(width: 600, height: 600)
        .onAppear {
            loadVideosToConvert()
        }
    }
    
    private func loadVideosToConvert() {
        // Filter videos that can be converted
        let convertibleExtensions = ["mkv", "wmv", "avi", "mpg", "mpeg", "mov", "m4v", "3gp", "3g2"]
        
        videosToConvert = allVideoFiles.filter { url in
            let ext = url.pathExtension.lowercased()
            // Include files with convertible extensions, but exclude MP4 files
            return convertibleExtensions.contains(ext) && ext != "mp4"
        }
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
                    currentFileStartTime = Date()
                    estimatedTimeRemaining = ""
                    hasLoggedInitialOutput = false
                    // Clear debug output for new file to prevent memory issues
                    debugOutput = "Starting conversion of: \(videoURL.lastPathComponent)\n"
                }
                
                do {
                    // Try MKVRemuxer first for compatible MKV files
                    let isMKV = videoURL.pathExtension.lowercased() == "mkv"
                    let canRemux = isMKV ? await MKVRemuxer.shared.canRemux(url: videoURL) : false
                    
                    if isMKV && canRemux {
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
                        
                        // Rename original to .bak temporarily
                        let backupURL = videoURL.appendingPathExtension("bak")
                        try FileManager.default.moveItem(at: videoURL, to: backupURL)
                        
                        // If conversion succeeded, delete the backup
                        try? FileManager.default.removeItem(at: backupURL)
                        
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
        // Immediately terminate FFmpeg process
        currentFFmpegProcess?.terminate()
        currentFFmpegProcess = nil
        
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
        // Check if FFmpeg is available (bundled or system)
        guard let ffmpegPath = FFmpegManager.shared.ffmpegPath else {
            throw ConversionError.ffmpegNotAvailable
        }
        
        print("🎬 \(FFmpegManager.shared.availabilityMessage)")
        
        // Run ffmpeg conversion
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                let process = Process()
                
                // Store process reference for immediate termination
                Task { @MainActor in
                    self.currentFFmpegProcess = process
                }
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                
                // Set up arguments for high quality conversion with hardware acceleration
                process.arguments = [
                    "-i", input.path,
                    "-c:v", "libx264",       // Use H.264 video codec
                    "-progress", "pipe:2",   // Output progress to stderr
                    "-preset", "medium",      // Balance between speed and compression
                    "-crf", "18",            // High quality (lower = better, 18 is visually lossless)
                    "-c:a", "aac",           // Use AAC audio codec
                    "-b:a", "192k",          // Audio bitrate
                    "-movflags", "+faststart", // Optimize for streaming
                    "-y",                    // Overwrite output file
                    output.path
                ]
                
                // Try hardware acceleration if available
                if ProcessInfo.processInfo.environment["DISABLE_HW_ACCEL"] == nil {
                    // Check for VideoToolbox support (macOS hardware acceleration)
                    process.arguments = [
                        "-i", input.path,
                        "-c:v", "h264_videotoolbox",  // Hardware accelerated H.264
                        "-progress", "pipe:2",         // Output progress to stderr
                        "-b:v", "6M",                  // Video bitrate for HW encoding
                        "-c:a", "aac",
                        "-b:a", "192k",
                        "-movflags", "+faststart",
                        "-y",
                        output.path
                    ]
                }
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                var conversionTask: Task<Void, Never>?
                
                // Monitor progress from stderr
                conversionTask = Task {
                    let errorHandle = errorPipe.fileHandleForReading
                    var duration: Double?
                    var lastProgressTime = Date()
                    var progressCounter = 0.0
                    var outputBuffer = ""
                    
                    while !Task.isCancelled {
                        let data = errorHandle.availableData
                        guard !data.isEmpty else { 
                            // If no output for 5 seconds, show fake progress to indicate activity
                            if Date().timeIntervalSince(lastProgressTime) > 5 {
                                let newProgress = min(progressCounter + 0.01, 0.95) // Cap at 95% for fake progress
                                progressCounter = newProgress
                                Task { @MainActor in
                                    progress(newProgress)
                                }
                                lastProgressTime = Date()
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            continue 
                        }
                        
                        if let output = String(data: data, encoding: .utf8) {
                            // Add to local buffer for duration parsing
                            outputBuffer += output
                            
                            // Print all output until we get 10 frame updates (to catch duration in different order)
                            let shouldLog = await MainActor.run { !hasLoggedInitialOutput }
                            if shouldLog {
                                print("🎬 FFmpeg: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                                
                                // Stop logging after seeing several frame updates
                                if output.contains("frame=") {
                                    Task { @MainActor in
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            self.hasLoggedInitialOutput = true
                                            print("🎬 Stopping detailed logging after 2 seconds")
                                        }
                                    }
                                }
                            }
                            
                            // Append to debug output (keep only last 50 lines to prevent memory issues)
                            Task { @MainActor in
                                debugOutput += output
                                let lines = debugOutput.split(separator: "\n")
                                if lines.count > 50 {
                                    debugOutput = lines.suffix(50).joined(separator: "\n") + "\n"
                                }
                            }
                            
                            // Parse duration if not yet found (use local buffer to handle split lines)
                            if duration == nil {
                                if let match = outputBuffer.range(of: "Duration: ") {
                                    let start = outputBuffer.index(match.upperBound, offsetBy: 0)
                                    let remainingString = String(outputBuffer[start...])
                                    // Look for the duration format (HH:MM:SS.ms) followed by comma
                                    if let commaIndex = remainingString.firstIndex(of: ",") {
                                        let durationStr = String(remainingString[..<commaIndex])
                                        duration = parseFFmpegDuration(durationStr)
                                        if let duration = duration {
                                            print("🎬 ✅ DURATION FOUND: \(durationStr) = \(duration) seconds")
                                        } else {
                                            print("🎬 ❌ FAILED TO PARSE DURATION: '\(durationStr)'")
                                        }
                                    }
                                }
                            }
                            
                            // Parse current time for progress (check both "time=" and "out_time=")
                            if let duration = duration {
                                var timeStr: String?
                                
                                // Try "out_time=" first (newer FFmpeg format)
                                if let match = output.range(of: "out_time=") {
                                    let start = output.index(match.upperBound, offsetBy: 0)
                                    let remainingString = String(output[start...])
                                    if let newlineIndex = remainingString.firstIndex(of: "\n") {
                                        timeStr = String(remainingString[..<newlineIndex])
                                    }
                                }
                                // Fallback to "time=" (older FFmpeg format)
                                else if let match = output.range(of: "time=") {
                                    let start = output.index(match.upperBound, offsetBy: 0)
                                    let remainingString = String(output[start...])
                                    if let spaceIndex = remainingString.firstIndex(of: " ") {
                                        timeStr = String(remainingString[..<spaceIndex])
                                    }
                                }
                                
                                if let timeStr = timeStr, let currentTime = await parseFFmpegDuration(timeStr) {
                                    let progressValue = min(currentTime / duration, 1.0)
                                    Task { @MainActor in
                                        progress(progressValue)
                                    }
                                }
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                    
                    // Check for cancellation periodically with timeout
                    var timeoutCounter = 0
                    let maxTimeout = 9000 // 15 minute timeout (9000 * 0.1 seconds)
                    
                    while process.isRunning {
                        if Task.isCancelled {
                            process.terminate()
                            conversionTask?.cancel()
                            // Clear process reference
                            Task { @MainActor in
                                self.currentFFmpegProcess = nil
                            }
                            continuation.resume(throwing: ConversionError.cancelled)
                            return
                        }
                        
                        timeoutCounter += 1
                        if timeoutCounter > maxTimeout {
                            print("FFmpeg timeout after 15 minutes, terminating...")
                            process.terminate()
                            conversionTask?.cancel()
                            // Clear process reference
                            Task { @MainActor in
                                self.currentFFmpegProcess = nil
                            }
                            continuation.resume(throwing: ConversionError.ffmpegNotAvailable)
                            return
                        }
                        
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    }
                    
                    conversionTask?.cancel()
                    
                    // Clear process reference
                    Task { @MainActor in
                        self.currentFFmpegProcess = nil
                    }
                    
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ConversionError.ffmpegNotAvailable)
                    }
                } catch {
                    conversionTask?.cancel()
                    // Clear process reference
                    Task { @MainActor in
                        self.currentFFmpegProcess = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // Helper function to parse FFmpeg duration/time strings (HH:MM:SS.ms)
    private func parseFFmpegDuration(_ timeStr: String) -> Double? {
        let components = timeStr.split(separator: ":")
        guard components.count == 3 else { return nil }
        
        guard let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }
        
        return hours * 3600 + minutes * 60 + seconds
    }
    
    private func updateTimeEstimate(progress: Double, currentIndex: Int) {
        // Use per-file timing for more accurate estimates - CURRENT FILE ONLY
        guard let fileStartTime = currentFileStartTime, progress > 0 else { return }
        
        let elapsed = Date().timeIntervalSince(fileStartTime)
        
        // Simple calculation: if 50% done in 30 seconds, total is 60 seconds, so 30 seconds left
        let estimatedTotalTime = elapsed / progress
        let remainingTime = estimatedTotalTime - elapsed
        
        if remainingTime > 0 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            
            // Show only the time for THIS file
            estimatedTimeRemaining = "~\(formatter.string(from: remainingTime) ?? "")"
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
            return FFmpegManager.shared.availabilityMessage
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

