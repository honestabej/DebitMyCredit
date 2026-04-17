import CoreData

extension CoreDataService {
    
    /// Saves or updates accounts from SimpleFIN API response
    func saveSimpleFinAccounts(_ accountsData: [[String: Any]], forUserID userID: UUID, in context: NSManagedObjectContext) throws {
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSxxxxx"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Fetch the user
        guard let user = fetchUser(byID: userID, in: context) else {
            throw NSError(
                domain: "CoreDataService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "User not found"]
            )
        }
        
        for accountData in accountsData {
            guard let accountID = accountData["id"] as? String,
                  let name = accountData["name"] as? String,
                  let bank = accountData["bank"] as? String,
                  let accountNumber = accountData["accountNumber"] as? String else {
                print("Skipping account with missing id, name, or bank")
                continue
            }
            
            // Fetch or create Account entity
            let fetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
            fetchRequest.predicate = NSPredicate(format: "id == %@", accountID)
            fetchRequest.fetchLimit = 1
            
            let accountEntity: Account
            if let existingAccount = try context.fetch(fetchRequest).first {
                accountEntity = existingAccount
                print("Updating existing account: \(name)")
            } else {
                accountEntity = Account(context: context)
                accountEntity.id = accountID
                accountEntity.createdAt = Date()
                print("Creating new account: \(name)")
            }
            
            // Update account properties
            accountEntity.name = name
            accountEntity.bank = bank
            accountEntity.accountNumber = accountNumber
            
            // Parse account balance (available-balance or accountBalance from response)
            if let balanceValue = accountData["accountBalance"] as? Double {
                accountEntity.accountBalance = NSDecimalNumber(value: balanceValue)
            } else if let balanceValue = accountData["accountBalance"] as? NSNumber {
                accountEntity.accountBalance = NSDecimalNumber(decimal: balanceValue.decimalValue)
            }
            
            // Parse account type
            if let accountType = accountData["accountType"] as? String {
                accountEntity.accountType = accountType
            }
            
            // Parse balance date
            if let balanceDateString = accountData["balanceDate"] as? String {
                accountEntity.balanceDate = isoFormatter.date(from: balanceDateString)
            }
            
            // Set updated timestamp and user relationship
            accountEntity.updatedAt = Date()
            accountEntity.user = user
        }
        
        // Save the context
        if context.hasChanges {
            try context.save()
            print("✅ Saved \(accountsData.count) accounts to Core Data")
        }
    }
    
    /// Saves a single account from SimpleFIN API response
    @discardableResult
    func saveSimpleFinAccount(
        _ accountData: [String: Any],
        forUserID userID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Account? {
        try saveSimpleFinAccounts([accountData], forUserID: userID, in: context)
        
        // Return the account we just saved
        guard let accountID = accountData["id"] as? String else { return nil }
        
        let fetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        fetchRequest.predicate = NSPredicate(format: "id == %@", accountID)
        fetchRequest.fetchLimit = 1
        
        return try context.fetch(fetchRequest).first
    }
}
