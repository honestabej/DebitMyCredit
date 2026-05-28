import SwiftUI
import CoreData
import Combine

enum AccountsBalanceHistoryRange: String, CaseIterable {
    case oneMonth = "1M"
    case sixMonths = "6M"
    case ytd = "YTD"
    case oneYear = "1Y"
    case allTime = "All"
}

struct AccountsBalanceHistoryChart: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedRange: AccountsBalanceHistoryRange = .oneMonth
    
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
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            
            // Range selector
            HStack(spacing: 8) {
                ForEach(AccountsBalanceHistoryRange.allCases, id: \.self) { range in
                    let isSelected = selectedRange == range
                    Group {
                        if isSelected {
                            Button(range.rawValue) { selectedRange = range }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        } else {
                            Button(range.rawValue) { selectedRange = range }
                                .font(.caption.weight(.regular))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
}

#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    AccountsBalanceHistoryChart()
        .environment(\.managedObjectContext, context)
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    AccountsBalanceHistoryChart()
        .environment(\.managedObjectContext, context)
}



