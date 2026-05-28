import SwiftUI
import CoreData

struct AccountsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    // Fetch all accounts except hidden/placeholder types, sorted by type then name
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Account.accountType, ascending: true),
            NSSortDescriptor(keyPath: \Account.name, ascending: true)
        ],
        predicate: NSPredicate(format: "accountType != %@ AND accountType != %@", "-", "Hide"),
        animation: .default
    )
    private var accounts: FetchedResults<Account>

    // Display order for known account types; unknown types fall at the end
    private let typeOrder = ["Cash", "Credit", "Investment", "Loan"]

    // Accounts grouped by type, in the defined display order
    private var groupedAccounts: [(type: String, accounts: [Account])] {
        let dict = Dictionary(grouping: accounts, by: { $0.accountType ?? "Other" })
        let knownTypes = typeOrder.filter { dict[$0] != nil }
        let otherTypes = dict.keys.filter { !typeOrder.contains($0) }.sorted()
        return (knownTypes + otherTypes).compactMap { type in
            guard let group = dict[type] else { return nil }
            return (type: type, accounts: group)
        }
    }
    
    var body: some View {
        // Background Color
        ZStack () {
            Color.appGreen.ignoresSafeArea()
            
            // Actual Content
            VStack {
                PageHeaderView(title: "Accounts", leftButton: EmptyView?.none, includeRefresh: true)
                
                // TODO: Implement chart
//                AccountsBalanceHistoryChart()
//                    .frame(height: 230)
                
                accountsList
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.lightBackground)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        
    }
    
    // View to display the list of accounts grouped by type
    private var accountsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groupedAccounts, id: \.type) { group in
                    accountSection(title: group.type, accounts: group.accounts)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 83) }
    }

    @ViewBuilder
    private func accountSection(title: String, accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section {
                ForEach(accounts) { account in
                    AccountRow(account: account, useAvailableBalance: title == "Cash")
                        .padding(.vertical, 5)
                }
            } header: {
                Text(title)
                    .font(.system(size: 14))
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .padding(.leading, 8)
                    .background(Color.lightBackground)
            }
            .padding(.horizontal, 8)
        }
    }
    
}

struct AccountRow: View {
    @ObservedObject var account: Account
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showAccountDetail = false
    @State private var refreshToken = UUID()
    var useAvailableBalance: Bool = true

    private var adjustedBalance: NSDecimalNumber? {
        guard let balance = useAvailableBalance ? account.availableBalance : account.balance else { return nil }
        let pending = account.unpaidTransactionsOfAccount(account: account)
        return balance.subtracting(pending)
    }

    var body: some View {
        Button(action: { showAccountDetail = true }) {
            HStack(alignment: .center, spacing: 10) {
                
                // Display corresponding Bank Logo
                Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 45, height: 45)
                    .clipShape(Circle())
                
                VStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name ?? "")
                            .fontWeight(.bold)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    // Display the account number if available, and the time since last update
                    HStack {
                        if let accountNumber = account.accountNumber, !accountNumber.isEmpty {
                            Text("•••• \(accountNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("•")
                        }
                        
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                            Text(timeSinceLastUpdate(from: account.balanceDate))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                let unpaid = account.unpaidTransactionsOfAccount(account: account)
                let _ = refreshToken
                Text(adjustedBalance.map { ($0.decimalValue as Decimal).formatted(.currency(code: "USD")) } ?? "")
                    .font(.system(size: 17))
                    .fontWeight(.bold)

                Circle()
                    .fill(unpaid == 0 ? Color.green : Color.appOrange as Color)
                    .frame(width: 8, height: 8)
                    .padding(.leading, -5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAccountDetail) {
            AccountView(account: account)
                .environment(\.managedObjectContext, viewContext)
                .presentationDragIndicator(.visible)
        }
        .padding(8)
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            refreshToken = UUID()
        }
        .id(refreshToken)
    }
}



// View for each row
#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewEmptyAuthManager())
}


