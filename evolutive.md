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
| **G2** | Allineamento numeri traccia/disco da Store (singolo album) | Alta | Sì | D | ✅ |

Ordine di esecuzione: **A → B → G → D → D-bis → C → F → E → G2**.
Multi-disco: escluso dai fix automatici; la Fase G2 supporta multi-disco in modo nativo (disc-aware).

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

### Fase G2 — Allineamento numeri traccia/disco da Store  ✅

**Obiettivo:** dato un album, cerca le edizioni su iTunes e propone l'allineamento 1:1 dei numeri traccia/disco con la tracklist Store scelta. Disc-aware: supporta natively multi-disco.

**Flusso (2 step):**
1. **Scelta edizione** — `EnrichmentService.lookupAlbumCandidates` restituisce top-N candidati (nome, artista, anno, n.tracce, n.dischi, score). L'utente sceglie l'edizione corretta.
2. **Mappa di conferma editabile** — `AlbumService.proposeAlbumPositions` calcola il match 1:1 greedy e produce `[PositionProposal]`. Ogni riga mostra posizione attuale, abbinamento store, campi numerici editabili. Colore per confidenza. Niente viene scritto finché non si preme "Scrivi".

**Algoritmo match:**
- Normalizzazione titolo: fold diacritici, strip `(...)`, `[...]`, `- suffix`, `feat./ft.`, `&`→`and` → core lowercase.
- Similarità ibrida: `max(Jaccard(core), 1 − Levenshtein/maxLen)`.
- Assegnamento greedy 1:1 (per score decrescente, ogni store track usato una volta). Disco derivato dal match store, non dal tag locale.
- Post-pass: duplicati `(disco, traccia)` → declassati a `uncertain`.
- Conteggi coerenti per-disco: `trackCount` = max trackNumber sul disco, `discCount` = max disco store.

**Confidenza:**
- `high` (verde, pre-spuntata): `sim ≥ 0.80`, `Δ ≥ 0.25` o mutual, no qual-mismatch.
- `medium` (arancione): `0.55 ≤ sim < 0.80`.
- `uncertain` (rosso): `sim < 0.55`, o `Δ < 0.10`, o qual-mismatch (Live/Remastered), o conflitto greedy.
- `unmatched` (rosso, campi vuoti): nessun match trovato — da compilare a mano.

**Tracce senza match (bonus track, edizioni divergenti):** la riga rimane nella mappa con campi vuoti e confidenza `unmatched`. L'utente li compila manualmente; non vengono scritte se vuote.

**Multi-disco:** supportato nativamente. L'algoritmo aggrega tutte le tracce store e deriva `(disco, traccia)` dal match. Nessun cambiamento all'aggregazione `albumGroups`.

**File modificati:**
- `EnrichmentService.swift`: `StoreTrack` += `trackCount/discNumber/discCount`; nuovo `lookupAlbumCandidates`; `iTunesSong`/`iTunesAlbum` Codable aggiornati.
- `AlbumService.swift`: structs `TrackMatchConfidence`, `PositionProposal`, `AlbumAlignment`; metodi `proposeAlbumPositions(for:candidate:)`, `writeProposedPositions`; helpers `trackTitleCore`, `hybridTitleSimilarity`, `jaccardTokens`, `levenshtein`.
- `AlbumsView.swift`: `AlbumPositionAlignSheet` (2 step), `ProposalRow` (riga editabile), voce menu contestuale "Allinea numeri traccia/disco…".

## Note operative finali
1. **Reindex richiesto** ("Indicizza tutto") per popolare `cloudStatus` (abilita F ed E).
2. **Verifica codici cloudStatus** dopo il reindex: `SELECT cloudStatus, COUNT(*) FROM track GROUP BY cloudStatus;` — se compaiono codici non mappati, aggiornare `CloudStatus.init(code:)` in `Model/Track.swift`.
3. Lo scan online (D) è lento (~3 s/album): lanciarlo dalla Vista Album, è ripristinabile.

- 

---

## Evolutive (nuova serie) — stato

| Fase | Funzionalità | Stato |
|---|---|---|
| **11** | Copertine: iTunes hi-res (3000) + Deezer + Discogs (token) | ✅ |
| **12** | Anno pubblicazione: filtro/sort + vista raggruppata a sezioni | ✅ |
| **13** | Ignora in MusiFix (brano + album): esclusi da verifica completezza album e normalizzazione | ✅ |
| **14** | Ricerca Google embedded (finestra WKWebView, no browser esterno) | ✅ |
| **15** | Evidenziare brani non in playlist (escluse smart) + evidenziazione condizionale (assorbe "senza copertina") | ✅ |

