import SwiftUI
import MusiFixCore
import Persistence

/// Anteprima "prima → dopo" obbligatoria per operazioni batch.
struct DiffPreviewView: View {
    let tracks: [DBTrack]
    let update: TrackMetadataUpdate
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Anteprima modifiche")
                    .font(.headline)
                Spacer()
                Text("\(tracks.count) brani").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            // Campi che cambiano
            VStack(alignment: .leading, spacing: 8) {
                Text("Campi modificati").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(changedFields, id: \.field) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.field)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            if let before = entry.before {
                                Text(before)
                                    .font(.caption)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.after)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(16)

            Divider()

            // Anteprima brani interessati
            Text("Brani interessati").font(.caption.bold()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            List(tracks.prefix(20), id: \.persistentID) { t in
                Text("\(t.artist.isEmpty ? "" : "\(t.artist) — ")\(t.name)")
                    .font(.caption)
            }
            .frame(maxHeight: 150)

            if tracks.count > 20 {
                Text("… e altri \(tracks.count - 20) brani")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Button("Annulla", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Applica a \(tracks.count) brani", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
    }

    private struct FieldEntry { let field: String; let before: String?; let after: String }

    private var changedFields: [FieldEntry] {
        var entries: [FieldEntry] = []
        func common<T: Equatable>(_ kp: KeyPath<DBTrack, T>, format: (T) -> String) -> String? {
            let vals = tracks.map { $0[keyPath: kp] }
            return vals.dropFirst().allSatisfy({ $0 == vals.first! }) ? format(vals.first!) : "Valori diversi"
        }
        if let v = update.artist      { entries.append(.init(field: "Artista",      before: common(\.artist, format: { $0 }),             after: v)) }
        if let v = update.albumArtist { entries.append(.init(field: "Album Artist", before: common(\.albumArtist, format: { $0 }),         after: v)) }
        if let v = update.album       { entries.append(.init(field: "Album",        before: common(\.album, format: { $0 }),               after: v)) }
        if let v = update.year        { entries.append(.init(field: "Anno",         before: common(\.year, format: { $0 > 0 ? "\($0)" : "" }), after: "\(v)")) }
        if let v = update.genre       { entries.append(.init(field: "Genere",       before: common(\.genre, format: { $0 }),               after: v)) }
        if let v = update.comment     { entries.append(.init(field: "Commento",     before: common(\.comment, format: { $0 }),             after: v)) }
        if let v = update.composer    { entries.append(.init(field: "Compositore",  before: common(\.composer, format: { $0 }),            after: v)) }
        return entries
    }
}
