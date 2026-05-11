//
//  Persistence.swift
//  DebitMyCredit
//

import CoreData

struct PersistenceController {

    static let shared = PersistenceController()

    // MARK: - Preview (with data)

    /// Shared in-memory store pre-populated with realistic mock data for SwiftUI previews.
    /// User has both SimpleFIN and Lunch Flow credentials set.
    /// Use `PersistenceController.preview.container.viewContext` in all #Preview blocks.
    /// Use `PersistenceController.previewAccount` to get the primary debit account for views that need one.
    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // User — both services connected
        let user = User(context: context)
        user.id = UUID()
        user.email = "preview@test.com"
        user.lunchFlowCredentialsSet = true
        user.simpleFinCredentialsSet = true
        user.createdAt = Date()
        user.updatedAt = Date()

        // Transfer groups
        let tg1 = TransferGroup(context: context)
        tg1.id = UUID()
        tg1.name = "1"
        tg1.createdAt = Date()

        let tg2 = TransferGroup(context: context)
        tg2.id = UUID()
        tg2.name = "2"
        tg2.createdAt = Date()

        // Accounts
        let checking = Account(context: context)
        checking.id = UUID()
        checking.externalID = "act1"
        checking.name = "Abe's Checking"
        checking.bank = "Wells Fargo"
        checking.accountType = "Cash"
        checking.accountNumber = "1234"
        checking.accountSource = "SimpleFIN"
        checking.availableBalance = NSDecimalNumber(value: 1234.56)
        checking.balance = NSDecimalNumber(value: 1234.56)
        checking.balanceDate = Date()
        checking.accountColor = CoreDataService.randomAccountColor()

        let checking2 = Account(context: context)
        checking2.id = UUID()
        checking2.externalID = "act2"
        checking2.name = "Shae's Checking"
        checking2.bank = "Wells Fargo"
        checking2.accountType = "Cash"
        checking2.accountNumber = "2345"
        checking2.accountSource = "SimpleFIN"
        checking2.availableBalance = NSDecimalNumber(value: 7554.89)
        checking2.balance = NSDecimalNumber(value: 7554.89)
        checking2.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        checking2.accountColor = CoreDataService.randomAccountColor()

        let chase = Account(context: context)
        chase.id = UUID()
        chase.externalID = "act3"
        chase.name = "Chase Sapphire Preferred"
        chase.bank = "Chase"
        chase.accountType = "Credit"
        chase.accountNumber = "2345"
        chase.accountSource = "SimpleFIN"
        chase.balance = NSDecimalNumber(value: -240.00)
        chase.availableBalance = NSDecimalNumber(value: -240.00)
        chase.balanceDate = Date()
        chase.accountColor = CoreDataService.randomAccountColor()

        let apple = Account(context: context)
        apple.id = UUID()
        apple.externalID = "act4"
        apple.name = "Apple Card"
        apple.bank = "Apple"
        apple.accountType = "Credit"
        apple.accountNumber = "3456"
        apple.accountSource = "SimpleFIN"
        apple.balance = NSDecimalNumber(value: -567.89)
        apple.availableBalance = NSDecimalNumber(value: -567.89)
        apple.balanceDate = Date()
        apple.accountColor = CoreDataService.randomAccountColor()

        let hysa = Account(context: context)
        hysa.id = UUID()
        hysa.externalID = "act5"
        hysa.name = "Apple HYSA"
        hysa.bank = "Apple"
        hysa.accountType = "Cash"
        hysa.accountNumber = "4567"
        hysa.accountSource = "Manual"
        hysa.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa.balance = NSDecimalNumber(value: 22089.78)
        hysa.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa.accountColor = CoreDataService.randomAccountColor()
        
