import SwiftUI
import UIKit

// The 90-day "How you dewin?" report: the navy card from the founder's mockup, a "For your doctor"
// section with real units, a PDF for the doctor, and "Delete my data".
//
// Debug launch arguments (with `--report`): `--report-scroll=places|actions|doctor`,
// `--report-day=<index>` (selects a timeline day), `--report-share` (opens the share step),
// `--report-pdf` (writes the PDF to the app's tmp folder and logs the path).

// MARK: - Screen

struct HowYouDewinView: View {
    @Environment(ReportStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay: Int?
    @State private var showShare = false
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        ZStack {
            HYDStyle.page.ignoresSafeArea()
            if let report = store.report {
                content(report)
            } else if let error = store.error, !store.isLoading {
                failed(error)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(HYDStyle.text)
                    Text("Adding up your \(ReportStore.days) days…").font(.callout).foregroundStyle(HYDStyle.muted)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").fontWeight(.semibold).foregroundStyle(HYDStyle.text)
                }
                .accessibilityLabel("Close")
            }
        }
        .toolbarBackground(HYDStyle.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await store.load() }
        .sheet(isPresented: $showShare) {
            if let report = store.report {
                HYDShareSheet(report: report, firstName: UserProfile.firstName)
            }
        }
        .confirmationDialog("Delete all your Dewin data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your meals, photos and readings on this phone and on the Dewin server. It can't be undone.")
        }
        .alert("Couldn't delete your data", isPresented: Binding(get: { deleteError != nil },
                                                                  set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func content(_ report: ExposureReport) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 28) {
                        HYDCardBody(report: report, firstName: UserProfile.firstName, interactive: true,
                                    selectedDay: $selectedDay, onOpenLog: openLog)
                        buttons
                    }
                    .hydCard()

                    HYDDoctorSection(report: report, firstName: UserProfile.firstName)
                        .hydCard()
                        .id("doctor")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { await store.load(force: true) }
            #if DEBUG
            .task { await debugHooks(report, proxy: proxy) }
            #endif
        }
    }

    private var buttons: some View {
        HYDAdaptiveStack(spacing: 12) {
            Button { showShare = true } label: {
                Text("Share with my doctor")
                    .font(.callout.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.navy)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .frame(maxHeight: .infinity)
                    .background(HYDStyle.good, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button { confirmDelete = true } label: {
                ZStack {
                    if store.isDeleting {
                        ProgressView().tint(HYDStyle.muted)
                    } else {
                        Text("Delete my data").font(.callout.weight(.bold)).multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(HYDStyle.muted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 54)
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(HYDStyle.muted.opacity(0.45), lineWidth: 1.5))
            }
            .accessibilityLabel(store.isDeleting ? "Deleting your data" : "Delete my data")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(store.isDeleting)
    }

    private func failed(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(HYDStyle.muted)
            Text("Couldn't load your report").font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(HYDStyle.text)
            Text(error).font(.callout).foregroundStyle(HYDStyle.muted).multilineTextAlignment(.center)
            Button {
                Task { await store.load(force: true) }
            } label: {
                Text("Retry").font(.callout.weight(.bold)).foregroundStyle(Brand.navy)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(HYDStyle.good, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
    }

    private func openLog() {
        dismiss()
        router.open(Router.HealthSection.log)
    }

    private func deleteAll() async {
        do {
            try await store.deleteEverything()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    #if DEBUG
    private func debugHooks(_ report: ExposureReport, proxy: ScrollViewProxy) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        if let day = value("report-day").flatMap(Int.init) { selectedDay = day }
        if let target = value("report-scroll") {
            try? await Task.sleep(for: .milliseconds(500))
            proxy.scrollTo(target, anchor: .top)
        }
        if args.contains("--report-share") {
            try? await Task.sleep(for: .seconds(1))
            showShare = true
        }
        if args.contains("--report-pdf") {
            do {
                let url = try HYDReportPDF.make(report: report, hidePlaceNames: true, firstName: UserProfile.firstName)
                NSLog("[Report] PDF written to %@", url.path)
            } catch {
                NSLog("[Report] PDF failed: %@", String(describing: error))
            }
        }
    }
    #endif
}

// MARK: - Home summary card

/// The compact report for Home: header, score and trend, the summary sentence and the three tiles.
/// The whole card opens the full report.
struct HowYouDewinSummaryCard: View {
    let report: ExposureReport?
    let isLoading: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            let shown = report ?? MockReport.sample()
            VStack(alignment: .leading, spacing: 14) {
                // Home already greets by name, so the compact card doesn't repeat it.
                HYDHeader(firstName: "", subtitle: "last \(shown.days) days", showsChevron: true)
                VStack(alignment: .leading, spacing: 6) {
                    HYDScore(report: shown, size: 60)
                    Text(shown.summary)
                        .font(.callout)
                        .foregroundStyle(HYDStyle.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HYDTiles(report: shown)
            }
            .redacted(reason: report == nil ? .placeholder : [])
            .overlay {
                if report == nil, isLoading { ProgressView().tint(HYDStyle.text) }
            }
            .hydCard()
            .contentShape(RoundedRectangle(cornerRadius: HYDStyle.cardRadius, style: .continuous))
        }
        .buttonStyle(HYDPressStyle())
        .environment(\.colorScheme, .dark)
        .modifier(HYDPlaceholderLabel(text: report == nil ? (isLoading ? "90-day report, loading" : "90-day report, not ready yet") : nil))
        .accessibilityHint("Opens your 90-day report")
    }
}

// MARK: - Style

private enum HYDStyle {
    /// Dark navy, like the app icon.
    static let page = Brand.navy
    static let card = Color(red: 0x11 / 255, green: 0x15 / 255, blue: 0x27 / 255)
    static let cardStroke = Color.white.opacity(0.11)
    static let cardRadius: CGFloat = 26
    static let tile = Color(red: 0x18 / 255, green: 0x1D / 255, blue: 0x31 / 255)
    static let text = Color(red: 0xF1 / 255, green: 0xF5 / 255, blue: 0xF9 / 255)
    static let muted = Color(red: 0x97 / 255, green: 0x9E / 255, blue: 0xB5 / 255)
    static let track = Color.white.opacity(0.06)
    /// Clean / over on navy.
    static let good = Brand.aqua
    static let bad = Brand.orange

    /// Timeline bars: clean is a dimmed aqua (teal-green on navy), over is full orange.
    static func bar(_ level: ReportLevel) -> Color {
        switch level {
        case .good: good.opacity(0.42)
        case .neutral: Brand.gray.opacity(0.62)
        case .bad: bad
        }
    }
    static let gapStroke = Color.white.opacity(0.28)

    static func dayLabel(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
}

private extension View {
    func hydCard() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HYDStyle.card, in: RoundedRectangle(cornerRadius: HYDStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HYDStyle.cardRadius, style: .continuous)
                .strokeBorder(HYDStyle.cardStroke, lineWidth: 1.5))
    }
}

private struct HYDPlaceholderLabel: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.accessibilityLabel(text) } else { content }
    }
}

private struct HYDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Side by side, or stacked at accessibility text sizes.
private struct HYDAdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout { content }
    }
}

