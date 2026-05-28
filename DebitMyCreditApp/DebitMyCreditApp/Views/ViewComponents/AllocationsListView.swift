import SwiftUI

// Computes how many rows to use to wrap and fit all of the allocation pill views
struct AllocationsListView: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { row in
            row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
        }.reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[Int]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var rowWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = [index]
                rowWidth = size.width + spacing
            } else {
                currentRow.append(index)
                rowWidth += size.width + spacing
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }
}

