import SwiftUI
import AppKit
import MusiFixCore

/// Visualizza la copertina corrente e permette di sostituirla.
struct ArtworkEditorView: View {
    let pid: String
    let appState: AppState

    @State private var image: NSImage? = nil
    @State private var isLoading = false
    @State private var isReplacing = false
    @State private var error: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail copertina
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 100, height: 100)
                if isLoading {
                    ProgressView().scaleEffect(0.8)
                } else if let img = image {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))

            VStack(alignment: .leading, spacing: 6) {
                if let img = image {
                    let rep = img.representations.first
                    Text("\(rep?.pixelsWide ?? 0) × \(rep?.pixelsHigh ?? 0) px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Da file…") { pickFromFile() }
                    .disabled(isReplacing)
                Button("Dagli appunti") { pasteFromClipboard() }
                    .disabled(isReplacing || !NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.tiff.rawValue, "public.png", "public.jpeg"]))
                if isReplacing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6)
                        Text("Applico…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(12)
        .onAppear { loadArtwork() }
        .onChange(of: pid) { _, _ in loadArtwork() }
    }

    private func loadArtwork() {
        isLoading = true
        image = nil
        error = nil
        let bridge = appState.bridge
        let p = pid
        Task {
            let data = try? await bridge.artwork(persistentID: p)
            await MainActor.run {
                isLoading = false
                if let d = data { image = NSImage(data: d) }
            }
        }
    }

    private func pickFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        applyArtwork(data)
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        guard let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation else { return }
        applyArtwork(tiff)
    }

    private func applyArtwork(_ data: Data) {
        isReplacing = true
        error = nil
        let p = pid
        Task {
            do {
                _ = try await appState.writeService.setArtwork(data, for: p)
                await MainActor.run {
                    isReplacing = false
                    if let img = NSImage(data: data) { image = img }
                }
            } catch {
                await MainActor.run {
                    isReplacing = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
