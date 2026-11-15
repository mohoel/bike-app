import SwiftUI

/// Result of an FTP test with its transfer to intervals.icu and an undo.
struct FTPResultCard: View {
    @Environment(AppModel.self) private var model
    let outcome: FTPTestOutcome

    var body: some View {
        let result = outcome.result
        let delta = result.ftp - outcome.previousAppFTP
        Card("FTP-Test · \(result.kind.title)") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(result.ftp)")
                    .font(Theme.number(64, .heavy))
                    .foregroundStyle(Theme.accent)
                Text("W FTP")
                    .font(Theme.text(18))
                    .foregroundStyle(Theme.label)
                Text(String(format: "%.1f W/kg", Double(result.ftp) / Swift.max(30, model.settings.riderWeight)).replacingOccurrences(of: ".", with: ","))
                    .font(Theme.text(18, .semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(delta == 0 ? "unverändert" : "\(delta > 0 ? "+" : "−")\(abs(delta)) W")
                        .font(Theme.number(24, .bold))
                        .foregroundStyle(delta >= 0 ? Theme.ok : Theme.warn)
                    Text("vorher \(outcome.previousAppFTP) W")
                        .font(Theme.text(12, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Text(result.basisText)
                .font(Theme.text(13, .medium))
                .foregroundStyle(Theme.secondary)
            transferRow
        }
    }

    @ViewBuilder
    private var transferRow: some View {
        switch outcome.transfer {
        case .idle:
            HStack(spacing: 10) {
                Image(systemName: outcome.applied ? "checkmark.circle.fill" : "circle").foregroundStyle(outcome.applied ? Theme.ok : Theme.secondary)
                Text(outcome.applied ? "Als FTP in der App gespeichert." : "Noch nicht übernommen.")
                Spacer()
                if !outcome.applied {
                    Button("Übernehmen") { model.applyFTP(outcome, transfer: model.settings.autoTransferFTP) }
                }
                Button("Zu intervals.icu übertragen") {
                    if !outcome.applied { model.applyFTP(outcome, transfer: true) } else { model.transferFTP(outcome) }
                }
                .disabled(!model.intervals.isConfigured)
                if outcome.applied { Button("Rückgängig") { model.undoFTP(outcome) } }
            }
        case .waitingForKey:
            HStack(spacing: 10) {
                Image(systemName: "clock").foregroundStyle(Theme.warn)
                Text("In der App gespeichert. Wird zu intervals.icu übertragen, sobald du den API-Key einträgst.")
                Spacer()
                SettingsLink { Text("API-Key eintragen") }
                Button("Rückgängig") { model.undoFTP(outcome) }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Wird zu intervals.icu übertragen…")
            }
        case let .transferred(change):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("In der App und in intervals.icu übernommen (\(change.field == "indoor_ftp" ? "Indoor-FTP" : "FTP"): \(change.previous.map { "\($0) W" } ?? "leer") → \(change.new.map { "\($0) W" } ?? "leer")).")
                Spacer()
                Button("Rückgängig") { model.undoFTP(outcome) }
            }
        case .undone:
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Theme.secondary)
                Text("Zurückgesetzt, die FTP ist wieder \(outcome.previousAppFTP) W.")
                Spacer()
                Button("Doch übernehmen") { model.applyFTP(outcome, transfer: true) }
            }
        case let .failed(message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(message)
                Spacer()
                Button("Erneut versuchen") { model.transferFTP(outcome) }
            }
        case let .needsConfirmation(reason):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nicht automatisch übernommen.")
                    Text(reason).font(Theme.text(12, .regular)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Trotzdem übernehmen") { model.applyFTP(outcome, transfer: true) }
            }
        }
    }
}
