//
//  NLDataBaseManager.mm
//  NLSpotify
//

#import "NLDataBaseManager.h"
#import <WCDBObjc/WCDBObjc.h>
#import "NLSong+WCDB.h"
#import "NLPlaybackHistoryMetadata+WCDB.h"
#import "NLPlayList+WCDB.h"
#import "NLPlayListSongRelation+WCDB.h"
#import "NLDownloadItem+WCDB.h"
#import "NLAlbum+WCDB.h"
#import "NLSearchRecord+WCDB.h"
#import "NLAudioCacheInfo+WCDB.h"

static NSString * const kHistoryTableName = @"PlaybackHistoryTable";
static NSString * const kHistoryMetadataTableName = @"PlaybackHistoryMetadataTable";
static NSString * const kSchemaVersionTableName = @"DatabaseSchemaVersionTable";
static NSInteger const kCurrentSchemaVersion = 1;

static NSString * const kDownloadedSongsTableName = @"DownloadedSongsTable";
static NSString * const kLikedSongsTableName = @"LikedSongsTable";
static NSString * const kPlayListTableName = @"PlayListTable";
static NSString * const kPlayListSongRelationTableName = @"PlayListSongRelationTable";
static NSString * const kLocalSongsTableName = @"LocalSongsCacheTable";
static NSString * const kDownloadQueueTableName = @"DownloadQueueTable";
static NSString * const kLikedAlbumsTableName = @"LikedAlbumsTable";
static NSString * const kSearchHistoryTableName = @"SearchHistoryTable";
static NSString * const kSchemaVersionIdentifier = @"NLSpotify";
static NLDataBaseManager *NLSharedDataBaseManager;
static NSString * const kLegacyAudioCacheTableName = @"AudioCacheInfoTable";

@interface NLLegacyAudioCacheInfo : NSObject <WCTTableCoding>
@property (nonatomic, copy) NSString *urlMD5;
@property (nonatomic, copy, nullable) NSString *songId;
@property (nonatomic, assign) long long totalLength;
@property (nonatomic, copy) NSString *cachedRangesString;
@property (nonatomic, assign) NSTimeInterval lastAccessTime;
@property (nonatomic, assign) BOOL isFinished;
WCDB_PROPERTY(urlMD5)
WCDB_PROPERTY(songId)
WCDB_PROPERTY(totalLength)
WCDB_PROPERTY(cachedRangesString)
WCDB_PROPERTY(lastAccessTime)
WCDB_PROPERTY(isFinished)
@end

@implementation NLLegacyAudioCacheInfo
WCDB_IMPLEMENTATION(NLLegacyAudioCacheInfo)
WCDB_SYNTHESIZE(urlMD5)
WCDB_SYNTHESIZE(songId)
WCDB_SYNTHESIZE(totalLength)
WCDB_SYNTHESIZE(cachedRangesString)
WCDB_SYNTHESIZE(lastAccessTime)
WCDB_SYNTHESIZE(isFinished)
WCDB_PRIMARY(urlMD5)
@end

@interface NLDatabaseSchemaVersion : NSObject <WCTTableCoding>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) NSInteger version;
WCDB_PROPERTY(identifier)
WCDB_PROPERTY(version)
@end

@implementation NLDatabaseSchemaVersion
WCDB_IMPLEMENTATION(NLDatabaseSchemaVersion)
WCDB_SYNTHESIZE(identifier)
WCDB_SYNTHESIZE(version)
WCDB_PRIMARY(identifier)
@end

