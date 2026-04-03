import SwiftUI
import CoreData

@main
struct DebitMyCreditApp: App {
    
    // Setup everything here at the app level
    @StateObject var authManager = AuthManager()
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
