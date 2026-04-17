import SwiftUI
import CoreData

@main
struct DebitMyCreditApp: App {
    
    // Setup everything here at the app level
    let persistenceController = PersistenceController.shared
    @StateObject private var authManager: AuthManager
    
    init() {
        // Initialize AuthManager with the Core Data context
        let context = PersistenceController.shared.container.viewContext
        _authManager = StateObject(wrappedValue: AuthManager(viewContext: context))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
