import SwiftUI

// MARK: - Shared components

struct SectionHeader: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Theme.sectionLabel(text) }
}

/// A 6pt rounded bar on a faint track — the mockup's one and only chart idiom.
struct TrackBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.trackFill)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 0.5)
    }
}

// MARK: - Active now card

struct ActiveNowCard: View {
    let provider: String
    let model: String?
    let lastEventAt: Date

    /// Tick so the "38s" ages while the window is open.
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(Theme.activeDot).frame(width: 6, height: 6)
                Theme.sectionLabel("ACTIVE NOW").foregroundStyle(Theme.activeLabel)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(provider + (model.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.activeText)
                Spacer()
                Text(age)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.activeLabel)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.activeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { now = $0 }
    }

    private var age: String {
        let s = Int(now.timeIntervalSince(lastEventAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// MARK: - Token-flow bar chart

struct FlowChart: View {
    let flow: [(bucket: Date, billable: Int)]
    let hourly: Bool

    var body: some View {
        let maxV = flow.map(\.billable).max() ?? 1
        VStack(spacing: 4) {
            GeometryReader { geo in
                let n = max(flow.count, 1)
                let slot = geo.size.width / CGFloat(n)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(flow.enumerated()), id: \.offset) { i, b in
                        let recent = hourly && i >= n - 4   // the mockup darkens the last hours
                        RoundedRectangle(cornerRadius: 2)
                            .fill(recent ? Theme.purple : Theme.purpleSoft)
                            .frame(
                                width: max(2, slot * 0.72),
                                height: max(2, geo.size.height * CGFloat(b.billable) / CGFloat(maxV))
                            )
                            .frame(width: slot, alignment: .center)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 54)

            if !flow.isEmpty {
                HStack {
                    Text(label(flow.first!.bucket))
                    Spacer()
                    if flow.count > 2 { Text(label(flow[flow.count / 2].bucket)) }
                    Spacer()
                    Text(label(flow.last!.bucket))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = hourly ? "HH" : "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Empty state

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}
