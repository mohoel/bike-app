import Charts
import SwiftUI

typealias RideEntry = RideStore.Entry

/// List of all saved rides with a weekly overview; a ride opens its details.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        if let id = selection, let entry = model.history.first(where: { $0.id == id }) {
            RideDetailView(entry: entry) { selection = nil }
        } else {
            HistoryList { selection = $0 }
        }
    }
}

// MARK: - List

struct HistoryList: View {
    @Environment(AppModel.self) private var model
    let onSelect: (String) -> Void
    @State private var importMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Historie")
                            .font(Theme.text(30, .bold))
                        Text(model.history.isEmpty ? "Noch keine Fahrten" : "\(model.history.count) Fahrt\(model.history.count == 1 ? "" : "en")")
                            .font(Theme.text(14, .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if let importMessage {
                        Text(importMessage).font(Theme.text(12, .regular)).foregroundStyle(Theme.secondary)
                    }
                    Button {
                        importFIT()
                    } label: {
                        Label("Fahrt importieren…", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.large)
                }

                if model.history.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hier erscheinen deine Fahrten.")
                                .font(Theme.text(15, .semibold))
                            Text("Jede Fahrt wird nach dem Ende automatisch gesichert. Eine früher gesicherte FIT-Datei kannst du über „Fahrt importieren…“ hinzufügen.")
                                .font(Theme.text(13, .regular))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                } else {
                    WeekOverview(entries: model.history)
                    if model.pendingUploads > 0 { pendingBanner }
                    VStack(spacing: 10) {
                        ForEach(model.history) { entry in
                            RideRow(entry: entry, ftp: model.intervals.effectiveFTP, zones: model.intervals.zones, configured: model.intervals.isConfigured) {
                                onSelect(entry.id)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var pendingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.warn)
            Text(model.intervals.isConfigured
                 ? "\(model.pendingUploads) Fahrt(en) noch nicht bei intervals.icu."
                 : "\(model.pendingUploads) Fahrt(en) warten auf einen API-Key für intervals.icu.")
            Spacer()
            if model.intervals.isConfigured {
                Button("Jetzt hochladen") { Task { await model.syncPending() } }
            } else {
                SettingsLink { Text("API-Key eintragen") }
            }
        }
        .font(Theme.text(13, .medium))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warn.opacity(0.1)))
    }

    private func importFIT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fit") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            var failed = 0
            for url in panel.urls {
                do { try await model.importFIT(from: url) } catch { failed += 1 }
            }
            importMessage = failed == 0 ? "Importiert" : "\(failed) Datei(en) konnten nicht gelesen werden"
        }
    }
}

/// This week, the last 30 days and hours per week.
struct WeekOverview: View {
    let entries: [RideEntry]

    struct Week: Identifiable {
        let id: Date
        let label: String
        let hours: Double
        let km: Double
    }