### Fase 11 — Copertine ✅
- `EnrichmentService`: iTunes full 1400→3000 e limit 8→20; nuovi provider Deezer (no auth) e Discogs (token personale in UserDefaults `discogsToken`, popover ingranaggio in `EnrichmentSearchView`). `fetchImageData` invia User-Agent.

### Fase 12 — Anno di pubblicazione ✅
- `TrackDAO.fetchDistinctYears`; menu filtro "Anno pubbl." (`TrackFilter.year`); toggle "Raggruppa per anno" con group rows full-width in `TrackTableView`/`TrackBrowserViewModel` (`displayRows`).

### Fase 13 — Ignora in MusiFix ✅
- Migrazione **v9**: tabelle `track_ignore` / `album_ignore` + struct `DBTrackIgnore`/`DBAlbumIgnore`.
- `IgnoreService` (actor): ignore/unignore brano+album, `ignoredPIDsUnion`, `albumKey` coerente con AlbumDAO.
- Esclusione applicata a: **normalizzazione** (SQL NOT IN in `NormalizationService`) e **verifica completezza album** (`AlbumService`: `verifyAlbumsOnline`, `incompleteAlbums`, `completeVerifiedWithoutTag`).
- UI: menu contestuale in `TrackTableView` (ignora brano/i + album) e `AlbumsView` (ignora album), attenuazione righe/indicatore "Ignorato", filtro `TrackFilter.ignored` (icona nosign in toolbar).

### Fase 14 — Ricerca Google embedded ✅
- `WebSearchSheet` + `WebView` (WKWebView) in `ContentView`; pulsante toolbar (brano singolo) + voce menu contestuale "Cerca su Google" in `TrackTableView`. Query = titolo · artista · anno, finestra interna (no browser esterno).

### Fase 15 — Non in playlist + evidenziazione condizionale ✅
- Bridge ObjC: `MusicUserPlaylist` (smart/specialKind) + `userPlaylists`; `regularPlaylistTrackPersistentIDs` (bulk `arrayByApplyingSelector`, salta smart/cartelle/speciali). Fallback NSAppleScript.
- `AppleMusicBridge.tracksInRegularPlaylists()`; migrazione **v10** colonna `inPlaylist` (NULL/0/1) + indice; `IndexService.scanPlaylistMembership()`; pulsante toolbar "Scansiona playlist".
- Filtro `TrackFilter.notInAnyPlaylist` (icona list.bullet.rectangle).
- Evidenziazione condizionale di riga (`HighlightRowView`): "Non in playlist" (arancione) e "Senza copertina" (blu), con toggle nel popover impostazioni tabella; set caricate in `ContentView` (`TrackDAO.fetchNotInPlaylistPIDs`/`fetchMissingArtworkPIDs`) e ricaricate a fine scansione.
- ⚠️ `inPlaylist`/`hasArtwork` non sono nel modello `DBTrack` (come da design): rieseguire "Scansiona playlist"/"Scansiona copertine" dopo un reindex completo.

## Evolutive (serie 3) — piano dalle idee future

Dalle "idee future". Ambito confermato con l'utente: **implementare tutto**.
Decisioni prese: playlist di verifica = cartella **WORK** → playlist **ToCheck**;
pulsanti web = **finestra interna** (WKWebView, come Fase 14); sync automatica =
**reindex incrementale + riscansione playlist/copertine**.

| Fase | Funzionalità | Complessità | Rete | Dipende da | Stato |
|---|---|---|---|---|---|
| **16** | Ricerca web nell'editor (Google + Wikipedia, finestra interna) | Bassa | Sì (WebView) | 14 | ✅ |
| **17** | Copia file del brano (se scaricato) in cartella a scelta | Bassa | No | — | ✅ |
| **18** | Playlist "Da verificare" → WORK/ToCheck (crea se assente) | Media | No | — | ✅ |
| **19** | Playlist per brano + Vista Playlist + copia file cartella | Alta | No | 17, 18 | ✅ |
| **20** | Sincronizzazione automatica in background | Media | No | — | ⬜ |

