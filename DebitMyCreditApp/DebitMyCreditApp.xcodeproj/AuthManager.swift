import SwiftUI
import Security

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var jwt: String?

    // TODO: Update this to match your bundle identifier if desired
    private let keychainService = "com.example.yourapp"
    private let tokenAccount = "auth.jwt"

    init() {
        if let token = try? loadToken() {
            self.jwt = token
            self.isAuthenticated = validate(token: token)
        }
    }

    func login(username: String, password: String) async throws {
        let receivedJWT = try await fakeLoginRequest(username: username, password: password)
        guard validate(token: receivedJWT) else { throw AuthError.invalidToken }
        try saveToken(receivedJWT)
        self.jwt = receivedJWT
        self.isAuthenticated = true
    }

    func logout() {
        try? deleteToken()
        self.jwt = nil
        self.isAuthenticated = false
    }

    // MARK: - Validation
    private func validate(token: String) -> Bool {
        // Replace with real JWT decode/expiry check
        return !token.isEmpty
    }

    // MARK: - Networking placeholder
    private func fakeLoginRequest(username: String, password: String) async throws -> String {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard !username.isEmpty, !password.isEmpty else { throw AuthError.invalidCredentials }
        return "mock.jwt.token.value"
    }

    // MARK: - Keychain helpers
    private func saveToken(_ token: String) throws {
        try? deleteToken()
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychainError(status) }
    }

    private func loadToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw AuthError.keychainError(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AuthError.tokenDecodingFailed
        }
        return token
    }

    private func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainError(status)
        }
    }

    enum AuthError: Error {
        case invalidCredentials
        case invalidToken
        case tokenDecodingFailed
        case keychainError(OSStatus)
    }
}
