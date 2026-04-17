import SwiftUI
import CoreData

struct LoginView: View {
    @Binding var showRegister: Bool
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSecureEntry: Bool = true
    @State private var isLoading: Bool = false
    @State private var loadingMessage: String = "Signing In..."
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
                    
                    // Error message display
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
                    Button(action: login) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isLoading ? loadingMessage : "Sign In")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.20), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                    .opacity((isLoading || email.isEmpty || password.isEmpty) ? 0.25 : 1)
                    
                    // Forgot password / sign up
                    HStack {
                        Button("Forgot Password?") {}
                            .foregroundStyle(.white.opacity(0.9))
                            .font(.footnote)
                        Spacer()
                        Button("Create Account") {
                            showRegister = true
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
            .padding(.top, 100)
            .padding(.bottom, 24)
        }
    }

    private func login() {
        guard !email.isEmpty, !password.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        loadingMessage = "Signing In..."
        
        Task {
            do {
                // Call the API
                let response = try await APIService.shared.login(email: email, password: password)
                
                // Debug logging
                print("🔍 Swift - Response received:")
                print("  ├─ success: \(response.success ?? false)")
                print("  ├─ token: \(response.token != nil ? "Present" : "nil")")
                print("  ├─ user.id: \(response.user?.id ?? "nil")")
                print("  ├─ user.email: \(response.user?.email ?? "nil")")
                print("  └─ user.simpleFINConnected: \(response.user?.simpleFINConnected ?? false)")
                
                // Check for success and token
                guard response.success == true, let token = response.token else {
                    await MainActor.run {
                        errorMessage = response.message ?? response.error ?? "Login failed. Please try again."
                        isLoading = false
                    }
                    return
                }
                
                // Create or fetch the user in Core Data
                await MainActor.run {
                    let user = fetchOrCreateUser(id: response.user?.id, email: response.user?.email ?? email, simpleFINConnected: response.user?.simpleFINConnected ?? false)
                    
                    // Login with AuthManager
                    authManager.login(token: token, user: user)
                    
                    isLoading = false
                }
                
            } catch let error as APIError {
                await MainActor.run {
                    // Show retry message for server sleep
                    if error == .dbAsleep {
                        loadingMessage = "Waking DB, retrying..."
                    }
                    
                    // Only show error if not retrying
                    if !isLoading {
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
    
    private func fetchOrCreateUser(id: String?, email: String, simpleFINConnected: Bool) -> User {
        // Try to find existing user
        let fetchRequest = User.fetchRequest()
        
        if let userId = id, let uuid = UUID(uuidString: userId) {
            fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        } else {
            fetchRequest.predicate = NSPredicate(format: "email == %@", email)
        }
        
        if let existingUser = try? viewContext.fetch(fetchRequest).first {
            existingUser.simpleFinCredentialsSet = simpleFINConnected
            existingUser.updatedAt = Date()
            try? viewContext.save()
            return existingUser
        }
        
        // Create new user if not found
        let newUser = User(context: viewContext)
        newUser.id = id.flatMap { UUID(uuidString: $0) } ?? UUID()
        newUser.email = email
        newUser.simpleFinCredentialsSet = simpleFINConnected
        newUser.createdAt = Date()
        newUser.updatedAt = Date()
        
        try? viewContext.save()
        
        return newUser
    }
}

#Preview {
    let context = PersistenceController.preview.container.viewContext
    
    LoginView(showRegister: .constant(false))
        .environmentObject(AuthManager(viewContext: context))
        .environment(\.managedObjectContext, context)
}
