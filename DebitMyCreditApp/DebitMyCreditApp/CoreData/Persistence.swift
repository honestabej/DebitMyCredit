//
//  Persistence.swift
//  DebitMyCredit
//

import CoreData

struct PersistenceController {

    static let shared = PersistenceController()
    
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
    
    // MARK: Persistence container used in app prviws for development
    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        
        // Create the main user account, which has both services connected
        let user = makeUser(context: context, email: "honestaej@hotmail.com", lfSet: true, sfSet: true)

        // Accounts
        let abesWFChecking = makeAcct(context: context, extID: "act1", name: "Abe's Checking", bank: "Wells Fargo", acctType: "Cash", acctNum: "9204", acctSource: "SimpleFIN", availableBalance: 1116.92, balance: 1116.92)
        let shaesWFChecking = makeAcct(context: context, extID: "act2", name: "Shae's Checking", bank: "Wells Fargo", acctType: "Cash", acctNum: "2227", acctSource: "SimpleFIN", availableBalance: 25.14, balance: 25.14)
        let jointWFChecking = makeAcct(context: context, extID: "act3", name: "Joint Checking", bank: "Wells Fargo", acctType: "Cash", acctNum: "0533", acctSource: "SimpleFIN", availableBalance: 230.65, balance: 230.65)
        let billsWFChecking = makeAcct(context: context, extID: "act10", name: "Bills Checking", bank: "Wells Fargo", acctType: "Cash", acctNum: "0227", acctSource: "SimpleFIN", availableBalance: 3631.95, balance: 3631.95)
        let chaseCredit = makeAcct(context: context, extID: "act4", name: "Chase Sapphire Preferred", bank: "Chase", acctType: "Credit", acctNum: "1093", acctSource: "SimpleFIN", availableBalance: 0.0, balance: -196.62)
        let appleCredit = makeAcct(context: context, extID: "act5", name: "Apple Card", bank: "Apple", acctType: "Credit", acctNum: "", acctSource: "SimpleFIN", availableBalance: 0.0, balance: -29.22)
        let hysa = makeAcct(context: context, extID: "act6", name: "Apple HYSA", bank: "Apple", acctType: "Cash", acctNum: "", acctSource: "Manual", availableBalance: 27834.80, balance: 27834.80)
        let abeQDSS401K = makeAcct(context: context, extID: "act7", name: "Abe's QDSS 401K", bank: "ADP", acctType: "Investment", acctNum: "", acctSource: "Lunch Flow", availableBalance: 35428.39, balance: 35428.39)
        let shaeBanner401K = makeAcct(context: context, extID: "act8", name: "Shae's Banner 401K", bank: "Fidelity", acctType: "Investment", acctNum: "", acctSource: "Lunch Flow", availableBalance: 31912.47, balance: 31912.47)
        let kiaAutoLoan = makeAcct(context: context, extID: "act9", name: "KIA Auto Loan", bank: "Wells Fargo", acctType: "Loan", acctNum: "2406", acctSource: "SimpleFIN", availableBalance: 0.0, balance: -10872.14)

