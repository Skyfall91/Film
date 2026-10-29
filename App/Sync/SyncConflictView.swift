import SwiftUI

struct SyncConflictView: View {
    @Environment(AppStore.self) private var store
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        if let sync = store.deviceSync, !sync.conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Änderungen auf mehreren Geräten").font(.headline)
                Text("Wähle für jede betroffene Änderung den Stand, den du behalten möchtest.").foregroundStyle(.secondary)
                ForEach(sync.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(conflict.title)
                        HStack {
                            Button("Meine Änderung übernehmen") { resolve(conflict.id, local: true) }
                            Button("Stand vom anderen Gerät behalten") { resolve(conflict.id, local: false) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.disabled(busy)
        }
    }
    private func resolve(_ id: UUID, local: Bool) {
        guard let sync = store.deviceSync, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await sync.resolveConflict(id: id, useLocal: local) }
            catch { self.error = error.localizedDescription }
        }
    }
}
