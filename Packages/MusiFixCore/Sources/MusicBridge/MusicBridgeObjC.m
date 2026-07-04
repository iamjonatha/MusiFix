/*
 * MusicBridgeObjC.m — Implementazione ScriptingBridge per Music.app.
 */

#import "include/MusicBridgeObjC.h"
#import "Music_private.h"

NSString * const MBKeyPersistentID = @"persistentID";
NSString * const MBKeyDatabaseID   = @"databaseID";
NSString * const MBKeyLocation     = @"location";
NSString * const MBKeyName         = @"name";
NSString * const MBKeyArtist       = @"artist";
NSString * const MBKeyAlbumArtist  = @"albumArtist";
NSString * const MBKeyAlbum        = @"album";
NSString * const MBKeyYear         = @"year";
NSString * const MBKeyGenre        = @"genre";
NSString * const MBKeyComment      = @"comment";
NSString * const MBKeyComposer     = @"composer";
NSString * const MBKeyTrackNumber  = @"trackNumber";
NSString * const MBKeyTrackCount   = @"trackCount";
NSString * const MBKeyDiscNumber   = @"discNumber";
NSString * const MBKeyDiscCount    = @"discCount";
NSString * const MBKeyDuration     = @"duration";
NSString * const MBKeyBitRate      = @"bitRate";
NSString * const MBKeySampleRate   = @"sampleRate";
NSString * const MBKeyKind         = @"kind";
NSString * const MBKeyCloudStatus  = @"cloudStatus";
NSString * const MBKeyDateAdded    = @"dateAdded";
NSString * const MBKeyModDate      = @"modificationDate";

// ─── helpers ─────────────────────────────────────────────────────────────────

static NSError *bridgeError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"it.musifixapp.MusicBridge"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

/// Converte un OSType (codice 4-char dell'enum cloud status) in stringa.
/// Restituisce "" per 0/unknown.
static NSString *osTypeToString(OSType code) {
    if (code == 0) return @"";
    char c[5] = {
        (char)((code >> 24) & 0xFF), (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),  (char)(code & 0xFF), 0
    };
    NSString *s = [NSString stringWithCString:c encoding:NSMacOSRomanStringEncoding];
    return s ?: @"";
}

static NSDictionary *trackToDictionary(MusicTrack *t) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[MBKeyPersistentID] = t.persistentID ?: @"";
    d[MBKeyDatabaseID]   = @(t.databaseID);
    NSURL *loc = t.location;
    d[MBKeyLocation]     = loc ? loc.path : [NSNull null];
    d[MBKeyName]         = t.name ?: @"";
    d[MBKeyArtist]       = t.artist ?: @"";
    d[MBKeyAlbumArtist]  = t.albumArtist ?: @"";
    d[MBKeyAlbum]        = t.album ?: @"";
    d[MBKeyYear]         = @(t.year);
    d[MBKeyGenre]        = t.genre ?: @"";
    d[MBKeyComment]      = t.comment ?: @"";
    d[MBKeyComposer]     = t.composer ?: @"";
    d[MBKeyTrackNumber]  = @(t.trackNumber);
    d[MBKeyTrackCount]   = @(t.trackCount);
    d[MBKeyDiscNumber]   = @(t.discNumber);
    d[MBKeyDiscCount]    = @(t.discCount);
    d[MBKeyDuration]     = @(t.duration);
    d[MBKeyBitRate]      = @(t.bitRate);
    d[MBKeySampleRate]   = @(t.sampleRate);
    d[MBKeyKind]         = t.kind ?: @"";
    // La lettura dell'enum cloudStatus può lanciare su alcune tracce: la isoliamo.
    @try {
        d[MBKeyCloudStatus] = osTypeToString((OSType)t.cloudStatus);
    } @catch (NSException *ex) {
        d[MBKeyCloudStatus] = @"";
    }
    d[MBKeyDateAdded]    = t.dateAdded ?: [NSNull null];
    d[MBKeyModDate]      = t.modificationDate ?: [NSNull null];
    return [d copy];
}

// ─── MusicBridgeObjC ─────────────────────────────────────────────────────────

@implementation MusicBridgeObjC {
    MusicApplication *_app;
}

+ (nullable instancetype)sharedBridge {
    MusicApplication *app =
        [SBApplication applicationWithBundleIdentifier:@"com.apple.Music"];
    if (!app || ![app isRunning]) {
        // Tenta di attivare Music (necessario per ScriptingBridge)
        [app activate];
        // Breve attesa max 3 s
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (![app isRunning] && [[NSDate date] compare:deadline] == NSOrderedAscending) {
            [NSThread sleepForTimeInterval:0.2];
        }
        if (![app isRunning]) return nil;
    }
    MusicBridgeObjC *bridge = [[self alloc] init];
    bridge->_app = app;
    return bridge;
}