        // Transactions made by Abe's Checking
        let abeTx1 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx1", name: "Online Transfer", amount: -71.27, daysAgo: 0, pending: true)
        let abeTx2 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx2", name: "NIKE.com", amount: -115.87, daysAgo: 1, pending: false)
        let abeTx3 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx3", name: "Recurring Transfer From JOHNSON, ABRAHAM", amount: 260.00, daysAgo: 2, pending: false, notes: "CYCLE FOR TWO WEEKS")
        let abeTx4 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx4", name: "eBay", amount: 484.26, daysAgo: 3, pending: false)
        let abeTx5 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx5", name: "Zelle Transfer", amount: -150.00, daysAgo: 4, pending: false, notes: "Zelle Transfer to MORNINGSTAR TAKAPU")
        let abeTx6 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx6", name: "Online Transfer", amount: -14.00, daysAgo: 21, pending: false)
        let abeTx7 = makeTx(context: context, user: user, account: abesWFChecking, extID: "atx7", name: "Online Transfer", amount: -34.80, daysAgo: 15, pending: false)
        // Transactions made by Shae's Checking
        let shaeTx1 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx1", name: "StarBucks", amount: -10.48, daysAgo: 0, pending: true, notes: "PURCHASE STARBUCKS SEATTLE WA")
        let shaeTx2 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx2", name: "Py Black Rock Co", amount: -13.37, daysAgo: 0, pending: true)
        let shaeTx3 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx3", name: "Online Transfer", amount: -73.99, daysAgo: 1, pending: false)
        let shaeTx4 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx4", name: "Zelle Transfer", amount: -26.19, daysAgo: 1, pending: false)
        let shaeTx5 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx5", name: "Recurring Transfer To Johnson A", amount: -120.00, daysAgo: 1, pending: false)
        let shaeTx6 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx6", name: "Recurring Transfer From Johnson A", amount: 260.00, daysAgo: 1, pending: false)
        let shaeTx7 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx7", name: "Target", amount: -27.20, daysAgo: 2, pending: false)
        let shaeTx8 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx8", name: "Online Transfer", amount: -23.73, daysAgo: 15, pending: false)
        let shaeTx9 = makeTx(context: context, user: user, account: shaesWFChecking, extID: "sTx9", name: "Online Transfer", amount: -44.86, daysAgo: 8, pending: false)
        // Transactions made by Joint Checking
        let jointTx1 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx1", name: "Online Transfer", amount: -229.63, daysAgo: 0, pending: true)
        let jointTx2 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx2", name: "Online Transfer", amount: -202.90, daysAgo: 5, pending: false)
        let jointTx3 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx3", name: "Recurring Transfer From JOHNSON A", amount: 700.00, daysAgo: 6, pending: false)
        let jointTx4 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx4", name: "Online Transfer", amount: -304.09, daysAgo: 8, pending: false)
        let jointTx5 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx5", name: "Online Transfer", amount: -217.66, daysAgo: 12, pending: false)
        let jointTx6 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx6", name: "Online Transfer", amount: -39.45, daysAgo: 14, pending: false)
        let jointTx7 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx7", name: "Sky Harbor Garage", amount: -30, daysAgo: 14, pending: false)
        let jointTx8 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx8", name: "Online Transfer", amount: -149.78, daysAgo: 17, pending: false)
        let jointTx9 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx9", name: "Recurring Transfer From JOHNSON A", amount: 700.00, daysAgo: 20, pending: false)
        let jointTx10 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx10", name: "QuikTrip", amount: -45.17, daysAgo: 21, pending: false)
        let jointTx11 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx11", name: "Online Transfer", amount: -72.86, daysAgo: 21, pending: false)
        let jointTx12 = makeTx(context: context, user: user, account: jointWFChecking, extID: "jTx12", name: "online Transfer", amount: -146.14, daysAgo: 8, pending: false)
        // Transactions made by Bills checking
        // let billsTx1 = makeTx(context: context, user: user, account: billsWFChecking, extID: "bTx1", name: "Chase credit card payment", amount: -191.00, daysAgo: 8, pending: false)
        let billsTx2 = makeTx(context: context, user: user, account: billsWFChecking, extID: "bTx2", name: "Chase credit card payment", amount: -58.53, daysAgo: 23, pending: false)
        let billsTx3 = makeTx(context: context, user: user, account: billsWFChecking, extID: "bTx3", name: "Chase credit card payment", amount: -86.86, daysAgo: 34, pending: false)
        let billsTx4 = makeTx(context: context, user: user, account: billsWFChecking, extID: "bTx4", name: "Apple Card payment", amount: -16.99, daysAgo: 12, pending: false)
        // Transactions made by Chase credit card
        let chaseTx1 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx1", name: "Yogurtini Goodyear", amount: -14.53, daysAgo: 0, pending: true, notes: "YOGUTINI GOODYEAR #09451") // Unallocated
        let chaseTx2 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx2", name: "Microsoft", amount: -5.25, daysAgo: 0, pending: true) // Unallocated
        let chaseTx3 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx3", name: "American Airlines", amount: -90.00, daysAgo: 0, pending: true, isOrphaned: true)
        let chaseTx4 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx4", name: "Safeway", amount: -173.63, daysAgo: 0, pending: true, isOrphaned: true)
        let chaseTx5 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx5", name: "Payment", amount: 58.83, daysAgo: 22, pending: false)
        let chaseTx6 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx6", name: "Target", amount: -35.85, daysAgo: 1, pending: false) // Unallocated
        let chaseTx7 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx7", name: "Amazon", amount: -43.80, daysAgo: 1, pending: false) // Unallocated
        let chaseTx8 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx8", name: "Safeway", amount: -116.97, daysAgo: 1, pending: false)
        let chaseTx9 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx9", name: "Fry's Food and Drug", amount: -6.84, daysAgo: 2, pending: false)
        let chaseTx10 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx10", name: "Target", amount: -56.33, daysAgo: 3, pending: false)
        let chaseTx11 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx11", name: "CrunchyRoll", amount: -10.86, daysAgo: 3, pending: false)
        let chaseTx12 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx12", name: "Black Rock Coffee Bar", amount: -6.64, daysAgo: 3, pending: false)
        let chaseTx13 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx13", name: "Gloss Buss Bar Haircut", amount: -34.80, daysAgo: 3, pending: false)
        let chaseTx14 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx14", name: "Freddy's Frozen Custard and Steakburgers", amount: -17.09, daysAgo: 4, pending: false)
        let chaseTx15 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx15", name: "Target", amount: -69.29, daysAgo: 4, pending: false)
        let chaseTx16 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx16", name: "RAISING CANE'S", amount: -17.57, daysAgo: 5, pending: false)
        let chaseTx17 = makeTx(context: context, user: user, account: chaseCredit, extID: "cTx17", name: "Payment", amount: 86.86, daysAgo: 33, pending: false)
        // Transactions made by Apple credit card
        let appleTx1 = makeTx(context: context, user: user, account: appleCredit, extID: "apTx1", name: "Apple Music Family Subscription", amount: -16.99, daysAgo: 18, pending: false)
        let appleTx2 = makeTx(context: context, user: user, account: appleCredit, extID: "aplTx2", name: "Internet Transfer", amount: 16.99, daysAgo: 11, pending: false)
        // Transactions made by Apple HYSA
        let hsyaTx1 = makeTx(context: context, user: user, account: hysa, extID: "hTx1", name: "Deposit From Bills Checking", amount: 2052.83, daysAgo: 12, pending: false)
        let hysaTx2 = makeTx(context: context, user: user, account: hysa, extID: "hTx2", name: "Deposit From Abe and Shae Checking", amount: 2285.25, daysAgo: 14, pending: false)
        let hysaTx3 = makeTx(context: context, user: user, account: hysa, extID: "hTx3", name: "Apple Card cash back", amount: 0.32, daysAgo: 21, pending: false)
        // Transactions made by Abe's 401K
        let abe401KTx1 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx1", name: "T. Rowe Price", amount: 106.44, daysAgo: 4, pending: false)
        let abe401KTx2 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx2", name: "Employee Contribution", amount: 212.88, daysAgo: 4, pending: false)
        let abe401KTx3 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx3", name: "T. Rowe Price", amount: -6.14, daysAgo: 18, pending: false)
        let abe401KTx4 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx4", name: "Employee Contribution", amount: 374.88, daysAgo: 18, pending: false)
        let abe401KTx5 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx5", name: "T. Rowe Price", amount: 187.44, daysAgo: 18, pending: false)
        let abe401KTx6 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx6", name: "Employee Contribution", amount: 212.88, daysAgo: 32, pending: false)
        let abe401KTx7 = makeTx(context: context, user: user, account: abeQDSS401K, extID: "a401KTx7", name: "T. Rowe Price", amount: 106.44, daysAgo: 32, pending: false)
        // Transactions made by Shae's 401K
        let shae401KTx1 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx1", name: "realizedGainLoss", amount: 0.81, daysAgo: 7, pending: false)
        let shae401KTx2 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx2", name: "fees", amount: -7.25, daysAgo: 7, pending: false)
        let shae401KTx3 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx3", name: "contribution", amount: 307.16, daysAgo: 12, pending: false)
        let shae401KTx4 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx4", name: "contribution", amount: 205.89, daysAgo: 26, pending: false)
        let shae401KTx5 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx5", name: "contribution", amount: 315.02, daysAgo: 40, pending: false)
        let shae401KTx6 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx6", name: "fees", amount: 2.87, daysAgo: 43, pending: false)
        let shae401KTx7 = makeTx(context: context, user: user, account: shaeBanner401K, extID: "s401KTx7", name: "fees", amount: -1.01, daysAgo: 52, pending: false)

