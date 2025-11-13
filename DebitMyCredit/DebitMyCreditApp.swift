//
//  DebitMyCreditApp.swift
//  DebitMyCredit
//
//  Created by Abe Johnson on 11/13/25.
//

import SwiftUI
import CoreData

@main
struct DebitMyCreditApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
