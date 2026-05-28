
import CoreData

extension TransferGroup {
    // Get the total amount of all transactions within a Payment Group
    var totalAmount: Decimal {
        guard let txns = transactions as? Set<Transaction> else { return 0 }
        return txns.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) }
    }

    struct CreditCardPayment {
        let account: Account
        let amount: Decimal
    }

    // Unique credit card accounts associated with this payment group's transactions, with their total payment amount
    var creditCards: [CreditCardPayment] {
        guard let txns = transactions as? Set<Transaction> else { return [] }
        var totals: [NSManagedObjectID: (Account, Decimal)] = [:]
        for txn in txns {
            guard let account = txn.account else { continue }
            let amount = txn.amount?.decimalValue ?? 0
            if let existing = totals[account.objectID] {
                totals[account.objectID] = (existing.0, existing.1 + amount)
            } else {
                totals[account.objectID] = (account, amount)
            }
        }
        return totals.values.map { CreditCardPayment(account: $0.0, amount: $0.1) }
    }
}

extension CoreDataService {

    // Fetches all TransferGroup entities for a given user.
    /// The "Manual" group always appears first; remaining groups are sorted by createdAt descending (newest first).
    func fetchTransferGroups(forUserID userID: UUID, in context: NSManagedObjectContext) -> [TransferGroup] {
        let fetchRequest: NSFetchRequest<TransferGroup> = NSFetchRequest(entityName: "TransferGroup")
        fetchRequest.predicate = NSPredicate(format: "user.id == %@", userID as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let groups = try context.fetch(fetchRequest)
            return groups.sorted { a, b in
                if a.name == "Manual" { return true }
                if b.name == "Manual" { return false }
                let aDate = a.createdAt ?? .distantPast
                let bDate = b.createdAt ?? .distantPast
                return aDate > bDate
            }
        } catch {
            print("Failed to fetch transfer groups for user \(userID): \(error)")
            return []
        }
    }
    
    
}
