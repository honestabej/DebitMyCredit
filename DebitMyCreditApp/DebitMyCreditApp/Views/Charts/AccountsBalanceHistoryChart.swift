import SwiftUI
import CoreData
import Combine

enum BalanceHistoryRange: String, CaseIterable {
    case oneMonth = "1M"
    case sixMonths = "6M"
    case ytd = "YTD"
    case oneYear = "1Y"
    case allTime = "All"
}

struct AccountsBalanceHistoryChart: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedRange: BalanceHistoryRange = .oneMonth
    
    var body: some View {
        VStack(spacing: 8) {
            
            // Graph container
            ZStack(alignment: .top) {
                // Title and key
                HStack(alignment: .top) {
                    Text("Balances History")
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.appGreen)
                                .frame(width: 16, height: 4)
                            Text("Debit")
                                .font(.caption)
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.appRed)
                                .frame(width: 16, height: 4)
                            Text("Credit")
                                .font(.caption)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.70))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            
            // Range selector
            HStack(spacing: 8) {
                ForEach(BalanceHistoryRange.allCases, id: \.self) { range in
                    let isSelected = selectedRange == range
                    Button(range.rawValue) {
                        selectedRange = range
                    }
                    .font(.caption.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(isSelected ? .white.opacity(0.30) : .clear)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
}

// MARK: - Preview helpers

private func makePreviewData() -> NSManagedObjectContext {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let calendar = Calendar.current
    func daysAgo(_ n: Int) -> Date {
        calendar.date(byAdding: .day, value: -n, to: Date())!
    }

    // Checking account
    let checking = Account(context: context)
    checking.id = "acct-1"
    checking.name = "Abe's Checking"
    checking.bank = "Wells Fargo"
    checking.accountType = "Debit"
    checking.accountNumber = "1234"
    checking.availableBalance = NSDecimalNumber(value: 1234.56)
    checking.balance = NSDecimalNumber(value: 1234.56)
    checking.balanceDate = Date()

    // Credit card
    let credit = Account(context: context)
    credit.id = "acct-2"
    credit.name = "Chase Sapphire"
    credit.bank = "Chase"
    credit.accountType = "Credit"
    credit.accountNumber = "5678"
    credit.availableBalance = NSDecimalNumber(value: -420.00)
    credit.balance = NSDecimalNumber(value: -420.00)
    credit.balanceDate = Date()

    // Balance history for checking
    let checkingHistory: [(Int, Double)] = [(30, 800), (25, 950), (20, 1100), (15, 890), (10, 1050), (5, 1300), (0, 1234.56)]
    for (daysBack, bal) in checkingHistory {
        let entry = AccountBalanceHistory(context: context)
        entry.id = UUID()
        entry.account = checking
        entry.balance = NSDecimalNumber(value: bal)
        entry.availableBalance = NSDecimalNumber(value: bal)
        entry.balanceDate = daysAgo(daysBack)
        entry.createdAt = daysAgo(daysBack)
    }

    // Balance history for credit
    let creditHistory: [(Int, Double)] = [(30, -150), (25, -230), (20, -310), (15, -180), (10, -390), (5, -450), (0, -420)]
    for (daysBack, bal) in creditHistory {
        let entry = AccountBalanceHistory(context: context)
        entry.id = UUID()
        entry.account = credit
        entry.balance = NSDecimalNumber(value: bal)
        entry.availableBalance = NSDecimalNumber(value: bal)
        entry.balanceDate = daysAgo(daysBack)
        entry.createdAt = daysAgo(daysBack)
    }

    try? context.save()
    return context
}

#Preview {
    let context = makePreviewData()
    AccountsBalanceHistoryChart()
        .environment(\.managedObjectContext, context)
}



