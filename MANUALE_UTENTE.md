# MusiFix — Manuale d'uso

MusiFix è un'app macOS per gestire e pulire i metadati della tua libreria Apple Music. Tutte le modifiche vengono scritte attraverso Music.app, quindi rimangono sincronizzate con iCloud Music Library su tutti i tuoi dispositivi.

---

## Primo avvio

1. Assicurati che **Music.app sia aperta** e la libreria sia caricata.
2. Avvia MusiFix. Al primo avvio macOS chiederà il permesso di **Automazione** per Music.app — concedilo.
3. Clicca **Indicizza tutto** nella toolbar per costruire l'indice locale. Su 25k brani impiega qualche minuto; una barra di avanzamento mostra lo stato. L'operazione è riprendibile se interrotta.
4. Al termine compare la tabella con tutti i brani. Le sincronizzazioni successive sono incrementali e molto più rapide.

> **Nota:** l'indice locale è una cache. La fonte di verità rimane sempre Music.app.

---

## Finestra principale

La finestra è divisa in:

- **Toolbar** — azioni globali e sync
- **Barra di ricerca** — ricerca full-text su titolo, artista, album
- **Tabella brani** — scorri, seleziona, ordina per colonna
- **Pannello editor** (laterale destro) — compare quando selezioni un singolo brano
- **Status bar** — contatore totale e selezione corrente

### Toolbar — bottoni

| Icona / Etichetta | Funzione |
|---|---|
| `↔` | Verifica divergenze tra l'indice locale e Music.app per i brani selezionati |
| Modifica N brani… | Apre il batch editor sui brani selezionati |
| 🗑 (rosso) | Elimina i brani selezionati da Music.app |
| 📊 | Dashboard — statistiche libreria |
| ✨ | Normalizzazione generi e artisti |
| ⧉ | Trova duplicati |
| 🕐 | Cronologia operazioni (log + undo) |
| Indicizza tutto | Riscansione completa — usare solo al primo avvio o se l'indice è corrotto |
| Sync | Aggiornamento incrementale — rileva solo le tracce cambiate dall'ultima sync |

---

## Ricerca e filtri

La barra di ricerca usa la ricerca full-text (FTS5): digita qualsiasi parola da titolo, artista o album e i risultati si aggiornano in tempo reale.

I **filtri rapidi** si attivano dalla Dashboard cliccando su una statistica (es. "Anno mancante"). Una barra colorata sopra la tabella indica il filtro attivo; la X a destra lo rimuove.

---

## Editing di un singolo brano

Clicca un brano nella tabella per aprire il pannello laterale.

- **Copertina**: cliccaci sopra per aprire l'editor artwork (vedi §Copertine).
- **Campi testo**: modifica direttamente nei campi. Il bottone **Applica** diventa attivo appena c'è una modifica.
- **Applica** — scrive le modifiche su Music.app. L'operazione è loggata e annullabile dal log.
- **Ripristina** — annulla le modifiche non ancora applicate nel pannello.
- **Finder** — rivela il file su disco nel Finder.
- **Music** — seleziona il brano in Music.app e porta l'app in primo piano.
- **🗑** (rosso) — elimina il brano (con conferma).

---

## Editing batch (più brani)

Seleziona più brani nella tabella (⌘+clic o ⇧+clic), poi clicca **Modifica N brani…**.

Nel batch editor:
- Attiva il toggle a sinistra di ogni campo per includere quel campo nella scrittura batch.
- Compila il valore desiderato.
- Clicca **Anteprima** per vedere il diff "prima → dopo" su tutti i brani interessati.
- Clicca **Applica** nella schermata di anteprima per eseguire.

Tutti i campi non attivati vengono ignorati.

---

## Copertine

