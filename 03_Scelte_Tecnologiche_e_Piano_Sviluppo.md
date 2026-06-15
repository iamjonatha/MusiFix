# Scelte Tecnologiche e Architettura — MusiFix

**Nome prodotto:** *MusiFix*
**Versione documento:** 1.1
**Data ultima modifica:** 15 giugno 2026
**Documenti di riferimento:** «01 — Analisi Funzionale», «02 — Analisi Tecnica e di Fattibilità»
**Piattaforma target:** macOS nativo (Developer ID, fuori App Store)
**Stato:** Completato — tutte le 6 fasi implementate

---

## 0. Sintesi delle decisioni (TL;DR)

Questo documento **chiude le decisioni aperte** del §13 dell'analisi tecnica, **congela lo stack** e definisce un **piano di sviluppo per fasi** con milestone, deliverable e criteri di uscita verificabili.

Decisioni chiave prese:

1. **Distribuzione:** Developer ID + notarizzazione, **app NON sandboxed** (uso personale single-user). → semplifica automazione Music e accesso a `~/Music`.
2. **Fingerprint audio (Chromaprint):** **incluso nel prodotto**, ma consegnato in **Fase 4** dietro toggle opzionale (il caso "coppie MP3/M4A" è esplicito dell'utente).
3. **Sorgente copertine primaria:** **iTunes Search API** (allineata al catalogo Apple), poi MusicBrainz/Cover Art Archive → Discogs → fallback web assistito manuale.
4. **"Mantieni organizzata la cartella":** strategia **M-A che non rinomina** + **verifica path post-operazione**; in più l'app **consiglia di disattivare** l'opzione durante le sessioni di editing di massa (con guida in-app), senza imporlo.
5. **Lettura tag:** **AVFoundation** (robusta, zero dipendenze C++). **Scrittura su file:** **TagLib** (solo fallback M-B/M-C). La maggior parte delle scritture passa da **M-A (Apple Music)**.
6. **Gate di rischio:** nessuna riga di UI definitiva finché il **PoC di Fase 0** non dà esito **go** sulla persistenza delle modifiche dopo "Aggiorna libreria iCloud" e sul non-spostamento dei file.

---

## 1. Stack tecnologico congelato

| Ambito | Scelta definitiva | Motivazione sintetica |
|--------|-------------------|-----------------------|
| Linguaggio | **Swift 6** (strict concurrency) | Nativo, performante, tooling maturo |
| UI | **SwiftUI** come base + **AppKit `NSTableView`** per la tabella 25k righe | SwiftUI `Table` non regge fluido a 25k righe; `NSTableView` view-based virtualizzato sì |
| Gestione pacchetti | **Swift Package Manager** | Standard, niente CocoaPods/Carthage |
| Persistenza/indice | **SQLite via GRDB.swift** | Controllo SQL fine, migrazioni, observation, prestazioni su 25k+ |
| Ricerca full-text | **SQLite FTS5** | Ricerca as-you-type < 200 ms |
| Integrazione Apple Music | **`AppleMusicBridge`** (protocollo) con 2 impl.: **ScriptingBridge** (primaria) + **`NSAppleScript`/Apple Events grezzi** (fallback) | Mitiga regressioni macOS 26 Tahoe; selezione a runtime |
| Lettura tag/metadati audio | **AVFoundation** (`AVAsset`/`AVMetadataItem`) | Robusta, nessuna dipendenza nativa per la lettura |
| Scrittura tag su file | **TagLib** via thin C++ wrapper (target SPM) | Solo per M-B/M-C; standardizza MP3 su **ID3v2.4 UTF-8** |
| Fingerprint audio | **Chromaprint** (C) — confronto locale, AcoustID opzionale | Dedup per contenuto, coppie MP3/M4A; nessun upload audio |
| Fuzzy matching | **Jaro-Winkler + token-set ratio** (impl. interna) | Normalizzazione/duplicati; nessuna lib pesante |
| Networking | **`URLSession` async/await** + rate limiter + cache | Provider copertine/anno |
| Immagini | **ImageIO + CoreImage** | Resize/encode copertine (max ~1400px, JPEG q≈0.85) |
| Concorrenza | **Swift Concurrency** (async/await, `actor`) | `actor` dedicato serializza accesso a Music e a SQLite-write |
| Watch file system | **FSEvents** (event ID persistito) | Delta senza riscansione completa |
| Permessi file | **Security-scoped bookmark** sulla radice `~/Music` | Accesso persistente |
| Logging | **OSLog** (`Logger`) + tabella `operation_log` in SQLite | Diagnostica + audit/undo |
| Test | **Swift Testing** (unit) + **XCTest** (UI/integrazione) | Copertura servizi e bridge |
| Build/CI | **xcodebuild** da CLI; script di notarizzazione (`notarytool`) | Flusso ripetibile, niente Xcode obbligatorio |
| Versione minima | **Deployment target macOS 14**, **validazione primaria su macOS 26** | Compatibilità + ambiente reale utente |

### 1.1 Dipendenze esterne (SPM / vendored)

- `GRDB.swift` (SPM)
- `TagLib` (vendored come SwiftPM C++ target con header bridging) — *opzionale a runtime, usato solo nei fallback*
- `chromaprint` + `fftw`/`kissfft` (vendored C target) — *Fase 4, dietro feature flag*
- Tutto il resto è SDK Apple (AVFoundation, ImageIO, CoreImage, FSEvents, ScriptingBridge, OSAKit).

> **Principio:** minimizzare le dipendenze native (C/C++) e isolarle dietro protocolli, così che un problema di build/toolchain non blocchi l'app. TagLib e Chromaprint sono confinati a moduli sostituibili.

---

## 2. Architettura dei moduli (mappa pacchetti)

Monorepo Swift Package multi-target + app shell Xcode:

```
MusiFix/                         (workspace)
├── MusiFixApp/                  (app shell SwiftUI/AppKit, entitlements, packaging)
└── Packages/
    └── MusiFixCore/             (Swift Package)
        ├── Persistence/         GRDB, schema, migrazioni, DAO, FTS5
        ├── Model/               entità dominio (Track, Album, AliasRule, Operation…)
        ├── AppleMusic/          AppleMusicBridge (protocollo) + 2 impl + read-back
        ├── TagIO/               lettura AVFoundation + scrittura TagLib (mapping MP3/M4A)
        ├── Indexing/            IndexService, sync incrementale, FSEvents, hashing
        ├── Writing/             MetadataWriteService, coda transazionale, undo/log
        ├── Enrichment/          provider multi-sorgente, cache, rate limit, scoring
        ├── Normalization/       dizionari, clustering fuzzy, anteprima impatto
        ├── Duplicates/          metadati (blocking+fuzzy) + fingerprint (opz.)
        ├── Deletion/            salvaguardie, Cestino, log, propagazione iCloud
        └── Common/              concorrenza (actors), errori, utility
```

**Regole architetturali (da analisi tecnica §2.2):**
- Runtime source of truth = **indice SQLite**; data source of truth = **Apple Music**. L'indice è proiezione riconciliabile.
- **Tutte le scritture** passano da **coda transazionale** con snapshot "prima" (undo) e log.
- Operazioni **idempotenti e ripristinabili**; nessuno stato incoerente in caso di crash.
- **Verifica post-scrittura (read-back)** + confronto path file su ogni operazione.
- Accesso a Music e write su SQLite **serializzati** da `actor` dedicati (l'automazione di Music non ama la concorrenza); lettura tag file in parallelo (pool di task).

---

## 3. Risoluzione delle decisioni aperte (§13 analisi tecnica)

| # | Decisione | Scelta | Razionale / override |
|---|-----------|--------|----------------------|
| 1 | Distribuzione | **Developer ID, non sandboxed** | Single-user, automazione Music + `~/Music` senza attriti. *Override:* se in futuro serve MAS → introdurre sandbox + security-scoped bookmark (già previsti). |
| 2 | Fingerprint v1 | **Incluso, ma in Fase 4 dietro toggle** | Risolve il caso esplicito MP3/M4A senza ritardare le fasi core. |
| 3 | Copertine primaria | **iTunes Search API** | Restituisce esattamente l'artwork del catalogo Apple atteso dall'utente. |
| 4 | "Mantieni organizzata" | **M-A + verifica path + consiglio di disattivarla in editing di massa** | Rispetta preferenza utente ma protegge V1/V2; in-app si spiega il rischio. |

---

## 4. Mappa requisiti → moduli (tracciabilità)

| Requisito (F. funzionale) | Modulo |
|---|---|
| F1 Indicizzazione/sync | `IndexService` |
| F2 Browser | `TrackDAO` + `TrackBrowserViewModel` |
| F3 Editing | `MetadataWriteService` |
| F4 Copertine | `MetadataWriteService` (artwork) + `ArtworkEditorView` |
| F5 Arricchimento online | `EnrichmentService` |
| F6 Normalizzazione | `NormalizationService` |
| F7 Duplicati | `DuplicateService` + `AudioFingerprinter` |
| F8 Localizza/Elimina | `DeletionService` + `AppleMusicBridge.revealInMusic` |
| F9 Coda/anteprima/undo/log | `OperationDAO` + `MetadataWriteService.undo` |
| Verifica divergenze DB↔Music | `DivergenceService` *(Fase 6)* |

---

## 5. Rischi e mitigazioni

| Rischio | Mitigazione adottata |
|---|---|
| Automazione Music instabile su macOS 26 | Bridge a doppia impl. (ScriptingBridge + NSAppleScript fallback), selezione a runtime |
| Revert metadati da iCloud | Scrittura esclusiva via M-A (Apple Music); l'app non scrive mai direttamente sui file |
| Rinomina/spostamento file da "Mantieni organizzata" | M-A non innesca riorganizzazione; path verificato nell'indice |
| Toolchain C/C++ (TagLib/Chromaprint) | Isolati dietro protocolli, opzionali a runtime; TagLib non usato per scrittura in produzione |
| Falsi positivi duplicati | Soglie configurabili, conferma manuale, marcatura "non duplicati" |
| Eliminazioni accidentali | Cestino, doppia conferma sopra soglia, log dettagliato, undo limitato |
| Qualità/licenza dati online | Utente nel controllo delle copertine applicate; fonte tracciata |

---

*Documento complementare a «01 — Analisi Funzionale» e «02 — Analisi Tecnica e di Fattibilità».*
