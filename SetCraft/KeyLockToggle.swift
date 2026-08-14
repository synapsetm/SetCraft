import SwiftUI

/// Schalter für den Key-Lock. An = die Tonhöhe bleibt beim Tempowechsel
/// konstant (bisheriges Verhalten der App). Aus = die Tonart wandert mit dem
/// Tempo, und die Bibliothek zeigt die klingenden Tonarten an.
struct KeyLockToggle: View {
    @Binding var keyLock: Bool
    let hasLoadedTrack: Bool

    var body: some View {
        Button {
            keyLock.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: keyLock ? "lock.fill" : "lock.open")
                    .imageScale(.small)
                Text("key lock")
                    .font(.caption)
            }
            .foregroundStyle(keyLock ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().strokeBorder(
                    keyLock ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.3)
                )
            )
        }
        .buttonStyle(.plain)
        .opacity(hasLoadedTrack ? 1.0 : 0.55)
        .help(keyLock
              ? "Key lock an — die Tonhöhe bleibt beim Tempowechsel konstant"
              : "Key lock aus — die Tonart verschiebt sich mit dem Tempo")
    }
}
