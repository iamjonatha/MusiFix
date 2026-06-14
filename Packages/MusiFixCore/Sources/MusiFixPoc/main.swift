/*
 * MusiFix — Phase 0 PoC
 *
 * Verifica il gate GO/NO-GO:
 *   1. Enumerazione brani via bridge (ScriptingBridge o NSAppleScript)
 *   2. Scrittura metadati su brano campione
 *   3. Read-back immediato e confronto
 *   4. Verifica che il path file non cambi
 *   5. Test fallback NSAppleScript
 *
 * USO:
 *   swift run MusiFixPoc --pid <persistentID>          # test su brano specifico (fast path)
 *   swift run MusiFixPoc --limit N                     # enumerazione + test su N brani
 *   swift run MusiFixPoc --list                        # solo enumerazione, nessuna scrittura
 */

import Foundation
import MusiFixCore

// ─── CLI args ─────────────────────────────────────────────────────────────────

var sampleLimit = 3
var targetPID: String? = nil
var listOnly = false

var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--limit":
        if let n = args.first.flatMap(Int.init) { sampleLimit = n; args = args.dropFirst() }
    case "--pid":
        if let p = args.first { targetPID = p; args = args.dropFirst() }
    case "--list":
        listOnly = true
    default: break
    }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

@MainActor
func main() async {
    print("╔══════════════════════════════════════════╗")
    print("║  MusiFix PoC — Fase 0  GO/NO-GO gate    ║")
    print("╚══════════════════════════════════════════╝\n")

    print("▶ [F0.1] Selezione bridge…")
    let bridge = AppleMusicBridgeFactory.makeBridge()
    let bridgeName = (bridge is ScriptingBridgeImpl) ? "ScriptingBridge" : "NSAppleScript"
    print("  Bridge attivo: \(bridgeName)\n")

    // ── Fast path: --pid specificato → salta enumerazione completa ───────────
    if let pid = targetPID, !listOnly {
        print("▶ [F0.2] Fast path: carico singolo brano [\(pid)]…")
        let track: Track
        do {
            track = try await bridge.trackMetadata(persistentID: pid)
            print("  Trovato: \(track.name) — \(track.artist)")
            print("  location: \(track.location?.path ?? "<cloud-only>")\n")
        } catch {
            print("  ✘ Brano non trovato o errore: \(error)")
            print("\nNO-GO: impossibile leggere il brano.")
            return
        }

        await testWriteAndRestore(track: track, bridge: bridge, bridgeName: bridgeName)
        return
    }

    // ── Slow path: enumerazione completa (--list o --limit) ──────────────────
    print("▶ [F0.2] Enumerazione brani… (può richiedere qualche minuto su librerie grandi)")
    let allTracks: [Track]
    do {
        allTracks = try await bridge.allTracks()
        print("  Trovati \(allTracks.count) brani\n")
    } catch {
        print("  ✘ Errore: \(error)")
        print("\nNO-GO: impossibile enumerare i brani.")
        return
    }

    guard !allTracks.isEmpty else { print("NO-GO: libreria vuota."); return }

    print("  Anteprima (prime 10):")
    for t in allTracks.prefix(10) {
        let loc = t.location?.lastPathComponent ?? "<cloud-only>"
        print("    • [\(t.persistentID)] \(t.name) — \(t.artist) | \(loc)")
    }
    print()
    print("SUGGERIMENTO: riesegui con  --pid <persistentID>  per il test di scrittura rapido.\n")

    guard !listOnly else { return }

    let sample = Array(allTracks.filter { $0.location != nil }.prefix(sampleLimit))
    guard !sample.isEmpty else {
        print("Nessun brano con file locale trovato — skip test scrittura.")
        return
    }

    for track in sample {
        await testWriteAndRestore(track: track, bridge: bridge, bridgeName: bridgeName)
    }
}

// ─── Funzione di test write/restore ──────────────────────────────────────────

@MainActor
func testWriteAndRestore(track: Track, bridge: any AppleMusicBridge, bridgeName: String) async {
    let pid = track.persistentID
    let pathBefore = track.location?.path ?? "<cloud>"
    print("▶ [F0.3] Test scrittura: [\(pid)] \(track.name)")
    print("    path prima: \(pathBefore)")

    let sentinelComment = "MusiFix_PoC_test_\(Date().timeIntervalSince1970)"
    let originalComment = track.comment

    let update = TrackMetadataUpdate(comment: sentinelComment)
    do {
        try await bridge.updateMetadata(update, persistentID: pid)
        print("    ✔ scrittura commento OK")
    } catch {
        print("    ✘ scrittura fallita: \(error)")
        printResult(false, pid: pid, note: "scrittura: \(error)")
        return
    }

    print("    Attendo 1 s e leggo di ritorno…")
    try? await Task.sleep(for: .seconds(1))

    let readBack: Track
    do {
        readBack = try await bridge.trackMetadata(persistentID: pid)
    } catch {
        print("    ✘ read-back fallito: \(error)")
        printResult(false, pid: pid, note: "read-back: \(error)")
        return
    }

    let commentMatch = readBack.comment == sentinelComment
    print("    read-back commento: «\(readBack.comment)» → \(commentMatch ? "✔ OK" : "✘ MISMATCH")")

    let pathAfter = readBack.location?.path ?? "<cloud>"
    let pathOK = pathBefore == pathAfter
    print("    path dopo:  \(pathAfter) → \(pathOK ? "✔ invariato" : "✘ CAMBIATO!")")

    // Ripristina
    let restore = TrackMetadataUpdate(comment: originalComment)
    do {
        try await bridge.updateMetadata(restore, persistentID: pid)
        print("    ✔ commento originale ripristinato")
    } catch {
        print("    ⚠ ripristino fallito — commento brano lasciato a: «\(sentinelComment)»")
        print("    ⚠ Correggilo manualmente in Music.app: campo Commento → «\(originalComment)»")
    }

    // F0.6 fallback NSAppleScript
    if bridge is ScriptingBridgeImpl {
        print("\n▶ [F0.6] Test fallback NSAppleScript…")
        let asBridge = NSAppleScriptImpl()
        do {
            let t = try await asBridge.trackMetadata(persistentID: pid)
            print("    NSAppleScript read: «\(t.name)» ✔")
        } catch {
            print("    NSAppleScript ✘: \(error)")
        }
    }

    let ok = commentMatch && pathOK
    printResult(ok, pid: pid, note: ok ? "OK" : "commentMatch=\(commentMatch) pathOK=\(pathOK)")

    print()
    print("══════════════════════════════════════════════")
    if ok {
        print("🟢 GO — persistenza e path verificati. Bridge \(bridgeName) funzionante.")
    } else {
        print("🔴 NO-GO — rivedi i log sopra.")
    }
    print("══════════════════════════════════════════════")
    print()
    print("NOTA: per verificare la persistenza post-iCloud (F0.4):")
    print("  1. Music.app → File → Libreria → Aggiorna libreria iCloud")
    print("  2. Riesegui:  swift run MusiFixPoc --pid \(pid)")
    print("     Il commento deve essere quello originale (già ripristinato).")
}

func printResult(_ ok: Bool, pid: String, note: String) {
    print("\n  \(ok ? "✔" : "✘") [\(pid)] \(note)")
}

await main()
