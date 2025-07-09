import SwiftUI

struct StartupProgressView: View {
    @State private var progressMessages: [String] = []
    @State private var isComplete = false
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Video Viewer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            if !isComplete {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                    .padding()
                
                Text("Initializing...")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            // Console-style log view
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(progressMessages.enumerated()), id: \.offset) { index, message in
                            Text(message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.green)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(height: 200)
                .background(Color.black.opacity(0.9))
                .cornerRadius(8)
                .onChange(of: progressMessages.count) { oldValue, newValue in
                    withAnimation {
                        scrollProxy.scrollTo(newValue - 1, anchor: .bottom)
                    }
                }
            }
            
            if isComplete {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(width: 600, height: 500)
        .onAppear {
            performStartupTasks()
        }
    }
    
    private func addMessage(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            progressMessages.append("[\(Date().formatted(.dateTime.hour().minute().second()))] \(message)")
        }
    }
    
    private func performStartupTasks() {
        Task {
            addMessage("Starting Video Viewer...")
            
            // Check for first run
            await MainActor.run {
                addMessage("Checking application settings...")
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            
            // Initialize managers
            await MainActor.run {
                addMessage("Initializing category system...")
                _ = CategoryManager.shared
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            await MainActor.run {
                addMessage("Initializing video metadata manager...")
                _ = VideoMetadataManager.shared
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            await MainActor.run {
                addMessage("Initializing cleanup manager...")
                _ = CleanupManager.shared
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            await MainActor.run {
                addMessage("Initializing settings manager...")
                _ = SettingsManager.shared
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            // Check default folder
            await MainActor.run {
                if let defaultFolder = UserDefaults.standard.string(forKey: "defaultFolder") {
                    addMessage("Default folder set: \(URL(fileURLWithPath: defaultFolder).lastPathComponent)")
                } else {
                    addMessage("No default folder configured")
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            // Complete
            await MainActor.run {
                addMessage("✓ Initialization complete!")
                isComplete = true
            }
            
            // Auto-continue after a short delay if user hasn't clicked
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            await MainActor.run {
                onComplete()
            }
        }
    }
}