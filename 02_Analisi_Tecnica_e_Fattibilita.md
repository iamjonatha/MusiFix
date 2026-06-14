# Analisi Tecnica e di Fattibilità — Gestore Libreria Apple Music (macOS)

**Nome di lavoro:** *MusicLibrarian*
**Versione documento:** 1.0
**Data:** 14 giugno 2026
**Approccio scelto:** App Mac nativa (Swift/SwiftUI) con indice interno persistente

---

## 0. Sintesi esecutiva (TL;DR)

L'idea è **fattibile**, ma il vero nodo non è l'editing dei tag (problema risolto da anni): è **far convivere le modifiche con iCloud Music Library** senza che vengano annullate e senza spostare/rinominare i file.

Conclusione tecnica chiave: **con Sync Library attiva, la fonte di verità è il database di Apple Music, non i tag nei file.** Scrivere solo nei file è inaffidabile (le modifiche possono essere ignorate o sovrascritte all'"Aggiorna libreria iCloud"). La strategia robusta è **scrivere attraverso Apple Music** (Apple Events/AppleScript) per i campi standard, eventualmente affiancata dalla scrittura nei file per i casi non coperti, mantenendo un **indice interno** (SQLite) che riconcilia continuamente lo stato.

Stack raccomandato: **app nativa Swift + SwiftUI**, **SQLite (GRDB)** per l'indice, **TagLib** (via wrapper) per la lettura/scrittura tag a basso livello quando serve, **Apple Events/ScriptingBridge** per l'integrazione con Apple Music, **Chromaprint/AcoustID** opzionale per i duplicati basati su contenuto, e una **strategia multi-sorgente** per copertine/anno con l'utente nel controllo.

Avvertenza di piattaforma: su **macOS 26 (Tahoe)** sono stati segnalati problemi con ScriptingBridge verso Apple Music ([Apple Developer Forums](https://developer.apple.com/forums/thread/801357)); va previsto un fallback su Apple Events grezzi/`NSAppleScript` e va validato per prima cosa con un PoC.

---

## 1. Il problema centrale: Apple Music + iCloud Music Library

### 1.1 Come Apple Music tratta i metadati
Quando **Sync Library (iCloud Music Library)** è attiva, ogni brano locale viene **abbinato (matched)** o **caricato (uploaded)** al cloud, e il **database di Music** (`Music Library.musiclibrary`, in `~/Music/Music/`) diventa la fonte di verità per i metadati. Conseguenze documentate dalla community:

- Modificando i tag **nel file** e poi eseguendo *"Aggiorna libreria iCloud"*, i metadati possono **tornare allo stato precedente** (override dal cloud) — problema ricorrente ([Apple Community 1](https://discussions.apple.com/thread/253598645), [Apple Community 2](https://discussions.apple.com/thread/253800621), [Apple Community 3](https://discussions.apple.com/thread/7371256)).
- Editando i campi **dentro Music** la modifica viene salvata nel DB e **sincronizzata** correttamente (con limitazioni note su alcuni campi, es. titolo di brani "matched").

### 1.2 "Mantieni organizzata la cartella" vs vincolo "non spostare/rinominare"
L'opzione *Keep Music Media folder organized* consente a Music di **rinominare/riposizionare** i file in base ai tag. In pratica si comporta in modo incoerente (a volte rinomina solo aggiungendo uno spazio al titolo, ecc. — [Apple Community](https://discussions.apple.com/thread/251926152)), ma rappresenta un **rischio diretto per i vincoli V1/V2** (no move, no rename).

**Implicazione progettuale:** preferire la scrittura via Music per i **campi che Music gestisce nel DB senza toccare il file** (la maggior parte dei metadati editoriali non forza la rinomina), e verificare sempre, dopo ogni operazione, che il **percorso del file non sia cambiato** (l'indice conserva il path precedente e lo confronta). In caso di rinomina rilevata, segnalare e riconciliare.

### 1.3 Cosa può e non può fare l'automazione di Music
- AppleScript/Apple Events **possono** leggere e **scrivere le proprietà dei track** della libreria (titolo, artista, album artist, album, anno/`year`, genere, numero traccia, ecc.) e **impostare l'artwork**. Queste modifiche entrano nel DB di Music e quindi **si sincronizzano** con iCloud.
- AppleScript **non** può manipolare direttamente lo stato "cloud" (matched/uploaded) né operare sui contenuti esclusivamente cloud ([Doug's AppleScripts — iCloud category](https://dougscripts.com/itunes/category/icloud-music-library/)). Ma per i nostri scopi (brani scaricati in locale) questo non è bloccante: si modifica la voce di libreria e Music propaga.
- `location` di un track espone il percorso del file → utile per collegare la voce di Music alla riga dell'indice/file system.

> **Decisione architetturale n.1.** Per i campi standard si usa la **scrittura via Apple Music (modalità M-A)**: garantisce coerenza con iCloud e non innesca rinomine se non si toccano i pattern di organizzazione. La scrittura diretta nei file (M-B/M-C) è un fallback per casi specifici.

---

## 2. Architettura proposta

### 2.1 Vista a strati

```
┌──────────────────────────────────────────────────────────────┐
│  UI Layer — SwiftUI + AppKit dove serve                       │
│  (tabella virtuale 25k righe, pannelli editing, duplicati,    │
│   normalizzazione, anteprime diff, code operazioni)           │
├──────────────────────────────────────────────────────────────┤
│  Application / Services Layer                                  │
│   • IndexService (sync incrementale, riconciliazione)         │
│   • MetadataWriteService (M-A / M-B / M-C, coda transazionale)│
│   • EnrichmentService (cover + anno, multi-sorgente)          │
│   • NormalizationService (generi/artisti, regole)             │
│   • DuplicateService (fuzzy + fingerprint opzionale)          │
│   • DeletionService (salvaguardie, Cestino, log)              │
├──────────────────────────────────────────────────────────────┤
│  Integration Layer                                            │
│   • AppleMusicBridge (Apple Events / ScriptingBridge / OSA)   │
│   • TagIO (TagLib wrapper per MP3/M4A)                        │
│   • FileSystem (security-scoped bookmarks, FSEvents)          │
│   • Network (provider copertine/anno, fingerprint)            │
├──────────────────────────────────────────────────────────────┤
│  Persistence Layer                                            │
│   • SQLite (GRDB) — indice, snapshot/undo, log, cache         │
│   • Artwork cache (file su disco)                             │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 Principi
- **Single source of truth runtime = indice SQLite**; **source of truth dei dati = Apple Music**. L'indice è una proiezione riconciliabile, non un sostituto.
- **Tutte le scritture passano da una coda transazionale** con snapshot del "prima" (per undo) e log.
- **Operazioni idempotenti e ripristinabili**; nessun passaggio che lasci l'indice incoerente in caso di crash.
- **Verifica post-scrittura** (read-back) per confermare che il dato sia effettivamente in Music e che il path non sia cambiato.

---

## 3. Stack tecnologico raccomandato

| Ambito | Scelta raccomandata | Alternative / note |
|--------|--------------------|--------------------|
| Linguaggio/UI | **Swift + SwiftUI** (con AppKit per la tabella ad alte prestazioni) | Objective-C non necessario; SwiftUI `Table` o `NSTableView` ospitato |
| Persistenza indice | **SQLite via GRDB.swift** | Core Data possibile ma GRDB offre controllo SQL fine, FTS5 e prestazioni migliori su 25k+ righe |
| Ricerca testo | **SQLite FTS5** | indicizzazione full-text per ricerca as-you-type |
| Tag I/O file | **TagLib** (wrapper Swift/C++) | È il motore usato dai migliori editor (es. *Meta*). In alternativa **swift-audio-marker** (puro Swift, zero dipendenze, ID3v2 + MP4 a livello di byte) — ottimo se si vuole evitare C++ |
| Integrazione Apple Music | **Apple Events** via `ScriptingBridge` + fallback `NSAppleScript`/`OSAKit` | Necessario gestire entitlement automazione; PoC prioritario causa regressioni su macOS 26 |
| Lettura artwork/metadati audio | **AVFoundation** (`AVAsset`/`AVMetadataItem`) per lettura robusta; scrittura via TagLib/M-A | AVFoundation in scrittura tag è limitato → preferire TagLib per write su file |
| Fingerprint audio (dedup avanzato) | **Chromaprint** (lib C) + servizio **AcoustID** opzionale | Per dedup locale basta il confronto di fingerprint, senza chiamare AcoustID |
| Fuzzy matching | Algoritmi di distanza (Levenshtein/Jaro-Winkler/token-set) | Implementazione interna o piccola lib |
| Networking | `URLSession` async/await | con rate limiting e caching |
| Immagini | `CoreImage`/`ImageIO` per resize/encode copertine | controllo qualità/peso |
| Concorrenza | **Swift Concurrency** (async/await, actors) | `actor` per serializzare l'accesso a Music e all'indice |
| Watch file system | **FSEvents** | rilevare modifiche esterne ai file |
| Sandbox/permessi | **Security-scoped bookmarks**, entitlement Automation | vedi §8 |

### 3.1 MP3 vs M4A: gestione del mapping
I due formati hanno modelli di tag diversi e l'app deve presentarli in modo uniforme:

| Campo logico | MP3 (ID3v2.3/2.4) | M4A (atomi MP4/iTunes) |
|--------------|-------------------|------------------------|
| Titolo | `TIT2` | `©nam` |
| Artista | `TPE1` | `©ART` |
| Artista album | `TPE2` | `aART` |
| Album | `TALB` | `©alb` |
| Anno | `TDRC` (v2.4) / `TYER` (v2.3) | `©day` |
| Genere | `TCON` | `©gen` (o `gnre`) |
| N. traccia | `TRCK` | `trkn` |
| Disco | `TPOS` | `disk` |
| Copertina | `APIC` | `covr` |
| Compilation | `TCMP` | `cpil` |

TagLib astrae buona parte di queste differenze tramite la sua `PropertyMap`, ma per i casi delicati (es. anno in ID3v2.3 vs 2.4) va gestita logica esplicita. **Raccomandazione:** standardizzare gli MP3 su **ID3v2.4 UTF-8** in scrittura, preservando la compatibilità in lettura.

---

## 4. Indice interno e sincronizzazione

### 4.1 Modello dati (estratto)

```
track(
  id INTEGER PK,
  music_persistent_id TEXT,     -- ID stabile in Apple Music
  file_path TEXT,               -- percorso assoluto (verificato, mai modificato dall'app)
  file_format TEXT,             -- 'mp3' | 'm4a'
  title, artist, album_artist, album, genre TEXT,
  year INTEGER,
  track_no, track_total, disc_no INTEGER,
  duration_ms INTEGER,
  bitrate INTEGER,
  has_artwork INTEGER,
  content_hash TEXT,            -- hash rapido (es. su header+campione) per change-detection
  audio_fingerprint TEXT,       -- chromaprint, opzionale
  file_mtime INTEGER,
  added_at INTEGER,
  sync_state TEXT,              -- in_sync | local_modified | error | cloud_only
  last_seen_at INTEGER
)

genre_alias(variant TEXT, canonical TEXT)
artist_alias(variant TEXT, canonical TEXT)
operation_log(id, ts, type, track_id, field, old_value, new_value, write_mode, source, result)
enrichment_cache(query_key, provider, payload, ts)
```

### 4.2 Strategia di sincronizzazione incrementale
La riscansione completa di 25k file a ogni avvio è da evitare. Approccio a costo crescente:

1. **Delta da Apple Music.** Interrogare la libreria di Music (via Apple Events) per ottenere l'elenco track con `persistent id`, `modification date`/`date added` e `location`. Confrontare con l'indice: nuovi / rimossi / modificati. È l'origine primaria perché riflette la fonte di verità.
2. **Delta da file system.** Usare **FSEvents** per ricevere notifiche sui file cambiati mentre l'app è chiusa/aperta; al riavvio leggere lo storico FSEvents (event ID persistito) per sapere cosa è cambiato senza scansionare tutto.
3. **Verifica leggera.** Per i candidati "modificati" leggere solo `mtime`/dimensione e, se necessario, rileggere i tag del singolo file.
4. **Riconciliazione.** Aggiornare l'indice e marcare divergenze (es. dato in Music ≠ dato nel file) per revisione.

> La prima indicizzazione completa (necessariamente O(n)) è eseguita una sola volta, con avanzamento e ripresa; le successive sono delta.

### 4.3 Prestazioni
- Lettura tag in **parallelo** (pool di task) ma con **scrittura serializzata** verso Music (un `actor`), perché l'automazione di Music non ama la concorrenza.
- Batch di operazioni Apple Events per ridurre l'overhead inter-processo.
- UI su tabella **virtualizzata** (rende solo le righe visibili); dati paginati dall'indice.

---

## 5. Scrittura metadati: dettaglio delle modalità

### M-A — Via Apple Music (default per campi standard)
- Individuare il track in Music tramite `persistent id` (o `location`).
- Impostare le proprietà (`name`, `artist`, `album artist`, `album`, `year`, `genre`, `track number`, ecc.).
- Impostare l'artwork (`data of artwork 1`).
- **Read-back** della proprietà per conferma; aggiornare l'indice; loggare.
- **Pro:** coerenza con iCloud garantita, nessun rischio di revert, nessuna rinomina file. **Contro:** dipende dall'automazione di Music (vincolo di piattaforma, vedi §0/§8); alcuni campi possono avere limitazioni (es. titolo di brani "matched").

### M-B — Via file + refresh
- Scrivere il tag nel file con TagLib.
- Forzare il riconoscimento da parte di Music (es. rimozione+re-add controllato della voce, o trigger di refresh). **Attenzione:** con Sync Library il rischio è il revert dal cloud.
- Usare **solo** per campi non gestibili in M-A o per file non in libreria.

### M-C — Solo file
- Per file non presenti in Apple Music. Nessuna garanzia di propagazione (per definizione fuori da Music).

> **Regola operativa:** l'app tenta M-A; se il campo non è impostabile via Music o l'operazione fallisce, propone M-B con avviso esplicito dei rischi. Ogni operazione registra la modalità usata.

---

## 6. Arricchimento online: copertina + anno

L'utente riferisce che la ricerca "su Google" ha reso meglio di Discogs/MusicBrainz. Tradotto in strategia tecnica sostenibile:

### 6.1 Strategia multi-sorgente raccomandata
1. **iTunes/Apple Music Search API** (pubblica, senza chiave, ottima per copertine ad alta risoluzione e anno di pubblicazione di release commerciali). È spesso la **migliore prima scelta** per una libreria allineata ad Apple, perché restituisce esattamente l'artwork del catalogo Apple. Endpoint pubblico, alta risoluzione ottenibile manipolando l'URL dell'immagine.
2. **Cover Art Archive + MusicBrainz** come seconda sorgente (buona copertura, dati strutturati, licenza chiara).
3. **Discogs API** come terza sorgente (forte su edizioni/anno preciso).
4. **Ricerca immagini web generica** come *fallback assistito*: utile per casi rari, ma con cautele legali e qualità variabile; va trattata come suggerimento da confermare manualmente, non come pipeline automatica massiva.

> **Perché non "solo Google".** L'esperienza dell'utente con Google è comprensibile (recall altissimo), ma un'app non può fare scraping massivo dei risultati immagini di Google in modo affidabile/lecito. La combinazione **iTunes Search API (primaria) + MusicBrainz/CoverArtArchive + Discogs**, con **ricerca web come fallback manuale**, replica quel "recall" restando robusta, legale e automatizzabile. Per una libreria Apple, la iTunes Search API tende a dare proprio le copertine che l'utente si aspetta di vedere in Apple Music.

### 6.2 Pipeline
- Costruire la query da artista album + album (e durata/traccia per disambiguare).
- Interrogare le sorgenti in ordine, con **caching** (`enrichment_cache`) e **rate limiting**.
- Raccogliere candidati (immagine + risoluzione + anno + provider + score di confidenza).
- **Modalità assistita** (default): mostrare candidati, l'utente sceglie. **Modalità automatica**: applicare il miglior candidato sopra soglia, sempre revisionabile.
- Normalizzare l'immagine (resize/encode) prima dell'embedding.
- Applicare via M-A; tracciare la **fonte** del dato.

### 6.3 Note legali/etiche
- Copertine: uso personale; tracciare provenienza. Evitare scraping aggressivo; rispettare i ToS delle API.
- Nessun upload dei file audio a servizi esterni senza consenso (rilevante per il fingerprint, §7).

---

## 7. Rilevamento duplicati

### 7.1 Due livelli complementari
1. **Metadati (richiesto): stesso artista + titolo simile.**
   - Normalizzare artista e titolo (lowercase, rimozione "feat.", parentesi, punteggiatura).
   - Fuzzy match sul titolo (es. **Jaro-Winkler**/token-set ratio) con soglia configurabile.
   - Conferma con **durata** (Δ entro pochi secondi) per ridurre i falsi positivi.
   - Blocking per chiave (artista normalizzato) per evitare confronti O(n²) sull'intera libreria.
2. **Contenuto (raccomandato, opzionale): fingerprint audio con Chromaprint.**
   - Genera un fingerprint compatto (~2.5 KB, <100 ms su 2 min) analizzando l'inizio del brano ([AcoustID/Chromaprint](https://acoustid.org/chromaprint)).
   - Confronto di similarità tra fingerprint → individua **stessi brani con metadati diversi** e **coppie MP3/M4A** dello stesso brano (caso esplicito dell'utente).
   - Può funzionare **interamente in locale** (nessuna chiamata ad AcoustID), preservando la privacy. Tool di riferimento concettuale: [soundalike](https://codeberg.org/derat/soundalike).

### 7.2 Presentazione e scelta
- Gruppi di duplicati con confronto (formato, bitrate, durata, copertina, percorso).
- Suggerimento del "keeper" per regole (es. preferisci M4A/AAC, bitrate maggiore, con copertina).
- Azioni → eliminazione dei ridondanti via DeletionService (§8).

---

## 8. Integrazione, permessi e vincoli di piattaforma

### 8.1 Automazione di Apple Music
- Richiede l'entitlement **Apple Events / Automation** e l'autorizzazione utente (TCC: "Controlla Music"). Prima esecuzione → prompt di sistema.
- **Rischio noto:** su **macOS 26 (Tahoe)** ScriptingBridge verso Music ha avuto regressioni ([forum Apple](https://developer.apple.com/forums/thread/801357)) e cambi di comportamento già visti in passato (Big Sur, [forum](https://developer.apple.com/forums/thread/669239)). **Mitigazione:** astrarre l'integrazione dietro `AppleMusicBridge` con due implementazioni (ScriptingBridge e Apple Events grezzi/`NSAppleScript`), selezionabili a runtime; **PoC iniziale obbligatorio** per validare lettura/scrittura/artwork sulla versione di macOS dell'utente.

### 8.2 Sandbox e distribuzione
- **App non sandboxed o con eccezioni temporanee** per accedere liberamente a `~/Music` e automatizzare Music è più semplice; per distribuzione su Mac App Store il sandbox impone **security-scoped bookmarks** e l'entitlement automazione, con più attriti. **Raccomandazione:** per uso personale, distribuzione **Developer ID + notarizzazione** (fuori App Store), che semplifica permessi e automazione mantenendo la sicurezza.
- Accesso ai file via **security-scoped bookmarks** sulla cartella radice `Music`.

### 8.3 Coerenza con iCloud ed eliminazioni
- L'eliminazione di una voce in Music con Sync Library attiva **si propaga agli altri dispositivi**: l'app deve spiegarlo chiaramente.
- Preferire lo spostamento del file nel **Cestino** (recuperabile) anziché `unlink` definitivo.
- Doppia conferma sopra soglia; log completo; nessuno spostamento/rinomina al di fuori dell'eliminazione esplicita.

---

## 9. Backup, sicurezza dati, undo

- **Snapshot pre-modifica** in `operation_log` (valori vecchi) → **undo** dei metadati.
- **Export/backup dell'indice** (SQLite) e delle regole di normalizzazione.
- Raccomandare all'utente un **backup Time Machine** e/o copia di `Music Library.musiclibrary` prima delle prime operazioni di massa.
- Operazioni batch sempre precedute da **anteprima diff**.

---

## 10. Alternative architetturali valutate

| Opzione | Pro | Contro | Verdetto |
|---------|-----|--------|----------|
| **App nativa Swift + indice (scelta)** | Prestazioni, UX, integrazione profonda con Music, controllo totale | Maggiore sforzo di sviluppo | **Raccomandata** |
| Script Python/AppleScript attorno a Music | Veloce da prototipare; `python-itunes`/`appscript`/mutagen | UX povera su 25k brani; niente indice/duplicati avanzati; fragile | Buono per **PoC**/utility, non come prodotto |
| Estendere **Yate** (azioni/script) | Riusa un editor maturo | L'utente l'ha già scartato; personalizzazione limitata sul flusso iCloud | Sconsigliato come base |
| Editor file puri (Meta, Mp3tag) | Ottimi per tag | **Non risolvono il problema iCloud** (scrivono nei file → rischio revert) | Insufficienti per V3 |

> **Su "non reinventare nulla".** Si possono **riusare componenti** maturi (TagLib, Chromaprint, GRDB, iTunes/MusicBrainz/Discogs API) dentro un'app nativa che orchestra il flusso specifico richiesto. Ma il **valore aggiunto** — coerenza con iCloud + indice + dedup + normalizzazione su 25k brani senza spostare i file — non esiste pronto: va costruito. Gli editor di tag esistenti falliscono proprio sul requisito iCloud.

---

## 11. Fattibilità: sintesi per area

| Requisito | Fattibilità | Rischio | Note |
|-----------|-------------|---------|------|
| Editing metadati MP3/M4A | **Alta** | Basso | TagLib/M-A maturi |
| Copertine add/replace | **Alta** | Basso | TagLib + M-A |
| Cover+anno online | **Alta** | Medio | multi-sorgente; "solo Google" non automatizzabile in modo lecito |
| Raggruppa/ordina/filtra/cerca | **Alta** | Basso | SQLite + FTS5 |
| Normalizzazione generi/artisti | **Alta** | Basso | regole + fuzzy |
| Duplicati (metadati) | **Alta** | Medio | soglie/falsi positivi |
| Duplicati (fingerprint) | **Media-Alta** | Medio | Chromaprint locale |
| Indice interno + sync incrementale | **Alta** | Medio | FSEvents + delta da Music |
| Coerenza con Apple Music (V3) | **Media-Alta** | **Alto** | dipende da automazione Music; **PoC necessario** |
| No move/no rename (V1/V2) | **Alta** | Medio | M-A non rinomina; verifica path post-op |
| Refresh selettivo dei soli brani modificati | **Alta** | Basso | M-A applica per singolo track; nessun refresh globale necessario |

**Verdetto complessivo:** progetto **fattibile** con rischio concentrato sull'**integrazione con Apple Music sotto iCloud** e sulla **stabilità dell'automazione tra versioni di macOS**. Entrambi vanno sciolti subito con un PoC mirato.

---

## 12. Roadmap consigliata (per fasi)

**Fase 0 — PoC di rischio (1–2 settimane).** Validare su Mac e versione macOS dell'utente: lettura libreria via Apple Events, scrittura di titolo/artista/album/anno/genere e artwork via M-A su un campione, **verifica che le modifiche persistano dopo "Aggiorna libreria iCloud"** e che **i file non vengano rinominati/spostati**. È il go/no-go tecnico.

**Fase 1 — Indice + Browser.** Indicizzazione completa, SQLite/FTS5, tabella virtuale, raggruppa/ordina/filtra/cerca, sync incrementale (FSEvents + delta Music).

**Fase 2 — Editing.** Editing singolo e batch via M-A, anteprime diff, coda, log, undo, gestione MP3/M4A uniforme, copertine.

**Fase 3 — Arricchimento.** Pipeline multi-sorgente (iTunes Search API → MusicBrainz/CAA → Discogs → fallback web assistito), caching, modalità assistita/automatica.

**Fase 4 — Normalizzazione + Duplicati.** Dizionari generi/artisti, cluster e fuzzy; duplicati per metadati e (opzionale) fingerprint Chromaprint.

**Fase 5 — Eliminazione & rifiniture.** DeletionService con salvaguardie/Cestino/log; localizza in Finder/Music; hardening, performance, packaging (Developer ID + notarizzazione).

---

## 13. Decisioni aperte da confermare

1. **Distribuzione**: uso personale (Developer ID, no sandbox stretto) vs Mac App Store (sandbox + bookmarks). Raccomandato: Developer ID.
2. **Fingerprint duso**: includere Chromaprint in v1 (consigliato per le coppie MP3/M4A) o rimandarlo.
3. **Sorgente primaria copertine**: confermare iTunes Search API come default (allineata ad Apple) con web come fallback manuale.
4. **Gestione "Mantieni organizzata"**: lasciarla attiva (preferenza utente) verificando post-op che non rinomini, oppure consigliare di disattivarla durante le sessioni di editing di massa.

---

## Fonti

- [Apple Community — iTunes/iCloud metadata being overwritten](https://discussions.apple.com/thread/253598645)
- [Apple Community — Metadata overridden, how to stop](https://discussions.apple.com/thread/253800621)
- [Apple Community — Songs metadata changes reverting](https://discussions.apple.com/thread/7371256)
- [Apple Community — Metadata in iTunes and iCloud](https://discussions.apple.com/thread/252505836)
- [Apple Community — Force file name change in Music](https://discussions.apple.com/thread/251926152)
- [Apple Support — Change where music files are stored on Mac](https://support.apple.com/guide/music/change-where-music-files-are-stored-mus69248042d/mac)
- [Apple Developer Forums — Apple Music ScriptingBridge broken in macOS Tahoe 26](https://developer.apple.com/forums/thread/801357)
- [Apple Developer Forums — AppleScript track properties no longer working in Big Sur](https://developer.apple.com/forums/thread/669239)
- [Doug's AppleScripts — iCloud Music Library category](https://dougscripts.com/itunes/category/icloud-music-library/)
- [Doug's AppleScripts — Managing Tracks](https://dougscripts.com/itunes/category/managing-tracks/)
- [Take Control — Extend the Music and TV Apps with AppleScripts](https://www.takecontrolbooks.com/article/extend-the-music-and-tv-apps-with-applescripts/)
- [Meta — Music Tag Editor (powered by TagLib)](https://www.nightbirdsevolve.com/meta/)
- [swift-audio-marker (GitHub)](https://github.com/atelier-socle/swift-audio-marker)
- [Mp3tag — universal tag editor](https://www.mp3tag.de/en/)
- [Chromaprint / AcoustID](https://acoustid.org/chromaprint)
- [Chromaprint (GitHub)](https://github.com/acoustid/chromaprint)
- [soundalike — duplicati via fingerprint (Codeberg)](https://codeberg.org/derat/soundalike)
- [beets — Chromaprint/AcoustID plugin](https://beets.readthedocs.io/en/stable/plugins/chroma.html)