        // Allocate credit card transactions
        makeAllo(context: context, creditTx: chaseTx8, allocateTo: jointWFChecking, amount: chaseTx8.amount!)
        makeAllo(context: context, creditTx: chaseTx9, allocateTo: jointWFChecking, amount: chaseTx9.amount!)
        makeAllo(context: context, creditTx: chaseTx10, allocateTo: shaesWFChecking, amount: -34) // Split
        makeAllo(context: context, creditTx: chaseTx10, allocateTo: jointWFChecking, amount: -22.33) // Split
        makeAllo(context: context, creditTx: chaseTx11, allocateTo: shaesWFChecking, amount: chaseTx11.amount!)
        makeAllo(context: context, creditTx: chaseTx12, allocateTo: shaesWFChecking, amount: chaseTx12.amount!)
        makeAllo(context: context, creditTx: chaseTx13, allocateTo: abesWFChecking, amount: chaseTx13.amount!)
        makeAllo(context: context, creditTx: chaseTx14, allocateTo: shaesWFChecking, amount: chaseTx14.amount!)
        makeAllo(context: context, creditTx: chaseTx15, allocateTo: jointWFChecking, amount: chaseTx15.amount!)
        makeAllo(context: context, creditTx: chaseTx16, allocateTo: abesWFChecking, amount: -14) // Split
        makeAllo(context: context, creditTx: chaseTx16, allocateTo: jointWFChecking, amount: -3.57) // Split
        makeAllo(context: context, creditTx: appleTx1, allocateTo: billsWFChecking, amount: appleTx1.amount!)
        
