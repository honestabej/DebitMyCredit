import CoreData

extension CoreDataService {
    
    // Saves or updates accounts from SimpleFIN API response
    func saveBankConnectionAccounts(_ accountsData: [[String: Any]], forUserID userID: UUID, in context: NSManagedObjectContext) throws {
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
            // Get the name, bank, accountSource, & accountNumber from the account
            guard let internalID = accountData["id"] as? UUID,
                  let externalID = accountData["externalID"] as? String,
                  let name = accountData["name"] as? String,
                  let bank = accountData["bank"] as? String
            else {
                print("[CoreDataService+Account] Skipping account with missing id, name, or bank")
                continue
            }
            let accountSource = accountData["accountSource"] as? String
            let accountNumber = accountData["accountNumber"] as? String
            
            // Fetch or create Account entity
            let fetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
            fetchRequest.predicate = NSPredicate(format: "id == %@", internalID as CVarArg)
            fetchRequest.fetchLimit = 1
            
            let accountEntity: Account
            
            // Determine if Account exists or needs to be created
            if let existingAccount = try context.fetch(fetchRequest).first {
                accountEntity = existingAccount
                print("[CoreDataService+Account] Updating existing account: \(name)")
            } else {
                // Set basic attributes of a new account
                accountEntity = Account(context: context)
                accountEntity.id = internalID
                accountEntity.externalID = externalID
                accountEntity.createdAt = Date()
                accountEntity.accountColor = CoreDataService.randomAccountColor()
                print("[CoreDataService+Account] Creating new account: \(name)")
            }
            
            // Update account properties
            accountEntity.name = name
            accountEntity.bank = bank
            accountEntity.accountNumber = accountNumber
            accountEntity.accountSource = accountSource
            
            // Parse account availableBalance (available-balance or availableBalance from response)
            if let balanceValue = accountData["availableBalance"] as? Double {
                accountEntity.availableBalance = NSDecimalNumber(value: balanceValue)
            } else if let balanceValue = accountData["availableBalance"] as? NSNumber {
                accountEntity.availableBalance = NSDecimalNumber(decimal: balanceValue.decimalValue)
            }
            
            // Parse account balance
            if let balanceValue = accountData["balance"] as? Double {
                accountEntity.balance = NSDecimalNumber(value: balanceValue)
            } else if let balanceValue = accountData["balance"] as? NSNumber {
                accountEntity.balance = NSDecimalNumber(decimal: balanceValue.decimalValue)
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
            print("[CoreDataService+Account] Saved \(accountsData.count) accounts to Core Data")
        }
    }
    
    // Deletes all accounts with the given accountSource value, along with their cascading transactions
    func deleteAccounts(withSource source: String, in context: NSManagedObjectContext) throws {
        let fetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        fetchRequest.predicate = NSPredicate(format: "accountSource == %@", source)
        
        let accounts = try context.fetch(fetchRequest)
        for account in accounts {
            context.delete(account)
        }
        
        if context.hasChanges {
            try context.save()
            print("[CoreDataService+Account] Deleted \(accounts.count) accounts with source '\(source)'")
        }
    }
    
    // Return the counts of each accountSource
    func getAccountSourceCounts(context: NSManagedObjectContext) throws -> [String: Int] {
        let simpleFINFetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        simpleFINFetchRequest.predicate = NSPredicate(format: "accountSource == %@", "SimpleFIN")
        
        let lunchFlowFetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        lunchFlowFetchRequest.predicate = NSPredicate(format: "accountSource == %@", "Lunch Flow")
        
        let manualFetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        manualFetchRequest.predicate = NSPredicate(format: "accountSource == %@", "Manual")
        
        // Get the count of each type of account
        let simpleFINAccountsCount = try context.fetch(simpleFINFetchRequest).count
        let lunchFlowAccountsCount = try context.fetch(lunchFlowFetchRequest).count
        let manualAccountsCount = try context.fetch(manualFetchRequest).count
        
        return [
            "simpleFINAccountsCount": simpleFINAccountsCount,
            "lunchFlowAccountsCount": lunchFlowAccountsCount,
            "manualAccountsCount": manualAccountsCount
        ]
    }
    
    func getAccountsOfAccountSource(context: NSManagedObjectContext, accountSource: String) throws -> [Account] {
        let request: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        request.predicate = NSPredicate(format: "accountSource == %@", accountSource)
        
        return try context.fetch(request)
    }
    
    // Saves a single account from SimpleFIN API response
    @discardableResult
    func saveBankConnectionAccount(
        _ accountData: [String: Any],
        forUserID userID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Account? {
        try saveBankConnectionAccounts([accountData], forUserID: userID, in: context)
        
        // Return the account we just saved
        guard let accountID = accountData["id"] as? UUID else { return nil }

        let fetchRequest: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
        fetchRequest.predicate = NSPredicate(format: "id == %@", accountID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        return try context.fetch(fetchRequest).first
    }
}
