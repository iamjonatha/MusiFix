# MusiFix — Guida per Claude

App macOS nativa per la gestione metadati di una libreria Apple Music (25k+ brani).
Swift 6, SwiftUI + AppKit, GRDB, Chromaprint. Uso personale, Developer ID non-sandboxed.

## Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -workspace MusiFix.xcworkspace \
             -scheme MusiFixApp \
             -destination 'platform=macOS' \
             build 2>&1 | tail -5
```

Workspace root: `/Volumes/EXTERNAL/Progetti/MusiFix/`

## Struttura

```
MusiFixApp/MusiFixApp/          App shell (UI)
  AppState.swift                Singleton @MainActor: istanze dei servizi
  ContentView.swift             Finestra principale: toolbar + browser + pannello editor
  Browser/                      TrackBrowserViewModel + TrackTableView (NSTableView virtuale)
  Editor/                       TrackEditorPanel (singolo), BatchEditorView, DiffPreviewView,
                                ArtworkEditorView, EnrichmentSearchView, OperationLogView
  Dashboard/DashboardView.swift  Statistiche libreria + navigazione rapida filtri
  Normalization/                NormalizationView
  Duplicates/DuplicatesView.swift
  Deletion/DeletionView.swift
  Divergence/DivergenceView.swift  Confronto live DB ↔ Music.app

Packages/MusiFixCore/Sources/
  MusiFixCore/
    AppleMusic/    AppleMusicBridge (protocollo), ScriptingBridgeImpl, NSAppleScriptImpl
    Indexing/      IndexService (full + incremental sync)
    Writing/       MetadataWriteService (scrivi su Music, undo, log)
    Enrichment/    EnrichmentService (iTunes API + MusicBrainz)
    Normalization/ NormalizationService (generi, artisti, alias fuzzy)
    Duplicates/    DuplicateService + AudioFingerprinter (Chromaprint)
    Deletion/      DeletionService
    Divergence/    DivergenceService (confronto live DB ↔ Music.app)
    Model/         Track, TrackMetadataUpdate
    Common/        MusiFixError
  Persistence/
    AppDatabase.swift           DatabasePool GRDB
    DBTrack.swift               Tutte le struct DB (DBTrack, DBOperation, ecc.)
    DAO/                        TrackDAO, OperationDAO, SyncStateDAO
    Migrations/Migrations.swift Schema SQLite + migrazioni
  MusicBridge/                  Target ObjC: MusicBridgeObjC wrapper ScriptingBridge
```

## Principi architetturali

**Fonte di verità:** Apple Music (DB di Music.app). L'indice SQLite locale è una cache riconciliabile.

**Tutte le scritture passano via Music.app** (modalità M-A): `MetadataWriteService` → `AppleMusicBridge` → `ScriptingBridgeImpl` → `MusicBridgeObjC` → Music.app. Music aggiorna autonomamente i tag nei file fisici. Non si usa mai TagLib per scrivere in produzione.

**Concorrenza:** ogni servizio è un `actor` Swift. `MetadataWriteService` e `IndexService` serializzano l'accesso a Music e a SQLite. Le query di lettura GRDB sono concorrenti (pool 4 reader).

**Undo:** ogni scrittura inserisce righe in `operation_log` con snapshot "prima". `MetadataWriteService.undo(batchID:)` ripristina via bridge.

**Identità brano:** `persistentID` (stringa esadecimale assegnata da Music.app). È la chiave primaria in tutto il sistema.

## Pattern ricorrenti

- Nuova feature di scrittura → implementare in `MetadataWriteService`, aggiungere campo a `TrackMetadataUpdate` e al mapping in `ScriptingBridgeImpl.toObjCDict()`
- Nuovo filtro browser → aggiungere case a `TrackFilter` in `TrackDAO.swift` e gestirlo in `applyFilter`
- Nuovo campo DB → aggiungere colonna in `Migrations.swift` (nuova migrazione numerata), aggiungere proprietà a `DBTrack`

## DB location (runtime)

`~/Library/Application Support/MusiFix/musifixindex.db`

## Commit convention

Messaggi in italiano, prefisso per fase se rilevante (es. `Fase 6:`).
