import CoreData

extension CoreDataService {

    func upsertCreditAccount(
        id: String,
        name: String,
        balanceDate: Date?,
        createdAt: Date,
        updatedAt: Date,
        user: User,
        context: NSManagedObjectContext
    ) {
        let request: NSFetchRequest<CreditAccount> = CreditAccount.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)

        let existing = try? context.fetch(request).first
        let acct = existing ?? CreditAccount(context: context)

        acct.id = id
        acct.name = name
        acct.balanceDate = balanceDate
        acct.createdAt = createdAt
        acct.updatedAt = updatedAt
        acct.user = user
    }

    func fetchCreditAccounts(for user: User, context: NSManagedObjectContext) -> [CreditAccount] {
        let request: NSFetchRequest<CreditAccount> = CreditAccount.fetchRequest()
        request.predicate = NSPredicate(format: "user == %@", user)

        return (try? context.fetch(request)) ?? []
    }

    func deleteCreditAccount(_ acct: CreditAccount, context: NSManagedObjectContext) {
        context.delete(acct)
    }
}
