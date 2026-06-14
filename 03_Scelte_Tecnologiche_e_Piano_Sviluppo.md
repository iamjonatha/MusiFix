# Scelte Tecnologiche e Piano di Sviluppo — MusiFix

**Nome prodotto:** *MusiFix*
**Versione documento:** 1.0
**Data:** 14 giugno 2026
**Documenti di riferimento:** «01 — Analisi Funzionale», «02 — Analisi Tecnica e di Fattibilità»
**Piattaforma target:** macOS nativo (Developer ID, fuori App Store)

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

## 4. Piano di sviluppo per fasi

Stima a sviluppatore singolo esperto Swift/macOS. Le stime sono indicative; il **gate di Fase 0 è bloccante** per tutte le successive.

### Fase 0 — PoC di rischio *(GO/NO-GO)* — 1–2 settimane

**Obiettivo:** sciogliere il rischio principale (integrazione Music sotto iCloud, stabilità su macOS 26) prima di investire nella UI.

**Task:**
- F0.1 Setup workspace, package `MusiFixCore`, target app shell, entitlement Automation, firma Developer ID.
- F0.2 `AppleMusicBridge` minimale: enumerare i track (persistent id, location, modification date), leggere proprietà standard.
- F0.3 Scrittura via M-A di titolo/artista/album artist/album/anno/genere + **artwork** su un campione (~50 brani MP3 e M4A).
- F0.4 **Read-back** e verifica persistenza **dopo "Aggiorna libreria iCloud"**.
- F0.5 Verifica che **i percorsi file NON cambino** (con "Mantieni organizzata" sia ON che OFF).
- F0.6 Implementare e testare il **fallback `NSAppleScript`** sugli stessi campi (regressione Tahoe).

**Criteri di uscita (GO):**
- ✅ Modifiche M-A visibili in Music e **non revertite** dopo refresh iCloud.
- ✅ Nessun file spostato/rinominato (path identici pre/post).
- ✅ Almeno una delle due implementazioni del bridge funziona in modo affidabile su macOS dell'utente.

> **NO-GO →** rivedere strategia (es. peso maggiore su M-B con contenimento del revert, o limitare ambito V3). Da decidere con l'utente.

### Fase 1 — Indice + Browser — 2–3 settimane

**Deliverable:** app che indicizza 25k brani e li naviga fluida.

**Task:**
- F1.1 Schema SQLite (GRDB) + migrazioni: `track`, `genre_alias`, `artist_alias`, `operation_log`, `enrichment_cache` (vedi analisi tecnica §4.1) + tabelle FTS5.
- F1.2 **Indicizzazione completa** prima esecuzione: delta da Music + arricchimento file (formato, bitrate via AVFoundation, `mtime`, content-hash). Avanzamento + **ripresa se interrotta** (F1.7).
- F1.3 **Sync incrementale**: delta da Music (persistent id/modification date) + FSEvents (event ID persistito) + verifica leggera (mtime/size). Riconciliazione e marcatura divergenze.
- F1.4 Gestione **cloud-only** (marcati non editabili a livello file).
- F1.5 **Tabella virtuale** `NSTableView` (colonne configurabili) su dati paginati dall'indice; scrolling fluido.
- F1.6 Raggruppamento / ordinamento multi-colonna / filtri combinabili / ricerca FTS5 as-you-type / selezione multipla / smart views salvate.
- F1.7 Indicatore "ultima sincronizzazione" e sync in corso.

**Criteri di uscita:** apertura < 3 s a regime; sync incrementale tipica < 30 s; ricerca/filtro < 200 ms percepiti su 25k righe; nessuna riscansione completa percepibile.

### Fase 2 — Editing + Copertine — 2–3 settimane

**Deliverable:** editing singolo/batch via M-A con coda, anteprima, undo, log.