@interface NLDataBaseManager ()
@property (nonatomic, strong, readwrite) WCTDatabase *database;
@property (nonatomic, copy) NSString *databasePath;
@property (nonatomic, copy) NSString *legacyDatabasePath;
@property (nonatomic, strong) dispatch_queue_t writerQueue;
@property (nonatomic, assign) BOOL databaseReady;
- (nullable instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error;
- (instancetype)initWithDatabasePath:(NSString *)path
              initializeImmediately:(BOOL)initializeImmediately
                              error:(NSError **)error;
- (BOOL)ensureDatabaseReady:(NSError **)error;
- (BOOL)migrateSchemaIfNeeded:(NSError **)error;
+ (void)setSharedManagerForTesting:(NLDataBaseManager *)manager;
@end

@implementation NLDataBaseManager

+ (instancetype)sharedManager {
    @synchronized (self) {
        if (!NLSharedDataBaseManager) {
            NLSharedDataBaseManager = [[self alloc] init];
        }
        return NLSharedDataBaseManager;
    }
}

+ (void)setSharedManagerForTesting:(NLDataBaseManager *)manager {
    @synchronized (self) {
        NLSharedDataBaseManager = manager;
    }
}

- (instancetype)init {
    NSString *supportPath = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [supportPath stringByAppendingPathComponent:@"NLSpotify"];
    NSString *databasePath = [directory stringByAppendingPathComponent:@"NLSpotify_v2.sqlite"];
    self = [self initWithDatabasePath:databasePath initializeImmediately:NO error:nil];
    if (self) {
        NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _legacyDatabasePath = [documentsPath stringByAppendingPathComponent:@"NLSpotify_v2.sqlite"];
    }
    return self;
}

- (instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error {
    return [self initWithDatabasePath:path initializeImmediately:YES error:error];
}

- (instancetype)initWithDatabasePath:(NSString *)path
              initializeImmediately:(BOOL)initializeImmediately
                              error:(NSError **)error {
    if (path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Database path is empty."}];
        return nil;
    }

    self = [super init];
    if (!self) return nil;
    _databasePath = [path copy];
    _writerQueue = dispatch_queue_create("com.nlspotify.wcdb.writer", DISPATCH_QUEUE_SERIAL);

    if (initializeImmediately && ![self ensureDatabaseReady:error]) return nil;
    return self;
}

- (WCTDatabase *)database {
    if (![self ensureDatabaseReady:nil]) return nil;
    return _database;
}

- (BOOL)ensureDatabaseReady:(NSError **)error {
    @synchronized (self) {
        if (self.databaseReady && _database) return YES;

        NSString *directory = [self.databasePath stringByDeletingLastPathComponent];
        NSError *directoryError = nil;
        BOOL directoryReady = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                                       withIntermediateDirectories:YES
                                                                        attributes:nil
                                                                             error:&directoryError];
        if (!directoryReady) {
            if (error) *error = directoryError ?: [NSError errorWithDomain:@"NLDataBaseManager"
                                                                       code:2
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Database directory could not be created."}];
            return NO;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (self.legacyDatabasePath.length > 0 &&
            ![fileManager fileExistsAtPath:self.databasePath] &&
            [fileManager fileExistsAtPath:self.legacyDatabasePath]) {
            // WCDB moves the complete file family, including WAL and repair material.
            // Do not open an empty destination if relocation fails.
            WCTDatabase *legacyDatabase = [[WCTDatabase alloc] initWithPath:self.legacyDatabasePath];
            if (![legacyDatabase moveFilesToDirectory:directory]) {
                if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                        code:8
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Database relocation failed and can be retried."}];
                return NO;
            }
        }

        if (!_database) _database = [[WCTDatabase alloc] initWithPath:self.databasePath];
        if (![_database canOpen]) {
            if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                    code:3
                                                userInfo:@{NSLocalizedDescriptionKey: @"WCDB could not open the database."}];
            return NO;
        }

        BOOL tablesReady =
            [_database createTable:kHistoryTableName withClass:NLSong.class] &&
            [_database createTable:kHistoryMetadataTableName withClass:NLPlaybackHistoryMetadata.class] &&
            [_database createTable:kSchemaVersionTableName withClass:NLDatabaseSchemaVersion.class] &&
            [_database createTable:kDownloadedSongsTableName withClass:NLSong.class] &&
            [_database createTable:kLikedSongsTableName withClass:NLSong.class] &&
            [_database createTable:kPlayListTableName withClass:NLPlayList.class] &&
            [_database createTable:kPlayListSongRelationTableName withClass:NLPlayListSongRelation.class] &&
            [_database createTable:kLocalSongsTableName withClass:NLSong.class] &&
            [_database createTable:kDownloadQueueTableName withClass:NLDownloadItem.class] &&
            [_database createTable:kLikedAlbumsTableName withClass:NLAlbum.class] &&
            [_database createTable:kSearchHistoryTableName withClass:NLSearchRecord.class];
        if (!tablesReady) {
            if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                    code:4
                                                userInfo:@{NSLocalizedDescriptionKey: @"WCDB table initialization failed."}];
            return NO;
        }

        if (![self migrateSchemaIfNeeded:error]) return NO;
        self.databaseReady = YES;
        return YES;
    }
}

- (BOOL)migrateSchemaIfNeeded:(NSError **)error {
    NLDatabaseSchemaVersion *storedVersion = [_database getObjectOfClass:NLDatabaseSchemaVersion.class
                                                                 fromTable:kSchemaVersionTableName
                                                                     where:NLDatabaseSchemaVersion.identifier == kSchemaVersionIdentifier];
    if (storedVersion.version > kCurrentSchemaVersion) {
        if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                code:5
                                            userInfo:@{NSLocalizedDescriptionKey: @"Database schema is newer than this application."}];
        return NO;
    }
    if (storedVersion.version == kCurrentSchemaVersion) return YES;

    NSArray<NLSong *> *legacySongs = [_database getObjectsOfClass:NLSong.class fromTable:kHistoryTableName];
    if (!legacySongs) {
        if (error) *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                                code:6
                                            userInfo:@{NSLocalizedDescriptionKey: @"Legacy playback history could not be read."}];
        return NO;
    }

    BOOL migrated = [_database runTransaction:^BOOL(WCTHandle *transactionHandle) {
        for (NLSong *song in legacySongs) {
            if (song.songId.length == 0) continue;
            NLPlaybackHistoryMetadata *metadata = [transactionHandle getObjectOfClass:NLPlaybackHistoryMetadata.class
                                                                               fromTable:kHistoryMetadataTableName
                                                                                   where:NLPlaybackHistoryMetadata.songId == song.songId];
            if (metadata) continue;

            metadata = [[NLPlaybackHistoryMetadata alloc] init];
            metadata.songId = song.songId;
            metadata.lastPlayedAt = 0;
            metadata.playCount = 1;
            if (![transactionHandle insertOrReplaceObject:metadata intoTable:kHistoryMetadataTableName]) return NO;
        }

        NLDatabaseSchemaVersion *version = [[NLDatabaseSchemaVersion alloc] init];
        version.identifier = kSchemaVersionIdentifier;
        version.version = kCurrentSchemaVersion;
        return [transactionHandle insertOrReplaceObject:version intoTable:kSchemaVersionTableName];
    }];
    if (!migrated && error) {
        *error = [NSError errorWithDomain:@"NLDataBaseManager"
                                     code:7
                                 userInfo:@{NSLocalizedDescriptionKey: @"Playback history migration failed and can be retried."}];
    }
    return migrated;
}

