import SwiftUI
import AVKit

// Safe wrapper around AVKit's VideoPlayer to handle initialization issues
struct SafeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Update player if needed
        if nsView.player !== player {
            nsView.player = player
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        // Clean up player view
        nsView.player = nil
    }
}