    static func weeks(_ entries: [RideEntry], count: Int = 8, now: Date = Date()) -> [Week] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let rides = entries.filter { $0.date >= start && $0.date < end }
            return Week(
                id: start,
                label: "KW \(calendar.component(.weekOfYear, from: start))",
                hours: rides.reduce(0) { $0 + $1.movingTime } / 3600,
                km: rides.reduce(0) { $0 + $1.distance } / 1000
            )
        }
    }

    var body: some View {
        let weeks = Self.weeks(entries)
        let calendar = Calendar(identifier: .iso8601)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let monthStart = Date().addingTimeInterval(-30 * 86_400)
        let thisWeek = entries.filter { $0.date >= weekStart }
        let month = entries.filter { $0.date >= monthStart }

        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                periodTile("DIESE WOCHE", thisWeek)
                periodTile("LETZTE 30 TAGE", month)
            }
            .frame(width: 360)

            Card("Stunden pro Woche") {
                Chart(weeks) { week in
                    BarMark(x: .value("Woche", week.label), y: .value("Stunden", week.hours))
                        .foregroundStyle(week.id == weeks.last?.id ? Theme.accent : Theme.accent.opacity(0.45))
                        .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel {
                            if let h = value.as(Double.self) { Text("\(Fmt.decimal(h, h < 10 ? 1 : 0)) h") }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private func periodTile(_ title: String, _ rides: [RideEntry]) -> some View {
        let km = rides.reduce(0) { $0 + $1.distance } / 1000
        let hours = rides.reduce(0) { $0 + $1.movingTime }
        let kj = rides.reduce(0) { $0 + ($1.summary?.kilojoules ?? 0) }
        return VStack(alignment: .leading, spacing: 10) {
            MetricLabel(text: title, size: 11)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                figure("\(rides.count)", rides.count == 1 ? "Fahrt" : "Fahrten")
                figure(Fmt.decimal(km, km < 100 ? 1 : 0), "km")
                figure(Fmt.clock(hours, hours: true).dropLast(3).description, "h")
                figure("\(Int(kj.rounded()))", "kJ")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
    }

    private func figure(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(Theme.number(22, .bold))
            Text(unit).font(Theme.text(11)).foregroundStyle(Theme.label)
        }
    }
}

/// One ride in the list.
struct RideRow: View {
    let entry: RideEntry
    let ftp: Int
    let zones: PowerZones
    let configured: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(HistoryFormat.dateLine(entry.date))
                            .font(Theme.text(11, .bold))
                            .tracking(0.9)
                            .foregroundStyle(Theme.label)
                        UploadBadge(entry: entry, configured: configured)
                    }
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(Theme.text(16, .semibold))
                            .lineLimit(1)
                        if let ftp = entry.ftpTestResult {
                            Text("FTP \(ftp) W")
                                .font(Theme.text(11, .bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.accent))
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 14) {
                        metric(Fmt.km(entry.distance), "km")
                        metric(Fmt.clock(entry.movingTime, hours: true), "")
                        if let s = entry.summary {
                            metric("\(s.avgPower)", "W Ø")
                            if s.ascent >= 1 { metric("↑ \(Int(s.ascent.rounded()))", "hm") }
                            if let hr = s.avgHeartRate { metric("♥ \(hr)", "") }
                        }
                    }
                }
                .frame(width: 400, alignment: .leading)

                VStack(spacing: 6) {
                    PowerBarsView(power: entry.series?.power ?? [], ftp: entry.ftp ?? ftp, zones: zones)
                        .frame(height: 44)
                    ZoneDistributionBar(seconds: entry.zoneSeconds ?? [])
                        .frame(height: 6)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.label)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.name), \(HistoryFormat.dateLine(entry.date))")
    }

    private func metric(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(Theme.number(18, .bold))
            if !unit.isEmpty { Text(unit).font(Theme.text(11)).foregroundStyle(Theme.label) }
        }
        .fixedSize()
    }
}

struct UploadBadge: View {
    let entry: RideEntry
    let configured: Bool

    var body: some View {
        let (text, symbol, color): (String, String, Color) = {
            if entry.isUploaded { return ("intervals.icu", "checkmark.circle.fill", Theme.ok) }
            if !configured { return ("wartet auf API-Key", "clock", Theme.warn) }
            if entry.lastError != nil { return ("Upload fehlgeschlagen", "exclamationmark.triangle.fill", Theme.bad) }
            return ("noch nicht hochgeladen", "arrow.up.circle", Theme.warn)
        }()
        Label(text, systemImage: symbol)
            .font(Theme.text(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

enum HistoryFormat {
    static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EE d. MMM · HH:mm"
        return f.string(from: date).uppercased()
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy · HH:mm 'Uhr'"
        return f.string(from: date)
    }
}

// MARK: - Detail

struct RideDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: RideEntry
    let onBack: () -> Void
    @State private var confirmDelete = false
    @State private var uploading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Label("Historie", systemImage: "chevron.left")
                            .font(Theme.text(14, .semibold))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !entry.isUploaded {
                        if uploading {
                            ProgressView().controlSize(.small)
                        }
                        Button("Hochladen") {
                            uploading = true
                            Task {
                                await model.uploadStored(entry.id)
                                uploading = false
                            }
                        }
                        .disabled(!model.intervals.isConfigured || uploading)
                    } else if let id = entry.uploadedActivityId, id != "ok", let url = URL(string: "https://intervals.icu/activities/\(id)") {
                        Link("In intervals.icu öffnen", destination: url)
                    }
                    Button("FIT exportieren…") { exportFIT() }
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                }
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(entry.name)
                            .font(Theme.text(26, .bold))
                        UploadBadge(entry: entry, configured: model.intervals.isConfigured)
                    }
                    Text([HistoryFormat.longDate(entry.date), entry.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.text(14, .medium))
                        .foregroundStyle(Theme.secondary)
                    if let error = entry.lastError, !entry.isUploaded {
                        Text("Letzter Upload-Versuch: \(error)")
                            .font(Theme.text(12, .regular))
                            .foregroundStyle(Theme.bad)
                    }
                }

