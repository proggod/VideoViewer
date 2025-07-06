import Foundation
import AVFoundation

class MKVRemuxer {
    static let shared = MKVRemuxer()
    
    private init() {}
    
    // Check if an MKV file can be remuxed (has compatible codecs)
    func canRemux(url: URL) async -> Bool {
        guard url.pathExtension.lowercased() == "mkv" else { return false }
        
        let asset = AVAsset(url: url)
        
        do {
            // Check video tracks
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { return false }
            
            // Get video format
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)
            guard let formatDesc = formatDescriptions.first else { return false }
            
            let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
            
            // Check if it's H.264 or H.265
            let supportedVideoCodecs: [CMVideoCodecType] = [
                kCMVideoCodecType_H264,
                kCMVideoCodecType_HEVC
            ]
            
            guard supportedVideoCodecs.contains(codecType) else {
                print("Unsupported video codec: \(codecType)")
                return false
            }
            
            // Check audio tracks
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                for audioTrack in audioTracks {
                    let audioFormats = try await audioTrack.load(.formatDescriptions)
                    guard let audioFormat = audioFormats.first else { continue }
                    
                    let audioCodec = CMFormatDescriptionGetMediaSubType(audioFormat)
                    
                    // Check if it's a supported audio codec
                    let supportedAudioCodecs: [AudioFormatID] = [
                        kAudioFormatMPEG4AAC,
                        kAudioFormatMPEGLayer3,
                        kAudioFormatMPEGLayer1,
                        kAudioFormatMPEGLayer2,
                        kAudioFormatLinearPCM
                    ]
                    
                    if !supportedAudioCodecs.contains(audioCodec) {
                        print("Unsupported audio codec: \(audioCodec)")
                        return false
                    }
                }
            }
            
            return true
        } catch {
            print("Error checking MKV compatibility: \(error)")
            return false
        }
    }
    
    // Remux MKV to MP4
    func remux(url: URL, progress: @escaping (Float) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        
        // Check if we can export as MP4
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RemuxError.exportSessionCreationFailed
        }
        
        // Create output URL (same directory, .mp4 extension)
        let outputURL = url.deletingPathExtension().appendingPathExtension("mp4")
        
        // Make sure output doesn't already exist
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // Start export with progress monitoring using Task
        let exportTask = Task {
            // Monitor progress in a separate task
            while !Task.isCancelled {
                progress(exportSession.progress)
                
                if exportSession.status == .completed || 
                   exportSession.status == .failed || 
                   exportSession.status == .cancelled {
                    break
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }
        
        // Start export
        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }
        
        // Cancel progress monitoring
        exportTask.cancel()
        
        switch exportSession.status {
        case .completed:
            // Rename original MKV to .mkv.bak
            let backupURL = url.appendingPathExtension("bak")
            try FileManager.default.moveItem(at: url, to: backupURL)
            
            return outputURL
            
        case .failed:
            if let error = exportSession.error {
                throw RemuxError.exportFailed(error)
            } else {
                throw RemuxError.unknownError
            }
            
        case .cancelled:
            throw RemuxError.cancelled
            
        default:
            throw RemuxError.unknownError
        }
    }
    
    // Batch remux all compatible MKVs in a directory
    func remuxAllCompatible(in directory: URL, progress: @escaping (String, Float, Int, Int) -> Void) async -> [RemuxResult] {
        var results: [RemuxResult] = []
        
        // Find all MKV files
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return results
        }
        
        let mkvFiles = contents.filter { $0.pathExtension.lowercased() == "mkv" }
        let totalFiles = mkvFiles.count
        var processedCount = 0
        
        for mkvFile in mkvFiles {
            processedCount += 1
            progress(mkvFile.lastPathComponent, 0, processedCount, totalFiles)
            
            // Check if it can be remuxed
            if await canRemux(url: mkvFile) {
                do {
                    let outputURL = try await remux(url: mkvFile) { fileProgress in
                        progress(mkvFile.lastPathComponent, fileProgress, processedCount, totalFiles)
                    }
                    results.append(.success(original: mkvFile, output: outputURL))
                } catch {
                    results.append(.failure(original: mkvFile, error: error))
                }
            } else {
                results.append(.skipped(original: mkvFile, reason: "Incompatible codecs"))
            }
        }
        
        return results
    }
}

enum RemuxError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(Error)
    case cancelled
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let error):
            return "Export failed: \(error.localizedDescription)"
        case .cancelled:
            return "Export was cancelled"
        case .unknownError:
            return "Unknown error occurred"
        }
    }
}

enum RemuxResult {
    case success(original: URL, output: URL)
    case failure(original: URL, error: Error)
    case skipped(original: URL, reason: String)
}