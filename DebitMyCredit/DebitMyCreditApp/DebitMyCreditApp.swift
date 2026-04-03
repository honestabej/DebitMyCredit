//
//  DebitMyCreditApp.swift
//  DebitMyCredit
//
//  Created by Abe Johnson on 3/31/26.
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