private struct HYDSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.medium))
            .tracking(1.8)
            .foregroundStyle(HYDStyle.muted)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct HYDTag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(HYDStyle.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(HYDStyle.muted.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Card pieces

private struct HYDHeader: View {
    var title = "How you dewin?"
    let firstName: String
    let subtitle: String
    var showsChevron = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("Mark")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(HYDStyle.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if !firstName.isEmpty { Text(firstName) }
                Text(subtitle)
            }
            .font(.caption)
            .foregroundStyle(HYDStyle.muted)
            .multilineTextAlignment(.trailing)
            .fixedSize()
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(HYDStyle.muted)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HYDScore: View {
    let report: ExposureReport
    var size: CGFloat = 80

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                number
                outOf
                trendText
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { number; outOf }
                trendText.padding(.bottom, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var number: some View {
        Text("\(report.score)")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(report.scoreLevel.color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var outOf: some View {
        Text("/ 100").font(.subheadline.weight(.medium)).foregroundStyle(HYDStyle.muted).fixedSize()
    }

    @ViewBuilder private var trendText: some View {
        if let trend {
            Text(trend.text).font(.caption.weight(.semibold)).foregroundStyle(trend.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var period: String { "previous \(report.days) days" }

    private var trend: (text: String, color: Color, spoken: String)? {
        guard let change = report.scoreChange else { return nil }
        if change > 0 { return ("↑ \(change) vs \(period)", HYDStyle.good, "up \(change) from the \(period)") }
        if change < 0 { return ("↓ \(-change) vs \(period)", HYDStyle.bad, "down \(-change) from the \(period)") }
        return ("same as \(period)", HYDStyle.muted, "the same as the \(period)")
    }

    private var accessibilityText: String {
        "Score \(report.score) out of 100" + (trend.map { ", \($0.spoken)" } ?? "")
    }
}

private struct HYDTiles: View {
    let report: ExposureReport

    var body: some View {
        HYDAdaptiveStack(spacing: 8) {
            ForEach(report.overLimit) { HYDTile(item: $0, days: report.days) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HYDTile: View {
    let item: ExposureReport.OverLimit
    let days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(1.4)
                .foregroundStyle(HYDStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(item.days)")
                .font(.system(.title, design: .rounded, weight: .heavy))
                .foregroundStyle(item.level.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if item.estimated == true { HYDTag("estimated") }
            Text("of \(days) days over")
                .font(.caption2)
                .foregroundStyle(HYDStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HYDStyle.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label): \(item.days) of \(days) days over the limit" + (item.estimated == true ? ", estimated" : ""))
    }
}

/// Everything inside the card except the two buttons. `interactive` is false for the PDF.
private struct HYDCardBody: View {
    let report: ExposureReport
    let firstName: String
    var subtitle: String?
    var interactive: Bool
    @Binding var selectedDay: Int?
    var onOpenLog: () -> Void = {}

    @State private var showMethod = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HYDHeader(firstName: firstName, subtitle: subtitle ?? "last \(report.days) days")
                .padding(.bottom, 4)

            HYDScore(report: report)

            Text(report.summary)
                .font(.body)
                .foregroundStyle(HYDStyle.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if interactive, let method = report.scoreMethod {
                Button { showMethod = true } label: {
                    Label("How this is scored", systemImage: "info.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HYDStyle.muted)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .popover(isPresented: $showMethod, arrowEdge: .top) {
                    HYDMethodPopover(method: method, comparison: report.comparisonSource)
                }
            }

            HYDTiles(report: report)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 10) {
                HYDSectionLabel("Timeline")
                HYDTimeline(report: report, interactive: interactive, selected: $selectedDay, onOpenLog: onOpenLog)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                HYDSectionLabel("Your places, worst first")
                ForEach(report.places) { HYDPlaceRow(place: $0) }
            }
            .padding(.top, 24)
            .id("places")

            if !report.actions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HYDSectionLabel("What to do")
                    ForEach(report.actions) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "arrow.right")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(HYDStyle.good)
                                .accessibilityHidden(true)
                            Text(action.text)
                                .font(.callout)
                                .foregroundStyle(HYDStyle.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 24)
                .id("actions")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HYDMethodPopover: View {
    let method: String
    let comparison: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this is scored").font(.system(.headline, design: .rounded))
            Text(method).font(.callout)
            if let comparison { Text(comparison).font(.footnote).foregroundStyle(HYDStyle.muted) }
        }
        .foregroundStyle(HYDStyle.text)
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(HYDStyle.tile)
        .environment(\.colorScheme, .dark)
    }
}

private struct HYDPlaceRow: View {
    let place: ExposureReport.Place
    @ScaledMetric(relativeTo: .callout) private var barWidth: CGFloat = 112

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                (Text(place.name)
                    + (place.verified ? Text(" ") + Text(Image(systemName: "checkmark.seal.fill")).font(.footnote).foregroundStyle(HYDStyle.good) : Text("")))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(HYDStyle.text)
                if let note = place.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(HYDStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(HYDStyle.track)
                    Capsule().fill(place.level.color)
                        .frame(width: max(proxy.size.height * 1.6, proxy.size.width * min(max(place.share, 0), 1)))
                }
            }
            .frame(width: min(barWidth, 150), height: 10)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [place.name]
        if let note = place.note, !note.isEmpty { parts.append(note) }
        parts.append(place.level.label)
        if place.verified { parts.append("measured by a Dewin sensor") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Timeline

private struct HYDTimeline: View {
    let report: ExposureReport
    let interactive: Bool
    @Binding var selected: Int?
    let onOpenLog: () -> Void

    @ScaledMetric(relativeTo: .caption2) private var calloutSize: CGFloat = 10.5

    private var timeline: [ExposureReport.TimelineDay] { report.timeline }

    /// At most four callouts, oldest first, each at its day's bar.
    private var callouts: [HYDCallout] {
        let calendar = Calendar.current
        let count = max(timeline.count, 1)
        return report.spikes.sorted { $0.date < $1.date }.prefix(4).map { spike in
            let index = timeline.firstIndex { calendar.isDate($0.date, inSameDayAs: spike.date) }
                ?? Int((spike.date.timeIntervalSince(report.from) / max(report.to.timeIntervalSince(report.from), 1)) * Double(count - 1))
            return HYDCallout(spike: spike, fraction: (CGFloat(min(max(index, 0), count - 1)) + 0.5) / CGFloat(count))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            graphic
            legend
            if interactive, let index = selected, timeline.indices.contains(index) {
                caption(for: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline, last \(timeline.count) days")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(interactive ? "Swipe up or down to step through the days." : "")
        .accessibilityAdjustableAction { direction in
            guard interactive, !timeline.isEmpty else { return }
            switch direction {
            case .increment: selected = min(timeline.count - 1, (selected ?? -1) + 1)
            case .decrement: selected = max(0, (selected ?? timeline.count) - 1)
            @unknown default: break
            }
        }
        .accessibilityActions {
            if interactive, let index = selected, isRecent(index) {
                Button("Open in Health log", action: onOpenLog)
            }
        }
    }

    private var graphic: some View {
        let callouts = callouts
        let size = min(calloutSize, 14)
        return HYDCalloutLayout(fractions: callouts.map(\.fraction), stripHeight: 26) {
            HYDStrip(timeline: timeline, selected: interactive ? selected : nil)
                .overlay {
                    if interactive {
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard !timeline.isEmpty, proxy.size.width > 0 else { return }
                                    let index = min(timeline.count - 1,
                                                    max(0, Int(location.x / proxy.size.width * CGFloat(timeline.count))))
                                    selected = selected == index ? nil : index
                                }
                        }
                    }
                }
            ForEach(callouts) { callout in
                Text("\(HYDStyle.dayLabel(callout.spike.date)) · \(callout.spike.label)")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(HYDStyle.text.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
            }
            ForEach(callouts) { _ in
                Rectangle().fill(HYDStyle.muted.opacity(0.75))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("clean", HYDStyle.bar(.good))
            legendItem("mixed", HYDStyle.bar(.neutral))
            legendItem("over", HYDStyle.bar(.bad))
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).strokeBorder(HYDStyle.gapStroke, lineWidth: 1).frame(width: 6, height: 10)
                Text("no data")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(HYDStyle.muted)
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 6, height: 10)
            Text(text)
        }
    }

    private func state(_ day: ExposureReport.TimelineDay) -> (text: String, color: Color) {
        if day.isGap { return ("no data", HYDStyle.muted) }
        switch day.level {
        case .good: return ("clean", HYDStyle.good)
        case .neutral: return ("mixed", HYDStyle.text)
        case .bad: return ("over the limit", HYDStyle.bad)
        }
    }

    private func isRecent(_ index: Int) -> Bool {
        guard timeline.indices.contains(index) else { return false }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: timeline[index].date),
                                           to: calendar.startOfDay(for: .now)).day ?? .max
        return days < 7
    }

    private func caption(for index: Int) -> some View {
        let day = timeline[index]
        let state = state(day)
        let spike = report.spikes.first { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(HYDStyle.dayLabel(day.date)) · \(state.text)" + (spike.map { " · \($0.label)" } ?? ""))
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.color)
            Spacer(minLength: 0)
            if isRecent(index) {
                Button("Open in Health log", action: onOpenLog)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HYDStyle.good)
                    .buttonStyle(.plain)
            }
        }
    }

    private var accessibilityValue: String {
        if interactive, let index = selected, timeline.indices.contains(index) {
            let day = timeline[index]
            return "\(day.date.formatted(.dateTime.month(.wide).day())), \(state(day).text)"
        }
        let gaps = timeline.filter(\.isGap).count
        let measured = timeline.filter { !$0.isGap }
        let clean = measured.filter { $0.level == .good }.count
        let mixed = measured.filter { $0.level == .neutral }.count
        let over = measured.filter { $0.level == .bad }.count
        var text = "\(clean) clean days, \(mixed) mixed, \(over) over the limit, \(gaps) with no data."
        if !report.spikes.isEmpty {
            text += " Spikes: " + report.spikes.sorted { $0.date < $1.date }
                .map { "\($0.date.formatted(.dateTime.month(.wide).day())), \($0.label)" }
                .joined(separator: "; ") + "."
        }
        return text
    }
}

private struct HYDCallout: Identifiable {
    let spike: ExposureReport.Spike
    let fraction: CGFloat
    var id: Date { spike.id }
}

/// One thin bar per day. Gaps (no data) are hollow; the selected day gets a white outline.
private struct HYDStrip: View {
    let timeline: [ExposureReport.TimelineDay]
    let selected: Int?

    var body: some View {
        Canvas { context, size in
            guard !timeline.isEmpty else { return }
            let pitch = size.width / CGFloat(timeline.count)
            let width = max(1, pitch * 0.58)
            let inset: CGFloat = 2
            for (index, day) in timeline.enumerated() {
                let rect = CGRect(x: CGFloat(index) * pitch + (pitch - width) / 2, y: inset,
                                  width: width, height: size.height - inset * 2)
                if day.isGap {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), cornerRadius: 0.8),
                                   with: .color(HYDStyle.gapStroke), lineWidth: 0.8)
                } else {
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1, width / 2)),
                                 with: .color(HYDStyle.bar(day.level)))
                }
            }
            if let selected, timeline.indices.contains(selected) {
                let rect = CGRect(x: CGFloat(selected) * pitch - 1, y: 0.75, width: pitch + 2, height: size.height - 1.5)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(HYDStyle.text), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Lays out the strip (first subview) at the bottom, then `n` callout labels, then `n` leader lines.
/// Labels are stacked in rows above the strip so none overlap and no leader line runs through a label.
private struct HYDCalloutLayout: Layout {
    /// Each callout's day, as a fraction of the width (the bar's center).
    var fractions: [CGFloat]
    var stripHeight: CGFloat
    var poleGap: CGFloat = 7
    var rowSpacing: CGFloat = 4

    struct Plan {
        var width: CGFloat
        var rows: [Int]
        var minX: [CGFloat]
        var rowCount: Int
        var labelHeight: CGFloat
    }

    func makeCache(subviews: Subviews) -> Plan? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Plan?) -> CGSize {
        let width = proposal.width ?? 320
        let plan = plan(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: height(plan))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Plan?) {
        guard let strip = subviews.first else { return }
        let plan = plan(width: bounds.width, subviews: subviews, cache: &cache)
        let stripTop = bounds.maxY - stripHeight
        strip.place(at: CGPoint(x: bounds.minX, y: stripTop), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: stripHeight))
        let n = count(subviews)
        for i in 0..<n {
            let labelBottom = stripTop - poleGap - CGFloat(plan.rows[i]) * (plan.labelHeight + rowSpacing)
            let labelTop = labelBottom - plan.labelHeight
            subviews[1 + i].place(at: CGPoint(x: bounds.minX + plan.minX[i], y: labelTop), anchor: .topLeading,
                                  proposal: .unspecified)
            let x = bounds.minX + fractions[i] * bounds.width
            let poleTop = labelBottom + 1.5
            subviews[1 + n + i].place(at: CGPoint(x: x - 0.5, y: poleTop), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: 1, height: max(0, stripTop - poleTop)))
        }
    }

    private func count(_ subviews: Subviews) -> Int { min(fractions.count, max(0, (subviews.count - 1) / 2)) }

    private func height(_ plan: Plan) -> CGFloat {
        guard plan.rowCount > 0 else { return stripHeight }
        return stripHeight + poleGap + CGFloat(plan.rowCount) * plan.labelHeight + CGFloat(plan.rowCount - 1) * rowSpacing
    }

    private func plan(width: CGFloat, subviews: Subviews, cache: inout Plan?) -> Plan {
        if let cache, cache.width == width { return cache }
        let n = count(subviews)
        let sizes = (0..<n).map { subviews[1 + $0].sizeThatFits(.unspecified) }
        let plan = Self.solve(width: width, xs: fractions.prefix(n).map { $0 * width }, sizes: sizes)
        cache = plan
        return plan
    }

    /// Tries every row and alignment (centered, flag to the right, flag to the left) for up to four
    /// labels and keeps the one with no collisions and the fewest rows.
    static func solve(width: CGFloat, xs: [CGFloat], sizes: [CGSize]) -> Plan {
        let n = xs.count
        let labelHeight = sizes.map(\.height).max() ?? 0
        guard n > 0 else { return Plan(width: width, rows: [], minX: [], rowCount: 0, labelHeight: 0) }
        func clamp(_ minX: CGFloat, _ w: CGFloat) -> CGFloat { min(max(0, minX), max(0, width - w)) }
        let options: [[CGFloat]] = (0..<n).map { i in
            let w = sizes[i].width, x = xs[i]
            var result = [clamp(x - w / 2, w)]
            if x - 2 + w <= width { result.append(max(0, x - 2)) }
            if x + 2 - w >= 0 { result.append(min(width - w, x + 2 - w)) }
            return result
        }
        var rows = [Int](repeating: 0, count: n), choice = [Int](repeating: 0, count: n)
        var best: (score: Int, rows: [Int], choice: [Int])?

        func score() -> Int {
            var collisions = 0
            for i in 0..<n {
                let a0 = options[i][choice[i]], a1 = a0 + sizes[i].width
                for j in 0..<n where j != i {
                    // Label j's leader line runs down through every row below it.
                    if rows[j] > rows[i], xs[j] > a0 - 4, xs[j] < a1 + 4 { collisions += 1 }
                    if j > i, rows[j] == rows[i] {
                        let b0 = options[j][choice[j]], b1 = b0 + sizes[j].width
                        if a0 < b1 + 10, b0 < a1 + 10 { collisions += 1 }
                    }
                }
            }
            return collisions * 1000 + ((rows.max() ?? 0) + 1) * 10 + choice.reduce(0, +)
        }

        func search(_ i: Int) {
            if i == n {
                let s = score()
                if best == nil || s < best!.score { best = (s, rows, choice) }
                return
            }
            for row in 0..<n {
                for option in options[i].indices {
                    rows[i] = row
                    choice[i] = option
                    search(i + 1)
                }
            }
        }
        search(0)

        let chosen = best!
        return Plan(width: width, rows: chosen.rows,
                    minX: (0..<n).map { options[$0][chosen.choice[$0]] },
                    rowCount: (chosen.rows.max() ?? 0) + 1, labelHeight: labelHeight)
    }
}

// MARK: - For your doctor

private struct HYDDoctorSection: View {
    let report: ExposureReport
    let firstName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HYDStyle.good)
                    .accessibilityHidden(true)
                Text("For your doctor")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(HYDStyle.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if !firstName.isEmpty { Text(firstName) }
                    Text(report.rangeLabel)
                }
                .font(.caption)
                .foregroundStyle(HYDStyle.muted)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 12) {
                HYDSectionLabel("Exposures, \(report.days)-day average")
                exposureTable
            }

            if let sentence = report.bodySentence {
                VStack(alignment: .leading, spacing: 6) {
                    HYDSectionLabel("Your body on bad days")
                    Text(sentence)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HYDStyle.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let device = report.body?.device {
                        Text("From your \(device)").font(.caption2).foregroundStyle(HYDStyle.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if report.scoreMethod != nil || report.comparisonSource != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HYDSectionLabel("How this is scored")
                    if let method = report.scoreMethod {
                        Text(method).font(.footnote).foregroundStyle(HYDStyle.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let comparison = report.comparisonSource {
                        Text(comparison).font(.footnote).foregroundStyle(HYDStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(report.sources.text)
                Text(report.sources.estimatedNote)
            }
            .font(.caption2)
            .foregroundStyle(HYDStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exposureTable: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Measure")
                Text("Your avg")
                Text("Safe limit")
                Text("Worst day")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(HYDStyle.muted)
            .accessibilityHidden(true)

            ForEach(report.exposures) { exposure in
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                GridRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exposure.label).font(.footnote.weight(.medium)).foregroundStyle(HYDStyle.text)
                        if !exposure.unit.isEmpty {
                            Text(exposure.unit).font(.caption2).foregroundStyle(HYDStyle.muted)
                        }
                        if exposure.estimated == true { HYDTag("estimated") }
                    }
                    .accessibilityElement(children: .combine)

                    Text(HYDStyle.number(exposure.average))
                        .font(.system(.footnote, design: .rounded, weight: .bold))
                        .foregroundStyle(exposure.withinLimit ? HYDStyle.text : HYDStyle.bad)
                        .accessibilityLabel("average \(HYDStyle.number(exposure.average)) \(exposure.unit)"
                                            + (exposure.withinLimit ? "" : ", over the safe limit"))

                    Text(exposure.limit)
                        .font(.footnote)
                        .foregroundStyle(HYDStyle.muted)
                        .accessibilityLabel("safe limit \(exposure.limit)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(HYDStyle.number(exposure.worst)).font(.footnote.weight(.semibold)).foregroundStyle(HYDStyle.text)
                        if let date = exposure.worstDate {
                            Text(HYDStyle.dayLabel(date)).font(.caption2).foregroundStyle(HYDStyle.muted)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("worst \(HYDStyle.number(exposure.worst))"
                                        + (exposure.worstDate.map { " on \($0.formatted(.dateTime.month(.wide).day()))" } ?? ""))
                }
            }
        }
    }
}

// MARK: - Share with my doctor

private struct HYDShareSheet: View {
    let report: ExposureReport
    let firstName: String

    @Environment(\.dismiss) private var dismiss
    @State private var hidePlaceNames = true
    @State private var file: HYDPDFFile?
    @State private var error: String?

    private var shownPlaces: [ExposureReport.Place] {
        (hidePlaceNames ? report.hydHidingPlaceNames() : report).places
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Makes a PDF of this report for your doctor: your score, the timeline, your places and the exposure table with safe limits. Nothing is sent until you choose where it goes.")
                        .font(.callout)
                        .foregroundStyle(HYDStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $hidePlaceNames) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Hide place names").font(.body.weight(.semibold)).foregroundStyle(HYDStyle.text)
                            Text("Shows Place 1, Place 2… instead of names, and leaves out notes that name a place.")
                                .font(.footnote)
                                .foregroundStyle(HYDStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(HYDStyle.good)
                    .padding(16)
                    .background(HYDStyle.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        HYDSectionLabel("Places in the PDF")
                        ForEach(shownPlaces) { place in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(place.level.color).frame(width: 7, height: 7)
                                Text(place.name).font(.callout).foregroundStyle(HYDStyle.text)
                                if let note = place.note {
                                    Text(note).font(.caption).foregroundStyle(HYDStyle.muted).lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    Button(action: create) {
                        Label("Create PDF", systemImage: "doc.richtext")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Brand.navy)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(HYDStyle.good, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(HYDStyle.bad)
                    }
                }
                .padding(20)
            }
            .background(HYDStyle.page.ignoresSafeArea())
            .navigationTitle("Share with my doctor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(HYDStyle.text)
                }
            }
            .toolbarBackground(HYDStyle.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(HYDStyle.page)
        .sheet(item: $file) { file in
            HYDActivityView(items: [file.url]) { completed in
                self.file = nil
                if completed { dismiss() }
            }
            .ignoresSafeArea()
            .presentationDetents([.medium, .large])
        }
    }

    private func create() {
        do {
            error = nil
            file = HYDPDFFile(url: try HYDReportPDF.make(report: report, hidePlaceNames: hidePlaceNames, firstName: firstName))
        } catch {
            self.error = "Couldn't make the PDF. \(error.localizedDescription)"
        }
    }
}

private struct HYDPDFFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct HYDActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - PDF

/// Renders the report for a doctor: page 1 is the card (without buttons), page 2 the doctor section.
@MainActor
enum HYDReportPDF {
    static let fileName = "Dewin-90-day-report.pdf"
    static let pageWidth: CGFloat = 420

    struct Failure: LocalizedError {
        var errorDescription: String? { "The PDF couldn't be written." }
    }

    static func make(report: ExposureReport, hidePlaceNames: Bool, firstName: String) throws -> URL {
        let shown = hidePlaceNames ? report.hydHidingPlaceNames() : report
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        var box = CGRect(x: 0, y: 0, width: pageWidth, height: 800)
        let info: [String: Any] = [kCGPDFContextTitle as String: "How you dewin? \(report.days)-day report",
                                   kCGPDFContextCreator as String: "Dewin"]
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw Failure() }

        let pages: [HYDPrintPage.Kind] = [.card, .doctor]
        for (index, kind) in pages.enumerated() {
            let renderer = ImageRenderer(content: HYDPrintPage(report: shown, firstName: firstName, kind: kind,
                                                               page: index + 1, of: pages.count))
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
            renderer.render { size, draw in
                var media = CGRect(origin: .zero, size: size)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
                pdf.beginPDFPage(pageInfo as CFDictionary)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure() }
        return url
    }
}

private struct HYDPrintPage: View {
    enum Kind { case card, doctor }

    let report: ExposureReport
    let firstName: String
    let kind: Kind
    let page: Int
    let of: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case .card:
                HYDCardBody(report: report, firstName: firstName, subtitle: report.rangeLabel,
                            interactive: false, selectedDay: .constant(nil))
                    .hydCard()
            case .doctor:
                HYDDoctorSection(report: report, firstName: firstName).hydCard()
            }
            HStack(alignment: .center) {
                Image("Wordmark").resizable().scaledToFit().frame(height: 18)
                Spacer()
                Text("Made \(Date.now.formatted(date: .abbreviated, time: .omitted)) · page \(page) of \(of)")
                    .font(.caption2)
                    .foregroundStyle(HYDStyle.muted)
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: HYDReportPDF.pageWidth)
        .background(HYDStyle.page)
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }
}

// MARK: - Hiding place names

private extension ExposureReport {
    /// For the doctor's PDF: "Place 1", "Place 2"… instead of names. Notes, spike labels and actions
    /// that still name a place are left out.
    func hydHidingPlaceNames() -> ExposureReport {
        var copy = self
        let names = Set(places.flatMap { Self.hydProperWords($0.name) })
        func namesPlace(_ text: String) -> Bool { !names.isDisjoint(with: Self.hydProperWords(text)) }
        func replacingNames(_ text: String) -> String {
            places.enumerated().reduce(text) { result, item in
                result.replacingOccurrences(of: item.element.name, with: "Place \(item.offset + 1)")
            }
        }
        copy.places = places.enumerated().map { index, place in
            var place = place
            place.name = "Place \(index + 1)"
            if let note = place.note, namesPlace(note) { place.note = nil }
            return place
        }
        copy.spikes = spikes.map { spike in
            var spike = spike
            spike.label = replacingNames(spike.label)
            if namesPlace(spike.label) { spike.label = "spike" }
            return spike
        }
        copy.actions = actions.compactMap { action in
            var action = action
            action.text = replacingNames(action.text)
            return namesPlace(action.text) ? nil : action
        }
        return copy
    }

    /// Capitalized words of three or more letters: the part of a place name that identifies it.
    static func hydProperWords(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’") }
            .map(String.init)
            .filter { $0.count >= 3 && ($0.first?.isUppercase ?? false) }
    }
}