// Restituisce la Library Source (prima sorgente di tipo kLib).
- (nullable MusicSource *)librarySource {
    for (MusicSource *src in [_app sources]) {
        if (src.kind == MusicESrcLibrary) return src;
    }
    return [[_app sources] firstObject];
}

- (nullable MusicTrack *)trackWithPersistentID:(NSString *)pid {
    // "whose" clause → un solo Apple Event invece di un loop su 25k brani
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"persistentID == %@", pid];
    SBElementArray<MusicTrack *> *filtered =
        (SBElementArray<MusicTrack *> *)[[_app tracks] filteredArrayUsingPredicate:pred];
    return filtered.count > 0 ? filtered[0] : nil;
}

// ─── allTracks ───────────────────────────────────────────────────────────────

- (nullable NSArray<NSDictionary *> *)allTracks:(NSError **)error {
    @try {
        SBElementArray<MusicTrack *> *tracks = [_app tracks];
        if (!tracks) {
            if (error) *error = bridgeError(1, @"Impossibile ottenere la lista dei track");
            return nil;
        }
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:tracks.count];
        for (MusicTrack *t in tracks) {
            [result addObject:trackToDictionary(t)];
        }
        return [result copy];
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(2, ex.reason ?: @"Eccezione ScriptingBridge");
        return nil;
    }
}

// ─── trackMetadata ───────────────────────────────────────────────────────────

- (nullable NSDictionary *)trackMetadataForPersistentID:(NSString *)pid
                                                   error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackWithPersistentID:pid];
        if (!t) {
            if (error) *error = bridgeError(3, [NSString stringWithFormat:@"Track non trovato: %@", pid]);
            return nil;
        }
        return trackToDictionary(t);
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(4, ex.reason ?: @"Eccezione ScriptingBridge");
        return nil;
    }
}

// ─── setMetadata ─────────────────────────────────────────────────────────────

- (BOOL)setMetadata:(NSDictionary<NSString *, id> *)update
    forPersistentID:(NSString *)pid
              error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackWithPersistentID:pid];
        if (!t) {
            if (error) *error = bridgeError(3, [NSString stringWithFormat:@"Track non trovato: %@", pid]);
            return NO;
        }
        if (update[MBKeyName])        t.name        = update[MBKeyName];
        if (update[MBKeyArtist])      t.artist      = update[MBKeyArtist];
        if (update[MBKeyAlbumArtist]) t.albumArtist = update[MBKeyAlbumArtist];
        if (update[MBKeyAlbum])       t.album       = update[MBKeyAlbum];
        if (update[MBKeyYear])        t.year        = [update[MBKeyYear] integerValue];
        if (update[MBKeyGenre])       t.genre       = update[MBKeyGenre];
        if (update[MBKeyComment])     t.comment     = update[MBKeyComment];
        if (update[MBKeyComposer])    t.composer    = update[MBKeyComposer];
        if (update[MBKeyTrackNumber]) t.trackNumber = [update[MBKeyTrackNumber] integerValue];
        if (update[MBKeyTrackCount])  t.trackCount  = [update[MBKeyTrackCount] integerValue];
        if (update[MBKeyDiscNumber])  t.discNumber  = [update[MBKeyDiscNumber] integerValue];
        if (update[MBKeyDiscCount])   t.discCount   = [update[MBKeyDiscCount] integerValue];
        return YES;
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(5, ex.reason ?: @"Eccezione scrittura");
        return NO;
    }
}

// ─── artwork ─────────────────────────────────────────────────────────────────

- (BOOL)setArtworkData:(NSData *)data
       forPersistentID:(NSString *)pid
                 error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackWithPersistentID:pid];
        if (!t) {
            if (error) *error = bridgeError(3, [NSString stringWithFormat:@"Track non trovato: %@", pid]);
            return NO;
        }
        SBElementArray<MusicArtwork *> *artworks = [t artworks];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image) {
            if (error) *error = bridgeError(6, @"Dati immagine non validi");
            return NO;
        }
        if (artworks.count > 0) {
            artworks[0].data = image;
        } else {
            // Crea un nuovo artwork element
            MusicArtwork *aw = [[[_app classForScriptingClass:@"artwork"] alloc] init];
            aw.data = image;
            [artworks addObject:aw];
        }
        return YES;
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(7, ex.reason ?: @"Eccezione artwork");
        return NO;
    }
}

