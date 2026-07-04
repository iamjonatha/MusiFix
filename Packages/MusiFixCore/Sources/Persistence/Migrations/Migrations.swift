import GRDB

/// Tutte le migrazioni dello schema, in ordine.
/// Aggiungere sempre nuove versioni IN FONDO — mai modificare quelle esistenti.
public enum Migrations {
    public static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema", migrate: v1)
        migrator.registerMigration("v1_fts5", migrate: v1_fts5)
        migrator.registerMigration("v2_operation_batchid", migrate: v2_operation_batchid)
        migrator.registerMigration("v3_duplicates", migrate: v3_duplicates)
        migrator.registerMigration("v4_deletion_log", migrate: v4_deletion_log)
        migrator.registerMigration("v5_cloud_status", migrate: v5_cloud_status)
        migrator.registerMigration("v6_album_store_info", migrate: v6_album_store_info)
        migrator.registerMigration("v7_has_artwork", migrate: v7_has_artwork)
        migrator.registerMigration("v8_perf_indexes", migrate: v8_perf_indexes)
        migrator.registerMigration("v9_musifix_ignore", migrate: v9_musifix_ignore)
        migrator.registerMigration("v10_playlist_membership", migrate: v10_playlist_membership)
    }

    // ── v10: appartenenza a playlist normali (Fase 15) ────────────────────────
    private static func v10_playlist_membership(_ db: Database) throws {
        // NULL = non ancora scansionato, 0 = in nessuna playlist normale, 1 = in ≥1.
        try db.alter(table: "track") { t in
            t.add(column: "inPlaylist", .integer)
        }
        try db.create(index: "track_in_playlist", on: "track", columns: ["inPlaylist"])
    }

    // ── v9: esclusioni "ignora in MusiFix" (brano + album) ────────────────────
    private static func v9_musifix_ignore(_ db: Database) throws {
        // Brani esclusi dai processi di sistemazione (per persistentID).
        try db.create(table: "track_ignore") { t in
            t.primaryKey("persistentID", .text)
            t.column("ignoredAt", .datetime).notNull()
        }
        // Album esclusi (chiave = LOWER(albumArtist|artist)+CHAR(31)+LOWER(album),
        // coerente con AlbumDAO/album_store_info).
        try db.create(table: "album_ignore") { t in
            t.primaryKey("albumKey", .text)
            t.column("albumArtist", .text).notNull().defaults(to: "")
            t.column("album", .text).notNull().defaults(to: "")
            t.column("ignoredAt", .datetime).notNull()
        }
    }

    // ── v1: schema principale ─────────────────────────────────────────────────
    private static func v1(_ db: Database) throws {
        // Tabella principale brani
        try db.create(table: "track") { t in
            t.primaryKey("persistentID", .text)
            t.column("databaseID", .integer).notNull()
            t.column("locationPath", .text)
            t.column("locationMtime", .double)
            t.column("locationSize", .integer)
            t.column("contentHash", .text)
            t.column("isCloudOnly", .boolean).notNull().defaults(to: false)
            t.column("isEditable", .boolean).notNull().defaults(to: true)
            t.column("name", .text).notNull().defaults(to: "")
            t.column("artist", .text).notNull().defaults(to: "")
            t.column("albumArtist", .text).notNull().defaults(to: "")
            t.column("album", .text).notNull().defaults(to: "")
            t.column("year", .integer).notNull().defaults(to: 0)
            t.column("genre", .text).notNull().defaults(to: "")
            t.column("comment", .text).notNull().defaults(to: "")
            t.column("composer", .text).notNull().defaults(to: "")
            t.column("trackNumber", .integer).notNull().defaults(to: 0)
            t.column("trackCount", .integer).notNull().defaults(to: 0)
            t.column("discNumber", .integer).notNull().defaults(to: 0)
            t.column("discCount", .integer).notNull().defaults(to: 0)
            t.column("duration", .double).notNull().defaults(to: 0)
            t.column("bitRate", .integer).notNull().defaults(to: 0)
            t.column("sampleRate", .double).notNull().defaults(to: 0)
            t.column("format", .text).notNull().defaults(to: "")
            t.column("kind", .text).notNull().defaults(to: "")
            t.column("musicDateAdded", .datetime)
            t.column("musicModDate", .datetime)
            t.column("indexedAt", .datetime).notNull()
            t.column("artistNormalized", .text).notNull().defaults(to: "")
            t.column("albumNormalized", .text).notNull().defaults(to: "")
            t.column("genreNormalized", .text).notNull().defaults(to: "")
        }

        // Indici per i pattern di query più comuni
        try db.create(index: "track_artist", on: "track", columns: ["artistNormalized"])
        try db.create(index: "track_album", on: "track", columns: ["albumNormalized"])
        try db.create(index: "track_genre", on: "track", columns: ["genreNormalized"])
        try db.create(index: "track_year", on: "track", columns: ["year"])
        try db.create(index: "track_moddate", on: "track", columns: ["musicModDate"])

        // Alias generi (per normalizzazione Fase 4)
        try db.create(table: "genre_alias") { t in
            t.primaryKey("from", .text)
            t.column("to", .text).notNull()
        }

        // Alias artisti
        try db.create(table: "artist_alias") { t in
            t.primaryKey("from", .text)
            t.column("to", .text).notNull()
        }

        // Log operazioni (undo/audit)
        try db.create(table: "operation_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("persistentID", .text).notNull()
                .references("track", onDelete: .cascade)
            t.column("field", .text).notNull()
            t.column("valueBefore", .text)
            t.column("valueAfter", .text)
            t.column("performedAt", .datetime).notNull()
            t.column("status", .text).notNull().defaults(to: "pending")
            t.column("errorMessage", .text)
        }
        try db.create(index: "oplog_pid", on: "operation_log", columns: ["persistentID"])
        try db.create(index: "oplog_status", on: "operation_log", columns: ["status"])

        // Cache arricchimento online (copertine / anno)
        try db.create(table: "enrichment_cache") { t in
            t.primaryKey("cacheKey", .text)
            t.column("provider", .text).notNull()
            t.column("artworkURL", .text)
            t.column("artworkData", .blob)
            t.column("releaseYear", .integer)
            t.column("fetchedAt", .datetime).notNull()
            t.column("score", .double).notNull().defaults(to: 0)
        }

        // Checkpoint indicizzazione (ripresa dopo crash)
        try db.create(table: "indexing_checkpoint") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startedAt", .datetime).notNull()
            t.column("lastPersistentID", .text)
            t.column("totalExpected", .integer).notNull().defaults(to: 0)
            t.column("processed", .integer).notNull().defaults(to: 0)
            t.column("phase", .text).notNull().defaults(to: "music_fetch")
            t.column("completedAt", .datetime)
        }

        // Stato sync FSEvents / ultima sync Music
        try db.create(table: "sync_state") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    // ── v2: batchID su operation_log ─────────────────────────────────────────────
    private static func v2_operation_batchid(_ db: Database) throws {
        try db.alter(table: "operation_log") { t in
            t.add(column: "batchID", .text)
        }
        try db.create(index: "oplog_batchid", on: "operation_log", columns: ["batchID"])
    }

    // ── v3: fingerprint audio + duplicate_ignore ──────────────────────────────
    private static func v3_duplicates(_ db: Database) throws {
        try db.alter(table: "track") { t in
            t.add(column: "audioFingerprint", .blob)
        }
        try db.create(table: "duplicate_ignore") { t in
            t.primaryKey(["pid1", "pid2"])
            t.column("pid1", .text).notNull()
            t.column("pid2", .text).notNull()
            t.column("ignoredAt", .datetime).notNull()
        }
    }

    // ── v4: deletion_log (audit eliminazioni) ─────────────────────────────────
    private static func v4_deletion_log(_ db: Database) throws {
        try db.create(table: "deletion_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("persistentID", .text).notNull()
            t.column("name", .text).notNull().defaults(to: "")
            t.column("artist", .text).notNull().defaults(to: "")
            t.column("album", .text).notNull().defaults(to: "")
            t.column("locationPath", .text)
            t.column("scope", .text).notNull()  // "music_only" | "music_and_trash"
            t.column("deletedAt", .datetime).notNull()
            t.column("status", .text).notNull() // "done" | "failed"
            t.column("errorMessage", .text)
            t.column("batchID", .text)
        }
        try db.create(index: "deletion_log_batchid", on: "deletion_log", columns: ["batchID"])
        try db.create(index: "deletion_log_date", on: "deletion_log", columns: ["deletedAt"])
    }

    // ── v5: stato iCloud reale (cloudStatus) ──────────────────────────────────
    private static func v5_cloud_status(_ db: Database) throws {
        try db.alter(table: "track") { t in
            // Codice 4-char Music.app: kMat/kUpl/kPur/kSub/… ("" = non noto)
            t.add(column: "cloudStatus", .text).notNull().defaults(to: "")
        }
    }

    // ── v6: cache info album dallo Store (Fase D) ──────────────────────────────
    private static func v6_album_store_info(_ db: Database) throws {
        try db.create(table: "album_store_info") { t in
            t.primaryKey("albumKey", .text)          // LOWER(albumArtist)+CHAR(31)+LOWER(album)
            t.column("albumArtist", .text).notNull().defaults(to: "")
            t.column("album", .text).notNull().defaults(to: "")
            t.column("collectionId", .integer)       // iTunes collectionId
            t.column("storeTrackCount", .integer)    // trackCount autorevole dallo Store
            t.column("matchState", .text).notNull().defaults(to: "pending")
                // "pending" | "found" | "notFound" | "multiDisc"
            t.column("fetchedAt", .datetime).notNull()
        }
    }

    // ── v7: presenza copertina ────────────────────────────────────────────────
    private static func v7_has_artwork(_ db: Database) throws {
        try db.alter(table: "track") { t in
            // NULL = non ancora scansionato, 0 = assente, 1 = presente
            t.add(column: "hasArtwork", .integer)
        }
        try db.create(index: "track_has_artwork", on: "track", columns: ["hasArtwork"])
    }

    // ── v8: indici prestazionali + anno di aggiunta materializzato ────────────
    private static func v8_perf_indexes(_ db: Database) throws {
        // Colonna materializzata dell'anno di aggiunta a Music. Evita lo strftime
        // per-riga (non-sargable) nei filtri/menu "anno di aggiunta". Popolata da
        // DBTrack.init e ri-backfillata qui per le righe già presenti.
        try db.alter(table: "track") { t in
            t.add(column: "addedYear", .integer)
        }
        try db.execute(sql: """
            UPDATE track SET addedYear = CAST(strftime('%Y', musicDateAdded) AS INTEGER)
            WHERE musicDateAdded IS NOT NULL
            """)
        try db.create(index: "track_added_year", on: "track", columns: ["addedYear"])

        // Indici compound che coprono l'ORDER BY della tabella browser: senza questi
        // SQLite riordina l'intera libreria (25k righe) a ogni cambio pagina/sort.
        // Il sort secondario è sempre [albumNormalized, discNumber, trackNumber].
        // Coprono anche i filtri .artist/.album e le subquery "valori multipli".
        try db.create(index: "track_sort_artist", on: "track",
                      columns: ["artistNormalized", "albumNormalized", "discNumber", "trackNumber"])
        try db.create(index: "track_sort_album", on: "track",
                      columns: ["albumNormalized", "discNumber", "trackNumber"])

        // I singoli indici su artistNormalized/albumNormalized sono ora ridondanti
        // (prefisso dei compound sopra): rimuoverli evita doppio costo in scrittura.
        try db.execute(sql: "DROP INDEX IF EXISTS track_artist")
        try db.execute(sql: "DROP INDEX IF EXISTS track_album")
    }

    // ── v1_fts5: ricerca full-text ─────────────────────────────────────────────
    private static func v1_fts5(_ db: Database) throws {
        // Tabella FTS5 virtuale content= per non duplicare dati.
        try db.create(virtualTable: "track_fts", using: FTS5()) { t in
            t.content = "track"
            t.contentRowID = "rowid"
            t.column("name")
            t.column("artist")
            t.column("albumArtist")
            t.column("album")
            t.column("genre")
            t.column("composer")
            t.tokenizer = .unicode61()
        }

        // Trigger per mantenere FTS sincronizzato con la tabella track
        try db.execute(sql: """
            CREATE TRIGGER track_fts_ai AFTER INSERT ON track BEGIN
                INSERT INTO track_fts(rowid, name, artist, albumArtist, album, genre, composer)
                VALUES (new.rowid, new.name, new.artist, new.albumArtist, new.album, new.genre, new.composer);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER track_fts_ad AFTER DELETE ON track BEGIN
                INSERT INTO track_fts(track_fts, rowid, name, artist, albumArtist, album, genre, composer)
                VALUES ('delete', old.rowid, old.name, old.artist, old.albumArtist, old.album, old.genre, old.composer);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER track_fts_au AFTER UPDATE ON track BEGIN
                INSERT INTO track_fts(track_fts, rowid, name, artist, albumArtist, album, genre, composer)
                VALUES ('delete', old.rowid, old.name, old.artist, old.albumArtist, old.album, old.genre, old.composer);
                INSERT INTO track_fts(rowid, name, artist, albumArtist, album, genre, composer)
                VALUES (new.rowid, new.name, new.artist, new.albumArtist, new.album, new.genre, new.composer);
            END;
            """)
    }
}