        let hysa1 = Account(context: context)
        hysa1.id = UUID()
        hysa1.externalID = "act5"
        hysa1.name = "Apple HYSA"
        hysa1.bank = "Apple"
        hysa1.accountType = "Cash"
        hysa1.accountNumber = "4567"
        hysa1.accountSource = "Manual"
        hysa1.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa1.balance = NSDecimalNumber(value: 22089.78)
        hysa1.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa1.accountColor = CoreDataService.randomAccountColor()
        let hysa2 = Account(context: context)
        hysa2.id = UUID()
        hysa2.externalID = "act5"
        hysa2.name = "Apple HYSA"
        hysa2.bank = "Apple"
        hysa2.accountType = "Cash"
        hysa2.accountNumber = "4567"
        hysa2.accountSource = "Manual"
        hysa2.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa2.balance = NSDecimalNumber(value: 22089.78)
        hysa2.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa2.accountColor = CoreDataService.randomAccountColor()
        let hysa3 = Account(context: context)
        hysa3.id = UUID()
        hysa3.externalID = "act5"
        hysa3.name = "Apple HYSA"
        hysa3.bank = "Apple"
        hysa3.accountType = "Cash"
        hysa3.accountNumber = "4567"
        hysa3.accountSource = "Manual"
        hysa3.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa3.balance = NSDecimalNumber(value: 22089.78)
        hysa3.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa3.accountColor = CoreDataService.randomAccountColor()
        let hysa4 = Account(context: context)
        hysa4.id = UUID()
        hysa4.externalID = "act5"
        hysa4.name = "Apple HYSA"
        hysa4.bank = "Apple"
        hysa4.accountType = "Cash"
        hysa4.accountNumber = "4567"
        hysa4.accountSource = "Manual"
        hysa4.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa4.balance = NSDecimalNumber(value: 22089.78)
        hysa4.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa4.accountColor = CoreDataService.randomAccountColor()
        let hysa5 = Account(context: context)
        hysa5.id = UUID()
        hysa5.externalID = "act5"
        hysa5.name = "Apple HYSA"
        hysa5.bank = "Apple"
        hysa5.accountType = "Cash"
        hysa5.accountNumber = "4567"
        hysa5.accountSource = "Manual"
        hysa5.availableBalance = NSDecimalNumber(value: 22089.78)
        hysa5.balance = NSDecimalNumber(value: 22089.78)
        hysa5.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        hysa5.accountColor = CoreDataService.randomAccountColor()
//        let hysa6 = Account(context: context)
//        hysa6.id = UUID()
//        hysa6.externalID = "act5"
//        hysa6.name = "Apple HYSA"
//        hysa6.bank = "Apple"
//        hysa6.accountType = "Cash"
//        hysa6.accountNumber = "4567"
//        hysa6.accountSource = "Manual"
//        hysa6.availableBalance = NSDecimalNumber(value: 22089.78)
//        hysa6.balance = NSDecimalNumber(value: 22089.78)
//        hysa6.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
//        hysa6.accountColor = CoreDataService.randomAccountColor()

        let abe401k = Account(context: context)
        abe401k.id = UUID()
        abe401k.externalID = "act6"
        abe401k.name = "ADP QDSS 401K"
        abe401k.bank = "ADP"
        abe401k.accountType = "Investment"
        abe401k.accountSource = "Lunch Flow"
        abe401k.balance = NSDecimalNumber(value: 32012.74)
        abe401k.availableBalance = NSDecimalNumber(value: 0)
        abe401k.accountColor = CoreDataService.randomAccountColor()

        let shae401k = Account(context: context)
        shae401k.id = UUID()
        shae401k.externalID = "act7"
        shae401k.name = "Fidelity Banner Health 401K"
        shae401k.bank = "Fidelity"
        shae401k.accountType = "Investment"
        shae401k.accountSource = "Lunch Flow"
        shae401k.balance = NSDecimalNumber(value: 28367.03)
        shae401k.availableBalance = NSDecimalNumber(value: 0)
        shae401k.accountColor = CoreDataService.randomAccountColor()

