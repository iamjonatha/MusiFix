# Analisi Funzionale — Gestore Libreria Apple Music (macOS)

**Nome di lavoro:** *MusicLibrarian* (placeholder)
**Versione documento:** 1.0
**Data:** 14 giugno 2026
**Piattaforma target:** macOS nativo (app standalone)

---

## 1. Contesto e obiettivo

L'utente possiede una libreria musicale di **~25.000 brani** gestita da **Apple Music** con **iCloud Music Library (Sync Library) attiva** e libreria scaricata in locale sul Mac. È attiva l'opzione *"Mantieni organizzata la cartella Music Media"*. Tutti i file risiedono in sottocartelle della radice `Music`, in formato misto **MP3** e **M4A (AAC)**.

Strumenti già provati (Yate, SongGenie/Songkick) non hanno dato risultati soddisfacenti sul caso d'uso reale, in particolare per la scala della libreria e per il flusso di lavoro desiderato.

L'obiettivo è realizzare un'**applicazione Mac nativa** che permetta di gestire, pulire e arricchire la libreria in modo efficiente, mantenendo **piena coerenza con Apple Music** e rispettando vincoli stringenti sulla posizione dei file.

> **Nota critica (vincolante per l'architettura).** Con iCloud Music Library attiva, **il database di Apple Music è la fonte di verità**, non i tag scritti nei file. Modificando i tag direttamente sul file system, le modifiche possono **non riflettersi** in Apple Music o addirittura **essere sovrascritte/annullate** al successivo "Aggiorna libreria iCloud". Questo aspetto, trattato in dettaglio nell'analisi tecnica, condiziona profondamente i requisiti funzionali sotto (vedi §6, "Modalità di scrittura").

---

## 2. Obiettivi e non-obiettivi

### 2.1 Obiettivi
- Editing efficiente dei metadati principali su grande scala.
- Gestione copertine (aggiunta/sostituzione).
- Arricchimento automatico (copertina + anno) tramite ricerca online.
- Raggruppamento, ordinamento e filtri avanzati.
- Normalizzazione di generi e nomi artista.
- Individuazione duplicati.
- Localizzazione/eliminazione del brano in Apple Music con tutte le verifiche di sicurezza.
- Indice interno persistente, aggiornato all'avvio o in background, per evitare la riscansione completa del file system a ogni apertura.
- Coerenza garantita con Apple Music.

### 2.2 Non-obiettivi (fuori ambito, almeno v1)
- Spostamento o rinomina dei file (vietato dai vincoli).
- Gestione di playlist, smart playlist, valutazioni o riproduzione.
- Editing di formati diversi da MP3 e M4A.
- Sincronizzazione/gestione diretta dei contenuti "cloud-only" (mai scaricati).
- Editing di brani in streaming dal catalogo Apple Music (non posseduti).

---

## 3. Vincoli funzionali

| ID | Vincolo |
|----|---------|
| V1 | I file **non devono essere spostati** dalla loro posizione sul file system. |
| V2 | I file **non devono essere rinominati**. |
| V3 | Ogni modifica deve **riflettersi nei brani di Apple Music**. |
| V4 | Deve supportare **MP3 e M4A/AAC** in modo trasparente per l'utente. |
| V5 | Deve reggere **~25.000 brani** con prestazioni fluide. |
| V6 | Operazioni distruttive (eliminazione) richiedono **conferme e salvaguardie**. |

> **Conflitto da gestire.** L'opzione *"Mantieni organizzata la cartella"* può indurre Apple Music a **rinominare/spostare** i file quando i tag cambiano, in contrasto con V1/V2. L'app deve adottare una strategia di scrittura che non inneschi la riorganizzazione (vedi analisi tecnica) e, ove necessario, avvisare l'utente.

---

## 4. Profili utente

Un solo profilo: **utente avanzato/power user single-user**, proprietario della libreria, che lavora sul proprio Mac. Non sono previsti multi-utenza, ruoli o permessi.

---

## 5. Panoramica funzionale (mappa delle feature)

```
┌─────────────────────────────────────────────────────────────┐
│  MusicLibrarian                                              │
├─────────────────────────────────────────────────────────────┤
│  F1  Indicizzazione e sincronizzazione con Apple Music      │
│  F2  Browser libreria (raggruppa / ordina / filtra / cerca) │
│  F3  Editing metadati (singolo + batch)                     │
│  F4  Gestione copertine                                     │
│  F5  Arricchimento online (cover + anno)                    │
│  F6  Normalizzazione (generi, artisti)                      │
│  F7  Rilevamento duplicati                                  │
│  F8  Localizza / Elimina in Apple Music                     │
│  F9  Coda operazioni, anteprima modifiche, undo/log         │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. Requisiti funzionali dettagliati

### F1 — Indicizzazione e sincronizzazione con Apple Music

**Descrizione.** L'app costruisce e mantiene un **indice interno persistente** della libreria, popolato a partire da Apple Music (fonte di verità) e arricchito con informazioni di file system (formato, percorso, dimensione, data, hash).

**Requisiti.**
- **F1.1** All'avvio l'app esegue una **sincronizzazione incrementale** (delta) rispetto allo stato precedente, non una riscansione completa.
- **F1.2** È possibile eseguire la sincronizzazione **in background** senza bloccare l'interfaccia.
- **F1.3** L'indice memorizza per ogni brano almeno: ID persistente Apple Music, percorso file, formato (MP3/M4A), titolo, artista, artista album, album, anno, genere, numero/totale traccia, disco, durata, bitrate, presenza/embedding copertina, data aggiunta, data modifica file, hash contenuto (per dedup), stato (in-sync / modificato localmente / errore).
- **F1.4** L'app rileva: brani **nuovi**, **rimossi**, **modificati** (da Apple Music o dal file) dall'ultima sincronizzazione.
- **F1.5** Indicazione visibile di "ultima sincronizzazione" e di sincronizzazione in corso.
- **F1.6** Gestione robusta dei brani **cloud-only** (presenti in Apple Music ma non scaricati): marcati come non editabili a livello di file, eventualmente editabili a livello di database Apple Music.
- **F1.7** La prima indicizzazione completa (25k brani) deve fornire **feedback di avanzamento** e poter essere ripresa se interrotta.

### F2 — Browser libreria: raggruppamento, ordinamento, filtri, ricerca

**Requisiti.**
- **F2.1** Vista tabellare ad alte prestabili su 25k righe (scrolling fluido, colonne configurabili).
- **F2.2** **Raggruppamento** per: anno, genere, artista, artista album, album.
- **F2.3** **Ordinamento** multi-colonna (es. artista → album → n. traccia).
- **F2.4** **Filtri** combinabili: per testo, per campo, per stato (es. "senza copertina", "senza anno", "genere non normalizzato", "duplicati", "solo MP3"/"solo M4A", "modificati localmente").
- **F2.5** **Ricerca** rapida full-text con risultati incrementali (as-you-type).
- **F2.6** Selezione multipla con operazioni batch sulla selezione.
- **F2.7** Salvataggio di filtri/viste ricorrenti ("smart views" interne all'app).

### F3 — Editing metadati

**Campi principali (priorità v1):** titolo, artista, artista album (album artist), album, anno, genere.
**Campi secondari (utili, opzionali):** numero traccia/totale, disco, commento, compilation flag.

**Requisiti.**
- **F3.1** Editing **singolo** brano con form dedicato.
- **F3.2** Editing **batch** sulla selezione, con supporto a:
  - assegnazione di un valore comune;
  - trova/sostituisci su un campo;
  - operazioni di "casing" (Title Case, ecc.) e trim spazi;
  - propagazione di "artista album"/"anno"/"genere" a tutti i brani di un album.
- **F3.3** **Anteprima delle modifiche** prima dell'applicazione (diff "prima → dopo"), specialmente nelle operazioni batch.
- **F3.4** Validazione campi (es. anno numerico plausibile, ecc.).
- **F3.5** Gestione trasparente delle differenze di mapping tra **ID3 (MP3)** e **atomi MP4 (M4A)** (vedi analisi tecnica): l'utente vede un set di campi uniforme.
- **F3.6** Indicazione, per ogni brano, della **modalità di scrittura** usata (vedi §6.1) e dell'esito.

#### 6.1 Modalità di scrittura (decisione funzionale chiave)

Per soddisfare V3 (coerenza con Apple Music) l'app deve scrivere le modifiche **attraverso Apple Music** e non solo nei file. Si definiscono tre modalità, selezionabili/auto:

- **M-A — Via Apple Music (raccomandata di default).** Le modifiche sono applicate al database di Apple Music tramite automazione (Apple Events/AppleScript). Apple Music propaga la modifica e sincronizza con iCloud. Non innesca rinomina file se gestito correttamente. È il metodo che garantisce V3.
- **M-B — Via file + forzatura refresh.** Scrittura del tag nel file e successiva forzatura del re-import/refresh in Apple Music. Più fragile (rischio di revert su "Aggiorna libreria iCloud"); usata solo per campi non gestibili in M-A.
- **M-C — Solo file (offline).** Per brani non presenti/non gestibili in Apple Music. Da usare con cautela.

> L'app deve rendere **esplicita** all'utente la modalità in uso e l'esito, e deve preferire M-A per i campi standard.

### F4 — Gestione copertine

**Requisiti.**
- **F4.1** Visualizzazione copertina corrente (embedded) per brano/album.
- **F4.2** **Aggiunta** copertina dove assente.
- **F4.3** **Sostituzione** copertina esistente.
- **F4.4** Sorgenti: file locale (drag&drop/file picker), incolla da appunti, o risultato della ricerca online (F5).
- **F4.5** Applicazione a livello di **album** (tutti i brani) o singolo brano.
- **F4.6** Normalizzazione immagine: ridimensionamento/qualità configurabili (es. max 1000–1400px, JPEG), per non gonfiare i file.
- **F4.7** Coerenza con Apple Music: la copertina deve comparire nel brano in Apple Music (via modalità M-A/M-B).

### F5 — Arricchimento online (copertina + anno di pubblicazione)

**Descrizione.** Ricerca automatica di copertina e anno per brani/album carenti. L'utente ha riscontrato che la ricerca "su Google" rende meglio delle API di Discogs/MusicBrainz; l'app deve offrire una **strategia configurabile e multi-sorgente** (dettaglio e raccomandazioni nell'analisi tecnica), con l'utente sempre nel controllo della scelta finale.

**Requisiti.**
- **F5.1** Avvio ricerca su selezione (singolo, album, batch).
- **F5.2** Presentazione di **candidati** (immagini + anno + fonte + risoluzione) con possibilità di scelta manuale.
- **F5.3** Modalità **assistita** (l'utente conferma) e **automatica** (applica il miglior candidato secondo regole), con possibilità di revisione successiva.
- **F5.4** Caching dei risultati per evitare richieste ripetute.
- **F5.5** Rispetto dei limiti di rate delle sorgenti; gestione errori/timeout.
- **F5.6** Tracciamento della **fonte** del dato applicato (provenienza), per audit.

### F6 — Normalizzazione (generi e nomi artista)

**Requisiti.**
- **F6.1** Rilevazione automatica di **varianti** dello stesso genere/artista (es. "Hip Hop"/"Hip-Hop"/"hiphop"; "Beatles"/"The Beatles").
- **F6.2** Dizionario/regole di mapping **modificabili dall'utente** (canonical form).
- **F6.3** Suggerimenti basati su fuzzy matching e raggruppamento per similarità.
- **F6.4** Anteprima dell'impatto ("X brani passeranno da A a B") prima di applicare.
- **F6.5** Applicazione batch con possibilità di escludere singoli casi.
- **F6.6** Gestione separata di **artista** vs **artista album** (per compilation/feat.).
- **F6.7** Regole comuni: gestione "The", featuring/feat./ft., maiuscole, spazi multipli, caratteri speciali.

### F7 — Rilevamento duplicati

**Logica richiesta:** stesso artista + titolo simile. L'app deve inoltre poter sfruttare segnali più forti quando disponibili.

**Requisiti.**
- **F7.1** Rilevamento per **similarità di metadati**: stesso artista (normalizzato) + titolo simile (fuzzy), con soglia configurabile; considerare durata come segnale di conferma.
- **F7.2** (Opzionale, raccomandato) Rilevamento per **fingerprint audio** (contenuto) per individuare stessi brani con metadati diversi o formati diversi (MP3 vs M4A dello stesso brano).
- **F7.3** Presentazione a **gruppi di duplicati**, con attributi a confronto (formato, bitrate, durata, presenza copertina, percorso) per facilitare la scelta del "migliore".
- **F7.4** Suggerimento del candidato da conservare secondo criteri configurabili (es. preferisci M4A/AAC, bitrate maggiore, con copertina).
- **F7.5** Azioni sui duplicati: marcare, **eliminare** quelli ridondanti (passa per F8 con le relative salvaguardie). Nessuno spostamento file.
- **F7.6** Falsi positivi gestibili: possibilità di marcare un gruppo come "non duplicati".

### F8 — Localizza / Elimina in Apple Music

**Requisiti.**
- **F8.1** **Localizza**: dal brano nell'app, rivelare rapidamente il file nel Finder e/o selezionare il brano corrispondente in Apple Music ("Mostra nel Finder" / "Mostra in Music").
- **F8.2** **Elimina**: rimuovere il brano. Deve gestire la duplice natura (voce in Apple Music + file).
- **F8.3** Salvaguardie obbligatorie prima dell'eliminazione:
  - conferma esplicita con riepilogo di ciò che verrà eliminato (n. brani, dove);
  - scelta dell'ambito: rimuovi da Apple Music e/o sposta file nel Cestino;
  - protezione dall'eliminazione accidentale di massa (doppia conferma sopra una soglia);
  - log dettagliato delle eliminazioni.
- **F8.4** Coerenza con iCloud: l'eliminazione deve comportarsi in modo prevedibile anche con Sync Library attiva (chiarire all'utente l'effetto su altri dispositivi).
- **F8.5** Preferenza per spostamento nel **Cestino** anziché eliminazione definitiva, ove possibile.

### F9 — Coda operazioni, anteprima, undo/log

**Requisiti.**
- **F9.1** Tutte le operazioni di scrittura passano da una **coda** con stato (in attesa, in corso, completata, errore).
- **F9.2** **Anteprima/diff** prima dell'applicazione di modifiche batch.
- **F9.3** **Log** persistente delle operazioni (cosa, quando, esito, modalità di scrittura, fonte dei dati).
- **F9.4** **Undo** delle modifiche di metadati (almeno tramite snapshot dei valori precedenti memorizzati nell'indice). L'undo dell'eliminazione file è limitato al recupero dal Cestino.
- **F9.5** Gestione e ripresa dopo interruzioni; nessuna corruzione dell'indice in caso di crash.

---

## 7. Casi d'uso principali (UC)

### UC-01 — Primo avvio e indicizzazione
1. L'utente apre l'app e concede i permessi (accesso alla cartella Music, automazione di Apple Music).
2. L'app indicizza la libreria (25k) mostrando avanzamento.
3. Al termine, mostra dashboard con statistiche (brani senza copertina, senza anno, generi non normalizzati, potenziali duplicati).

### UC-02 — Pulizia di un album
1. L'utente filtra/raggruppa per album.
2. Seleziona un album con metadati incompleti.
3. Avvia arricchimento online → sceglie copertina e anno tra i candidati.
4. Normalizza il genere via dizionario.
5. Conferma; l'app applica via Apple Music e mostra l'esito.

### UC-03 — Normalizzazione di massa dei generi
1. L'utente apre il pannello Normalizzazione → Generi.
2. L'app mostra cluster di varianti.
3. L'utente definisce le forme canoniche.
4. Anteprima dell'impatto → applica → log.

### UC-04 — Deduplica
1. L'utente apre il pannello Duplicati.
2. L'app mostra gruppi (metadati + eventuale fingerprint).
3. Per ogni gruppo l'utente sceglie il brano da conservare.
4. Elimina i ridondanti con doppia conferma; file ridondanti nel Cestino; log.

### UC-05 — Editing batch metadati
1. Selezione multipla.
2. Operazione (valore comune / trova-sostituisci / propaga ad album).
3. Anteprima diff → applica via Apple Music.

### UC-06 — Localizza ed elimina singolo brano
1. Dal brano, "Mostra in Music" o "Mostra nel Finder".
2. In alternativa "Elimina" → conferma ambito e salvaguardie → esecuzione → log.

---

## 8. Requisiti non funzionali

| Categoria | Requisito |
|-----------|-----------|
| **Prestazioni** | Apertura app < 3 s; sync incrementale tipica < 30 s; UI fluida su 25k righe; ricerca/filtro < 200 ms percepiti. |
| **Scalabilità** | Architettura adatta a 50k+ brani senza ridisegno. |
| **Affidabilità** | Nessuna perdita dati; operazioni transazionali; indice resistente a crash. |
| **Sicurezza dati** | Operazioni distruttive protette; preferenza Cestino; log completo; backup/export dell'indice. |
| **Coerenza** | Stato dell'indice sempre riconciliabile con Apple Music; rilevazione e segnalazione delle divergenze. |
| **Usabilità** | Flussi batch chiari, anteprime, feedback d'avanzamento, messaggi d'errore comprensibili. |
| **Compatibilità** | macOS recente; MP3 e M4A/AAC; resiliente alle differenze tra versioni di Apple Music. |
| **Manutenibilità** | Regole di normalizzazione e mapping configurabili senza ricompilare. |
| **Privacy** | Le richieste online riguardano solo metadati/copertine; nessun upload dei file audio senza consenso esplicito (es. fingerprint via servizi esterni). |

---

## 9. Rischi funzionali (sintesi; dettaglio tecnico nel doc dedicato)

1. **Mancata propagazione/revert delle modifiche** a causa di iCloud Music Library → mitigato dalla modalità M-A (scrittura via Apple Music) e dalla riconciliazione dell'indice.
2. **Rinomina/spostamento file indesiderati** da "Mantieni organizzata" in conflitto con V1/V2 → strategia di scrittura che non innesca riorganizzazione + verifica post-operazione.
3. **Qualità/licenza dei dati online** (copertine, anno) → utente nel controllo, tracciamento fonte.
4. **Falsi positivi nei duplicati** → soglie configurabili, conferma manuale, opzione fingerprint.
5. **Eliminazioni accidentali** → salvaguardie, Cestino, log, undo limitato.

---

## 10. Criteri di accettazione (estratto)

- Una modifica di metadato applicata nell'app è **visibile in Apple Music** entro pochi secondi e **non viene annullata** dopo "Aggiorna libreria iCloud".
- Nessun file risulta **spostato o rinominato** dopo le operazioni (verificabile confrontando i percorsi nell'indice).
- L'avvio a regime usa **sync incrementale** (nessuna riscansione completa percepibile).
- Il rilevamento duplicati individua correttamente coppie MP3/M4A dello stesso brano (con fingerprint attivo).
- Un'eliminazione richiede conferma e finisce nel Cestino, con voce nel log.

---

*Documento complementare: «02 — Analisi Tecnica e di Fattibilità».*
