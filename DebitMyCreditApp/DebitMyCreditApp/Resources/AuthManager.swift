// AuthManager.swift
// Manages login state + keychain token

import Foundation
import Combine
import CoreData

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
    @Published var isLoadingUserData: Bool = false
    
    private let viewContext: NSManagedObjectContext

    // Initialized in RootView, initializes tew Auth on app launch
    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
        
        // Check for existing token and auto-login
        if let token = KeychainHelper.get("auth_token") {
            // Load the user from CoreData
            let fetchRequest = User.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \User.updatedAt, ascending: false)]
            fetchRequest.fetchLimit = 1
            
            if let user = try? viewContext.fetch(fetchRequest).first {
                self.currentUser = user
                self.isLoggedIn = true
                print("[AuthManager] Token found for user: \(user.email ?? "unknown")")
                
                // Load fresh data from server in the background
                Task {
                    await self.loadUserData()
                }
            } else {
                // Token exists but no user in Core Data - clear the token
                print("[AuthManager] Token found but no user in Core Data. Clearing token.")
                KeychainHelper.delete("auth_token")
            }
        } else {
            print("[AuthManager] No token found, user needs to login")
        }
    }

    // Save the JWT token to Keychain when logging in, and set login status
    func login(token: String, user: User) {
        KeychainHelper.save(token, key: "auth_token")
        self.currentUser = user
        self.isLoggedIn = true
        print("[AuthManager] User logged in: \(user.email ?? "unknown")")
        
        // Call to Azure DB to load all of the user's data
        Task {
            await self.loadUserData()
        }
    }

    // Delete the JWT from Keychain when logging out, and set set login status
    func logout() {
        KeychainHelper.delete("auth_token")
        self.currentUser = nil
        self.isLoggedIn = false
        print("[AuthManager] User logged out")
    }
    
    // Load all user data from server and sync to Core Data
    @MainActor
    func loadUserData() async {
        guard let token = KeychainHelper.get("auth_token") else {
            print("[AuthManager] No token available for loading user data")
            return
        }
        
        guard !isLoadingUserData else {
            print("[AuthManager] Already loading user data, skipping...")
            return
        }
        
        isLoadingUserData = true
        print("[AuthManager] Loading user data from server...")
        
        defer {
            isLoadingUserData = false
        }
        
        do {
            // Use APIService to initiate call to the AzureDB
            let response = try await APIService.shared.fetchUserData(token: token)
            
            guard response.success else {
                print("[AuthManager] Server returned success=false")
                return
            }
            
            print("[AuthManager] User data obtained from DB: \(response.accounts.count) accounts, \(response.transactions.count) transactions")
            
            // Update Core Data with the response from the DB
            await CoreDataService.shared.syncUserData(
                user: response.user,
                accounts: response.accounts,
                transactions: response.transactions,
                transferGroups: response.transferGroups,
                context: viewContext
            )
            
            // Refresh current user reference
            if let userId = response.user?.id,
               let uuid = UUID(uuidString: userId) {
                let fetchRequest = User.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                fetchRequest.fetchLimit = 1
                
                if let updatedUser = try? viewContext.fetch(fetchRequest).first {
                    self.currentUser = updatedUser
                }
            }
            
        } catch {
            print("[AuthManager] Sever returned success, but failed to load into CoreData: \(error.localizedDescription)")
        }
    }
    
    // Trigger a background sync from SimpleFIN to the AzureDB
    func triggerSync() async {
        guard let token = KeychainHelper.get("auth_token") else {
            print("[AuthManager] No token available for SimpleFIN to AzureDB sync")
            return
        }
        
        print("[AuthManager] Triggering SimpleFIN to AzureDB background sync...")
        
        do {
            let response = try await APIService.shared.triggerSync(token: token)
            print("[AuthManager] Sync triggered: \(response.message)")
            
            // Wait a moment for sync to complete, then refresh data
            try await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
            await loadUserData()
            
        } catch {
            print("[AuthManager] Failed to trigger sync: \(error.localizedDescription)")
        }
    }
}
