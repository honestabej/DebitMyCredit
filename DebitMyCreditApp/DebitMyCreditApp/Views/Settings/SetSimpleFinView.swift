import SwiftUI
import CoreData

struct SetSimpleFinView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    
    @State private var setupToken: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSaving: Bool = false
    @State private var isSavingMessage: String = "Saving Credentials..."
    @State private var successfulMessage: String = "Your credentials were saved successfully!"
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var isEditing: Bool = false
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var credentialsAreSet: Bool {
        authManager.currentUser?.simpleFinCredentialsSet == true
    }

    var body: some View {
        ZStack {
            VStack {

                VStack(alignment: .leading, spacing: 8) {
                    
                    ZStack(alignment: .topLeading) {
                        // Placeholder or masked text
                        if setupToken.isEmpty && !isEditing && credentialsAreSet {
                            Text("************")
                                .foregroundColor(.gray)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 19)
                                .font(.system(size: 14))
                        } else if setupToken.isEmpty {
                            Text("Paste SimpleFIN setup token here")
                                .foregroundColor(.gray.opacity(0.6))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 19)
                                .font(.system(size: 14))
                        }

                        // TextEditor
                        TextEditor(text: $setupToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.primary)
                            .font(.system(size: 14))
                            .frame(height: 100)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .disabled(credentialsAreSet && !isEditing)
                            .opacity((credentialsAreSet && !isEditing) ? 0.5 : 1.0)
                    }
                    .frame(height: 120)
                }
                .padding(.horizontal, 20)

                // --- SAVE / EDIT BUTTON ---
                HStack(spacing: 12) {
                    if credentialsAreSet {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Text("Disconnect")
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .fontWeight(.bold)
                        }
                        .confirmationDialog(
                            "Are you sure you want to disconnect your SimpleFIN account?",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible,
                            actions: {
                                Button("Remove", role: .destructive) { delete() }
                                Button("Cancel", role: .cancel) {}
                            }
                        )
                    }
                    
                    Button(action: {
                        if credentialsAreSet && !isEditing {
                            // Begin editing → clear inputs and reset placeholders
                            isEditing = true
                            setupToken = ""
                        } else {
                            save()
                        }
                    }) {
                        Text(credentialsAreSet && !isEditing ? "Edit" : "Save")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.appOrange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .fontWeight(.bold)
                    }
                    .disabled(isSaving || (isEditing && setupToken.isEmpty))
                    .opacity((isSaving || (isEditing && setupToken.isEmpty)) ? 0.45 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                // Open SimpleFIN button
                Button {
                    if let url = URL(string: "https://bridge.simplefin.org/simplefin/create") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Open SimpleFIN Bridge")
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding()
                .frame(width: 320, height: 40)
                .background(.clear)
                .foregroundColor(Color.appOrange)
                .cornerRadius(12)
                .fontWeight(.medium)
                .padding(.bottom, 20)
            }
            .alert("Success", isPresented: $showSuccessAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text(successfulMessage)
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }

            // Overlay during saving
            if isSaving {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()

                ProgressView(isSavingMessage)
                    .padding(16)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .navigationTitle("SimpleFIN Setup Token")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDragIndicator(.visible)
    }

    private func save() {
        // Just to be sure, ensure there is a currentUser
        guard let currentUser = authManager.currentUser else {
            errorMessage = "No user logged in"
            showErrorAlert = true
            return
        }
        
        // Ensure that a token was entered
        errorMessage = nil
        guard !setupToken.isEmpty else {
            errorMessage = "Access token is required"
            showErrorAlert = true
            return
        }
        
        // Get user ID before async context
        guard let userID = currentUser.id else {
            errorMessage = "Invalid user ID"
            showErrorAlert = true
            return
        }
        
        isSavingMessage = "Connecting to SimpleFIN..."
        isSaving = true
        
        // Set the Core Data flag to true before calling API, then revert if unsuccessful to keep them in line
        do {
            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
        } catch {
            isSaving = false
            print("Failed to update Core Data:", error)
            errorMessage = "Core Data error, please try again later"
            showErrorAlert = true
        }
        
        Task {
            do {
                // Call API through the APIService file
                let response = try await APIService.shared.connectSimpleFin(
                    userID: userID,
                    setupToken: setupToken
                )
                
                await MainActor.run {
                    isSaving = false
                    
                    if response.success == true {
                        // Update UI state
                        isSaving = false
                        isEditing = false
                        setupToken = "************"
                        
                        successfulMessage = "SimpleFIN account connected successfully!"
                        showSuccessAlert = true
                        
                        // Save the accounts to Core Data
                        if let accounts = response.accounts, !accounts.isEmpty {
                            // Convert SimpleFINAccount objects to dictionaries
                            let accountsData = accounts.map { $0.toDictionary }
                            
                            do {
                                try CoreDataService.shared.saveSimpleFinAccounts(accountsData, forUserID: userID, in: viewContext)
                            } catch {
                                isSaving = false
                                print("Failed to save Accounts to Core Data:", error)
                                errorMessage = "An error occurred savings bank accounts to Core Data after connecting SimpleFIN account"
                                showErrorAlert = true
                            }
                        }
                    } else {
                        // Set Core Data flag back to false
                        do {
                            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                        } catch {
                            isSaving = false
                            print("Failed to update Core Data:", error)
                            errorMessage = "Core Data error occurred after connecting SimpleFIN account"
                            showErrorAlert = true
                        }
                        
                        errorMessage = response.message ?? "Failed to connect SimpleFIN account"
                        showErrorAlert = true
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    isSaving = false
                    
                    // Revert Core Data flag back to false since API failed
                    do {
                        try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                    } catch {
                        print("Failed to revert Core Data after API error:", error)
                    }
                    
                    errorMessage = error.errorDescription
                    showErrorAlert = true
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    
                    // Revert Core Data flag back to false since API failed
                    do {
                        try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                    } catch {
                        print("Failed to revert Core Data after API error:", error)
                    }
                    
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    func delete() {
        // Just to be sure, ensure there is a currentUser
        guard let currentUser = authManager.currentUser else {
            errorMessage = "No user logged in"
            showErrorAlert = true
            return
        }
        
        // Get user ID before async context
        guard let userID = currentUser.id else {
            errorMessage = "Invalid user ID"
            showErrorAlert = true
            return
        }
        
        // Set the Core Data flag to true before calling API, then revert if unsuccessful to keep them in line
        do {
            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
        } catch {
            isSaving = false
            print("Failed to update Core Data:", error)
            errorMessage = "Core Data error, please try again later"
            showErrorAlert = true
        }
        
        Task {
            do {
                // Call API through the APIService file
                let response = try await APIService.shared.disconnectSimpleFin(
                    userID: userID
                )
                
                await MainActor.run {
                    isSaving = false
                    
                    if response.success == true {
                        // Update UI state
                        isSaving = false
                        isEditing = false
                        setupToken = "Paste SimpleFIN setup token here"
                        
                        successfulMessage = "SimpleFIN account disconnected successfully"
                        showSuccessAlert = true
                    } else {
                        // Set Core Data flag back to true
                        do {
                            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                        } catch {
                            isSaving = false
                            print("Failed to update Core Data:", error)
                            errorMessage = "Core Data error occurred after disconnecting SimpleFIN account"
                            showErrorAlert = true
                        }
                        
                        errorMessage = response.message ?? "Failed to disconnect SimpleFIN account"
                        showErrorAlert = true
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    isSaving = false
                    
                    // Revert Core Data flag back to true since API failed
                    do {
                        try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                    } catch {
                        print("Failed to revert Core Data after API error:", error)
                    }
                    
                    errorMessage = error.errorDescription
                    showErrorAlert = true
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    
                    // Revert Core Data flag back to true since API failed
                    do {
                        try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                    } catch {
                        print("Failed to revert Core Data after API error:", error)
                    }
                    
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
}



#Preview("Not Connected") {
    let persistence = PersistenceController(inMemory: true)
    let context = persistence.container.viewContext

    let user = User(context: context)
    user.id = UUID()
    user.email = "test@example.com"
    user.simpleFinCredentialsSet = false
    user.createdAt = Date()
    user.updatedAt = Date()
    try? context.save()

    let authManager = AuthManager(viewContext: context)
    authManager.currentUser = user
    authManager.isLoggedIn = true

    return NavigationStack {
        SetSimpleFinView()
            .environmentObject(authManager)
            .environment(\.managedObjectContext, context)
    }
}

#Preview("Already Connected") {
    let persistence = PersistenceController(inMemory: true)
    let context = persistence.container.viewContext

    let user = User(context: context)
    user.id = UUID()
    user.email = "test@example.com"
    user.simpleFinCredentialsSet = true
    user.createdAt = Date()
    user.updatedAt = Date()
    try? context.save()

    let authManager = AuthManager(viewContext: context)
    authManager.currentUser = user
    authManager.isLoggedIn = true

    return NavigationStack {
        SetSimpleFinView()
            .environmentObject(authManager)
            .environment(\.managedObjectContext, context)
    }
}


