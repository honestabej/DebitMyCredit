// AuthManager.swift
// Manages login state + keychain token

import Foundation
import Combine

struct LoggedInUser {
    let id: UUID
    let email: String
    let simpleFinCredentialsSet: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let lastDatabaseSync: Date?
    let lastSimpleFinSync: Date?
}

class AuthManager: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var currentUser: User? = nil

    init() {
        // Check Keychain on launch — auto-login if token exists
        if KeychainHelper.get("auth_token") != nil {
            self.isLoggedIn = true
        }
    }

    func login(token: String, user: User) {
        KeychainHelper.save(token, key: "auth_token")
        self.currentUser = user
        self.isLoggedIn = true
    }

    func logout() {
        KeychainHelper.delete("auth_token")
        self.currentUser = nil
        self.isLoggedIn = false
    }
}
