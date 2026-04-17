import CoreData

extension CoreDataService {
    
    /// Updates a user's SimpleFin credentials status in Core Data
    /// - Parameters:
    ///   - userID: The UUID of the user to update
    ///   - simpleFinCredentialsSet: Whether SimpleFin credentials are set
    ///   - context: The managed object context to use
    /// - Throws: Core Data errors if the fetch or save fails
    /// - Returns: The updated User object, or nil if not found
    @discardableResult
    func updateUserSimpleFinStatus(
        userID: UUID,
        simpleFinCredentialsSet: Bool,
        in context: NSManagedObjectContext
    ) throws -> User? {
        // Create fetch request
        let fetchRequest: NSFetchRequest<User> = NSFetchRequest(entityName: "User")
        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        // Fetch the user
        let results = try context.fetch(fetchRequest)
        guard let user = results.first else {
            print("⚠️ User with ID \(userID) not found")
            return nil
        }
        
        // Update the property
        user.simpleFinCredentialsSet = simpleFinCredentialsSet
        user.updatedAt = Date()
        
        // Save if there are changes
        if context.hasChanges {
            try context.save()
            print("✅ Updated SimpleFin status for user \(userID)")
        }
        
        return user
    }
    
    /// Fetches a user by their UUID
    /// - Parameters:
    ///   - userID: The UUID of the user to fetch
    ///   - context: The managed object context to use
    /// - Returns: The User object if found, nil otherwise
    func fetchUser(byID userID: UUID, in context: NSManagedObjectContext) -> User? {
        let fetchRequest: NSFetchRequest<User> = NSFetchRequest(entityName: "User")
        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        fetchRequest.fetchLimit = 1
        
        do {
            let results = try context.fetch(fetchRequest)
            return results.first
        } catch {
            print("❌ Failed to fetch user \(userID): \(error)")
            return nil
        }
    }
}
