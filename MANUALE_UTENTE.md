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

## Arricchimento online (copertine + anno)

L'arricchimento online è accessibile dall'editor artwork (bottone **Cerca online**).

La ricerca avviene in ordine su: **iTunes Search API → MusicBrainz/Cover Art Archive**. I risultati sono memorizzati nella cache locale per evitare richieste ripetute sullo stesso album.

Modalità:
- **Assistita** (default): scegli tu il candidato.
- **Auto**: attiva dal pannello di ricerca per applicare automaticamente il candidato con score più alto sopra la soglia.

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