Clicca sulla copertina nel pannello laterale (o sull'area grigia se assente) per aprire l'editor artwork.

**Sorgenti disponibili:**
- **Cerca online** — avvia una ricerca su iTunes API e MusicBrainz. Vengono presentati i candidati con anteprima, risoluzione, anno e fonte. Clicca un candidato per applicarlo.
- **Da file** — trascina un'immagine sull'editor o usa il file picker.
- **Dagli appunti** — incolla un'immagine copiata in precedenza.

Le immagini vengono normalizzate automaticamente (max 1400px, JPEG q=0.85) prima della scrittura.

---

## Arricchimento online (copertine)

L'arricchimento online è accessibile dall'editor artwork (bottone **Cerca online**).

### Pannello di ricerca

All'apertura compaiono tre campi editabili pre-compilati con i metadati del brano:

| Campo | Valore iniziale |
|---|---|
| **Artista** | Artista album (o artista del brano se assente) |
| **Album** | Titolo dell'album |
| **Titolo** | Titolo del singolo brano |

La ricerca viene eseguita automaticamente all'apertura. Puoi modificare qualsiasi campo e cliccare **Cerca di nuovo** per raffinare i risultati senza chiudere il pannello.

### Provider e strategia di ricerca

La ricerca avviene su due provider in parallelo:

1. **iTunes Search API** — query per *artista + album*; se il titolo del brano è diverso dall'album, viene eseguita anche una seconda query *artista + titolo* per recuperare singoli o brani che non compaiono nella ricerca per album. I risultati dei due passaggi vengono uniti e deduplicati; in caso di duplicati viene mantenuto lo score più alto.
2. **MusicBrainz / Cover Art Archive** — query per *artista + album*; vengono inclusi solo i release con copertina front disponibile.

I risultati sono ordinati per score (similarità con la query) e memorizzati nella cache locale per la sessione corrente, evitando richieste ripetute con gli stessi parametri.

### Selezione e applicazione

- Clicca un candidato nella griglia per selezionarlo; il dettaglio (album, artista, anno, fonte, score) compare in basso.
- **Applica a questo brano** — scrive la copertina solo sul brano corrente.
- **Applica all'album (N brani)** — scrive la stessa copertina su tutti i brani dello stesso album presenti in libreria.

### Modalità automatica

Attiva il toggle **Automatica** per applicare senza intervento manuale il primo candidato il cui score supera la soglia configurabile (50–100%). Utile per sessioni di arricchimento su più brani in sequenza.

---

## Normalizzazione

Apri il pannello **Normalizzazione** dalla toolbar (✨).

**Tab Anteprima:**
- L'app mostra i cluster di varianti rilevate (es. "Hip Hop", "Hip-Hop", "hiphop" → forma canonica proposta).
- Per ogni cluster, puoi escludere singole righe dal toggle.
- Clicca **Applica selezionati** per scrivere le forme canoniche su Music.app.

**Tab Alias:**
- Visualizza e gestisci manualmente il dizionario delle corrispondenze (da → a) per generi e artisti.
- Aggiungi nuove regole con il form in fondo.

---

## Duplicati

Apri il pannello **Duplicati** dalla toolbar (⧉).

L'app raggruppa i brani per similarità (artista normalizzato + titolo fuzzy, soglia configurabile). Per ogni gruppo viene mostrato un confronto con formato, bitrate, durata e presenza copertina.

Azioni per ogni gruppo:
- **Seleziona il brano da conservare** (il "keeper" consigliato è evidenziato).
- **Elimina i ridondanti** — passa dal pannello di eliminazione con le relative salvaguardie.
- **Ignora** — marca il gruppo come "non duplicati" per non rivederlo.

---

## Dashboard

La dashboard (📊) mostra statistiche aggregate sulla libreria:

- Totale brani, cloud-only, formati
- Campi mancanti: anno, artista, album, artista album, genere, copertina
- Incoerenze: valori multipli di album/artista album per lo stesso gruppo
- Brani per genere, per anno, per artista (top N)

Clicca su qualsiasi contatore per applicare il filtro corrispondente nella tabella principale.

---

## Eliminazione

Seleziona uno o più brani, poi clicca l'icona **🗑** nella toolbar.

Nel pannello di eliminazione scegli l'ambito:
- **Solo da Music** — rimuove la voce dalla libreria Music.app; il file su disco resta intatto.
- **Da Music + Cestino** — rimuove la voce dalla libreria E sposta il file nel Cestino macOS.

Sopra una soglia configurabile viene richiesta una **doppia conferma**. Ogni eliminazione è registrata nel log con artista, titolo, percorso file e data.

> Con iCloud Music Library attiva, la rimozione da Music.app si propaga agli altri dispositivi sincronizzati.

---

## Verifica divergenze (DB ↔ Music.app)

Utile se usi la libreria su più dispositivi con iCloud Music Library: modifiche fatte da un altro dispositivo o da Music.app direttamente possono divergere dall'indice locale.

**Come si usa:**
1. Seleziona i brani da verificare nella tabella.
2. Clicca il bottone **↔** nella toolbar.
3. MusiFix confronta campo per campo l'indice locale con i valori live di Music.app.
4. Se trova divergenze, le mostra in un pannello con diff "DB / Music" per ogni campo.
5. Per ogni brano scegli **DB** (applica i valori dell'indice a Music.app) o **Music** (aggiorna l'indice con i valori correnti di Music.app).
6. Usa **DB per tutti** / **Music per tutti** per applicare la stessa scelta all'intera selezione.
7. Clicca **Applica** per eseguire le correzioni.

### Brani "presenti in Music ma non su disco" — cause comuni

Music.app conserva il percorso di ogni file come URL nel suo database interno. Se il file esiste fisicamente ma Music non lo trova, il campo `location` restituito dal bridge è `nil` o punta a un percorso obsoleto. Le cause più frequenti:

| Causa | Spiegazione |
|---|---|
| **File spostato manualmente nel Finder** | Music.app non si accorge dello spostamento; il percorso nel database non viene aggiornato. |
| **Disco esterno rimontato sotto path diverso** | Se il volume viene rinominato o rimontato con un punto di mount differente, il percorso assoluto cambia e il riferimento si rompe. |
| **Libreria non consolidata** | Con "Mantieni organizzata la cartella Media" disattivata, i file possono trovarsi ovunque; spostamenti o rinomina manuale rompono i riferimenti. |
| **iCloud Music Library — stato di sincronizzazione** | Con iCloud attivo, un brano può risultare "cloud-only" in Music.app anche se il file locale esiste ancora, perché lo stato di download non è stato aggiornato. |

**Come correggere:** in Music.app seleziona il brano → tasto destro → *Informazioni sul file* → aggiorna il percorso manualmente. In alternativa usa *Archivio → Consolida libreria* per riportare tutti i file sotto la cartella gestita da Music.app e riallineare automaticamente i riferimenti.

---

## Cronologia operazioni e Undo

Apri il log dalla toolbar (🕐).

Il log mostra tutte le operazioni di scrittura con campo, valore prima/dopo, data e stato.

Per annullare un batch di modifiche: individua il batch nel log e clicca **Annulla**. L'undo ripristina i valori precedenti su Music.app campo per campo. Le operazioni artwork non sono annullabili (nessun dato "prima" viene salvato).

---

## Sync e indice

- **Sync** (incrementale): confronta le date di modifica dei brani nell'indice con quelle in Music.app e aggiorna solo le righe cambiate. Rapida, da eseguire dopo aver usato Music.app o dopo un cambio su iCloud.
- **Indicizza tutto**: riscansione completa. Necessaria solo al primo avvio o se l'indice risulta corrotto. Supporta il checkpoint: se interrotta, riprende dall'ultimo brano elaborato.

L'indice è memorizzato in `~/Library/Application Support/MusiFix/musifixindex.db`.

---

## Note importanti

- **MusiFix non sposta né rinomina mai i file**. Se l'opzione "Mantieni organizzata la cartella Media" è attiva in Music.app, è consigliabile disattivarla durante sessioni di editing di massa per evitare che Music rinomini i file autonomamente.
- I brani **cloud-only** (non scaricati localmente) sono mostrati nell'indice ma non sono editabili — sono marcati come tali nella tabella.
- Prima di operazioni massive (batch su migliaia di brani, eliminazioni multiple) è raccomandato avere un backup della libreria Music (`~/Music/Music/Music Library.musiclibrary`).

---

## Risoluzione dei problemi

### La ricerca copertina non trova nulla

1. Controlla che i campi Artista e Album nel pannello di ricerca siano corretti — Music.app a volte li lascia vuoti o incompleti.
2. Prova a modificare manualmente i campi: usa la grafia inglese se il nome è internazionale, oppure inserisci solo il cognome dell'artista.
3. Se il brano è un singolo o una raccolta, il campo **Titolo** può aiutare più del campo Album: cancella il valore Album e lascia solo Artista + Titolo, poi clicca **Cerca di nuovo**.
4. I risultati MusicBrainz richiedono che la copertina sia archiviata nel Cover Art Archive — non tutti i release ne hanno una.

### Un brano appare in Music.app ma il file non si trova nel Finder

Vedi §[Brani "presenti in Music ma non su disco"](#brani-presenti-in-music-ma-non-su-disco--cause-comuni).

### L'indice non si aggiorna dopo una modifica fatta direttamente in Music.app

Esegui **Sync** dalla toolbar. La sync incrementale rileva le modifiche confrontando le date di modifica e aggiorna solo le righe cambiate.

### Il pannello di divergenza mostra differenze su brani che sembrano corretti

Questo può capitare con iCloud Music Library: un altro dispositivo può aver applicato una modifica che non si è ancora propagata all'indice locale. Usa l'opzione **Music per tutti** nel pannello divergenze per allineare l'indice ai valori correnti di Music.app, poi esegui una **Sync**.
