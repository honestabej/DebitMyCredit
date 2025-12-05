//
//  Login.swift
//  DebitMyCredit
//
//  Created by Abe Johnson on 12/5/25.
//

import SwiftUI

struct LoginView: View {
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSecureEntry: Bool = true
    @State private var isLoading: Bool = false
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
                    Button(action: login) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isLoading ? "Signing In..." : "Sign In")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.20), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                    .opacity((isLoading || email.isEmpty || password.isEmpty) ? 0.75 : 1)

                    // Forgot password / sign up
                    HStack {
                        Button("Forgot Password?") {}
                            .foregroundStyle(.white.opacity(0.9))
                            .font(.footnote)
                        Spacer()
                        Button("Create Account") {}
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
            .alert("Sign In Error", isPresented: $showErrorAlert, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }

            if isLoading {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                ProgressView("Logging in...")
                    .padding(16)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
    }

    private func login() {
        let start = Date()
        errorMessage = nil
        guard !email.isEmpty, !password.isEmpty else { return }
        isLoading = true

        APIService.login(email: email, password: password) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let json):
                    // Check if login was successful from server response
                    if let success = json["success"] as? Bool, success {
                        // TODO: Navigate to main app view or save auth token
                        print("Login successful: \(json)")
                    } else {
                        errorMessage = json["message"] as? String ?? "Login failed"
                        print("[Login] Server indicated failure. message=", errorMessage ?? "<none>")
                        showErrorAlert = true
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    print("[Login] Network error=", error.localizedDescription)
                    showErrorAlert = true
                }
            }
        }
    }
}

#Preview {
    LoginView()
}