        // Create Payment "TG 99" and link the Transactions
        let tg99 = makePayment(context: context, user: user, forCard: chaseCredit, name: "TG 99", completed: true)
        makePaymentAccount(context: context, account: billsWFChecking, payment: tg99, isPaidFrom: true, matchedTx: billsTx3, complete: true)
        makePaymentAccount(context: context, account: abesWFChecking, payment: tg99, isPaidFrom: false, matchedTx: abeTx7, complete: true)
        makePaymentAccount(context: context, account: jointWFChecking, payment: tg99, isPaidFrom: false, matchedTx: jointTx11, complete: true)
        chaseTx15.payment = tg99
        chaseTx16.payment = tg99
        
        // Create Payment "TG 100" and link the Transactions
        let tg100 = makePayment(context: context, user: user, forCard: chaseCredit, name: "TG 100", completed: true)
        makePaymentAccount(context: context, account: billsWFChecking, payment: tg100, isPaidFrom: true, matchedTx: billsTx2, complete: true)
        makePaymentAccount(context: context, account: abesWFChecking, payment: tg100, isPaidFrom: false, matchedTx: abeTx6, complete: true)
        makePaymentAccount(context: context, account: shaesWFChecking, payment: tg100, isPaidFrom: false, matchedTx: shaeTx8, complete: true)
        chaseTx12.payment = tg100
        chaseTx13.payment = tg100
        chaseTx14.payment = tg100
        
        // Create Payment for "Apple Card Payment"
        let applePayment = makePayment(context: context, user: user, forCard: appleCredit, name: "Apple Card payment", completed: true)
        makePaymentAccount(context: context, account: billsWFChecking, payment: applePayment, isPaidFrom: true, matchedTx: billsTx4, complete: true)
        appleTx1.payment = applePayment
        
