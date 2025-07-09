import SwiftUI

struct SettingsView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.largeTitle)
                .padding(.bottom)
            
            GroupBox(label: Text("Database Location").font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    if let dbPath = settingsManager.databaseDirectory {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(dbPath.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                            Text("Using default location")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Button("Change Location...") {
                            settingsManager.showDatabaseDirectoryPicker {}
                        }
                        
                        if settingsManager.databaseDirectory != nil {
                            Button("Use Default") {
                                settingsManager.databaseDirectory = nil
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    Text("The database stores your categories and cleanup rules. Using a network location allows sharing between machines.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
            
            GroupBox(label: Text("Startup").font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show startup progress", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "showStartupProgress") },
                        set: { UserDefaults.standard.set($0, forKey: "showStartupProgress") }
                    ))
                    
                    Text("Display initialization progress when the app starts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}