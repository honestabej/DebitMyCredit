//
//  CoreDataService+Transaction.swift
//  DebitMyCredit
//
//  Created by Abe Johnson on 12/9/25.
//

import CoreData

extension CoreDataService {

    // MARK: - Fetch

    /// Fetches all transactions for a given user, sorted by transaction date descending.
    func fetchTransactions(forUserID userID: UUID, in context: NSManagedObjectContext) -> [Transaction] {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "user.id == %@", userID as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "transactionDate", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Failed to fetch transactions for user \(userID): \(error)")
            return []
        }
    }

    /// Fetches all transactions for a specific account, sorted by transaction date descending.
    func fetchTransactions(forAccountID accountID: String, in context: NSManagedObjectContext) -> [Transaction] {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "account.id == %@", accountID)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "transactionDate", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Failed to fetch transactions for account \(accountID): \(error)")
            return []
        }
    }

    /// Fetches a single transaction by its ID.
    func fetchTransaction(byID transactionID: String, in context: NSManagedObjectContext) -> Transaction? {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "id == %@", transactionID)
        fetchRequest.fetchLimit = 1

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Failed to fetch transaction \(transactionID): \(error)")
            return nil
        }
    }

    /// Fetches transactions within a date range for a given user.
    func fetchTransactions(
        forUserID userID: UUID,
        from startDate: Date,
        to endDate: Date,
        in context: NSManagedObjectContext
    ) -> [Transaction] {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(
            format: "user.id == %@ AND transactionDate >= %@ AND transactionDate <= %@",
            userID as CVarArg,
            startDate as CVarArg,
            endDate as CVarArg
        )
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "transactionDate", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Failed to fetch transactions in date range: \(error)")
            return []
        }
    }

    // MARK: - Save / Update

    /// Saves or updates a batch of transactions from the server API response.
    func saveTransactions(
        _ transactions: [APIModels.UserDataResponse.Transaction],
        forUserID userID: UUID,
        in context: NSManagedObjectContext
    ) throws {
        guard let user = fetchUser(byID: userID, in: context) else {
            throw NSError(
                domain: "CoreDataService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "User not found"]
            )
        }

        for serverTxn in transactions {
            let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
            fetchRequest.predicate = NSPredicate(format: "id == %@", serverTxn.id)
            fetchRequest.fetchLimit = 1

            let txn: Transaction
            if let existing = try context.fetch(fetchRequest).first {
                txn = existing
            } else {
                txn = Transaction(context: context)
                txn.id = serverTxn.id
                txn.createdAt = Date()
            }

            txn.user = user
            txn.amount = NSDecimalNumber(value: serverTxn.amount)
            txn.name = serverTxn.name
            txn.pending = serverTxn.pending
            txn.updatedAt = Date()

            if let transactionDate = serverTxn.transactionDate.dateValue {
                txn.transactionDate = transactionDate
            }

            // Link to account
            if !serverTxn.accountID.isEmpty {
                let accountFetch: NSFetchRequest<Account> = NSFetchRequest(entityName: "Account")
                accountFetch.predicate = NSPredicate(format: "id == %@", serverTxn.accountID)
                accountFetch.fetchLimit = 1
                if let account = try context.fetch(accountFetch).first {
                    txn.account = account
                }
            }
        }

        if context.hasChanges {
            try context.save()
            print("✅ Saved \(transactions.count) transactions to Core Data")
        }
    }

    /// Updates the pending status and/or name of a transaction.
    @discardableResult
    func updateTransaction(
        id: String,
        name: String? = nil,
        pending: Bool? = nil,
        in context: NSManagedObjectContext
    ) throws -> Transaction? {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        fetchRequest.fetchLimit = 1

        guard let txn = try context.fetch(fetchRequest).first else {
            print("⚠️ Transaction \(id) not found")
            return nil
        }

        if let name = name { txn.name = name }
        if let pending = pending { txn.pending = pending }
        txn.updatedAt = Date()

        if context.hasChanges {
            try context.save()
            print("✅ Updated transaction \(id)")
        }

        return txn
    }

    // MARK: - Delete

    /// Deletes a single transaction by ID.
    func deleteTransaction(id: String, in context: NSManagedObjectContext) throws {
        let fetchRequest: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        fetchRequest.fetchLimit = 1

        guard let txn = try context.fetch(fetchRequest).first else {
            print("⚠️ Transaction \(id) not found — nothing to delete")
            return
        }

        context.delete(txn)

        if context.hasChanges {
            try context.save()
            print("✅ Deleted transaction \(id)")
        }
    }

    /// Deletes all transactions for a given account.
    func deleteTransactions(forAccountID accountID: String, in context: NSManagedObjectContext) throws {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "Transaction")
        fetchRequest.predicate = NSPredicate(format: "account.id == %@", accountID)

        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDelete.resultType = .resultTypeObjectIDs

        let result = try context.execute(batchDelete) as? NSBatchDeleteResult
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                into: [context]
            )
        }

        print("✅ Deleted transactions for account \(accountID)")
    }
}
