//
//  Persistence.swift
//  DebitMyCredit
//

import CoreData

struct PersistenceController {

    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Add mock User for previews (safe to delete)
        let user = User(context: context)
        user.id = UUID()
        user.email = "preview@test.com"
        user.fetchFrequency = 0
        user.createdAt = Date()
        user.updatedAt = Date()

        do {
            try context.save()
        } catch {
            print("Preview save failed:", error)
        }

        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "DebitMyCredit")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                print("Core Data failed to load:", error, error.userInfo)
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