                RideDetailContent(entry: entry, zones: model.intervals.zones, fallbackFTP: model.intervals.effectiveFTP)
            }
            .padding(28)
        }
        .confirmationDialog("Fahrt löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                model.deleteRide(entry.id)
                onBack()
            }
        } message: {
            Text(entry.isUploaded
                 ? "Die Fahrt wird nur auf diesem Mac gelöscht. In intervals.icu bleibt sie erhalten."
                 : "Die Fahrt ist noch nicht bei intervals.icu und geht damit endgültig verloren.")
        }
    }

    private func exportFIT() {
        guard let data = model.rides.fit(for: entry.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.id
        panel.allowedContentTypes = [.init(filenameExtension: "fit") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}

/// Figures, zones and charts of one ride (used in the history and after a ride).
struct RideDetailContent: View {
    let entry: RideEntry
    let zones: PowerZones
    let fallbackFTP: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let s = entry.summary {
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        StatTile(label: "ZEIT", value: Fmt.clock(s.movingTime, hours: true), unit: nil)
                        StatTile(label: "DISTANZ", value: Fmt.km(s.distance), unit: "km")
                        StatTile(label: "Ø GESCHWINDIGKEIT", value: Fmt.decimal(s.avgSpeed * 3.6, 1), unit: "km/h")
                        StatTile(label: "HÖHENMETER", value: "\(Int(s.ascent.rounded()))", unit: "m")
                    }
                    GridRow {
                        StatTile(label: "Ø LEISTUNG", value: "\(s.avgPower)", unit: "W", color: Theme.zoneColor(zones.index(watts: Double(s.avgPower), ftp: Double(ftp))))
                        StatTile(label: "NP", value: "\(s.normalizedPower)", unit: "W", color: Theme.zoneColor(zones.index(watts: Double(s.normalizedPower), ftp: Double(ftp))))
                        StatTile(label: "MAX", value: "\(s.maxPower)", unit: "W")
                        StatTile(label: "ARBEIT", value: "\(Int(s.kilojoules.rounded()))", unit: "kJ")
                    }
                    GridRow {
                        StatTile(label: "Ø TRITTFREQUENZ", value: s.avgCadence.map(String.init) ?? "–", unit: "rpm")
                        StatTile(label: "Ø PULS", value: s.avgHeartRate.map(String.init) ?? "–", unit: "bpm")
                        StatTile(label: "MAX PULS", value: s.maxHeartRate.map(String.init) ?? "–", unit: "bpm")
                        StatTile(label: "FTP", value: "\(ftp)", unit: "W")
                    }
                }
            } else {
                Card {
                    Text("Für diese Fahrt liegen keine Details vor.")
                        .foregroundStyle(Theme.secondary)
                }
            }

            if let seconds = entry.zoneSeconds, seconds.reduce(0, +) > 0 {
                Card("Zeit in Zonen") {
                    ZoneDistributionBar(seconds: seconds)
                        .frame(height: 14)
                    HStack(spacing: 18) {
                        ForEach(Array(seconds.enumerated()), id: \.offset) { i, value in
                            if value > 0 {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3).fill(Theme.zoneColor(i)).frame(width: 10, height: 10)
                                    Text("\(PowerZones.shortName(i)) \(PowerZones.name(i))")
                                        .foregroundStyle(Theme.secondary)
                                    Text(minutes(value))
                                        .fontWeight(.bold)
                                }
                                .font(Theme.text(12, .medium))
                            }
                        }
                    }
                }
            }

            if let series = entry.series, !series.power.isEmpty {
                Card("Leistung") {
                    PowerBarsView(power: series.power, ftp: ftp, zones: zones, spacing: 1)
                        .frame(height: 150)
                    timeAxis(series)
                }
                if series.heartRate.contains(where: { $0 > 0 }) {
                    Card("Puls") {
                        HeartRateLineView(values: series.heartRate)
                            .frame(height: 90)
                        timeAxis(series)
                    }
                }
                let columns = Self.altitudeColumns(series)
                if !columns.isEmpty {
                    Card("Höhenprofil") {
                        ProfileBarsView(columns: columns, marker: nil, spacing: 1, minHeight: 4, highlightCurrent: false)
                            .frame(height: 90)
                        HStack {
                            Text("0 km")
                            Spacer()
                            Text("\(Fmt.km(series.distance.last ?? 0)) km")
                        }
                        .font(Theme.text(12))
                        .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
            }
        }
    }

    private var ftp: Int { entry.ftp ?? fallbackFTP }

    private func minutes(_ seconds: Double) -> String {
        seconds >= 3600 ? Fmt.clock(seconds, hours: true) : "\(Int((seconds / 60).rounded())) min"
    }

    private func timeAxis(_ series: StoredSeries) -> some View {
        let total = Double(series.power.count) * series.bucketSeconds
        return HStack {
            ForEach(0..<5, id: \.self) { i in
                Text(Fmt.clock(total * Double(i) / 4, hours: false))
                if i < 4 { Spacer(minLength: 0) }
            }
        }
        .font(Theme.text(12))
        .foregroundStyle(Color.white.opacity(0.55))
    }

    /// Elevation columns from the stored altitude and distance, coloured by grade.
    static func altitudeColumns(_ series: StoredSeries) -> [ProfileColumn] {
        let alt = series.altitude
        guard alt.count > 1, let lo = alt.min(), let hi = alt.max(), hi - lo >= 1 else { return [] }
        let span = Swift.max(hi - lo, 30)
        return alt.indices.map { i in
            var grade = 0.0
            if i > 0, i < series.distance.count {
                let d = series.distance[i] - series.distance[i - 1]
                if d > 1 { grade = (alt[i] - alt[i - 1]) / d * 100 }
            }
            return ProfileColumn(norm: (alt[i] - lo) / span, grade: grade)
        }
    }
}

