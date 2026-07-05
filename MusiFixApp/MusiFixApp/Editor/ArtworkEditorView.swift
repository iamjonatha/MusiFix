import SwiftUI
import AppKit
import MusiFixCore
import Persistence

/// Visualizza la copertina corrente e permette di sostituirla (file, clipboard, ricerca online).
struct ArtworkEditorView: View {
    let track: DBTrack
    let appState: AppState

    @State private var image: NSImage? = nil
    @State private var isLoading = false
    @State private var isReplacing = false
    @State private var error: String? = nil
    @State private var showEnrichment = false
    @State private var zoom = false
    @State private var loadTask: Task<Void, Never>? = nil

    var pid: String { track.persistentID }

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
                        .onTapGesture { zoom = true }
                        .help("Clic per ingrandire")
                        .popover(isPresented: $zoom, arrowEdge: .trailing) {
                            ArtworkZoomPopover(image: image)
                        }
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
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Da file…") { pickFromFile() }.disabled(isReplacing)
                Button("Dagli appunti") { pasteFromClipboard() }
                    .disabled(isReplacing || !NSPasteboard.general.canReadItem(
                        withDataConformingToTypes: [NSPasteboard.PasteboardType.tiff.rawValue,
                                                    "public.png", "public.jpeg"]))
                Button("Cerca online…") { showEnrichment = true }.disabled(isReplacing)
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
        .sheet(isPresented: $showEnrichment) {
            EnrichmentSearchView(
                track: track,
                appState: appState,
                onApplied: { reloadAfterApply() },
                isPresented: $showEnrichment
            )
        }
    }

    private func loadArtwork() {
        loadTask?.cancel()
        isLoading = true; image = nil; error = nil
        let bridge = appState.bridge; let p = pid
        loadTask = Task {
            let data = try? await bridge.artwork(persistentID: p)
            guard !Task.isCancelled else { return }
            await MainActor.run { isLoading = false; if let d = data { image = NSImage(data: d) } }
        }
    }

    /// Rilettura dopo un'applicazione da "Cerca online": la persistenza cloud non è
    /// immediata, quindi si ritenta qualche volta prima di mostrare la copertina.
    private func reloadAfterApply() {
        loadTask?.cancel()
        isLoading = true; error = nil
        let bridge = appState.bridge; let p = pid
        loadTask = Task {
            let img = await Self.rereadArtwork(bridge: bridge, pid: p, retries: 4)
            guard !Task.isCancelled else { return }
            await MainActor.run { isLoading = false; if let img { image = img } }
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
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation else { return }
        applyArtwork(tiff)
    }

    private func applyArtwork(_ data: Data) {
        isReplacing = true; error = nil
        let bridge = appState.bridge; let p = pid
        Task {
            do {
                _ = try await appState.writeService.setArtwork(data, for: pid)
                // Rilegge la copertina effettiva dal brano in Music (cloud library),
                // non il dato locale: Music può ricomprimerla/ridimensionarla. Piccolo
                // retry perché la persistenza cloud non è immediata.
                let reread = await Self.rereadArtwork(bridge: bridge, pid: p, retries: 3)
                await MainActor.run {
                    isReplacing = false
                    image = reread ?? NSImage(data: data)   // fallback al dato locale
                }
            } catch {
                await MainActor.run { isReplacing = false; self.error = error.localizedDescription }
            }
        }
    }

    /// Rilegge la copertina da Music con qualche tentativo, per dare tempo alla
    /// cloud library di persistere il nuovo artwork.
    private static func rereadArtwork(bridge: any AppleMusicBridge, pid: String, retries: Int) async -> NSImage? {
        for attempt in 0..<max(retries, 1) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            if let data = try? await bridge.artwork(persistentID: pid), let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }
}
