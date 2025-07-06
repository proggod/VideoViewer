import SwiftUI
import AVKit
// Using built-in AVFoundation for video conversion - no external dependencies needed

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
                        // Use built-in AVFoundation converter
                        print("🎬 Using AVFoundation conversion for: \(videoURL.lastPathComponent)")
                        
                        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("mp4")
                        
                        // Check if the converter can handle this format
                        if VideoConverter.shared.canConvert(url: videoURL) {
                            try await VideoConverter.shared.convertWithFallback(from: videoURL, to: outputURL) { progress in
                                Task { @MainActor in
                                    self.currentProgress = Double(progress)
                                    self.updateTimeEstimate(progress: Double(progress), currentIndex: index)
                                }
                            }
                            
                            // Rename original to .bak
                            let backupURL = videoURL.appendingPathExtension("bak")
                            try FileManager.default.moveItem(at: videoURL, to: backupURL)
                            
                            results.append(.success(original: videoURL, output: outputURL, method: .converted))
                        } else {
                            throw ConversionError.unsupportedFormat
                        }
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
    
    // Video conversion is now handled by VideoConverter.swift using built-in AVFoundation
    
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
    case unsupportedFormat
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This video format cannot be converted. Only MKV files with compatible codecs can be remuxed."
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