import SwiftUI

struct MKVRemuxProgressView: View {
    let directoryURL: URL
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var isProcessing = false
    @State private var currentFileName = ""
    @State private var currentProgress: Float = 0
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var results: [RemuxResult] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Convert MKV Files")
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
            
            if !isProcessing && results.isEmpty {
                // Start screen
                VStack(spacing: 20) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Convert Compatible MKV Files")
                        .font(.title3)
                    
                    Text("This will convert MKV files with H.264/H.265 video to MP4 format")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Text("Original files will be renamed with .bak extension")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: startRemuxing) {
                        Text("Start Conversion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isProcessing {
                // Processing view
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle())
                    
                    Text("Converting MKV Files...")
                        .font(.headline)
                    
                    if !currentFileName.isEmpty {
                        VStack(spacing: 8) {
                            Text(currentFileName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 400)
                            
                            ProgressView(value: currentProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 300)
                            
                            Text("\(Int(currentProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Text("\(processedCount) / \(totalCount) files")
                        .font(.title3)
                        .fontWeight(.medium)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                                    case .success(let original, _):
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text(original.lastPathComponent)
                                            .font(.caption)
                                        Spacer()
                                        Text("Converted")
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
                                        
                                    case .skipped(let original, let reason):
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.orange)
                                        Text(original.lastPathComponent)
                                            .font(.caption)
                                        Spacer()
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    HStack {
                        let successCount = results.filter { if case .success = $0 { return true } else { return false } }.count
                        let failureCount = results.filter { if case .failure = $0 { return true } else { return false } }.count
                        let skippedCount = results.filter { if case .skipped = $0 { return true } else { return false } }.count
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(successCount) converted, \(failureCount) failed, \(skippedCount) skipped")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if successCount > 0 {
                                Text("Converted MKV files are now MP4. Original files saved as .mkv.bak")
                                    .font(.caption2)
                                    .foregroundColor(.green)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 600, height: 500)
    }
    
    private func startRemuxing() {
        isProcessing = true
        results = []
        
        Task {
            let remuxResults = await MKVRemuxer.shared.remuxAllCompatible(in: directoryURL) { fileName, progress, processed, total in
                Task { @MainActor in
                    self.currentFileName = fileName
                    self.currentProgress = progress
                    self.processedCount = processed
                    self.totalCount = total
                }
            }
            
            await MainActor.run {
                self.results = remuxResults
                self.isProcessing = false
                
                // Refresh the file browser to show new MP4 files
                NotificationCenter.default.post(name: .refreshBrowser, object: nil)
            }
        }
    }
}