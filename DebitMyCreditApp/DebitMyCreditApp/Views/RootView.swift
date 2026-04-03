//
//  DebitMyCreditApp.swift
//  DebitMyCredit
//
//  Created by Abe Johnson on 3/31/26.
//

import SwiftUI
import CoreData

@main
struct Root: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
