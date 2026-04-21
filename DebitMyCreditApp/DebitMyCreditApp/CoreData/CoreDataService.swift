import CoreData
import Foundation

final class CoreDataService {

    static let shared = CoreDataService()
    private init() {}

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
            
            for serverAccount in accounts {
                let accountFetch = Account.fetchRequest()
                accountFetch.predicate = NSPredicate(format: "id == %@", serverAccount.id)
                
                let fetchResult = try? context.fetch(accountFetch)
                let isNewAccount = fetchResult?.first == nil
                
                let localAccount = fetchResult?.first ?? Account(context: context)
                localAccount.id = serverAccount.id
                localAccount.name = serverAccount.name
                localAccount.bank = serverAccount.bank
                localAccount.accountNumber = serverAccount.accountNumber ?? ""
                localAccount.accountBalance = NSDecimalNumber(value: serverAccount.accountBalance)
                localAccount.accountType = serverAccount.accountType
                
                // Set the user relationship
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
            
            // 3. Sync Transactions
            for serverTxn in transactions {
                let txnFetch = Transaction.fetchRequest()
                txnFetch.predicate = NSPredicate(format: "id == %@", serverTxn.id)
                
                let localTxn = (try? context.fetch(txnFetch).first) ?? Transaction(context: context)
                localTxn.id = serverTxn.id
                
                // Set the user relationship
                if let userEntity = userEntity {
                    localTxn.user = userEntity
                }
                
                // Link to the account by finding it via accountID
                if !serverTxn.accountID.isEmpty {
                    let accountFetch = Account.fetchRequest()
                    accountFetch.predicate = NSPredicate(format: "id == %@", serverTxn.accountID)
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
            
            // 5. Save all changes
            do {
                if context.hasChanges {
                    print("[CoreDataService] Saving context with changes...")
                    try context.save()
                    print("[CoreDataService] Successfully saved: \(accounts.count) accounts, \(transactions.count) transactions, \(transferGroups.count) transfer groups, to Core Data")
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
