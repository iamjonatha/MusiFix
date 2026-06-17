# MusiFix — Piano evolutive: gestione Album

Stato avanzamento delle nuove funzionalità di gestione album. Aggiornare la colonna
**Stato** ad ogni avanzamento: ⬜ da fare · 🔄 in corso · ✅ fatto.

## Dati libreria (base di stima, snapshot iniziale)

| Metrica | Valore |
|---|---|
| Tracce totali | 24.358 |
| Album distinti (albumArtist+album) | 8.093 |
| Album con tag *trackCount* valorizzato | 2.494 |
| Album incompleti rilevabili offline (count < tag) | 860 |
| "Album" con 1 sola traccia | 6.122 |
| Tracce senza file locale (`isCloudOnly`) | 6.688 |

**Nota critica:** i valori di `kind` sono localizzati in italiano ("acquistato",
"abbinato", "File audio MPEG") e non esiste un `kind` per "caricato" (uploaded).
La logica `isCloudOnly` attuale in `IndexService` cerca stringhe inglesi
("apple music"/"matched") mai presenti → va corretta in Fase C tramite la
proprietà reale `cloudStatus` di Music.app.

## Sequenza e stato fasi

| Fase | Funzionalità | Complessità | Rete | Dipende da | Stato |
|---|---|---|---|---|---|
| **A** | Normalizzazione "- Single" (batch manuale) | Molto bassa | No | — | ✅ |
| **B** | Report album incompleti offline (via tag) | Bassa | No | — | ✅ |
| **G** | Vista Album (hub UI) | Media | No | B | ✅ |
| **D** | Verifica online completezza + cache persistente | Media | Sì (lento) | — | ✅ |
| **D-bis** | Scrittura massiva trackCount/discCount | Bassa | Sì | D | ✅ |
| **C** | `cloudStatus` nel bridge + reindex | Alta | No | — | ✅ (richiede reindex) |
| **F** | Report album con tracce non abbinate/caricate | Media | No | C | ✅ |
| **E** | Diff durate caricato vs Store | Media-alta | Sì | C, D | ✅ |

Ordine di esecuzione: **A → B → G → D → D-bis → C → F → E**.
Multi-disco: escluso in fase 1 (album con `discCount>1` marcati e saltati nelle fasi online).

---

## Dettaglio fasi

### Fase A — Normalizzazione "- Single" (batch manuale)  ✅
**Obiettivo:** azione su selezione multipla nel browser che appende ` - Single` al campo `album`.
- Core: `AlbumService.markAsSingle(pids:useTrackNameAsAlbum:)` → riusa `MetadataWriteService.writeBatch`. Guard anti-doppio suffisso (salta album che già finiscono con `- Single`).
- UI: voce menu contestuale in `TrackTableView` (opera sulla selezione, o sulla riga cliccata se fuori selezione) → `confirmationDialog` in `ContentView`.
- Undo/log automatici via operation_log.
- **File:** `Albums/AlbumService.swift` (nuovo), `AppState.swift`, `Browser/TrackTableView.swift`, `ContentView.swift`.

### Fase B — Report album incompleti offline  ✅
- DAO: `AlbumDAO.fetchAlbumGroups` (nuovo file `Persistence/DAO/AlbumDAO.swift`) → struct `AlbumGroup` + enum `AlbumCompleteness` (complete/incomplete/excess/unknown/multiDisc).
- Raggruppamento per `LOWER(albumArtist|artist) + CHAR(31) + LOWER(album)`, esclusi album vuoti e singoli.
- `AlbumService.albumGroups()` / `incompleteAlbums()`.
- Multi-disco (`tagDiscCount>1`) → stato `multiDisc`, escluso dal flag incompleto.
- Perf: singola query, < 1 s.

### Fase G — Vista Album (hub UI)  ✅
- UI: `MusiFixApp/MusiFixApp/Albums/AlbumsView.swift` (aggiunto al target in `project.pbxproj`, gruppo Albums, ID AA/BB000035, EE000009).
- Pulsante toolbar (icona `square.stack`) + sheet in `ContentView`.
- Filtro segmentato (Tutti/Incompleti/Senza tag/Completi/Eccesso), badge `count/totale`, indicatore completezza, conteggio solo-cloud.
- Doppio click → `browser.filter = .album(...)` e chiude.
- Hub per le fasi D-bis, F, E.

