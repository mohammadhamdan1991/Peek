#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// Waterfall of the attempt's phases from `URLSessionTaskMetrics`, plus every attempt of the same call.
struct TimingSection: View {
    let record: HTTPRecord
    let attempts: [HTTPRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let timing = record.timing, let total = timing.total {
                waterfall(timing, total: total)
                if let insight = insight(timing, total: total) {
                    Label(insight, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.warningText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.clientError.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text(record.isComplete ? "No timing metrics for this request." : "Waiting for the response…")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if attempts.count > 1 {
                Labeled("Attempts · same call") {
                    VStack(spacing: 0) {
                        ForEach(attempts.indices, id: \.self) { index in
                            attemptRow(attempts[index], number: index + 1)
                            if index < attempts.count - 1 { Divider().overlay(Theme.hairline) }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                }
            }
        }
    }

    private func waterfall(_ timing: HTTPTiming, total: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text([timing.networkProtocol, timing.isReusedConnection ? "reused connection" : "new connection"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            ForEach(timing.phases, id: \.self) { phase in
                HStack(spacing: 8) {
                    Text(phase.name).font(.footnote).foregroundStyle(Theme.secondaryText).frame(width: 72, alignment: .leading)
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let start = phase.interval.start.timeIntervalSince(total.start) / max(total.duration, 0.001)
                        let length = phase.interval.duration / max(total.duration, 0.001)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline.opacity(0.6))
                            Capsule()
                                .fill(color(phase.name))
                                .frame(width: max(3, width * length))
                                .offset(x: width * start)
                        }
                    }
                    .frame(height: 10)
                    Text(Format.duration(phase.interval.duration))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(phase.name), \(Format.duration(phase.interval.duration))")
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Total").font(.footnote).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(Format.duration(total.duration)).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(Theme.text)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }

    private func attemptRow(_ attempt: HTTPRecord, number: Int) -> some View {
        HStack {
            Text("#\(number) · \(attempt.startedAt.formatted(date: .omitted, time: .standard))")
                .font(.subheadline)
                .foregroundStyle(Theme.text)
            if attempt.id == record.id {
                Text("this one").font(.caption).foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Text(Format.status(attempt))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.color(for: StatusClass(attempt)))
            Text(attempt.duration.map(Format.duration) ?? "…")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(attempt.id == record.id ? Theme.hairline.opacity(0.4) : .clear)
    }

    /// One plain-language hint when a single phase dominates.
    private func insight(_ timing: HTTPTiming, total: DateInterval) -> String? {
        guard total.duration > 0.3, let slowest = timing.phases.max(by: { $0.interval.duration < $1.interval.duration }) else { return nil }
        let share = Int(slowest.interval.duration / total.duration * 100)
        guard share >= 60 else { return nil }
        switch slowest.name {
        case "Waiting": return "Waiting for the server took \(share)% of the time. The connection itself was fine."
        case "DNS", "Connect", "TLS": return "\(slowest.name) took \(share)% of the time: the network or connection setup is the bottleneck."
        case "Response": return "Downloading the response took \(share)% of the time: the payload may be large."
        default: return nil
        }
    }

    private func color(_ phase: String) -> Color {
        switch phase {
        case "DNS", "Connect": Theme.redirect
        case "TLS": Theme.accent
        case "Waiting": Theme.clientError
        default: Theme.success
        }
    }
}
#endif