**Task:**
- F2.1 **MetadataWriteService** + **coda transazionale** (stati: in attesa/in corso/completata/errore), snapshot pre-modifica.
- F2.2 Mapping uniforme MP3/M4A (tabella campi §3.1 analisi tecnica); UI con set di campi unico.
- F2.3 Editing **singolo** (form) e **batch** (valore comune, trova/sostituisci, casing/trim, propagazione album-artist/anno/genere all'album).
- F2.4 **Anteprima diff** "prima → dopo" prima di applicare (obbligatoria sui batch).
- F2.5 Validazione campi (anno plausibile, ecc.). Indicazione **modalità di scrittura** (M-A/M-B/M-C) ed esito per brano.
- F2.6 **Gestione copertine**: visualizza/aggiungi/sostituisci da file, appunti, o (più avanti) risultato F5; applicazione a livello album o singolo; normalizzazione immagine (ImageIO).
- F2.7 **Undo** metadati (da snapshot in `operation_log`); **log** persistente; ripresa post-crash senza corruzione indice.

**Criteri di uscita:** una modifica nell'app è visibile in Music in pochi secondi e non viene annullata dopo refresh iCloud; undo ripristina i valori; nessuna corruzione dopo kill durante una coda.

### Fase 3 — Arricchimento online — 1.5–2 settimane

**Deliverable:** pipeline copertina + anno multi-sorgente con utente nel controllo.

**Task:**
- F3.1 **EnrichmentService** con provider in ordine: **iTunes Search API → MusicBrainz/Cover Art Archive → Discogs → fallback web assistito**.
- F3.2 Query da album-artist + album (+ durata/traccia per disambiguare); **caching** (`enrichment_cache`) + **rate limiting** + gestione timeout/errori.
- F3.3 Presentazione **candidati** (immagine + risoluzione + anno + provider + score); modalità **assistita** (default) e **automatica** (soglia, revisionabile).
- F3.4 Tracciamento **fonte/provenienza** del dato applicato (audit); applicazione via M-A.

**Criteri di uscita:** per un campione di album incompleti, i candidati iTunes corrispondono all'artwork atteso; nessun upload di file audio; provenienza registrata.

### Fase 4 — Normalizzazione + Duplicati — 2–3 settimane

**Deliverable:** pulizia generi/artisti e deduplica (metadati + fingerprint opzionale).

**Task:**
- F4.1 **NormalizationService**: dizionari `genre_alias`/`artist_alias` editabili; clustering per similarità (fuzzy); regole "The"/feat./casing/spazi; gestione artista vs album-artist.
- F4.2 **Anteprima impatto** ("X brani da A → B"), applicazione batch con esclusione di singoli casi.
- F4.3 **DuplicateService — metadati**: blocking per artista normalizzato, fuzzy sul titolo (Jaro-Winkler/token-set, soglia configurabile), conferma con durata.
- F4.4 **DuplicateService — fingerprint (toggle)**: Chromaprint locale; rileva stessi brani con metadati/format diversi (MP3 vs M4A).
- F4.5 Presentazione a **gruppi** con confronto (formato, bitrate, durata, copertina, percorso); suggerimento "keeper" (preferenze configurabili); marcatura "non duplicati".

**Criteri di uscita:** individua correttamente coppie MP3/M4A dello stesso brano (fingerprint ON); falsi positivi gestibili via soglie e conferma.

### Fase 5 — Eliminazione + rifiniture + packaging — 1.5–2 settimane

**Deliverable:** prodotto distribuibile.

**Task:**
- F5.1 **DeletionService**: conferma con riepilogo, scelta ambito (rimuovi da Music e/o **Cestino** file), **doppia conferma sopra soglia**, log dettagliato; chiarimento effetti iCloud su altri dispositivi.
- F5.2 **Localizza**: "Mostra nel Finder" / "Mostra in Music".
- F5.3 **Dashboard** statistiche (senza copertina/anno, generi non normalizzati, duplicati potenziali) — UC-01.
- F5.4 **Backup/export** indice + regole; reminder Time Machine / copia `Music Library.musiclibrary` prima delle prime operazioni di massa.
- F5.5 Hardening, performance pass, gestione errori, accessibilità di base.
- F5.6 **Packaging**: firma Developer ID + **notarizzazione** (`notarytool`) + stapling; DMG.

**Criteri di uscita:** tutti i criteri di accettazione del §10 dell'analisi funzionale soddisfatti; app notarizzata installabile.

---

## 5. Riepilogo milestone

| Fase | Durata stim. | Esito | Bloccante? |
|------|--------------|-------|------------|
| 0 — PoC rischio | 1–2 sett. | GO/NO-GO integrazione Music+iCloud | **Sì** |
| 1 — Indice + Browser | 2–3 sett. | Navigazione fluida 25k | — |
| 2 — Editing + Copertine | 2–3 sett. | Scrittura M-A + undo/log | — |
| 3 — Arricchimento | 1.5–2 sett. | Cover+anno multi-sorgente | — |
| 4 — Normalizzazione + Duplicati | 2–3 sett. | Pulizia + dedup | — |
| 5 — Eliminazione + packaging | 1.5–2 sett. | App notarizzata | — |

**Totale indicativo:** ~10–15 settimane a sviluppatore singolo, fasi sequenziali con possibili sovrapposizioni dopo il GO di Fase 0.

---

## 6. Mappa requisiti → fasi (tracciabilità)

| Requisito (F. funzionale) | Fase |
|---|---|
| F1 Indicizzazione/sync | 1 |
| F2 Browser | 1 |
| F3 Editing | 2 |
| F4 Copertine | 2 (con sorgenti online in 3) |
| F5 Arricchimento online | 3 |
| F6 Normalizzazione | 4 |
| F7 Duplicati | 4 |
| F8 Localizza/Elimina | 5 |
| F9 Coda/anteprima/undo/log | 2 (trasversale) |
| Modalità scrittura M-A/B/C | 0 (PoC) → 2 |

---

## 7. Rischi e mitigazioni (residui)

| Rischio | Mitigazione | Fase |
|---|---|---|
| Automazione Music instabile su macOS 26 | Bridge a doppia impl. + PoC bloccante | 0 |
| Revert metadati da iCloud | Default M-A + read-back + riconciliazione | 0/2 |
| Rinomina/spostamento file | M-A non rinomina + verifica path post-op + consiglio disattivare "organizza" | 0/2 |
| Toolchain C/C++ (TagLib/Chromaprint) | Isolati dietro protocolli, opzionali a runtime, fallback su AVFoundation/M-A | 2/4 |
| Falsi positivi duplicati | Soglie, conferma, fingerprint, marcatura "non duplicati" | 4 |
| Eliminazioni accidentali | Cestino, doppia conferma, log, undo limitato | 5 |
| Qualità/licenza dati online | Utente nel controllo, provenienza, no scraping massivo | 3 |

---

## 8. Prossimo passo operativo

Avviare la **Fase 0**: creare il workspace, il package `MusiFixCore` con il modulo `AppleMusic`, e il PoC di lettura/scrittura/artwork via M-A con verifica di persistenza post-iCloud e non-rinomina file. È il **go/no-go** che condiziona tutto il resto.

---

*Documento complementare a «01 — Analisi Funzionale» e «02 — Analisi Tecnica e di Fattibilità».*