### Fase D — Verifica online completezza + cache  ✅
- `EnrichmentService.lookupAlbum(albumArtist:album:)` → (collectionId, storeTrackCount) via iTunes entity=album, best match con `tokenSimilarity` (soglia 0.5).
- Rate limiter dedicato `albumScanRate` a 3 s.
- Cache: migrazione **v6** + tabella `album_store_info` + struct `DBAlbumStoreInfo`.
- `AlbumService.verifyAlbumsOnline(force:progress:)`: scansiona solo album «senza tag», ripristinabile (salta quelli in cache), cancellabile. Errori di rete → non salvati (ritentati).
- `AlbumService.storeInfoByKey()` per la lettura cache.
- UI: barra in `AlbumsView` con conteggio «senza tag», pulsante "Verifica online", progress + interrompi. Le righe «senza tag» mostrano il conteggio/stato derivato dallo Store.
- Multi-disco escluso (gli album «senza tag» hanno discCount 0; i multi-disco con tag sono già stato `multiDisc`).

### Fase D-bis — Scrittura massiva trackCount/discCount  ✅
- `AlbumService.completeVerifiedWithoutTag()` → album senza tag risultati completi (store==actual).
- `AlbumService.writeTrackCounts()` → scrive trackCount(=store) + discCount=1 via writeBatch (undo automatico).
- UI: pulsante "Scrivi conteggi verificati…" + sheet `AlbumCountFixSheet` con checkbox per album. Solo mono-disco.

### Fase C — `cloudStatus` nel bridge + reindex  ✅ (richiede reindex)
- `Music_private.h`: aggiunto enum `MusicEClS` (kMat/kUpl/kPur/kSub/…), `cloudStatus` corretto da BOOL a `(readonly) MusicEClS`.
- `MusicBridgeObjC`: `MBKeyCloudStatus`, helper `osTypeToString`, lettura guarded (@try/@catch) in `trackToDictionary`.
- `Track.cloudStatus` (String 4-char) + enum semantico `CloudStatus` (label IT + `isCloudHosted`).
- Parsing in `ScriptingBridgeImpl`; migrazione **v5** colonna `cloudStatus`; proprietà in `DBTrack`.
- `IndexService`: mappa cloudStatus + **fix `isCloudOnly`** (ora basato su `CloudStatus.isCloudHosted`, non più sulle stringhe inglesi del `kind` mai presenti nella libreria IT).
- ⚠️ **Richiede un reindex completo** ("Indicizza tutto") per popolare `cloudStatus` sulle tracce esistenti.

### Fase F — Report album con tracce non abbinate/caricate  ✅
- `AlbumGroup.cloudStatusCounts` + `hasMixedCloudStatus` (aggregazione `GROUP_CONCAT(cloudStatus)` in `AlbumDAO`).
- UI: filtro "Cloud misto" + riepilogo stati nella riga album (es. "Abbinato 8 · Caricato 2", arancione se misto).
- Richiede reindex (Fase C) per dati cloudStatus reali.

### Fase E — Diff durate caricato vs Store  ✅
- `EnrichmentService.lookupCollectionTracks(collectionId:)` (entity=song, trackTimeMillis).
- `AlbumService.durationDiffs(for:threshold:)` → filtra tracce uploaded, match per titolo (similarità ≥0.6), soglia 2 s.
- UI: menu contestuale "Confronta durate (caricati)" sull'album + sheet `DurationDiffSheet`.

---

## Rifiniture UI (post-fasi)
- **Vista Album incorporata** (non più sheet): toggle segmentato Brani/Album nella toolbar di `ContentView`; `AlbumsView` refactor a vista inline (rimosso `isPresented`/frame fisso).
- **Drill ai brani**: doppio click / menu "Apri brani per modifica" → filtra browser su album + torna alla vista brani (editor in-place). `onOpenTracks`.
- **Zoom copertina**: clic su copertina album/brano → `ArtworkZoomPopover` (400px + risoluzione). In `AlbumArtwork` e `ArtworkEditorView`.

## Note operative finali
1. **Reindex richiesto** ("Indicizza tutto") per popolare `cloudStatus` (abilita F ed E).
2. **Verifica codici cloudStatus** dopo il reindex: `SELECT cloudStatus, COUNT(*) FROM track GROUP BY cloudStatus;` — se compaiono codici non mappati, aggiornare `CloudStatus.init(code:)` in `Model/Track.swift`.
3. Lo scan online (D) è lento (~3 s/album): lanciarlo dalla Vista Album, è ripristinabile.
