import CoreData

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
            "Account",
            "CreditAccount",
            "OtherAccount"
        ]
        
        entityNames.forEach { entityName in
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            do {
                try context.execute(batchDelete)
            } catch {
                print("Failed to delete \(entityName):", error)
            }
        }

        do {
            try context.save()
            print("All Core Data cleared")
        } catch {
            print("Failed to save context after clearing Core Data:", error)
        }
    }
}