        // Transactions
        func makeTx(id: String, name: String, amount: Double, daysAgo: Int = 0, pending: Bool = false, account: Account, notes: String? = nil) -> Transaction {
            let tx = Transaction(context: context)
            tx.id = UUID()
            tx.externalID = id
            tx.name = name
            tx.amount = NSDecimalNumber(value: amount)
            tx.transactionDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())
            tx.pending = pending
            tx.account = account
            tx.notes = notes
            return tx
        }

        let t1 = makeTx(id: "pt1", name: "Starbucks", amount: -5.75, account: checking, notes: "STARBUCKS CORP #79209")
        let t2 = makeTx(id: "pt2", name: "Target", amount: -23.50, account: checking)
        let t3 = makeTx(id: "pt3", name: "Safeway", amount: -131.58, account: checking)
        let t4 = makeTx(id: "pt4", name: "Online Transfer", amount: -240.00, account: checking, notes: "ONLINE TRANSFER TO CHASE ACCT 2345")
        let t5 = makeTx(id: "pt5", name: "Amazon", amount: -42.99, pending: true, account: checking)
        let t6 = makeTx(id: "pt6", name: "McDonald's", amount: -26.83, daysAgo: 2, account: checking)
        let t7 = makeTx(id: "pt7", name: "Black Rock Coffee", amount: -7.26, daysAgo: 3, account: checking)

        let t8 = makeTx(id: "pt8", name: "Target", amount: -81.24, pending: true, account: chase)
        let t9 = makeTx(id: "pt9", name: "Amazon", amount: -46.10, daysAgo: 2, account: chase)
        t9.transferGroup = tg2
        let t10 = makeTx(id: "pt10", name: "Oregano's Bistro", amount: -57.23, daysAgo: 2, account: chase)
        t10.transferGroup = tg1
        let t11 = makeTx(id: "pt11", name: "Netflix", amount: -15.99, daysAgo: 1, account: chase)
        t11.transferGroup = tg1

        let t12 = makeTx(id: "pt12", name: "Life Cafe", amount: -9.60, pending: true, account: apple)
        t12.transferGroup = tg2
        let t13 = makeTx(id: "pt13", name: "Black Rock Coffee", amount: -7.26, daysAgo: 3, account: apple)
        t13.transferGroup = tg1
        let t14 = makeTx(id: "pt14", name: "Walmart", amount: -27.86, account: apple)

        // Allocations
        func makeAllo(tx: Transaction, account: Account, amount: Double) {
            let allo = TransactionAllocation(context: context)
            allo.transaction = tx
            allo.account = account
            allo.amount = NSDecimalNumber(value: amount)
        }

        makeAllo(tx: t8, account: checking, amount: -51.24)
        makeAllo(tx: t8, account: checking2, amount: -30)
        makeAllo(tx: t9, account: checking, amount: -46.10)
        makeAllo(tx: t10, account: checking, amount: -16.22)
        makeAllo(tx: t10, account: checking2, amount: -16.23)
        makeAllo(tx: t11, account: checking, amount: -15.99)
        makeAllo(tx: t12, account: checking, amount: -9.60)
        makeAllo(tx: t13, account: checking, amount: -7.26)

        // Suppress unused variable warnings
        _ = (t1, t2, t3, t4, t5, t6, t7, t14)

        // Balance history for charts
        func makeHistory(account: Account, entries: [(daysAgo: Int, balance: Double)]) {
            let cal = Calendar.current
            for (daysBack, bal) in entries {
                let entry = AccountBalanceHistory(context: context)
                entry.id = UUID()
                entry.account = account
                entry.balance = NSDecimalNumber(value: bal)
                entry.availableBalance = NSDecimalNumber(value: bal)
                entry.balanceDate = cal.date(byAdding: .day, value: -daysBack, to: Date())
                entry.createdAt = cal.date(byAdding: .day, value: -daysBack, to: Date())
            }
        }

        makeHistory(account: checking, entries: [(30, 800), (25, 950), (20, 1100), (15, 890), (10, 1050), (5, 1300), (0, 1234.56)])
        makeHistory(account: chase, entries: [(30, -150), (25, -230), (20, -310), (15, -180), (10, -390), (5, -250), (0, -240)])
        makeHistory(account: checking2, entries: [(30, 6200), (25, 7100), (20, 6800), (15, 7300), (10, 7000), (5, 7400), (0, 7554.89)])

        do {
            try context.save()
        } catch {
            print("Preview save failed:", error)
        }

        return controller
    }()
    
    @MainActor
    static let previewConnectedNoAccounts: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // User — both services connected
        let user = User(context: context)
        user.id = UUID()
        user.email = "preview@test.com"
        user.lunchFlowCredentialsSet = true
        user.simpleFinCredentialsSet = true
        user.createdAt = Date()
        user.updatedAt = Date()
        
        do {
            try context.save()
        } catch {
            print("PreviewEmpty save failed:", error)
        }

        return controller
    } ()

    // MARK: - Preview (empty — no credentials, no data)

    /// Shared in-memory store with a user that has no SimpleFIN or Lunch Flow credentials set,
    /// and no accounts, transactions, or transfer groups. Use this to preview empty states.
    @MainActor
    static let previewEmpty: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let user = User(context: context)
        user.id = UUID()
        user.email = "preview@test.com"
        user.simpleFinCredentialsSet = false
        user.lunchFlowCredentialsSet = false
        user.createdAt = Date()
        user.updatedAt = Date()

        do {
            try context.save()
        } catch {
            print("PreviewEmpty save failed:", error)
        }

        return controller
    }()

    // MARK: - Preview helpers

    /// The primary debit checking account from `preview`, for views that need a specific account.
    @MainActor
    static var previewDebitAccount: Account {
        let context = preview.container.viewContext
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", "act1")
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first ?? Account(context: context)
    }
    
    @MainActor
    static var previewCreditAccount: Account {
        let context = preview.container.viewContext
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", "act3")
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first ?? Account(context: context)
    }

    /// A configured AuthManager for the `preview` context (both credentials set).
    @MainActor
    static func previewAuthManager() -> AuthManager {
        let context = preview.container.viewContext
        let auth = AuthManager(viewContext: context)
        let request = User.fetchRequest()
        request.fetchLimit = 1
        auth.currentUser = (try? context.fetch(request))?.first
        auth.isLoggedIn = true
        return auth
    }
    
    @MainActor
    static func previewConnectedNoAccountsAuthManager() -> AuthManager {
        let context = previewConnectedNoAccounts.container.viewContext
        let auth = AuthManager(viewContext: context)
        let request = User.fetchRequest()
        request.fetchLimit = 1
        auth.currentUser = (try? context.fetch(request))?.first
        auth.isLoggedIn = true
        return auth
    }

    /// A configured AuthManager for the `previewEmpty` context (no credentials set).
    @MainActor
    static func previewEmptyAuthManager() -> AuthManager {
        let context = previewEmpty.container.viewContext
        let auth = AuthManager(viewContext: context)
        let request = User.fetchRequest()
        request.fetchLimit = 1
        auth.currentUser = (try? context.fetch(request))?.first
        auth.isLoggedIn = true
        return auth
    }

    // MARK: - Init

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
