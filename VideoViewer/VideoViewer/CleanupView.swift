import SwiftUI

struct CleanupView: View {
    @StateObject private var cleanupManager = CleanupManager.shared
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var editingRule: CleanupManager.CleanupRule?
    @State private var editingSearchText = ""
    @State private var editingReplaceText = ""
    @State private var showingDeleteAlert = false
    @State private var ruleToDelete: CleanupManager.CleanupRule?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Cleanup Rules")
                    .font(.largeTitle)
                    .bold()
                
                Spacer()
            }
            .padding()
            
            // Add new rule
            VStack(alignment: .leading, spacing: 8) {
                Text("Add New Rule")
                    .font(.headline)
                
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search for:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Text to find", text: $searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 200)
                    }
                    
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replace with:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Replacement text", text: $replaceText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 200)
                    }
                    
                    Button("Add Rule") {
                        addRule()
                    }
                    .disabled(searchText.isEmpty)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 16) {
                        Text("Tip: Spaces are shown as ␣ in the list below")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .foregroundColor(.secondary)
                        
                        Text("Use * as wildcard to match any text (e.g., (*) matches (12345))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 16) {
                        Text("Note: Searches are case-insensitive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .foregroundColor(.secondary)
                        
                        Text("Auto-cleanup: removes leading/trailing spaces, collapses multiple spaces")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            // Rules list
            List {
                ForEach(Array(cleanupManager.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack {
                        // Up/Down arrows for reordering
                        VStack(spacing: 4) {
                            Button(action: {
                                if index > 0 {
                                    cleanupManager.moveRule(from: index, to: index - 1)
                                }
                            }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .disabled(index == 0)
                            .foregroundColor(index == 0 ? .gray : .accentColor)
                            
                            Button(action: {
                                if index < cleanupManager.rules.count - 1 {
                                    cleanupManager.moveRule(from: index, to: index + 1)
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .disabled(index == cleanupManager.rules.count - 1)
                            .foregroundColor(index == cleanupManager.rules.count - 1 ? .gray : .accentColor)
                        }
                        
                        // Enable/disable toggle
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { newValue in
                                _ = cleanupManager.toggleRule(id: rule.id, isEnabled: newValue)
                            }
                        ))
                        .toggleStyle(CheckboxToggleStyle())
                        .labelsHidden()
                        
                        if editingRule?.id == rule.id {
                            // Edit mode
                            HStack(spacing: 8) {
                                TextField("Search", text: $editingSearchText)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(width: 150)
                                
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.secondary)
                                
                                TextField("Replace", text: $editingReplaceText)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(width: 150)
                                
                                Button("Save") {
                                    saveEdit()
                                }
                                
                                Button("Cancel") {
                                    editingRule = nil
                                }
                            }
                        } else {
                            // Display mode - show with brackets
                            Text("[\(rule.displaySearchText)]")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(rule.isEnabled ? .primary : .secondary)
                            
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            
                            Text("[\(rule.displayReplaceText)]")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(rule.isEnabled ? .primary : .secondary)
                            
                            Spacer()
                            
                            Button(action: {
                                editingRule = rule
                                editingSearchText = rule.searchText
                                editingReplaceText = rule.replaceText
                            }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            
                            Button(action: {
                                ruleToDelete = rule
                                showingDeleteAlert = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(InsetListStyle())
        }
        .frame(minWidth: 600, minHeight: 400)
        .alert("Delete Rule", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let rule = ruleToDelete {
                    _ = cleanupManager.deleteRule(id: rule.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete this cleanup rule?")
        }
    }
    
    private func addRule() {
        if cleanupManager.addRule(searchText: searchText, replaceText: replaceText) {
            searchText = ""
            replaceText = ""
        }
    }
    
    private func saveEdit() {
        if let rule = editingRule {
            _ = cleanupManager.updateRule(
                id: rule.id,
                searchText: editingSearchText,
                replaceText: editingReplaceText
            )
        }
        editingRule = nil
    }
}