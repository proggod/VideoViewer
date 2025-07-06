import Foundation

/// Manages FFmpeg binary location and availability
class FFmpegManager {
    static let shared = FFmpegManager()
    
    /// Get the path to FFmpeg binary
    var ffmpegPath: String? {
        // 1. First check for bundled FFmpeg in app resources
        if let bundledPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            // Ensure it's executable
            ensureExecutable(at: bundledPath)
            return bundledPath
        }
        
        // 2. Check common Homebrew locations
        let homebrewPaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon
            "/usr/local/bin/ffmpeg"       // Intel
        ]
        
        for path in homebrewPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // 3. Check system PATH
        if let systemPath = findInPath() {
            return systemPath
        }
        
        return nil
    }
    
    /// Check if FFmpeg is available
    var isAvailable: Bool {
        return ffmpegPath != nil
    }
    
    /// Find FFmpeg in system PATH
    private func findInPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            print("Error finding FFmpeg: \(error)")
        }
        
        return nil
    }
    
    /// Ensure binary has execute permissions
    private func ensureExecutable(at path: String) {
        do {
            let attributes = [FileAttributeKey.posixPermissions: 0o755]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            print("Failed to set executable permissions on FFmpeg: \(error)")
        }
    }
    
    /// Get user-friendly message about FFmpeg availability
    var availabilityMessage: String {
        if isAvailable {
            if let path = ffmpegPath {
                if path.contains(Bundle.main.bundlePath) {
                    return "Using bundled FFmpeg"
                } else {
                    return "Using system FFmpeg at: \(path)"
                }
            }
        }
        return "FFmpeg not found. Please install with: brew install ffmpeg"
    }
}