- (void)performWrite:(BOOL (^)(WCTDatabase *database))write
     completionQueue:(dispatch_queue_t)completionQueue
          completion:(void (^)(BOOL success))completion {
    dispatch_async(self.writerQueue, ^{
        BOOL success = [self ensureDatabaseReady:nil] && write && write(self->_database);
        dispatch_queue_t callbackQueue = completionQueue ?: dispatch_get_main_queue();
        dispatch_async(callbackQueue, ^{
            if (completion) completion(success);
        });
    });
}

- (void)performWriteTransaction:(BOOL (^)(WCTHandle *transactionHandle))transaction
                completionQueue:(dispatch_queue_t)completionQueue
                     completion:(void (^)(BOOL success))completion {
    dispatch_async(self.writerQueue, ^{
        BOOL success = NO;
        if ([self ensureDatabaseReady:nil] && transaction) {
            success = [self->_database runTransaction:^BOOL(WCTHandle *transactionHandle) {
                return transaction(transactionHandle);
            }];
        }
        dispatch_queue_t callbackQueue = completionQueue ?: dispatch_get_main_queue();
        dispatch_async(callbackQueue, ^{
            if (completion) completion(success);
        });
    });
}


- (void)performRead:(id _Nullable (^)(WCTDatabase *database))read
    completionQueue:(dispatch_queue_t)completionQueue
         completion:(void (^)(id _Nullable result))completion {
    dispatch_async(self.writerQueue, ^{
        id result = nil;
        if ([self ensureDatabaseReady:nil] && read) result = read(self->_database);
        dispatch_queue_t callbackQueue = completionQueue ?: dispatch_get_main_queue();
        dispatch_async(callbackQueue, ^{
            if (completion) completion(result);
        });
    });
}

