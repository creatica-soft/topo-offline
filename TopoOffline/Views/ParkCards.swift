import SwiftUI

extension Campsite {
    /// SF Symbol for the map pin and cards.
    var symbol: String {
        if kind == "Hut" { return "house.fill" }
        if kind == "Caravan park" { return "car.fill" }
        return camping ? "tent.fill" : "fork.knife"
    }
}

private extension Campsite {
    var statusColor: Color {
        switch closureStatus {
        case .current: return .red
        case .upcoming: return .orange
        case .none: return isCommunity ? .teal : .green
        }
    }

    /// Everything known about facilities, official first, then community-reported.
    var allAmenities: [String] { (amenities ?? []) + (communityAmenities ?? []) }

    var facilities: String {
        if let detail, !detail.isEmpty { return detail }
        if !allAmenities.isEmpty { return ([kind] + allAmenities.prefix(4)).joined(separator: " · ") }
        var parts = [kind]
        if camping && kind != "Campsite" { parts.append("Camping") }
        if picnic { parts.append("Picnic area") }
        if fee { parts.append("Fees apply") }
        return parts.joined(separator: " · ")
    }
}

private extension ClosedLine {
    var kindText: String {
        switch kind {
        case .track: return closure.partial ? "Track partly closed" : "Track closed"
        case .road: return closure.partial ? "Road partly closed" : "Road or vehicle track closed"
        }
    }
}

/// Card for a Victorian campsite, day area or hut.
struct SiteCard: View {
    let site: Campsite
    let updated: String?
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        CardFrame(onOpen: onOpen, onClose: onClose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: site.symbol)
                    .font(.title3)
                    .foregroundStyle(site.statusColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(site.name).font(.headline).lineLimit(2)
                    Text(site.facilities).font(.subheadline).foregroundStyle(.secondary)
                    if let closure = site.closure, site.closureStatus != .none {
                        ClosureLines(closure: closure)
                    }
                    if let access = site.access {
                        Text(access).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if site.isCommunity || site.communityAmenities != nil {
                        Text(site.isCommunity ? "Community data (OpenStreetMap)" : "Facilities from OpenStreetMap")
                            .font(.caption2).foregroundStyle(.teal)
                    }
                    DetailsHint()
                }
            }
        }
    }

}

/// Card for a New Zealand freedom-camping rule area.
struct RuleCard: View {
    let rule: CampingRule
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        CardFrame(onOpen: onOpen, onClose: onClose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: rule.prohibited ? "nosign" : "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(rule.prohibited ? .red : .orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.prohibited ? "No freedom camping" : "Freedom camping restricted")
                        .font(.headline)
                    Text([rule.name, rule.location].compactMap { $0 }.joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let first = rule.conditions.first {
                        Text(first).font(.caption).lineLimit(2)
                    }
                    DetailsHint()
                }
            }
        }
    }
}

struct RuleDetailView: View {
    let rule: CampingRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailScaffold(title: rule.name, onDone: { dismiss() }) {
            Label(rule.prohibited ? "Freedom camping prohibited" : "Freedom camping restricted",
                  systemImage: rule.prohibited ? "nosign" : "exclamationmark.circle.fill")
                .foregroundStyle(rule.prohibited ? .red : .orange)
            if let location = rule.location { Text(location).foregroundStyle(.secondary) }
            if !rule.conditions.isEmpty {
                DetailSection(title: "Conditions") {
                    ForEach(rule.conditions, id: \.self) { Text("• \($0)").fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("Freedom camping rules on DOC land. Councils have their own bylaws for other land.")
                .font(.footnote).foregroundStyle(.secondary)
            Credit(source: NZParkData.attribution, updated: nil)
        }
    }
}

/// Card for a closed track or road.
struct ClosureCard: View {
    let closure: ClosedLine
    let updated: String?
    let onOpen: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    var body: some View {
        CardFrame(onOpen: onOpen, onClose: onClose, onZoom: onZoom) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(closure.name).font(.headline).lineLimit(2)
                    Text(closure.kindText).font(.subheadline).foregroundStyle(.secondary)
                    ClosureLines(closure: closure.closure)
                    DetailsHint()
                }
            }
        }
    }

}

