/*
 * MusicBridgeObjC.h — Public API del wrapper ScriptingBridge per Music.app.
 * Espone un'interfaccia ObjC semplice che Swift può importare.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Chiavi per i dizionari di metadati (TrackInfo e TrackUpdate).
extern NSString * const MBKeyPersistentID;
extern NSString * const MBKeyDatabaseID;
extern NSString * const MBKeyLocation;    // NSString (path) o NSNull
extern NSString * const MBKeyName;
extern NSString * const MBKeyArtist;
extern NSString * const MBKeyAlbumArtist;
extern NSString * const MBKeyAlbum;
extern NSString * const MBKeyYear;        // NSNumber (integer)
extern NSString * const MBKeyGenre;
extern NSString * const MBKeyComment;
extern NSString * const MBKeyComposer;
extern NSString * const MBKeyTrackNumber;
extern NSString * const MBKeyTrackCount;
extern NSString * const MBKeyDiscNumber;
extern NSString * const MBKeyDiscCount;
extern NSString * const MBKeyDuration;    // NSNumber (double, seconds)
extern NSString * const MBKeyBitRate;     // NSNumber (integer, kbps)
extern NSString * const MBKeySampleRate;  // NSNumber (double, Hz)
extern NSString * const MBKeyKind;        // NSString ("MPEG audio file" ecc.)
extern NSString * const MBKeyDateAdded;   // NSDate
extern NSString * const MBKeyModDate;     // NSDate

/// Wrapper ScriptingBridge attorno a Music.app.
/// Tutte le operazioni sono sincrone; devono essere chiamate da un thread/actor dedicato.
@interface MusicBridgeObjC : NSObject

/// Restituisce nil se Music.app non è raggiungibile.
+ (nullable instancetype)sharedBridge;

/// Enumera tutti i brani dalla Library Source.
/// @return Array di NSDictionary con le chiavi MB*. Nil in caso di errore.
- (nullable NSArray<NSDictionary *> *)allTracks:(NSError **)error;

/// Legge i metadati di un singolo track tramite persistentID.
- (nullable NSDictionary *)trackMetadataForPersistentID:(NSString *)pid
                                                   error:(NSError **)error;

/// Scrive i metadati contenuti in @p update (solo le chiavi presenti vengono applicate).
/// @param update Dizionario con un sottoinsieme delle chiavi MBKey* testuali/numeriche.
- (BOOL)setMetadata:(NSDictionary<NSString *, id> *)update
    forPersistentID:(NSString *)pid
              error:(NSError **)error;

/// Imposta la copertina (immagine raw JPEG/PNG come NSData) su un track.
- (BOOL)setArtworkData:(NSData *)data
       forPersistentID:(NSString *)pid
                 error:(NSError **)error;

/// Legge la copertina come NSData (primo artwork, nil se assente).
- (nullable NSData *)artworkDataForPersistentID:(NSString *)pid
                                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
