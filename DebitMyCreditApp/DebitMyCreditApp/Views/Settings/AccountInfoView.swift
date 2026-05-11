import SwiftUI
import CoreData
import Combine

struct AccountInfoView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @State private var isEditing = false
    @State private var newEmail = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var showSuccessAlert = false

    private var currentEmail: String {
        authManager.currentUser?.email ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading) {
            if isEditing {
                editingFields
            } else {
                infoDisplay
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .navigationTitle("Account Info")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDragIndicator(.visible)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong")
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") {}
                .tint(.blue)
        } message: {
            Text("Account info updated successfully!")
        }
    }

    // MARK: View for diaplying current account info
    private var infoDisplay: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledField(label: "Email", value: currentEmail)
            LabeledField(label: "Password", value: "••••••••")
            
            Button(action: {
                newEmail = currentEmail
                newPassword = ""
                confirmPassword = ""
                isEditing = true
            }) {
                Text("Edit")
                    .frame(maxWidth: 100, minHeight: 40)
                    .background(Color.appOrange)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .fontWeight(.bold)
            }
            .padding(.top, 20)
        }
    }

    // MARK: - View for editing acount info
    private var editingFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                TextField("New email", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            }
            .frame(height: 37)

            ZStack {
                SecureField("New password", text: $newPassword)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            }
            .frame(height: 37)

            ZStack {
                SecureField("Confirm password", text: $confirmPassword)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            }
            .frame(height: 37)

            // Stack to hold the buttons to save and cancel the edits
            HStack(spacing: 12) {
                Button(role: .cancel, action: {
                    isEditing = false
                }) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.appRed)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .fontWeight(.bold)
                }

                Button(action: {
                    let emailToSend = newEmail.trimmingCharacters(in: .whitespaces)
                    let emailChanged = emailToSend != currentEmail && !emailToSend.isEmpty
                    let passwordChanged = !newPassword.isEmpty

                    guard emailChanged || passwordChanged else {
                        errorMessage = "No changes to save."
                        showErrorAlert = true
                        return
                    }
                    guard newPassword == confirmPassword else {
                        errorMessage = "Passwords do not match."
                        showErrorAlert = true
                        return
                    }
                    Task {
                        await saveAccountUpdate(
                            email: emailChanged ? emailToSend : nil,
                            password: passwordChanged ? newPassword : nil
                        )
                    }
                }) {
                    Text("Save")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.appOrange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .fontWeight(.bold)
                }
            }
        }
    }
    
    // Saves updated email/password to the server and reflects email change in CoreData
    @MainActor
    private func saveAccountUpdate(email: String?, password: String?) async {
        guard let token = KeychainHelper.get("auth_token") else {
            errorMessage = "Not logged in."
            showErrorAlert = true
            return
        }

        do {
            let response = try await APIService.shared.updateUserAccountInfo(
                email: email,
                password: password,
                token: token
            )

            guard response.success == true else {
                errorMessage = response.message ?? "Update failed."
                showErrorAlert = true
                return
            }

            // Update email in CoreData if it changed, using the server's updatedAt
            if let newEmailValue = email, let user = authManager.currentUser {
                user.email = newEmailValue
                user.updatedAt = APIModels.FlexibleDate.string(response.updatedAt ?? "").dateValue ?? Date()
                try? viewContext.save()
                authManager.objectWillChange.send()
            }

            showSuccessAlert = true
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}

#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return NavigationStack {
        AccountInfoView()
            .environment(\.managedObjectContext, context)
            .environmentObject(PersistenceController.previewAuthManager())
    }
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    return NavigationStack {
        AccountInfoView()
            .environment(\.managedObjectContext, context)
            .environmentObject(PersistenceController.previewEmptyAuthManager())
    }
}

// MARK: - Helper view

private struct LabeledField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }
}