        // Create Payment "TG 101" and link the Transactions
        let tg101 = makePayment(context: context, user: user, forCard: chaseCredit, name: "TG 101", completed: false)
        makePaymentAccount(context: context, account: billsWFChecking, payment: tg101, isPaidFrom: true, complete: false)
        makePaymentAccount(context: context, account: jointWFChecking, payment: tg101, isPaidFrom: false, matchedTx: jointTx12, complete: true)
        makePaymentAccount(context: context, account: shaesWFChecking, payment: tg101, isPaidFrom: false, matchedTx: shaeTx9, complete: true)
        chaseTx8.payment = tg101
        chaseTx9.payment = tg101
        chaseTx10.payment = tg101
        chaseTx11.payment = tg101

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

    // MARK: - Preview helpers for creating entites
    // Make a User entity
    @discardableResult
    static func makeUser(context: NSManagedObjectContext, email: String, lfSet: Bool, sfSet: Bool) -> User {
        let user = User(context: context)
        user.id = UUID()
        user.email = email
        user.lunchFlowCredentialsSet = lfSet
        user.simpleFinCredentialsSet = sfSet
        user.createdAt = Date()
        user.updatedAt = Date()
        return user
    }
    
    // Make an Account entity
    @discardableResult
    static func makeAcct(context: NSManagedObjectContext, extID: String, name: String, bank: String, acctType: String, acctNum: String, acctSource: String, availableBalance: NSDecimalNumber, balance: NSDecimalNumber) -> Account {
        let acct = Account(context: context)
        acct.id = UUID()
        acct.externalID = extID
        acct.name = name
        acct.bank = bank
        acct.accountType = acctType
        acct.accountNumber = acctNum
        acct.accountSource = acctSource
        acct.availableBalance = availableBalance
        acct.balance = balance
        acct.balanceDate = Date()
        acct.accountColor = CoreDataService.randomAccountColor()
        return acct
    }
    
    // Make a Transaction entity
    @discardableResult
    static func makeTx(context: NSManagedObjectContext, user: User, account: Account, extID: String, name: String, amount: NSDecimalNumber, daysAgo: Int = 0, pending: Bool = false, notes: String? = nil, isOrphaned: Bool? = false) -> Transaction {
        let tx = Transaction(context: context)
        tx.user = user
        tx.account = account
        tx.id = UUID()
        tx.externalID = extID
        tx.name = name
        tx.amount = amount
        tx.transactionDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())
        tx.pending = pending
        tx.notes = notes
        tx.isOrphaned = isOrphaned ?? false
        return tx
    }
    
    // Make an Allocation entity
    @discardableResult
    static func makeAllo(context: NSManagedObjectContext, creditTx: Transaction, allocateTo: Account, amount: NSDecimalNumber) -> TransactionAllocation {
        let allo = TransactionAllocation(context: context)
        allo.transaction = creditTx
        allo.account = allocateTo
        allo.amount = amount
        return allo
    }
    
    // Make a Payment entity
    @discardableResult
    static func makePayment(context: NSManagedObjectContext, user: User, forCard: Account, name: String, completed: Bool) -> Payment {
        let payment = Payment(context: context)
        payment.user = user
        payment.creditCardAccount = forCard
        payment.id = UUID()
        payment.name = name
        payment.completed = completed
        payment.createdAt = Date()
        return payment
    }
    
    // Make a PaymentAccount entity
    @discardableResult
    static func makePaymentAccount(context: NSManagedObjectContext, account: Account, payment: Payment, isPaidFrom: Bool, matchedTx: Transaction? = nil, complete: Bool) -> PaymentAccount {
        let pmtAcct = PaymentAccount(context: context)
        pmtAcct.account = account
        pmtAcct.payment = payment
        pmtAcct.matchedTransaction = matchedTx
        pmtAcct.isComplete = complete
        pmtAcct.updatedAt = Date()
        pmtAcct.createdAt = Date()
        return pmtAcct
    }
    

    @MainActor
    static var previewDebitAccount: Account {
        let context = preview.container.viewContext
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "externalID == %@", "act1")
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first ?? Account(context: context)
    }

    @MainActor
    static var previewCreditAccount: Account {
        let context = preview.container.viewContext
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "externalID == %@", "act3")
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
}
