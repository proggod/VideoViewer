import Foundation
import AVFoundation

class VideoConverter {
    static let shared = VideoConverter()
    
    enum ConversionError: LocalizedError {
        case unsupportedFormat
        case exportFailed(String)
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This video format cannot be converted using the built-in converter"
            case .exportFailed(let reason):
                return "Export failed: \(reason)"
            case .cancelled:
                return "Conversion was cancelled"
            }
        }
    }
    
    /// Check if a video can be converted using AVFoundation
    func canConvert(url: URL) -> Bool {
        let asset = AVAsset(url: url)
        
        // Check if the asset is readable
        guard asset.isReadable else { return false }
        
        // Check for video tracks
        let videoTracks = asset.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return false }
        
        // AVFoundation can handle most common formats
        let supportedExtensions = ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "mpg", "mpeg", "3gp", "3g2"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }
    
    /// Convert video to MP4 using AVFoundation
    func convert(from inputURL: URL, to outputURL: URL, progress: @escaping (Float) -> Void) async throws {
        let asset = AVAsset(url: inputURL)
        
        // Check if we can export this asset
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            // Try with pass through if highest quality fails
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ConversionError.unsupportedFormat
            }
            return try await performExport(session: exportSession, outputURL: outputURL, progress: progress)
        }
        
        return try await performExport(session: exportSession, outputURL: outputURL, progress: progress)
    }
    
    private func performExport(session: AVAssetExportSession, outputURL: URL, progress: @escaping (Float) -> Void) async throws {
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        
        // Set up metadata
        var metadata = session.asset.metadata
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierCreator
        item.value = "VideoViewer" as NSString
        metadata.append(item)
        session.metadata = metadata
        
        return try await withCheckedThrowingContinuation { continuation in
            // Monitor progress
            let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                progress(session.progress)
            }
            
            session.exportAsynchronously {
                progressTimer.invalidate()
                
                switch session.status {
                case .completed:
                    progress(1.0)
                    continuation.resume()
                    
                case .failed:
                    if let error = session.error {
                        continuation.resume(throwing: ConversionError.exportFailed(error.localizedDescription))
                    } else {
                        continuation.resume(throwing: ConversionError.exportFailed("Unknown error"))
                    }
                    
                case .cancelled:
                    continuation.resume(throwing: ConversionError.cancelled)
                    
                default:
                    continuation.resume(throwing: ConversionError.exportFailed("Export status: \(session.status.rawValue)"))
                }
            }
        }
    }
    
    /// Get compatible export presets for an asset
    func getCompatiblePresets(for url: URL) -> [String] {
        let asset = AVAsset(url: url)
        let presets = [
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetLowQuality,
            AVAssetExportPresetPassthrough,
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPreset640x480
        ]
        
        return presets.filter { preset in
            AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset)
        }
    }
}

// Extension to support more formats using AVFoundation's built-in decoders
extension VideoConverter {
    /// Try multiple export strategies for difficult formats
    func convertWithFallback(from inputURL: URL, to outputURL: URL, progress: @escaping (Float) -> Void) async throws {
        let asset = AVAsset(url: inputURL)
        
        // Strategy 1: Try highest quality first
        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            
            do {
                return try await performExport(session: session, outputURL: outputURL, progress: progress)
            } catch {
                print("Highest quality export failed: \(error)")
            }
        }
        
        // Strategy 2: Try passthrough (fastest, keeps original quality)
        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            
            do {
                return try await performExport(session: session, outputURL: outputURL, progress: progress)
            } catch {
                print("Passthrough export failed: \(error)")
            }
        }
        
        // Strategy 3: Try specific resolution presets
        let resolutionPresets = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540
        ]
        
        for preset in resolutionPresets {
            if AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset),
               let session = AVAssetExportSession(asset: asset, presetName: preset) {
                session.outputURL = outputURL
                session.outputFileType = .mp4
                
                do {
                    return try await performExport(session: session, outputURL: outputURL, progress: progress)
                } catch {
                    print("\(preset) export failed: \(error)")
                    continue
                }
            }
        }
        
        // Strategy 4: Create custom composition for problematic formats
        do {
            try await convertUsingComposition(from: inputURL, to: outputURL, progress: progress)
        } catch {
            throw ConversionError.unsupportedFormat
        }
    }
    
    /// Convert using AVMutableComposition for more control
    private func convertUsingComposition(from inputURL: URL, to outputURL: URL, progress: @escaping (Float) -> Void) async throws {
        let asset = AVAsset(url: inputURL)
        let composition = AVMutableComposition()
        
        // Add video track
        if let videoTrack = asset.tracks(withMediaType: .video).first,
           let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: videoTrack,
                at: .zero
            )
            compositionVideoTrack.preferredTransform = videoTrack.preferredTransform
        }
        
        // Add audio track
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero
            )
        }
        
        // Export the composition
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConversionError.unsupportedFormat
        }
        
        return try await performExport(session: exportSession, outputURL: outputURL, progress: progress)
    }
}