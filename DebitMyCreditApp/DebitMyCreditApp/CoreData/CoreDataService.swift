import CoreData
import Foundation

final class CoreDataService {

    static let shared = CoreDataService()
    private init() {}

    // Palette of distinct colors for account color assignment
    static let accountColorPalette: [String] = [
        "#FF3B30", // Red
        "#FF9500", // Orange
        "#FFCC00", // Yellow
        "#34C759", // Green
        "#00C7BE", // Teal
        "#007AFF", // Blue
        "#5856D6", // Indigo
        "#AF52DE", // Purple
        "#FF2D55", // Pink
        "#A2845E", // Brown
        "#FF6B6B", // Coral
        "#FF9F43", // Tangerine
        "#FFC300", // Amber
        "#2ECC71", // Emerald
        "#1ABC9C", // Turquoise
        "#3498DB", // Sky Blue
        "#2980B9", // Dodger Blue
        "#9B59B6", // Amethyst
        "#E91E63", // Rose
        "#F06292", // Light Pink
        "#26C6DA", // Cyan
        "#66BB6A", // Light Green
        "#D4E157", // Lime
        "#FFA726", // Deep Orange
        "#8D6E63", // Mocha
        "#78909C", // Blue Grey
        "#EC407A", // Hot Pink
        "#AB47BC", // Medium Purple
        "#7E57C2", // Deep Purple
        "#42A5F5", // Light Blue
        "#26A69A", // Dark Teal
        "#EF5350", // Light Red
        "#BDBDBD", // Grey
        "#FF7043", // Deep Coral
        "#29B6F6", // Ice Blue
    ]

    /// Returns a random hex color string from the account color palette
    static func randomAccountColor() -> String {
        accountColorPalette.randomElement() ?? "#007AFF"
    }

    // Background context for large syncs
    func backgroundContext() -> NSManagedObjectContext {
        PersistenceController.shared.container.newBackgroundContext()
    }
    
    // Delete all core data, use on log out
    func clearAllData(context: NSManagedObjectContext) {
        let entityNames = [
            "User",
            "TransferGroup",
            "Transaction",
            "TransactionAllocation",
            "Account"
        ]
        
        context.performAndWait {
            entityNames.forEach { entityName in
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                batchDelete.resultType = .resultTypeObjectIDs
                
                do {
                    let result = try context.execute(batchDelete) as? NSBatchDeleteResult
                    
                    // Merge the changes to update the context
                    if let objectIDArray = result?.result as? [NSManagedObjectID] {
                        let changes = [NSDeletedObjectsKey: objectIDArray]
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                    }
                } catch {
                    print("Failed to delete \(entityName):", error)
                }
            }
            
            // Reset the context to clear all cached objects
            context.reset()
            
            do {
                try context.save()
                print("✅ All Core Data cleared")
            } catch {
                print("❌ Failed to save context after clearing Core Data:", error)
            }
        }
    }
    
