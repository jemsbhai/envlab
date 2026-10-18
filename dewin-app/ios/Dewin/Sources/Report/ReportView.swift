import SwiftUI
import UIKit

/// The 90-day "How you dewin?" report: one dark navy page, read top to bottom by the person and
/// by their doctor. Shown in a full-screen cover (RootView wraps it in a NavigationStack).
struct ReportView: View {
    @Environment(ReportStore.self) private var report
    @Environment(\.dismiss) private var dismiss

    @State private var shareFile: ReportShareFile?
    @State private var isRenderingPDF = false
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var pdfFailed = false

    var body: some View {
        Group {
            if let data = report.report {
                ScrollView {
                    VStack(spacing: 0) {
                        ReportContent(report: data, firstName: UserProfile.firstName, isPDF: false)
                        footerButtons
                            .padding(.horizontal, 20)
                            .padding(.bottom, 28)
                    }
                }
                .refreshable { await report.load(force: true) }
            } else if let error = report.error, !report.isLoading {
                errorState(error)
            } else {
                loadingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.navy.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.navy, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityLabel("Close")
            }
        }
        // The store keeps the report for the life of the app; fetch again once it no longer ends today.
        .task { await report.load(force: isStale) }
        .sheet(item: $shareFile, onDismiss: removePDF) { file in
            ReportActivitySheet(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("Delete all your Dewin data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                Task { await deleteEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your meals, photos and readings on this phone and on the Dewin server. It can't be undone.")
        }
        .alert("Couldn't delete your data", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Couldn't make the PDF", isPresented: $pdfFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again in a moment.")
        }
    }

    /// The report ends before yesterday (it was loaded on an earlier day and kept in memory).
    private var isStale: Bool {
        guard let to = report.report?.to else { return false }
        let calendar = Calendar.current
        return !calendar.isDateInToday(to) && !calendar.isDateInYesterday(to)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Brand.aqua)
            Text("Putting your 90 days together…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load your report", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await report.load(force: true) } }
                .buttonStyle(.borderedProminent)
                .tint(Brand.aqua)
                .foregroundStyle(Brand.navy)
        }
    }

    // MARK: Footer buttons (not in the PDF)

    private var footerButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await sharePDF() }
            } label: {
                HStack(spacing: 8) {
                    if isRenderingPDF {
                        ProgressView().tint(Brand.navy)
                    } else {
                        Image(systemName: "stethoscope")
                    }
                    Text("Share with my doctor")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Brand.navy)
                .background(Brand.aqua, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRenderingPDF || report.isDeleting)
            .accessibilityHint("Makes a PDF of this report to send")

            Button {
                confirmDelete = true
            } label: {
                HStack(spacing: 8) {
                    if report.isDeleting {
                        ProgressView().tint(.red)
                        Text("Deleting…")
                    } else {
                        Image(systemName: "trash")
                        Text("Delete my data")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Color.red)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.red.opacity(0.45), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(report.isDeleting)
        }
    }

    // MARK: Actions

    /// Renders the report (without these buttons) to one long PDF page and opens the share sheet.
    @MainActor
    private func sharePDF() async {
        isRenderingPDF = true
        defer { isRenderingPDF = false }
        if isStale { await report.load(force: true) }
        guard let data = report.report else { return }
        // Let the spinner draw before the (synchronous) render.
        try? await Task.sleep(for: .milliseconds(50))

        let page = ReportContent(report: data, firstName: UserProfile.firstName, isPDF: true)
            .frame(width: 390)
            .background(Brand.navy)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)

        let url = Self.pdfURL
        removePDF()
        var rendered = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            rendered = true
        }
        if rendered {
            shareFile = ReportShareFile(url: url)
        } else {
            NSLog("[Report] PDF render failed")
            pdfFailed = true
        }
    }

    private static let pdfURL = FileManager.default.temporaryDirectory.appending(path: "Dewin-90-day-report.pdf")

    /// The PDF is a full copy of the report: don't leave it on the phone after sharing or deleting.
    private func removePDF() {
        try? FileManager.default.removeItem(at: Self.pdfURL)
    }

    private func deleteEverything() async {
        removePDF()
        do {
            try await report.deleteEverything()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - The page (shared by the screen and the PDF)

/// Everything above the footer buttons. Also rendered to the PDF for "Share with my doctor".
private struct ReportContent: View {
    let report: ExposureReport
    let firstName: String
    /// The PDF is read away from the app (and maybe next year): it carries the year and the date it
    /// was made, and shows "How this is scored" open.
    let isPDF: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ReportHeader(report: report, firstName: firstName, isPDF: isPDF)
            ReportScoreCard(report: report, isPDF: isPDF)
            if !report.overLimit.isEmpty {
                ReportSection(title: "Days over the limit") {
                    ReportOverLimitRow(items: report.overLimit, totalDays: report.days)
                }
            }
            ReportSection(title: "Your 90 days") {
                ReportTimeline(report: report)
            }
            if !report.places.isEmpty {
                ReportSection(title: "Your places, ranked", subtitle: "Worst first") {
                    ReportPlaces(places: report.places)
                }
            }
            if !report.exposures.isEmpty {
                ReportSection(title: "What you were exposed to", subtitle: "For your doctor") {
                    ReportExposureTable(exposures: report.exposures)
                }
            }
            if let sentence = report.bodySentence {
                ReportSection(title: "Your body on bad days") {
                    ReportBodyCard(sentence: sentence, device: report.body?.device)
                }
            }
            if !report.actions.isEmpty {
                ReportSection(title: "What to do about it") {
                    ReportActions(actions: report.actions)
                }
            }
            ReportSources(sources: report.sources, hasEstimates: report.hasEstimates)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .foregroundStyle(.white)
    }
}

// MARK: 1. Header

private struct ReportHeader: View {
    let report: ExposureReport
    let firstName: String
    let isPDF: Bool

    /// "Jul 21 – Oct 18" on screen (as specified); with the year in the PDF.
    private var range: String {
        guard isPDF else { return report.rangeLabel }
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: report.from) == calendar.component(.year, from: report.to)
        let from = sameYear ? report.from.formatted(.dateTime.month(.abbreviated).day())
                            : report.from.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(from) – \(report.to.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image("Mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                Image("Wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dewin")

            VStack(alignment: .leading, spacing: 4) {
                Text("How you dewin?")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if !firstName.isEmpty {
                    Text(firstName)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(Brand.sky)
                }
                Text("Last \(report.days) days · \(range)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isPDF {
                    Text("Made by Dewin on \(Date.now.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 2. Score

private struct ReportScoreCard: View {
    let report: ExposureReport
    let isPDF: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 80
    @State private var showMethod = false

    private var level: ReportLevel { report.scoreLevel }
    private var verdict: String { level == .good ? "Good" : "Needs attention" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                // The number never wraps: the pill, then "/ 100", move down a line when space runs out.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        number
                        outOf
                        Spacer(minLength: 8)
                        pill.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 8 }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) { number; outOf }
                        pill
                    }
                    VStack(alignment: .leading, spacing: 8) { number; outOf; pill }
                }
                if let change = report.scoreChange {
                    ReportScoreTrend(change: change, days: report.days)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)

            ReportScoreGauge(score: report.score, level: level)

            Text(report.summary)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            if let source = report.comparisonSource, !source.isEmpty {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let method = report.scoreMethod, !method.isEmpty {
                Divider().overlay(.white.opacity(0.08))
                if isPDF {
                    // DisclosureGroup doesn't belong on paper: always open there.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How this is scored")
                            .font(.subheadline.weight(.semibold))
                        methodText(method)
                    }
                } else {
                    DisclosureGroup(isExpanded: $showMethod) {
                        methodText(method)
                            .padding(.top, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("How this is scored")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(.white.opacity(0.6))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A soft wash of the score's color. Linear, not radial: it also has to survive the PDF.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [level.color.opacity(0.2), Brand.navyRaised, Brand.navyRaised],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var number: some View {
        // Capped so "100" plus "/ 100" still fits a phone at the largest text sizes.
        Text("\(report.score)")
            .font(.system(size: min(scoreSize, 120), weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(level.color)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
    }

    private var outOf: some View {
        Text("/ 100")
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var pill: some View {
        ReportLevelPill(text: verdict, level: level).fixedSize()
    }

    private func methodText(_ method: String) -> some View {
        Text(method)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        var label = "Score \(report.score) out of 100, \(verdict.lowercased())"
        if let change = report.scoreChange, let previous = report.previousScore {
            label += change == 0 ? ". Same as the previous \(report.days) days"
                : ". \(change > 0 ? "Up" : "Down") \(abs(change)) from \(previous) in the previous \(report.days) days"
        }
        return label
    }
}

/// "↓ 6 vs previous 90 days": orange when the score fell, aqua when it rose.
private struct ReportScoreTrend: View {
    let change: Int
    let days: Int

    private var level: ReportLevel { change > 0 ? .good : change < 0 ? .bad : .neutral }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: change > 0 ? "arrow.up" : change < 0 ? "arrow.down" : "equal")
                .font(.footnote.weight(.bold))
            Text(change == 0 ? "Same as" : "\(abs(change))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(change == 0 ? "the previous \(days) days" : "vs previous \(days) days")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(change == 0 ? .white.opacity(0.8) : level.color)
    }
}

/// 0–100 track with a notch where "good" starts (70).
private struct ReportScoreGauge: View {
    let score: Int
    let level: ReportLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let fill = width * CGFloat(min(max(score, 0), 100)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(level.color).frame(width: max(fill, 6))
                    Rectangle()
                        .fill(Brand.navyRaised)
                        .frame(width: 3)
                        .offset(x: width * 0.7 - 1.5)
                }
            }
            .frame(height: 8)

            GeometryReader { geo in
                Text("Good from 70")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - geo.size.width * 0.7 }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 14)
        }
        .accessibilityHidden(true)
    }
}

// MARK: 3. Days over the limit

private struct ReportOverLimitRow: View {
    let items: [ExposureReport.OverLimit]
    let totalDays: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            ForEach(items) { item in
                ReportOverLimitTile(item: item, totalDays: totalDays)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReportOverLimitTile: View {
    let item: ExposureReport.OverLimit
    let totalDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(item.level.color)
                .frame(width: 22, height: 4)
                .padding(.bottom, 6)
            Text(item.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if item.estimated == true {
                ReportEstimatedTag()
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(item.days)")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(item.level.color)
                Image(systemName: ReportLevelPill.symbol(for: item.level))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(item.level.color)
            }
            Text("of \(totalDays) days")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The color marks scan at a glance; the icon and number carry the same meaning.
        .background(Brand.navyRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label)\(item.estimated == true ? ", estimated from public data" : ""): "
                            + "over the limit on \(item.days) of \(totalDays) days")
    }
}

// MARK: 4. Timeline

private struct ReportTimeline: View {
    let report: ExposureReport
    @ScaledMetric(relativeTo: .caption2) private var tickHeight: CGFloat = 18

    private let pinSize: CGFloat = 18
    private let stripHeight: CGFloat = 46

    /// Spikes with their block index, in date order, numbered 1…n.
    private var pins: [(number: Int, index: Int, spike: ExposureReport.Spike)] {
        report.spikes.sorted { $0.date < $1.date }.enumerated().map { offset, spike in
            (offset + 1, index(of: spike.date), spike)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.timeline.isEmpty {
                Text("No readings yet. Your timeline fills in as Dewin collects them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                chart
                legend
                if report.gapDays > 0 {
                    Text("\(report.gapDays) \(report.gapDays == 1 ? "day" : "days") with no readings (phone off or no sensor nearby).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !pins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(pins, id: \.number) { pin in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                ReportPin(number: pin.number, size: pinSize)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                (Text(pin.spike.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .fontWeight(.semibold)
                                 + Text(" · \(pin.spike.label)").foregroundColor(.white.opacity(0.8)))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.navyRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var chart: some View {
        let rows = pinRows
        let pinZone = pinSize * CGFloat((rows.values.max() ?? 0) + 1) + CGFloat(rows.values.max() ?? 0) * 4 + 10
        return GeometryReader { geo in
            let geometry = ReportStripGeometry(count: report.timeline.count, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                // Pins with a leader line down to their day.
                ForEach(pins, id: \.number) { pin in
                    let x = geometry.center(of: pin.index)
                    let row = CGFloat(rows[pin.number] ?? 0)
                    let top = pinZone - pinSize - row * (pinSize + 4) - 4
                    Rectangle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 1, height: pinZone - top - pinSize / 2)
                        .position(x: x, y: top + pinSize / 2 + (pinZone - top - pinSize / 2) / 2)
                    ReportPin(number: pin.number, size: pinSize)
                        .position(x: x, y: top + pinSize / 2)
                }

                Canvas { context, size in
                    for (index, day) in report.timeline.enumerated() {
                        // A day with no data is a faint stub, never a level color: a gap isn't "clean".
                        let height = size.height * (day.isGap ? Self.gapFraction : Self.heightFraction(day.level))
                        let rect = CGRect(x: geometry.minX(of: index), y: size.height - height,
                                          width: geometry.blockWidth, height: height)
                        let block = Path(roundedRect: rect, cornerRadius: min(geometry.blockWidth / 2, 1.5))
                        if day.isGap {
                            // Outlined like the "No data" legend swatch.
                            context.stroke(Path(rect.insetBy(dx: 0.4, dy: 0.4)), with: .color(Self.gapColor), lineWidth: 0.8)
                        } else {
                            context.fill(block, with: .color(day.level.color))
                        }
                    }
                }
                .frame(height: stripHeight)
                .offset(y: pinZone)

                // Month ticks under the strip.
                ForEach(monthStarts, id: \.index) { tick in
                    let x = geometry.minX(of: tick.index)
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(width: 1, height: 5)
                        .position(x: x, y: pinZone + stripHeight + 4)
                    Text(tick.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in -x }
                        .offset(y: pinZone + stripHeight + 7)
                }
            }
        }
        .frame(height: pinZone + stripHeight + 8 + tickHeight)
    }

    private var legendItems: [(label: String, color: Color)] {
        var items: [(label: String, color: Color)] = [("Clean", Brand.aqua), ("Mixed", Brand.gray), ("Bad day", Brand.orange)]
        if report.gapDays > 0 { items.append(("No data", Self.gapColor)) }
        return items
    }

    private var legend: some View {
        // One row when it fits, otherwise two columns.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(legendItems, id: \.label) { legendItem($0.label, $0.color, isGap: $0.label == "No data") }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: legendItems.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(legendItems[start..<min(start + 2, legendItems.count)], id: \.label) {
                            legendItem($0.label, $0.color, isGap: $0.label == "No data")
                        }
                    }
                }
            }
        }
    }

    private func legendItem(_ label: String, _ color: Color, isGap: Bool = false) -> some View {
        HStack(spacing: 5) {
            // "No data" is an outline so it can't be mistaken for the gray "Mixed".
            RoundedRectangle(cornerRadius: 2)
                .fill(isGap ? Color.clear : color)
                .strokeBorder(isGap ? Self.gapColor : .clear, lineWidth: 1)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    static let gapFraction: CGFloat = 0.18
    static let gapColor = Color.white.opacity(0.45)

    /// Taller blocks for worse days, so the bad days read as spikes.
    static func heightFraction(_ level: ReportLevel) -> CGFloat {
        switch level {
        case .good: 0.4
        case .neutral: 0.62
        case .bad: 1
        }
    }

    /// Puts each pin in the lowest row where it doesn't overlap the last pin there (pins closer
    /// than about 22 pt on the narrowest strip, ~300 pt wide), adding a row when none is free.
    private var pinRows: [Int: Int] {
        let closeDays = Double(report.timeline.count) * Double(pinSize + 4) / 300
        var rows: [Int: Int] = [:]
        var lastIndexInRow: [Int] = []
        for pin in pins {
            let row = lastIndexInRow.firstIndex { Double(pin.index - $0) >= closeDays } ?? lastIndexInRow.count
            if row == lastIndexInRow.count { lastIndexInRow.append(pin.index) } else { lastIndexInRow[row] = pin.index }
            rows[pin.number] = row
        }
        return rows
    }

    private var monthStarts: [(index: Int, label: String)] {
        let calendar = Calendar.current
        return report.timeline.enumerated().compactMap { index, day in
            // Skip a month that starts in the last few days: its label would run off the edge.
            guard calendar.component(.day, from: day.date) == 1, index < report.timeline.count - 6 else { return nil }
            return (index, day.date.formatted(.dateTime.month(.abbreviated)))
        }
    }

    private func index(of date: Date) -> Int {
        let calendar = Calendar.current
        if let match = report.timeline.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            return match
        }
        // Not in the timeline: place it by date across the range.
        let span = report.to.timeIntervalSince(report.from)
        let fraction = span > 0 ? date.timeIntervalSince(report.from) / span : 0
        return Int((Double(max(report.timeline.count - 1, 0)) * min(max(fraction, 0), 1)).rounded())
    }

    private var accessibilitySummary: String {
        guard !report.timeline.isEmpty else { return "\(report.days)-day timeline: no readings yet" }
        let bad = report.timeline.filter { !$0.isGap && $0.level == .bad }.count
        var label = "\(report.timeline.count)-day timeline: \(bad) bad days"
        if report.gapDays > 0 { label += ", \(report.gapDays) days with no data" }
        if !pins.isEmpty {
            let spikes = pins.map { "\($0.spike.date.formatted(.dateTime.month(.wide).day())) \($0.spike.label)" }
            label += ", spikes on " + spikes.joined(separator: ", ")
        }
        return label
    }
}

/// Block positions for the timeline strip, shared by the blocks, pins and ticks.
private struct ReportStripGeometry {
    let count: Int
    let width: CGFloat

    var gap: CGFloat { count > 60 ? 1 : 2 }
    var blockWidth: CGFloat {
        guard count > 0 else { return 0 }
        return max((width - gap * CGFloat(count - 1)) / CGFloat(count), 0.5)
    }

    func minX(of index: Int) -> CGFloat { CGFloat(index) * (blockWidth + gap) }
    func center(of index: Int) -> CGFloat { minX(of: index) + blockWidth / 2 }
}

private struct ReportPin: View {
    let number: Int
    let size: CGFloat

    var body: some View {
        Text("\(number)")
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(Brand.navy)
            .frame(width: size, height: size)
            .background(.white, in: Circle())
    }
}

// MARK: 5. Places

private struct ReportPlaces: View {
    let places: [ExposureReport.Place]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { offset, place in
                if offset > 0 {
                    Divider().overlay(.white.opacity(0.06))
                }
                ReportPlaceRow(rank: offset + 1, place: place)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Brand.navyRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReportPlaceRow: View {
    let rank: Int
    let place: ExposureReport.Place

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(rank)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 5) {
                        Text(place.name)
                            .font(.subheadline.weight(.semibold))
                        if place.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(Brand.aqua)
                                .accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(place.level.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(place.level.color)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule()
                            .fill(place.level.color)
                            .frame(width: max(geo.size.width * min(max(place.share, 0), 1), 6))
                    }
                }
                .frame(height: 6)
                if let note = place.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["\(rank). \(place.name)", place.level.label.lowercased()]
        if place.verified { parts.append("measured by a Dewin sensor") }
        if let note = place.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

// MARK: 6. Exposures (the doctor's table)

private struct ReportExposureTable: View {
    let exposures: [ExposureReport.Exposure]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                header("Your 90-day avg")
                header("Safe limit")
                header("Worst day")
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)

            ForEach(exposures) { exposure in
                Divider().overlay(.white.opacity(0.06))
                ReportExposureRows(exposure: exposure)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.navyRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One exposure: its name on its own line, then the three numbers under the column headers.
private struct ReportExposureRows: View {
    let exposure: ExposureReport.Exposure

    private var over: Bool { !exposure.withinLimit }
    private var estimated: Bool { exposure.estimated == true }
    private var worstOver: Bool { ReportLimit(exposure.limit)?.isOver(exposure.worst) ?? false }

    var body: some View {
        // VoiceOver reads the whole exposure once, from the name row; the numbers row is hidden.
        GridRow {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { name; tags }
                VStack(alignment: .leading, spacing: 4) { name; HStack(spacing: 6) { tags } }
            }
            .gridCellColumns(3)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        GridRow(alignment: .firstTextBaseline) {
            Text(valueText(exposure.average))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(over ? Brand.orange : .white)
            Text(limitText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueText(exposure.worst))
                        .font(.subheadline.weight(worstOver ? .semibold : .regular).monospacedDigit())
                    if worstOver {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(worstOver ? Brand.orange : .white.opacity(0.8))
                if let date = exposure.worstDate {
                    Text(date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 12)
        .accessibilityHidden(true)
    }

    private var name: some View {
        Text(exposure.label)
            .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder private var tags: some View {
        if over {
            Text("Over the limit")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Brand.orange.opacity(0.15), in: Capsule())
                .fixedSize()
        }
        if estimated {
            ReportEstimatedTag()
        }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Word joiners keep "µg/m³" in one piece when a large text size wraps the column.
    private var unit: String { exposure.unit.replacingOccurrences(of: "/", with: "\u{2060}/\u{2060}") }

    private func valueText(_ value: Double) -> String {
        unit.isEmpty ? Self.number(value) : "\(Self.number(value)) \(unit)"
    }

    private var limitText: String {
        unit.isEmpty ? exposure.limit : "\(exposure.limit) \(unit)"
    }

    private var accessibilityLabel: String {
        var label = exposure.label + (estimated ? ", estimated from public data" : "")
        label += ": your 90-day average \(valueText(exposure.average)), "
        label += over ? "over the safe limit of \(limitText)" : "within the safe limit of \(limitText)"
        label += ". Worst day \(valueText(exposure.worst))"
        if let date = exposure.worstDate { label += " on \(date.formatted(.dateTime.month(.wide).day()))" }
        if worstOver { label += ", over the limit" }
        return label
    }
}

// MARK: 7. Body

private struct ReportBodyCard: View {
    let sentence: String
    let device: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.title2)
                .foregroundStyle(Brand.orange)
                .accessibilityHidden(true)
            Text(sentence)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let device, !device.isEmpty {
                Text("From your \(device)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Brand.orange.opacity(0.18), Brand.navyRaised],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 8. Actions

private struct ReportActions: View {
    let actions: [ExposureReport.Action]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { offset, action in
                if offset > 0 {
                    Divider().overlay(.white.opacity(0.06))
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ReportLevelPill.symbol(for: action.level))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(action.level.color)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.source)
                            .font(.subheadline.weight(.semibold))
                        Text(action.text)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 13)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(Brand.navyRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: 9. Sources

private struct ReportSources: View {
    let sources: ExposureReport.Sources
    /// The note explains the "estimated" tags; without any tags it would point at nothing.
    let hasEstimates: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sources.text)
            if hasEstimates, !sources.estimatedNote.isEmpty {
                Text(sources.estimatedNote)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Building blocks

private struct ReportSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}

/// Gray "estimated" tag: this reading came from public data, not a Dewin sensor (see the footer).
private struct ReportEstimatedTag: View {
    var body: some View {
        Text("estimated")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Brand.gray.opacity(0.35), in: Capsule())
            .fixedSize()
    }
}

/// Reads the display limit ("≤ 9", "≤ 1,000", "≥ 5", "6.5–8.5") so a worst day over it can be
/// flagged. Unknown formats return nil and the value is shown unflagged.
private struct ReportLimit {
    var min: Double?
    var max: Double?

    init?(_ text: String) {
        let trimmed = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        func value(_ part: Substring) -> Double? {
            Double(part.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted))
        }
        if trimmed.hasPrefix("≤") || trimmed.hasPrefix("<") {
            guard let v = value(trimmed.dropFirst()) else { return nil }
            max = v
        } else if trimmed.hasPrefix("≥") || trimmed.hasPrefix(">") {
            guard let v = value(trimmed.dropFirst()) else { return nil }
            min = v
        } else {
            let parts = trimmed.split(whereSeparator: { $0 == "–" || $0 == "—" })
            guard parts.count == 2, let low = value(parts[0]), let high = value(parts[1]) else { return nil }
            min = low
            max = high
        }
    }

    func isOver(_ value: Double) -> Bool {
        if let max, value > max { return true }
        if let min, value < min { return true }
        return false
    }
}

private extension ExposureReport {
    var hasEstimates: Bool {
        overLimit.contains { $0.estimated == true } || exposures.contains { $0.estimated == true }
    }
}

/// Small label in a level's color, always with an icon and words so color is never the only signal.
private struct ReportLevelPill: View {
    let text: String
    let level: ReportLevel

    var body: some View {
        Label(text, systemImage: Self.symbol(for: level))
            .font(.caption.weight(.semibold))
            .foregroundStyle(level.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(level.color.opacity(0.15), in: Capsule())
    }

    static func symbol(for level: ReportLevel) -> String {
        switch level {
        case .good: "checkmark.circle.fill"
        case .neutral: "circle.lefthalf.filled"
        case .bad: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Sharing

private struct ReportShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ReportActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
