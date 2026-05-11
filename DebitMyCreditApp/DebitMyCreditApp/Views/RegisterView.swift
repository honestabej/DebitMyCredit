import SwiftUI
import CoreData

struct RegisterView: View {
    @Binding var showRegister: Bool
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var passwordReEntry: String = ""
    @State private var isSecureEntry: Bool = true
    @State private var isLoading: Bool = false
    @State private var loadingMessage: String = "Creating Account..."
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false

    var body: some View {
        ZStack {
            // Background gradient from Colors.swift
            AppGradients.mainGradient
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // App title / branding
                VStack(spacing: 8) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.95))
                        .symbolRenderingMode(.hierarchical)
                    Text("DebitMyCredit")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 8)

                // Form card
                VStack(spacing: 16) {
                    // Email
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(12)
                        .background(.white.opacity(0.12), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)

                    // Password
                    Group {
                        if isSecureEntry {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        } else {
                            TextField("Password", text: $password)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .overlay(alignment: .trailing) {
                        Button(action: { isSecureEntry.toggle() }) {
                            Image(systemName: isSecureEntry ? "eye.slash" : "eye")
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.trailing, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Password Re-Entry
                    Group {
                        if isSecureEntry {
                            SecureField("Re-Enter Password", text: $passwordReEntry)
                                .textContentType(.password)
                        } else {
                            TextField("Re-Enter Password", text: $passwordReEntry)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .overlay(alignment: .trailing) {
                        Button(action: { isSecureEntry.toggle() }) {
                            Image(systemName: isSecureEntry ? "eye.slash" : "eye")
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.trailing, 12)
                        }
                        .buttonStyle(.plain)
                    }

                    // Error message
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.35), in: .rect(cornerRadius: 10))
                            .transition(.opacity)
                    }

                    // Login button
                    Button(action: register) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isLoading ? loadingMessage : "Register Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.20), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty || passwordReEntry.isEmpty)
                    .opacity((isLoading || email.isEmpty || password.isEmpty || passwordReEntry.isEmpty) ? 0.25 : 1)

                    // Forgot password / sign up
                    HStack {
                        Spacer()
                        Text("Already have an account?")
                            .foregroundStyle(.white.opacity(0.9))
                            .font(.footnote)
                        Button("Log In") {
                            withAnimation {
                                showRegister = false
                            }
                        }
                        .foregroundStyle(.white)
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .padding(.top, 60)
            .padding(.bottom, 24)
        }
    }

    private func register() {
        // Validate inputs
        guard !email.isEmpty, !password.isEmpty, !passwordReEntry.isEmpty else {
            return
        }
        
        // Check if passwords match
        guard password == passwordReEntry else {
            errorMessage = "Passwords do not match"
            return
        }
        
        // Basic email validation
        guard email.contains("@") && email.contains(".") else {
            errorMessage = "Please enter a valid email address"
            return
        }
        
        // Basic password validation
        guard password.count >= 6 else {
            errorMessage = "Password must be at least 6 characters"
            return
        }
        
        isLoading = true
        errorMessage = nil
        loadingMessage = "Creating Account..."
        
        Task {
            do {
                // Call the API
                let response = try await APIService.shared.register(email: email, password: password)
                
                // Check for token (token presence indicates success)
                guard let token = response.token else {
                    await MainActor.run {
                        errorMessage = response.message ?? "Registration failed. Please try again."
                        isLoading = false
                    }
                    return
                }
                
                // Create the user in Core Data
                await MainActor.run {
                    let user = createUser(
                        id: response.user?.id,
                        email: response.user?.email ?? email
                    )
                    
                    // Login with AuthManager
                    authManager.login(token: token, user: user)
                    
                    isLoading = false
                }
                
            } catch let error as APIError {
                await MainActor.run {
                    if error == .dbAsleep {
                        // Show retry message but keep spinner going while APIService retries
                        loadingMessage = "Waking DB, retrying..."
                    } else {
                        errorMessage = error.localizedDescription
                        isLoading = false
                    }
                }
                
                // Re-throw to allow retry logic in APIService
                throw error
                
            } catch {
                await MainActor.run {
                    errorMessage = "An unexpected error occurred. Please try again."
                    isLoading = false
                }
            }
        }
    }
    
    private func createUser(id: String?, email: String) -> User {
        let newUser = User(context: viewContext)
        newUser.id = id.flatMap { UUID(uuidString: $0) } ?? UUID()
        newUser.email = email
        newUser.createdAt = Date()
        newUser.updatedAt = Date()
        
        try? viewContext.save()
        
        return newUser
    }
}

#Preview {
    
    let context = PersistenceController.preview.container.viewContext
    
    RegisterView(showRegister: .constant(true))
        .environmentObject(AuthManager(viewContext: context))
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
