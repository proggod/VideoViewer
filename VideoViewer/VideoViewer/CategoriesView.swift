import SwiftUI

struct CategoriesView: View {
    @StateObject private var categoryManager = CategoryManager.shared
    @State private var newCategoryName = ""
    @State private var editingCategory: CategoryManager.Category?
    @State private var editingName = ""
    @State private var showingDeleteAlert = false
    @State private var categoryToDelete: CategoryManager.Category?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Categories")
                    .font(.largeTitle)
                    .bold()
                
                Spacer()
            }
            .padding()
            
            // Add new category
            HStack {
                TextField("New category name", text: $newCategoryName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        addCategory()
                    }
                
                Button("Add") {
                    addCategory()
                }
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)
            
            // Categories list
            List {
                ForEach(categoryManager.categories) { category in
                    HStack {
                        if editingCategory?.id == category.id {
                            TextField("Category name", text: $editingName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onSubmit {
                                    saveEdit()
                                }
                            
                            Button("Save") {
                                saveEdit()
                            }
                            
                            Button("Cancel") {
                                editingCategory = nil
                                editingName = ""
                            }
                        } else {
                            Text(category.name)
                            
                            Spacer()
                            
                            Button(action: {
                                editingCategory = category
                                editingName = category.name
                            }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            
                            Button(action: {
                                categoryToDelete = category
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
        .frame(minWidth: 400, minHeight: 300)
        .alert("Delete Category", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let category = categoryToDelete {
                    _ = categoryManager.deleteCategory(id: category.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(categoryToDelete?.name ?? "")'? This will remove it from all videos.")
        }
    }
    
    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if categoryManager.addCategory(name: trimmedName) {
                newCategoryName = ""
            }
        }
    }
    
    private func saveEdit() {
        if let category = editingCategory {
            let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty && trimmedName != category.name {
                _ = categoryManager.updateCategory(id: category.id, newName: trimmedName)
            }
        }
        editingCategory = nil
        editingName = ""
    }
}