import SwiftUI

// MARK: - Shared components

struct SectionHeader: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Theme.sectionLabel(text) }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }
}

/// 4pt rounded bar on a warm track. One accent hue maximum per screen.
struct TrackBar: View {
    let fraction: Double
    var color: Color = Theme.bar
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Active now

/// A quiet single line: live dot, "Codex · GPT-5.6", age at right. No card.
struct ActiveNowRow: View {
    let provider: String
    let model: String?
    let lastEventAt: Date

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text(provider + (model.map { " · \($0)" } ?? ""))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer()
            Theme.mono(age, size: 11, color: Theme.textMuted)
        }
        .onReceive(timer) { now = $0 }
    }

    private var age: String {
        let s = Int(now.timeIntervalSince(lastEventAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// MARK: - Token flow

/// Bars only, no axis chrome. Today's hours; the most recent bar gets the accent.
struct FlowChart: View {
    let flow: [(bucket: Date, billable: Int)]
    let hourly: Bool

    var body: some View {
        let maxV = flow.map(\.billable).max() ?? 1
        VStack(spacing: 6) {
            GeometryReader { geo in
                let n = max(flow.count, 1)
                let slot = geo.size.width / CGFloat(n)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(flow.enumerated()), id: \.offset) { i, b in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i == n - 1 ? Theme.accent : Theme.accentSoft)
                            .frame(
                                width: max(2, slot * 0.62),
                                height: max(2, geo.size.height * CGFloat(b.billable) / CGFloat(maxV))
                            )
                            .frame(width: slot, alignment: .center)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 48)

            HStack {
                Text(label(flow.first!.bucket))
                Spacer()
                Text(label(flow.last!.bucket))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.textMuted)
        }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = hourly ? "HH:mm" : "MMM d"
        return f.string(from: d)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