- (nullable NSData *)artworkDataForPersistentID:(NSString *)pid
                                           error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackWithPersistentID:pid];
        if (!t) {
            if (error) *error = bridgeError(3, [NSString stringWithFormat:@"Track non trovato: %@", pid]);
            return nil;
        }
        SBElementArray<MusicArtwork *> *artworks = [t artworks];
        if (artworks.count == 0) return nil;
        MusicArtwork *aw = artworks[0];

        // Fonte primaria: i byte grezzi dell'immagine. Affidabili anche sui brani
        // cloud/matched, dove la proprietà `data` (NSImage) può tornare nil via
        // ScriptingBridge pur essendoci una copertina valida.
        NSData *raw = aw.rawData;
        if ([raw isKindOfClass:[NSData class]] && raw.length > 0) {
            return raw;
        }

        // Fallback: ricava i byte dall'NSImage `data` ricodificandolo in PNG.
        NSImage *img = aw.data;
        if (!img) return nil;
        CGImageRef cgImg = [img CGImageForProposedRect:nil context:nil hints:nil];
        if (!cgImg) return nil;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
        return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(8, ex.reason ?: @"Eccezione lettura artwork");
        return nil;
    }
}

// ─── deleteTrack ─────────────────────────────────────────────────────────────

- (BOOL)deleteTrackForPersistentID:(NSString *)pid error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackWithPersistentID:pid];
        if (!t) {
            if (error) *error = bridgeError(3, [NSString stringWithFormat:@"Track non trovato: %@", pid]);
            return NO;
        }
        [t delete];
        return YES;
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(9, ex.reason ?: @"Eccezione eliminazione track");
        return NO;
    }
}

// ─── revealInMusic ────────────────────────────────────────────────────────────

/// Cerca il brano nella library playlist, non in `every track`:
/// equivalente all'AppleScript `first track of library playlist 1 whose persistent ID is "..."`.
- (nullable MusicTrack *)trackForReveal:(NSString *)pid {
    MusicSource *src = [self librarySource];
    if (!src) return nil;
    SBElementArray<MusicLibraryPlaylist *> *playlists = [src libraryPlaylists];
    MusicLibraryPlaylist *lib = playlists.count > 0 ? playlists[0] : nil;
    if (!lib) return nil;
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"persistentID == %@", pid];
    SBElementArray<MusicTrack *> *filtered =
        (SBElementArray<MusicTrack *> *)[[lib tracks] filteredArrayUsingPredicate:pred];
    return filtered.count > 0 ? filtered[0] : nil;
}

// ─── playlist membership ──────────────────────────────────────────────────────

- (nullable NSArray<NSString *> *)regularPlaylistTrackPersistentIDs:(NSError **)error {
    @try {
        SBElementArray<MusicUserPlaylist *> *playlists = [_app userPlaylists];
        if (!playlists) {
            if (error) *error = bridgeError(11, @"Impossibile ottenere le playlist utente");
            return nil;
        }
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (MusicUserPlaylist *pl in playlists) {
            @try {
                // Salta smart playlist, cartelle e playlist speciali.
                if (pl.smart) continue;
                if (pl.specialKind != MusicESpKNone) continue;

                // Recupero massivo dei persistentID con un solo Apple Event.
                NSArray *pids = [[pl tracks] arrayByApplyingSelector:@selector(persistentID)];
                for (id pid in pids) {
                    if ([pid isKindOfClass:[NSString class]] && [(NSString *)pid length] > 0) {
                        [result addObject:pid];
                    }
                }
            } @catch (NSException *inner) {
                // Playlist problematica (es. condivisa/non accessibile): la saltiamo.
                NSLog(@"[MusicBridge] playlist saltata: %@", inner.reason ?: @"?");
            }
        }
        return [result copy];
    } @catch (NSException *ex) {
        if (error) *error = bridgeError(12, ex.reason ?: @"Eccezione enumerazione playlist");
        return nil;
    }
}

- (BOOL)revealInMusicForPersistentID:(NSString *)pid error:(NSError **)error {
    @try {
        MusicTrack *t = [self trackForReveal:pid];
        if (!t) {
            NSString *msg = [NSString stringWithFormat:@"Track non trovato per reveal: %@", pid];
            NSLog(@"[MusicBridge] %@", msg);
            if (error) *error = bridgeError(3, msg);
            return NO;
        }
        [_app reveal:t];
        [_app activate];
        return YES;
    } @catch (NSException *ex) {
        NSString *msg = ex.reason ?: @"Eccezione reveal in Music";
        NSLog(@"[MusicBridge] revealInMusic eccezione: %@", msg);
        if (error) *error = bridgeError(10, msg);
        return NO;
    }
}

@end
