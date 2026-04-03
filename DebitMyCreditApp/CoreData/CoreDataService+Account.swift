import CoreData

extension CoreDataService {

    func upsertAccount(
        id: String, name: String, accountBalance: Decimal, activeBalance: Decimal, balanceDate: Date?,
        accountType: String, createdAt: Date, updatedAt: Date, user: User, context: NSManagedObjectContext
    ) {
        let request: NSFetchRequest<Account> = Account.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)

        let existing = try? context.fetch(request).first
        let acct = existing ?? Account(context: context)

        acct.id = id
        acct.name = name
        acct.accountBalance = accountBalance as NSDecimalNumber
        acct.activeBalance = activeBalance as NSDecimalNumber
        acct.balanceDate = balanceDate
        acct.accountType = accountType
        acct.createdAt = createdAt
        acct.updatedAt = updatedAt
        acct.user = user
    }

    func fetchAccounts(for user: User, context: NSManagedObjectContext) -> [Account] {
        let request: NSFetchRequest<Account> = Account.fetchRequest()
        request.predicate = NSPredicate(format: "user == %@", user)

        return (try? context.fetch(request)) ?? []
    }

    func deleteAccount(_ acct: Account, context: NSManagedObjectContext) {
        context.delete(acct)
    }
}
