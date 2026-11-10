import AppKit
import SwiftUI

/// Sheet „Standard-Player": zeigt pro Audioformat die aktuelle Standard-App
/// im Finder und setzt auf Wunsch SetCraft. Logik in `DefaultPlayerAssociation`.
struct DefaultPlayerSheet: View {

    @State private var model = DefaultPlayerAssociation()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Default player")
                    .font(.headline)
                Text("Choose which audio formats open in SetCraft when you double-click them in the Finder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(model.rows) { row in
                    GridRow {
                        Text(verbatim: row.format.id)
                            .fontWeight(.medium)
                        handlerLabel(row)
                        Group {
                            if row.isSetCraft {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Use SetCraft") {
                                    Task { await model.makeDefault(for: [row.format]) }
                                }
                                .disabled(model.isWorking)
                            }
                        }
                        .gridColumnAlignment(.trailing)
                    }
                }
            }

            if let error = model.errorMessage {
                Text("Could not change the default app: \(error)")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("To switch back, select a file in the Finder, choose File → Get Info and pick another app under “Open with”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Use SetCraft for All") {
                    Task { await model.makeDefault(for: DefaultPlayerAssociation.formats) }
                }
                .disabled(model.isWorking || model.allSetCraft)

                if model.isWorking {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func handlerLabel(_ row: DefaultPlayerAssociation.Row) -> some View {
        if row.handlers.isEmpty {
            Text("No default app")
                .foregroundStyle(.secondary)
        } else if row.handlers.count > 1 {
            Text("Several apps")
                .foregroundStyle(.secondary)
        } else if let app = row.handlers.first {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(verbatim: FileManager.default.displayName(atPath: app.path))
            }
        }
    }
}
