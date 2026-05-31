import SwiftUI
import SetifyCore

struct KeyChip: View {
    @Bindable var transport: TransportViewModel
    let hasLoadedTrack: Bool

    @State private var showPopover = false

    private static let camelotAccent = Color(red: 93/255, green: 202/255, blue: 165/255)

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .imageScale(.small)
                Text(displayKey)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(transport.effectiveKey != nil ? Self.camelotAccent : Color.secondary)
                if transport.isGlobalKey {
                    Text("global")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if transport.isGlobalKey && !transport.keyMasterApplicable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help("Master-Key passt nicht auf diesen Track (Dur/Moll-Mismatch)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!hasLoadedTrack)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popover
                .padding(16)
                .frame(width: 360)
        }
    }

    private var displayKey: String {
        transport.effectiveKey?.description ?? "—"
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Key").font(.headline)
                Spacer()
                Toggle("global", isOn: Binding(
                    get: { transport.isGlobalKey },
                    set: { transport.setIsGlobalKey($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if transport.isGlobalKey && !transport.keyMasterApplicable {
                Label("Master-Key nicht anwendbar (Dur/Moll-Mismatch)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            camelotGrid

            HStack(spacing: 8) {
                Text("Halbton")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    transport.nudgeSemitone(-1)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)
                .disabled(!hasLoadedTrack)

                Button {
                    transport.nudgeSemitone(+1)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(!hasLoadedTrack)

                Button("Reset") {
                    if let original = playerOriginalKey {
                        transport.setKey(original)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(playerOriginalKey == nil)
            }
        }
    }

    /// 12×2-Grid: erste Zeile Moll (A), zweite Zeile Dur (B).
    private var camelotGrid: some View {
        VStack(spacing: 6) {
            keyRow(mode: .minor)
            keyRow(mode: .major)
        }
    }

    private func keyRow(mode: CamelotKey.Mode) -> some View {
        HStack(spacing: 4) {
            ForEach(1...12, id: \.self) { n in
                keyCell(number: n, mode: mode)
            }
        }
    }

    @ViewBuilder
    private func keyCell(number: Int, mode: CamelotKey.Mode) -> some View {
        let k = CamelotKey(number: number, mode: mode) ?? CamelotKey(number: 1, mode: mode)!
        let isCurrent = transport.effectiveKey == k
        Button {
            transport.setKey(k)
        } label: {
            Text(k.description)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isCurrent ? Self.camelotAccent.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCurrent ? Self.camelotAccent : Color.gray.opacity(0.4), lineWidth: 0.5)
                )
                .foregroundStyle(isCurrent ? Self.camelotAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!hasLoadedTrack)
    }

    private var playerOriginalKey: CamelotKey? { transport.originalKey }
}
