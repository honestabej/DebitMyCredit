import CoreData

extension CoreDataService {
    
    // Updates a user's SimpleFin credentials status in Core Data
    @discardableResult
    func updateUserSimpleFinStatus(userID: UUID, simpleFinCredentialsSet: Bool, in context: NSManagedObjectContext) throws -> User? {
        // Create fetch request
        let fetchRequest: NSFetchRequest<User> = NSFetchRequest(entityName: "User")
        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        // Fetch the user
        let results = try context.fetch(fetchRequest)
        guard let user = results.first else {
            print("[CoreDataService+User] User with ID \(userID) not found")
            return nil
        }
        
        // Update the property
        user.simpleFinCredentialsSet = simpleFinCredentialsSet
        user.updatedAt = Date()
        
        // Save if there are changes
        if context.hasChanges {
            try context.save()
            print("[CoreDataService+User] Updated SimpleFin status for user \(userID)")
        }
        
        return user
    }
    
    // Updates a user's Lunch Flow credentials status in Core Data
    @discardableResult
    func updateUserLunchFlowStatus(userID: UUID, lunchFlowCredentialsSet: Bool, in context: NSManagedObjectContext) throws -> User? {
        // Create fetch request
        let fetchRequest: NSFetchRequest<User> = NSFetchRequest(entityName: "User")
        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        // Fetch the user
        let results = try context.fetch(fetchRequest)
        guard let user = results.first else {
            print("[CoreDataService+User] User with ID \(userID) not found")
            return nil
        }
        
        // Update the property
        user.lunchFlowCredentialsSet = lunchFlowCredentialsSet
        user.updatedAt = Date()
        
        // Save if there are changes
        if context.hasChanges {
            try context.save()
            print("[CoreDataService+User] Updated Lunch Flow status for user \(userID)")
        }
        
        return user
    }
    
    // Fetches a user by their UUID
    func fetchUser(byID userID: UUID, in context: NSManagedObjectContext) -> User? {
        let fetchRequest: NSFetchRequest<User> = NSFetchRequest(entityName: "User")
        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        do {
            let results = try context.fetch(fetchRequest)
            return results.first
        } catch {
            print("[CoreDataService+User] Failed to fetch user \(userID): \(error)")
            return nil
        }
    }
}
