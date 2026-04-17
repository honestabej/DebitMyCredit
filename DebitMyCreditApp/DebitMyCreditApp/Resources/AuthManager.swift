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
    @Published var isRefreshing: Bool = false
    @Published var isSyncingSimpleFIN: Bool = false
    @Published var isLoadingUserData: Bool = false
    
    
    private let viewContext: NSManagedObjectContext

    // When AuthManager is initialized in RootView, this routine is called, automatically syncing user data from the server
    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
        
        // Check for existing token and auto-login
        if KeychainHelper.get("auth_token") != nil {
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
                    // await self.refreshData()
                    // For now when developing, I dont want the long call to SimpleFIN every time I open the app
                    await self.fetchAndLoadUserData()
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
        
        // Sync SimpleFIN and load all of the user's data
        Task {
            await self.refreshData()
        }
    }

    // Delete the JWT from Keychain when logging out, and set set login status
    func logout() {
        KeychainHelper.delete("auth_token")
        self.currentUser = nil
        self.isLoggedIn = false
        print("[AuthManager] User logged out")
    }
    
    // Global refresh function for user data, triggers sync from SimpleFIN > AzureDB, then fetches data from AzureDB to client and loads it to CoreData
    func refreshData() async {
        guard !isRefreshing else {
            print("[AuthManager] Already refreshing user data, skipping...")
            return
        }
        
        // Set refreshing status to avoid overlapping refresh attempts
        isRefreshing = true
        
        do {
            // First load AzureDB with fresh data from SimpleFIN
            await syncSimpleFIN()
            
            // Second, fetch new data from the AzureDB and load into CoreData
            await fetchAndLoadUserData()
            
            // Indicate the refreshing is complete
            isRefreshing = false
            
        } catch {
            print("[AuthManager] Failed to trigger sync: \(error.localizedDescription)")
            isRefreshing = false
        }
    }
    
    // Call the endpoint to trigger a sync from SimpleFIN and load the new info into the AzureDB
    @MainActor
    func syncSimpleFIN() async {
        // Check for authorization
        guard let token = KeychainHelper.get("auth_token") else {
            print("[AuthManager] No sign in token available, cannot inititate sync")
            return
        }
        
        // Verify that user has SimpleFIN connected
        guard currentUser?.simpleFinCredentialsSet == true else {
            print("[AuthManager] No SimpleFIN account connected, cannot initiate sync")
            return
        }
        
        // Make sure a request to sync SimpleFIN data isn't already being executed
        guard !isSyncingSimpleFIN else {
            print("[AuthManager] SimpleFIN sync request already in progress, skipping...")
            return
        }
        
        // Set the sync status so future attempts cant be initiated
        isSyncingSimpleFIN = true
        
        
        print("[AuthManager] Triggering SimpleFIN to AzureDB background sync...")
        
        do {
            // Call the /user/sync endpoint to load SimpleFIN data into AzureDB
            let response = try await APIService.shared.syncSimpleFIN(token: token)
            print("[AuthManager] SimpleFIN sync status: \(response.message)")
            
            // Indicate SimpleFIN syncing is complete
            isSyncingSimpleFIN = false
            
        } catch {
            print("[AuthManager] Failed to trigger sync: \(error.localizedDescription)")
            
            // Indicate SimpleFIN syncing is complete
            isSyncingSimpleFIN = false
        }
    }
    
    // Call the endpoint to fetch data from the AzureDB and load it into CoreData
    @MainActor
    func fetchAndLoadUserData() async {
        // Check for authorization
        guard let token = KeychainHelper.get("auth_token") else {
            print("[AuthManager] No sign in token available, cannot fetch and load user data")
            return
        }
        
        // Make sure a fetch and load request isnt already hppening
        guard !isLoadingUserData else {
            print("[AuthManager] Fetching user data request already in progress, skipping...")
            return
        }
        
        // Set the fetch and load status so future attempts cant be initiated
        isLoadingUserData = true
        
        print("[AuthManager] Loading new data from server...")
        
        do {
            // Use APIService to initiate call to the AzureDB
            let response = try await APIService.shared.fetchUserData(token: token)
            
            guard response.success else {
                print("[AuthManager] Server returned success=false")
                
                // Indicate user data fetch is complete
                isLoadingUserData = false
                return
            }
            
            print("[AuthManager] User data obtained from DB: \(response.accounts.count) bank accounts, \(response.transactions.count) transactions")
            
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
            
            // Indicate user data fetch is complete
            isLoadingUserData = false
            
        } catch {
            print("[AuthManager] Sever returned success, but failed to load into CoreData: \(error.localizedDescription)")
            
            // Indicate user data fetch is complete
            isLoadingUserData = false
        }
        
    }
    
    
    
    
    
    
    
    
    
    
    
    
//    // Load all user data from server and sync to Core Data
//    @MainActor
//    func loadUserData() async {
//        guard let token = KeychainHelper.get("auth_token") else {
//            print("[AuthManager] No token available for loading user data")
//            return
//        }
//        
//        guard !isLoadingUserData else {
//            print("[AuthManager] Already loading user data, skipping...")
//            return
//        }
//        
//        isLoadingUserData = true
//        print("[AuthManager] Loading user data from server...")
//        
//        defer {
//            isLoadingUserData = false
//        }
//        
//        do {
//            // Use APIService to initiate call to the AzureDB
//            let response = try await APIService.shared.fetchUserData(token: token)
//            
//            guard response.success else {
//                print("[AuthManager] Server returned success=false")
//                return
//            }
//            
//            print("[AuthManager] User data obtained from DB: \(response.accounts.count) accounts, \(response.transactions.count) transactions")
//            
//            // Update Core Data with the response from the DB
//            await CoreDataService.shared.syncUserData(
//                user: response.user,
//                accounts: response.accounts,
//                transactions: response.transactions,
//                transferGroups: response.transferGroups,
//                context: viewContext
//            )
//            
//            // Refresh current user reference
//            if let userId = response.user?.id,
//               let uuid = UUID(uuidString: userId) {
//                let fetchRequest = User.fetchRequest()
//                fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
//                fetchRequest.fetchLimit = 1
//                
//                if let updatedUser = try? viewContext.fetch(fetchRequest).first {
//                    self.currentUser = updatedUser
//                }
//            }
//            
//        } catch {
//            print("[AuthManager] Sever returned success, but failed to load into CoreData: \(error.localizedDescription)")
//        }
//    }
//    
//    // Trigger a background sync from SimpleFIN > AzureDB > Client
//    func triggerSync() async {
//        guard let token = KeychainHelper.get("auth_token") else {
//            print("[AuthManager] No token available for SimpleFIN to AzureDB sync")
//            return
//        }
//        
//        print("[AuthManager] Triggering SimpleFIN to AzureDB background sync...")
//        
//        do {
//            // Call the /user/sync endpoint to load SimpleFIN data into AzureDB
//            let response = try await APIService.shared.triggerSync(token: token)
//            print("[AuthManager] Sync complete: \(response.message)")
//            
//            // Wait a moment for sync to complete
//            try await Task.sleep(nanoseconds: 4_000_000_000)
//            
//            // Call the /user/update endpoint to fetch the new data from the AzureDB and load into CoreData
//            await loadUserData()
//            
//        } catch {
//            print("[AuthManager] Failed to trigger sync: \(error.localizedDescription)")
//        }
//    }
}