// MARK: - Building blocks

struct StatTile: View {
    let label: String
    let value: String
    let unit: String?
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricLabel(text: label, size: 11)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.number(30, .bold)).foregroundStyle(color)
                if let unit { Text(unit).font(Theme.text(13)).foregroundStyle(Theme.label) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
    }
}

/// Power over time as columns in zone colours.
struct PowerBarsView: View {
    let power: [Int]
    let ftp: Int
    let zones: PowerZones
    var spacing: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            guard !power.isEmpty else { return }
            let top = Swift.max(Double(power.max() ?? 1), Double(ftp) * 1.2, 1)
            let n = CGFloat(power.count)
            let gap = n * (spacing + 0.5) < size.width ? spacing : 0
            let w = Swift.max(0.5, (size.width - gap * (n - 1)) / n)
            for (i, p) in power.enumerated() {
                let h = Swift.max(1.5, CGFloat(Double(p) / top) * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h)
                let color = p > 0 ? Theme.zoneColor(zones.index(watts: Double(p), ftp: Double(ftp))) : Color.white.opacity(0.15)
                ctx.fill(Path(roundedRect: rect, cornerRadius: Swift.min(1.5, w / 2)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Heart rate as a line with a soft fill.
struct HeartRateLineView: View {
    let values: [Int]

    var body: some View {
        Canvas { ctx, size in
            let present = values.filter { $0 > 0 }
            guard let lo = present.min(), let hi = present.max(), values.count > 1 else { return }
            let minY = Double(lo) - 5, maxY = Double(hi) + 5
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: size.height * CGFloat(1 - (Double(values[i]) - minY) / (maxY - minY)))
            }
            var line = Path()
            var fill = Path()
            var started = false
            var firstX: CGFloat = 0
            var lastX: CGFloat = 0
            for i in values.indices where values[i] > 0 {
                let p = point(i)
                if !started {
                    line.move(to: p)
                    fill.move(to: CGPoint(x: p.x, y: size.height))
                    fill.addLine(to: p)
                    firstX = p.x
                    started = true
                } else {
                    line.addLine(to: p)
                    fill.addLine(to: p)
                }
                lastX = p.x
            }
            fill.addLine(to: CGPoint(x: lastX, y: size.height))
            fill.addLine(to: CGPoint(x: firstX, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(Theme.heart.opacity(0.14)))
            ctx.stroke(line, with: .color(Theme.heart), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Share of time in each power zone as one coloured bar.
struct ZoneDistributionBar: View {
    let seconds: [Double]

    var body: some View {
        GeometryReader { geo in
            let total = seconds.reduce(0, +)
            HStack(spacing: total > 0 ? 2 : 0) {
                if total > 0 {
                    ForEach(Array(seconds.enumerated()), id: \.offset) { i, value in
                        if value > 0 {
                            Capsule()
                                .fill(Theme.zoneColor(i))
                                .frame(width: Swift.max(2, (geo.size.width - 2 * CGFloat(seconds.filter { $0 > 0 }.count - 1)) * CGFloat(value / total)))
                        }
                    }
                } else {
                    Capsule().fill(Color.white.opacity(0.08))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
