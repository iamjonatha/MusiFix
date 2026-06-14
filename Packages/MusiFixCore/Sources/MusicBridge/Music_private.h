/*
 * Music.h — ScriptingBridge header for Music.app
 * Generated manually from the Music.app scripting dictionary (sdef).
 * Covers the subset needed for MusiFix PoC (Phase 0).
 */

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

@class MusicApplication, MusicLibraryPlaylist, MusicTrack, MusicArtwork, MusicSource;

typedef NS_ENUM(NSUInteger, MusicEPlS) {
    MusicEPlSStopped       = 'kPSS',
    MusicEPlSPlaying       = 'kPSP',
    MusicEPlSPaused        = 'kPSp',
    MusicEPlSFastForwarding = 'kPSF',
    MusicEPlSRewinding     = 'kPSR',
};

typedef NS_ENUM(NSUInteger, MusicEKnd) {
    MusicEKndUnknown         = 'kUnk',
    MusicEKndSong            = 'kSpT',
    MusicEKndMusicVideo      = 'kVdT',
};

typedef NS_ENUM(NSUInteger, MusicESrc) {
    MusicESrcLibrary     = 'kLib',
    MusicESrcCD          = 'kACD',
    MusicESrcDevice      = 'kDev',
    MusicESrcRadioTuner  = 'kTun',
    MusicESrcSharedLibrary = 'kShd',
    MusicESrcITunesStore = 'kITS',
    MusicESrcUnknown     = 'kUnk',
};

// ────────────────────────────────────────────────
// MusicArtwork
// ────────────────────────────────────────────────
@interface MusicArtwork : SBObject
@property (copy) NSImage *data;
@property NSInteger rawData;
@property (readonly) OSType format;
@property BOOL isDownloaded;
@property (copy, readonly) NSURL *description;
- (id)get;
@end

// ────────────────────────────────────────────────
// MusicTrack
// ────────────────────────────────────────────────
@interface MusicTrack : SBObject
@property (copy) NSString *name;
@property (copy) NSString *artist;
@property (copy) NSString *albumArtist;
@property (copy) NSString *album;
@property NSInteger year;
@property (copy) NSString *genre;
@property (copy) NSString *comment;
@property (copy) NSString *composer;
@property (copy) NSString *grouping;
@property NSInteger trackNumber;
@property NSInteger trackCount;
@property NSInteger discNumber;
@property NSInteger discCount;
@property double duration;
@property NSInteger bitRate;
@property double sampleRate;
@property (copy, readonly) NSString *kind;
@property (copy, readonly) NSString *persistentID;
@property (copy, readonly) NSURL *location;
@property (copy, readonly) NSDate *dateAdded;
@property (copy, readonly) NSDate *modificationDate;
@property (readonly) NSInteger databaseID;
@property BOOL cloudStatus;
- (SBElementArray<MusicArtwork *> *)artworks;
- (id)get;
@end

// ────────────────────────────────────────────────
// MusicLibraryPlaylist
// ────────────────────────────────────────────────
@interface MusicLibraryPlaylist : SBObject
@property (copy, readonly) NSString *name;
- (SBElementArray<MusicTrack *> *)tracks;
- (id)get;
@end

// ────────────────────────────────────────────────
// MusicSource
// ────────────────────────────────────────────────
@interface MusicSource : SBObject
@property (copy, readonly) NSString *name;
@property (readonly) MusicESrc kind;
- (SBElementArray<MusicLibraryPlaylist *> *)libraryPlaylists;
- (id)get;
@end

// ────────────────────────────────────────────────
// MusicApplication
// ────────────────────────────────────────────────
@interface MusicApplication : SBApplication
@property (readonly) MusicEPlS playerState;
@property (copy, readonly) MusicTrack *currentTrack;
- (SBElementArray<MusicSource *> *)sources;
- (SBElementArray<MusicTrack *> *)tracks;
- (SBElementArray<MusicLibraryPlaylist *> *)libraryPlaylists;
@end
