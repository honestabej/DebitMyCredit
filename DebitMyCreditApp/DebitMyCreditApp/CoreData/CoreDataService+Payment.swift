
import CoreData

extension Payment {
    // Get the total amount of all transactions within a Payment
    var totalAmount: Decimal {
        guard let txns = transactions as? Set<Transaction> else { return 0 }
        return txns.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) }
    }

    struct CreditCardPayment {
        let account: Account
        let amount: Decimal
    }

    // Unique credit card accounts associated with this payment's transactions, with their total payment amount
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

    // Fetches all Payment entities for a given user.
    func fetchPayments(forUserID userID: UUID, in context: NSManagedObjectContext) -> [Payment] {
        let fetchRequest: NSFetchRequest<Payment> = NSFetchRequest(entityName: "Payment")
        fetchRequest.predicate = NSPredicate(format: "user.id == %@", userID as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("Failed to fetch payments for user \(userID): \(error)")
            return []
        }
    }


}
