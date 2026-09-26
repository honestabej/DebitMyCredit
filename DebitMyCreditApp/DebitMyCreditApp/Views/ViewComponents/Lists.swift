import SwiftUI
import CoreData

// Standardized list format
/// Usage without swipe actions (e.g. TransactionsView):
///
///     TransactionListView(pendingTransactions: pending, settledByDay: settled) { tx in
///         TransactionRow(transaction: tx)
///     }
///
/// Usage with swipe actions (e.g. AccountView):
///
///     TransactionListView(pendingTransactions: pending, settledByDay: settled) { tx in
///         TransactionRowView(transaction: tx, ...)
///     } swipeActions: { tx in
///         Button(role: .destructive) { delete(tx) } label: { Label("Delete", systemImage: "trash") }
///     }
///
struct TransactionListView<RowContent: View, SwipeContent: View>: View {
    let pendingTransactions: [Transaction]
    let settledByDay: [(day: Date, transactions: [Transaction])]
    @ViewBuilder var row: (Transaction) -> RowContent
    @ViewBuilder var swipeActions: (Transaction) -> SwipeContent

    var body: some View {
        List {
            // Collapse the default top gap List adds before the first section
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets(top: -20, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.lightBackground)
                .listRowSeparator(.hidden)

            if !pendingTransactions.isEmpty {
                Section {
                    ForEach(pendingTransactions, id: \.objectID) { transaction in
                        row(transaction)
                            .padding(.horizontal, 18)
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 10)
                            .listRowBackground(Color.lightBackground)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(transaction)
                            }
                    }
                } header: {
                    TransactionSectionHeader(label: "Pending", labelColor: .secondary)
                }
            }

            ForEach(settledByDay, id: \.day) { group in
                Section {
                    ForEach(group.transactions, id: \.objectID) { transaction in
                        row(transaction)
                            .padding(.horizontal, 18)
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 10)
                            .listRowBackground(Color.lightBackground)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(transaction)
                            }
                    }
                } header: {
                    TransactionSectionHeader(
                        label: group.day.formatted(.dateTime.month(.wide).day().year()),
                        labelColor: .primary
                    )
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .onAppear {
            UITableView.appearance().sectionHeaderTopPadding = 1000
        }
    }
}

// Convenience init when no swipe actions are needed
extension TransactionListView where SwipeContent == EmptyView {
    init(
        pendingTransactions: [Transaction],
        settledByDay: [(day: Date, transactions: [Transaction])],
        @ViewBuilder row: @escaping (Transaction) -> RowContent
    ) {
        self.pendingTransactions = pendingTransactions
        self.settledByDay = settledByDay
        self.row = row
        self.swipeActions = { _ in EmptyView() }
    }
}

private struct TransactionSectionHeader: View {
    let label: String
    let labelColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15))
                .fontWeight(.semibold)
                .foregroundColor(labelColor)
                .fixedSize()
            Rectangle()
                .fill(Color(.separator))
                .frame(maxWidth: .infinity)
                .frame(height: 0.5)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets())
        .padding(.horizontal, 15)
    }
}
