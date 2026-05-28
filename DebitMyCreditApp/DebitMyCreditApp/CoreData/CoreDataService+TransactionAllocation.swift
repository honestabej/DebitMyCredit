import CoreData
import Foundation

extension CoreDataService {
    // Represents the total unpaid allocated amount for a single debit account.
    struct UnpaidAllocationSummary: Hashable {
        let accountName: String
        let accountColor: String?
        let total: Decimal
    }

    // Fetches all unpaid credit transactions (no transferGroup) and groups their allocations
    func fetchUnpaidCreditSummary(forUserID userID: UUID, in context: NSManagedObjectContext) -> (byAccount: [UnpaidAllocationSummary], unallocated: Decimal) {

        // Fetch all Credit transactions with no transferGroup for this user
        let txnFetch: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        txnFetch.predicate = NSPredicate(
            format: "user.id == %@ AND account.accountType == %@ AND transferGroup == nil AND amount < 0",
            userID as CVarArg,
            "Credit"
        )

        let unpaidTxns: [Transaction]
        do {
            unpaidTxns = try context.fetch(txnFetch)
        } catch {
            print("[CoreDataService] Failed to fetch unpaid credit transactions: \(error)")
            return ([], 0)
        }

        var accountTotals: [String: Decimal] = [:]
        var accountColors: [String: String?] = [:]
        var unallocated: Decimal = 0

        for txn in unpaidTxns {
            let allocations = (txn.allocations?.allObjects as? [TransactionAllocation]) ?? []

            if allocations.isEmpty {
                // No allocations — count the full transaction amount as unallocated
                let amount = (txn.amount ?? .zero).decimalValue
                unallocated += abs(amount)
            } else {
                for alloc in allocations {
                    guard let accountName = alloc.account?.name else { continue }
                    let amount = abs((alloc.amount ?? .zero).decimalValue)
                    accountTotals[accountName, default: 0] += amount
                    if accountColors[accountName] == nil {
                        accountColors[accountName] = alloc.account?.accountColor
                    }
                }
            }
        }

        let byAccount = accountTotals
            .map { UnpaidAllocationSummary(accountName: $0.key, accountColor: accountColors[$0.key] ?? nil, total: $0.value) }
            .sorted { $0.accountName < $1.accountName }

        return (byAccount: byAccount, unallocated: unallocated)
    }
    
    // Represents the allocated debit amount for a single debit account
    struct PaidAllocationSummary {
        let accountName: String
        let accountColor: String?
        let total: Decimal
    }
    
    // Groups all allocations from a payment group's transactions by debit account.
    // Returns a summary per account and the total amount of any unallocated transactions.
    func fetchPaidAllocationSummary(for transferGroup: TransferGroup) -> (byAccount: [PaidAllocationSummary], unallocated: Decimal) {
        guard let txns = transferGroup.transactions as? Set<Transaction> else { return ([], 0) }

        var accountTotals: [String: Decimal] = [:]
        var accountColors: [String: String?] = [:]
        var unallocated: Decimal = 0

        for txn in txns {
            let allocations = (txn.allocations?.allObjects as? [TransactionAllocation]) ?? []

            if allocations.isEmpty {
                unallocated += abs((txn.amount ?? .zero).decimalValue)
            } else {
                for alloc in allocations {
                    guard let accountName = alloc.account?.name else { continue }
                    let amount = abs((alloc.amount ?? .zero).decimalValue)
                    accountTotals[accountName, default: 0] += amount
                    if accountColors[accountName] == nil {
                        accountColors[accountName] = alloc.account?.accountColor
                    }
                }
            }
        }

        let byAccount = accountTotals
            .map { PaidAllocationSummary(accountName: $0.key, accountColor: accountColors[$0.key] ?? nil, total: $0.value) }
            .sorted { $0.accountName < $1.accountName }

        return (byAccount: byAccount, unallocated: unallocated)
    }

    

    // A snapshot of a single allocation, used to revert CoreData if the server call fails.
    struct AllocationSnapshot {
        let accountObjectID: NSManagedObjectID
        let amount: NSDecimalNumber
        let createdAt: Date?
        let updatedAt: Date?
    }

    // Replaces all existing allocations for a transaction with the provided set.
    // Returns the API entries to send to the server, and a revert closure to call if the server save fails.
    func saveAllocations(for transaction: Transaction, allocations: [(account: Account, amount: Double)], context: NSManagedObjectContext) throws -> (entries: [APIModels.AllocationEntry], revert: () throws -> Void) {
        // Snapshot the current allocations before touching anything
        let previousAllocations = transaction.allocations?.allObjects as? [TransactionAllocation] ?? []
        let snapshots: [AllocationSnapshot] = previousAllocations.compactMap { alloc in
            guard let accountID = alloc.account?.objectID else { return nil }
            return AllocationSnapshot(
                accountObjectID: accountID,
                amount: alloc.amount ?? NSDecimalNumber.zero,
                createdAt: alloc.createdAt,
                updatedAt: alloc.updatedAt
            )
        }

        // Delete existing allocations and write the new set
        for alloc in previousAllocations {
            context.delete(alloc)
        }

        var entries: [APIModels.AllocationEntry] = []

        for (account, amount) in allocations {
            guard amount > 0, let accountID = account.id else { continue }

            let alloc = TransactionAllocation(context: context)
            alloc.transaction = transaction
            alloc.account = account
            alloc.amount = NSDecimalNumber(value: -amount)
            alloc.createdAt = Date()
            alloc.updatedAt = Date()

            entries.append(APIModels.AllocationEntry(
                accountID: accountID.uuidString,
                amount: -amount
            ))
        }

        try context.save()

        // Build a revert closure that restores the previous state
        let revert: () throws -> Void = { [weak context] in
            guard let context else { return }
            // Delete the newly written allocations
            let currentAllocations = transaction.allocations?.allObjects as? [TransactionAllocation] ?? []
            for alloc in currentAllocations {
                context.delete(alloc)
            }
            // Restore the snapshotted allocations
            for snapshot in snapshots {
                guard let account = try? context.existingObject(with: snapshot.accountObjectID) as? Account else { continue }
                let alloc = TransactionAllocation(context: context)
                alloc.transaction = transaction
                alloc.account = account
                alloc.amount = snapshot.amount
                alloc.createdAt = snapshot.createdAt
                alloc.updatedAt = snapshot.updatedAt
            }
            try context.save()
            print("[CoreDataService] Allocations reverted to previous state")
        }

        return (entries: entries, revert: revert)
    }
}
