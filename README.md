# MusiFix

App macOS nativa per la gestione e la pulizia dei metadati di una libreria Apple Music di grandi dimensioni (25k+ brani).

Tutte le modifiche passano attraverso Apple Music tramite ScriptingBridge — i tag vengono aggiornati sia nel database di Music sia nei file fisici, garantendo la coerenza con iCloud Music Library.

## Funzionalità

- **Browser libreria** — tabella virtuale con ricerca FTS5, filtri rapidi, ordinamento multi-colonna e selezione multipla
- **Editing metadati** — pannello singolo brano e batch editor per selezioni multiple, con anteprima diff e undo
- **Gestione copertine** — visualizza, sostituisce o aggiunge artwork da file, appunti o ricerca online
- **Arricchimento online** — ricerca copertine e anno di pubblicazione via iTunes Search API e MusicBrainz
- **Normalizzazione** — pulizia automatica di generi e nomi artista con dizionari alias editabili e clustering fuzzy
- **Duplicati** — rilevamento per similarità metadati (Jaro-Winkler) e per contenuto audio (Chromaprint)
- **Dashboard** — statistiche libreria con navigazione rapida ai problemi (campi mancanti, incoerenze, cloud-only)
- **Eliminazione sicura** — rimozione da Music con opzione Cestino, doppia conferma sopra soglia e log
- **Verifica divergenze** — confronto live tra l'indice locale e i valori correnti in Music.app, con risoluzione bidirezionale (utile con iCloud Music Library attiva su più dispositivi)
- **Log operazioni** — cronologia completa con undo per ogni modifica di metadati

## Requisiti

- macOS 14 o superiore (testato su macOS 26 Tahoe)
- Apple Music installato e con la libreria caricata
- Permesso Automazione per Apple Music (richiesto al primo avvio)
- Distribuzione: Developer ID, **app non sandboxed**

## Build

```bash
# Apri il workspace in Xcode
open MusiFix.xcworkspace

# Oppure da CLI
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -workspace MusiFix.xcworkspace \
             -scheme MusiFixApp \
             -destination 'platform=macOS' \
             build
```

## Struttura del progetto

```
MusiFix/
├── MusiFixApp/          App shell SwiftUI (UI, AppState, packaging)
└── Packages/
    └── MusiFixCore/     Swift Package multi-target
        ├── MusiFixCore/ Servizi (Index, Write, Enrichment, Norm, Dup, Deletion, Divergence)
        ├── Persistence/ GRDB schema, migrazioni, DAO
        └── MusicBridge/ Wrapper ObjC per ScriptingBridge → Music.app
```

Per i dettagli tecnici vedi i documenti di analisi nella root del progetto.