#pragma mark - Audio cache ledger

NSString * const NLAudioCacheInfoTableName = @"AudioCacheInfoTable_v3";

- (void)migrateCacheLedgerIfNeededWithCompletion:(void (^)(BOOL))completion {
    dispatch_async(self.writerQueue, ^{
        BOOL success = [self ensureDatabaseReady:nil] && [self migrateCacheLedgerInWriterQueue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success);
        });
    });
}

- (BOOL)migrateCacheLedgerInWriterQueue {
    WCTDatabase *database = self->_database;
    WCTOptionalBool legacyExists = [database tableExists:kLegacyAudioCacheTableName];
    if (!legacyExists.succeed()) return NO;
    if (!legacyExists.value()) return [database createTable:NLAudioCacheInfoTableName withClass:NLAudioCacheInfo.class];

    NSArray<NLLegacyAudioCacheInfo *> *legacyRows = [database getObjectsOfClass:NLLegacyAudioCacheInfo.class
                                                                   fromTable:kLegacyAudioCacheTableName];
    if (!legacyRows) return NO;

    return [database runTransaction:^BOOL(WCTHandle *transactionHandle) {
        if (![transactionHandle createTable:NLAudioCacheInfoTableName withClass:NLAudioCacheInfo.class]) return NO;

        NSMutableSet<NSString *> *copiedIdentifiers = [NSMutableSet setWithCapacity:legacyRows.count];
        for (NLLegacyAudioCacheInfo *legacy in legacyRows) {
            if (legacy.urlMD5.length == 0) return NO;
            NLAudioCacheInfo *migratedRow = [[NLAudioCacheInfo alloc] init];
            migratedRow.cacheIdentifier = legacy.urlMD5;
            migratedRow.songId = legacy.songId;
            migratedRow.totalLength = legacy.totalLength;
            migratedRow.cachedRangesString = legacy.cachedRangesString ?: @"[]";
            migratedRow.lastAccessTime = legacy.lastAccessTime;
            migratedRow.isFinished = legacy.isFinished;
            if (![transactionHandle insertOrReplaceObject:migratedRow intoTable:NLAudioCacheInfoTableName]) return NO;
            [copiedIdentifiers addObject:legacy.urlMD5];
        }

        NSArray<NLAudioCacheInfo *> *writtenRows = [transactionHandle getObjectsOfClass:NLAudioCacheInfo.class
                                                                            fromTable:NLAudioCacheInfoTableName];
        if (!writtenRows || writtenRows.count < copiedIdentifiers.count) return NO;
        NSMutableDictionary<NSString *, NLAudioCacheInfo *> *writtenRowsByIdentifier = [NSMutableDictionary dictionaryWithCapacity:writtenRows.count];
        for (NLAudioCacheInfo *row in writtenRows) writtenRowsByIdentifier[row.cacheIdentifier] = row;
        for (NLLegacyAudioCacheInfo *legacy in legacyRows) {
            NLAudioCacheInfo *row = writtenRowsByIdentifier[legacy.urlMD5];
            NSString *expectedRanges = legacy.cachedRangesString ?: @"[]";
            if (!row || ((legacy.songId || row.songId) && ![row.songId isEqualToString:legacy.songId]) ||
                row.totalLength != legacy.totalLength || ![row.cachedRangesString isEqualToString:expectedRanges] ||
                row.lastAccessTime != legacy.lastAccessTime || row.isFinished != legacy.isFinished) return NO;
        }
        return [transactionHandle dropTable:kLegacyAudioCacheTableName];
    }];
}

@end