    // Sync all user data from server response into Core Data
    func syncUserData(
        user: APIModels.UserDataResponse.UserInfo?,
        accounts: [APIModels.Account],
        transactions: [APIModels.UserDataResponse.Transaction],
        transferGroups: [APIModels.UserDataResponse.TransferGroup],
        allocations: [APIModels.UserDataResponse.Allocation],
        context: NSManagedObjectContext
    ) async {
        await context.perform {
            // 1. Update User
            if let serverUser = user,
               let userId = UUID(uuidString: serverUser.id) {
                
                let userFetch = User.fetchRequest()
                userFetch.predicate = NSPredicate(format: "id == %@", userId as CVarArg)
                
                if let localUser = try? context.fetch(userFetch).first {
                    localUser.email = serverUser.email
                    localUser.simpleFinCredentialsSet = serverUser.isSimpleFINConnected
                    localUser.lunchFlowCredentialsSet = serverUser.isLunchFlowConnected
                    
                    // Parse dates from FlexibleDate
                    if let createdAt = serverUser.createdAt?.dateValue {
                        localUser.createdAt = createdAt
                    }
                    
                    if let updatedAt = serverUser.updatedAt?.dateValue {
                        localUser.updatedAt = updatedAt
                    }
                }
            }
            
            // 2. Sync Accounts
            // First, get the user to establish the relationship
            var userEntity: User?
            if let serverUser = user,
               let userId = UUID(uuidString: serverUser.id) {
                let userFetch = User.fetchRequest()
                userFetch.predicate = NSPredicate(format: "id == %@", userId as CVarArg)
                userEntity = try? context.fetch(userFetch).first
            }
            
            let serverAccountIDs = Set(accounts.map { $0.id })
            
            for serverAccount in accounts {
                let accountFetch = Account.fetchRequest()
                accountFetch.predicate = NSPredicate(format: "id == %@", serverAccount.id as CVarArg)
                
                let fetchResult = try? context.fetch(accountFetch)
                let isNewAccount = fetchResult?.first == nil
                
                let localAccount = fetchResult?.first ?? Account(context: context)
                localAccount.id = serverAccount.id
                localAccount.externalID = serverAccount.externalID
                localAccount.name = serverAccount.name
                localAccount.bank = serverAccount.bank
                localAccount.accountNumber = serverAccount.accountNumber ?? ""
                localAccount.availableBalance = NSDecimalNumber(value: serverAccount.availableBalance)
                localAccount.balance = NSDecimalNumber(value: serverAccount.balance)
                localAccount.accountType = serverAccount.accountType
                localAccount.accountSource = serverAccount.accountSource
                
                // Set the user relationship
                if isNewAccount {
                    localAccount.accountColor = CoreDataService.randomAccountColor()
                }

                if let userEntity = userEntity {
                    localAccount.user = userEntity
//                    print("   - \(isNewAccount ? "Creating" : "Updating") account: \(serverAccount.name) (user: \(userEntity.email ?? "unknown"))")
                } else {
                    print("   [CoreDataService] WARNING: No user entity found for account: \(serverAccount.name)")
                }
                
                // Parse dates from FlexibleDate
                if let balanceDate = serverAccount.balanceDate?.dateValue {
                    localAccount.balanceDate = balanceDate
                }
                
                if let createdAt = serverAccount.createdAt?.dateValue {
                    localAccount.createdAt = createdAt
                }
                
                if let updatedAt = serverAccount.updatedAt?.dateValue {
                    localAccount.updatedAt = updatedAt
                }
            }
            
            // Delete any local accounts not present in the server response
            let allLocalAccountsFetch = Account.fetchRequest()
            if let allLocalAccounts = try? context.fetch(allLocalAccountsFetch) {
                for localAccount in allLocalAccounts {
                    if let id = localAccount.id, !serverAccountIDs.contains(id) {
                        context.delete(localAccount)
                        print("[CoreDataService] Deleted stale account: \(localAccount.name ?? "unknown") (id: \(id))")
                    }
                }
            }
            
            // 3. Sync Transactions
            for serverTxn in transactions {
                let txnFetch = Transaction.fetchRequest()
                txnFetch.predicate = NSPredicate(format: "id == %@", serverTxn.id as CVarArg)
                
                let localTxn = (try? context.fetch(txnFetch).first) ?? Transaction(context: context)
                localTxn.id = serverTxn.id
                localTxn.externalID = serverTxn.externalID
                
                // Set the user relationship
                if let userEntity = userEntity {
                    localTxn.user = userEntity
                }
                
                // Link to the account by finding it via accountID
                if let accountUUID = UUID(uuidString: serverTxn.accountID) {
                    let accountFetch = Account.fetchRequest()
                    accountFetch.predicate = NSPredicate(format: "id == %@", accountUUID as CVarArg)
                    if let account = try? context.fetch(accountFetch).first {
                        localTxn.account = account
                    }
                }
                
                localTxn.amount = NSDecimalNumber(value: serverTxn.amount)
                localTxn.name = serverTxn.name
                localTxn.notes = serverTxn.notes ?? ""
                localTxn.pending = serverTxn.pending
                
                // Parse dates from FlexibleDate
                if let transactionDate = serverTxn.transactionDate.dateValue {
                    localTxn.transactionDate = transactionDate
                }
                
                if let createdAt = serverTxn.createdAt?.dateValue {
                    localTxn.createdAt = createdAt
                }
                
                if let updatedAt = serverTxn.updatedAt?.dateValue {
                    localTxn.updatedAt = updatedAt
                }
            }
            
            // Mark any local pending transactions not returned by the server as orphaned
            let serverTxnIDs = Set(transactions.map { $0.id })
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            let orphanFetch = Transaction.fetchRequest()
            orphanFetch.predicate = NSPredicate(
                format: "pending == YES AND transactionDate >= %@", thirtyDaysAgo as CVarArg
            )
            if let pendingLocal = try? context.fetch(orphanFetch) {
                for localTxn in pendingLocal {
                    if let id = localTxn.id, !serverTxnIDs.contains(id) {
                        localTxn.isOrphaned = true
                    }
                }
            }

            // 4. Sync Transfer Groups
            for serverGroup in transferGroups {
                // Convert String ID to UUID
                guard let groupUUID = UUID(uuidString: serverGroup.id) else {
                    print("[CoreDataService] WARNING: Skipping transfer group with invalid UUID: \(serverGroup.id)")
                    continue
                }
                
                let groupFetch = TransferGroup.fetchRequest()
                groupFetch.predicate = NSPredicate(format: "id == %@", groupUUID as CVarArg)
                
                let localGroup = (try? context.fetch(groupFetch).first) ?? TransferGroup(context: context)
                localGroup.id = groupUUID
                localGroup.name = serverGroup.name
                localGroup.completed = serverGroup.completed
                
                // Set the user relationship
                if let userEntity = userEntity {
                    localGroup.user = userEntity
                }
                
                // Parse dates from FlexibleDate
                if let createdAt = serverGroup.createdAt?.dateValue {
                    localGroup.createdAt = createdAt
                }
                
                if let updatedAt = serverGroup.updatedAt?.dateValue {
                    localGroup.updatedAt = updatedAt
                }
            }
            
            // 4b. Link transactions to their transfer groups
            for serverTxn in transactions {
                guard let groupIDString = serverTxn.transferGroupID,
                      let groupUUID = UUID(uuidString: groupIDString) else {
                    // No group — clear any stale local link
                    let txnFetch = Transaction.fetchRequest()
                    txnFetch.predicate = NSPredicate(format: "id == %@", serverTxn.id as CVarArg)
                    txnFetch.fetchLimit = 1
                    if let localTxn = try? context.fetch(txnFetch).first {
                        localTxn.transferGroup = nil
                    }
                    continue
                }

                let txnFetch = Transaction.fetchRequest()
                txnFetch.predicate = NSPredicate(format: "id == %@", serverTxn.id as CVarArg)
                txnFetch.fetchLimit = 1
                guard let localTxn = try? context.fetch(txnFetch).first else { continue }

                let groupFetch = TransferGroup.fetchRequest()
                groupFetch.predicate = NSPredicate(format: "id == %@", groupUUID as CVarArg)
                groupFetch.fetchLimit = 1
                if let localGroup = try? context.fetch(groupFetch).first {
                    localTxn.transferGroup = localGroup
                }
            }

            // Delete any local TransferGroups not present in the server response
            let serverGroupIDs = Set(transferGroups.compactMap { UUID(uuidString: $0.id) })
            let allLocalGroupsFetch = TransferGroup.fetchRequest()
            if let allLocalGroups = try? context.fetch(allLocalGroupsFetch) {
                for localGroup in allLocalGroups {
                    if let id = localGroup.id, !serverGroupIDs.contains(id) {
                        context.delete(localGroup)
                        print("[CoreDataService] Deleted stale transfer group: \(localGroup.name ?? "unknown") (id: \(id))")
                    }
                }
            }

            // 5. Sync Allocations — keyed by transaction+account pair
            for serverAlloc in allocations {
                let txnFetch = Transaction.fetchRequest()
                txnFetch.predicate = NSPredicate(format: "id == %@", serverAlloc.transactionID as CVarArg)
                txnFetch.fetchLimit = 1
                guard let localTxn = try? context.fetch(txnFetch).first else { continue }

                let accountFetch = Account.fetchRequest()
                accountFetch.predicate = NSPredicate(format: "id == %@", serverAlloc.accountID as CVarArg)
                accountFetch.fetchLimit = 1
                guard let localAccount = try? context.fetch(accountFetch).first else { continue }

                // Find existing allocation by transaction+account composite key
                let allocFetch = TransactionAllocation.fetchRequest()
                allocFetch.predicate = NSPredicate(format: "transaction == %@ AND account == %@", localTxn, localAccount)
                allocFetch.fetchLimit = 1

                let localAlloc = (try? context.fetch(allocFetch).first) ?? TransactionAllocation(context: context)
                localAlloc.transaction = localTxn
                localAlloc.account = localAccount
                localAlloc.amount = NSDecimalNumber(value: serverAlloc.amount)

                if let createdAt = serverAlloc.createdAt?.dateValue { localAlloc.createdAt = createdAt }
                if let updatedAt = serverAlloc.updatedAt?.dateValue { localAlloc.updatedAt = updatedAt }
            }

            // 6. Save all changes
            do {
                if context.hasChanges {
                    print("[CoreDataService] Saving context with changes...")
                    try context.save()
                    print("[CoreDataService] Successfully saved: \(accounts.count) accounts, \(transactions.count) transactions, \(transferGroups.count) transfer groups, \(allocations.count) allocations to Core Data")
                } else {
                    print("[CoreDataService] No changes to save")
                }
            } catch {
                print("[CoreDataService] Failed to save synced data: \(error)")
                print("   Error details: \(error.localizedDescription)")
                if let detailedError = error as NSError? {
                    print("   Domain: \(detailedError.domain)")
                    print("   Code: \(detailedError.code)")
                    print("   User info: \(detailedError.userInfo)")
                }
            }
        }
    }
}