### Fase 16 — Ricerca web nell'editor ✅
- Generalizzare `WebSearchSheet` con un enum `WebSearchEngine` (Google, Wikipedia): query e URL derivati dal brano. Wikipedia via `it.wikipedia.org/w/index.php?search=…` (nessuna API/limite: è la pagina di ricerca standard). Google resta come Fase 14.
- `TrackEditorPanel`: due pulsanti nella barra strumenti ("Cerca su Google", "Wikipedia") che aprono la finestra interna sul brano corrente.
- **File:** `ContentView.swift` (WebSearchSheet parametrico), `TrackEditorPanel.swift`.

### Fase 17 — Copia file brano in cartella ✅
- `FileCopyService` (core, actor): dato un insieme di pid, copia i file locali esistenti in una cartella destinazione; salta i brani cloud-only / senza file; ritorna esito (copiati/saltati/falliti + conflitti nome risolti con suffisso).
- UI: menu contestuale "Copia file in cartella…" (selezione) + pulsante nell'editor; `NSOpenPanel` per la cartella; alert riepilogo.
- **File:** `Packages/.../FileTransfer/FileCopyService.swift` (nuovo), `ContentView.swift`, `Browser/TrackTableView.swift`, `TrackEditorPanel.swift`, `AppState.swift`.

### Fase 18 — Playlist "Da verificare" (WORK/ToCheck) ✅
- Bridge ObjC: `ensurePlaylistNamed:inFolderNamed:` → crea (se assenti) cartella `WORK` e playlist `ToCheck` al suo interno, ritorna il persistentID della playlist. Riusa `userPlaylists`, crea via `make new`.
- `PlaylistService.ensureToCheckPlaylist()` + `markForVerification(pids:)` (ensure + addTracks con de-dup).
- UI: menu contestuale "Segna come da verificare (WORK/ToCheck)" + pulsante editor; feedback via alert playlist esistente.
- **File:** `MusicBridgeObjC.{h,m}`, `AppleMusicBridge.swift`, `ScriptingBridgeImpl.swift`, `PlaylistService.swift`, `ContentView.swift`, `TrackTableView.swift`, `TrackEditorPanel.swift`.

### Fase 19 — Playlist per brano + Vista Playlist ✅
> Nota: "Scansiona playlist" ora esegue la scansione *dettagliata* (`scanPlaylistFull`),
> che popola anche `playlist`/`playlist_track` oltre al flag `inPlaylist`.

- Bridge: `playlistMembership` → per ogni playlist normale/cartella: id, nome, parentID, isFolder, `trackIDs`. Un solo passaggio (bulk `arrayByApplyingSelector`).
- Migrazione **v11**: tabelle `playlist(id, name, parentID, isFolder, scannedAt)` e `playlist_track(playlistID, pid)` + indici; struct DB relative.
- `IndexService.scanPlaylistFull()` popola le due tabelle; pulsante/uso condiviso con "Scansiona playlist".
- DAO: `playlistsForTrack(pid)`, `tracksInPlaylist(id)`.
- UI: `TrackEditorPanel` mostra le playlist (non-smart) del brano come chip; nuova **Vista Playlist** (terzo modo o sheet) con elenco playlist → brani e azione "Copia file in cartella…" (nome cartella proposto = nome playlist, riusa Fase 17).
- **File:** bridge, migrazioni, `IndexService.swift`, nuovo `PlaylistDAO.swift`, `PlaylistsView.swift`, `ContentView.swift`, `TrackEditorPanel.swift`.

### Fase 20 — Sincronizzazione automatica ⬜
- Impostazioni (`AppStorage`): `autoSyncEnabled`, `autoSyncMinutes`. `AppState` schedula un `Task` periodico che, se non è già in corso un'indicizzazione, esegue sync incrementale + riscansione playlist e copertine, poi ricarica le set di evidenziazione.
- UI: popover impostazioni (toggle + intervallo) in toolbar.
- **File:** `AppState.swift`, `ContentView.swift`.

## Anomalie

- ✅ **Copertina "Cerca online"**: la sheet ora si chiude dopo "Applica a questo brano/album" e l'editor rilegge la copertina con qualche tentativo (la persistenza nella cloud library non è immediata, per questo prima "non sembrava salvata"). Fix in `EnrichmentSearchView.swift` + `ArtworkEditorView.swift`.