/// "Closed · Fire · Until 20 Dec 2026" plus the agency's note.
private struct ClosureLines: View {
    let closure: ClosureInfo
    var full = false

    var body: some View {
        let upcoming: Bool = { if case .upcoming = closure.status() { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 2) {
            Text(([upcoming ? nil : "Closed", closure.reason, closure.summary()].compactMap { $0 }).joined(separator: " · "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(upcoming ? .orange : .red)
            if let details = closure.details {
                Text(details)
                    .font(full ? .body : .caption)
                    .lineLimit(full ? nil : 2)
                    .fixedSize(horizontal: false, vertical: full)
            }
        }
    }
}

private struct Credit: View {
    let source: String
    let updated: String?

    var body: some View {
        Text([source, updated].compactMap { $0 }.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// Shared card chrome: material background, optional zoom button, and a large close button.
private struct CardFrame<Content: View>: View {
    let onOpen: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Tapping the text opens the full details.
            Button(action: onOpen) {
                HStack(spacing: 0) {
                    content
                        .padding(.vertical, 10)
                        .padding(.leading, 12)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows full details")
            if let onZoom {
                Button(action: onZoom) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Show on map")
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DetailsHint: View {
    var body: some View {
        Label("Tap for details", systemImage: "chevron.up")
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .labelStyle(.titleAndIcon)
            .padding(.top, 1)
    }
}

// MARK: - Full details (sheet)

struct SiteDetailView: View {
    let site: Campsite
    let updated: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailScaffold(title: site.name, onDone: { dismiss() }) {
            Label(site.facilities, systemImage: site.symbol)
                .foregroundStyle(site.statusColor)
            if let closure = site.closure, site.closureStatus != .none {
                DetailSection(title: "Closure") {
                    ClosureLines(closure: closure, full: true)
                    ClosureDates(closure: closure)
                }
            }
            if let amenities = site.amenities, !amenities.isEmpty {
                DetailSection(title: site.isCommunity ? "Facilities (community data)" : "Facilities") {
                    Text(amenities.joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let community = site.communityAmenities, !community.isEmpty {
                DetailSection(title: "Facilities (from OpenStreetMap)") {
                    Text(community.joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let access = site.access {
                DetailSection(title: site.isCommunity ? "Notes" : "Getting there") {
                    Text(access).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let website = site.website.flatMap(URL.init(string:)), website.scheme?.hasPrefix("http") == true {
                Link(destination: website) { Label(website.host ?? "Website", systemImage: "safari") }
            }
            if site.isCommunity || site.communityAmenities != nil {
                Text("Community information is added by OpenStreetMap volunteers and may be out of date. Check with the land manager before you rely on it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Credit(source: site.credit, updated: site.source == nil ? updated : nil)
            if site.communityAmenities != nil {
                Credit(source: CampSource.osmCredit, updated: nil)
            }
        }
    }
}

struct ClosureDetailView: View {
    let closure: ClosedLine
    let updated: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailScaffold(title: closure.name, onDone: { dismiss() }) {
            Label(closure.kindText, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            DetailSection(title: "Closure") {
                ClosureLines(closure: closure.closure, full: true)
                ClosureDates(closure: closure.closure)
            }
            Credit(source: closure.credit, updated: updated)
        }
    }
}

private struct ClosureDates: View {
    let closure: ClosureInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let start = closure.start {
                Text("From \(start.formatted(date: .long, time: .omitted))")
            }
            if let reopen = closure.reopen, Calendar.current.component(.year, from: reopen) < 2040 {
                Text("Expected to reopen \(reopen.formatted(date: .long, time: .omitted))")
            } else {
                Text("No reopening date given")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailScaffold<Content: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
