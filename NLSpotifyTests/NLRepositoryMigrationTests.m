#import <float.h>
#import <XCTest/XCTest.h>
#import "NLDataBaseManager.h"
#import "NLSongRepository.h"
#import "NLPlayListRepository.h"
#import "NLDownloadRepository.h"
#import "NLSong.h"
#import "NLPlayList.h"
#import "NLPlayListSongRelation.h"
#import "NLDownloadItem.h"

typedef NS_ENUM(NSUInteger, NLPlaybackState) {
    NLPlaybackStateIdle,
    NLPlaybackStateLoading,
    NLPlaybackStatePlaying,
    NLPlaybackStatePaused,
    NLPlaybackStateEnded,
    NLPlaybackStateError
};

@interface NLPlayerManager : NSObject
@end

@interface NLDataBaseManager (NLRepositoryMigrationTesting)
- (nullable instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error;
- (instancetype)initWithDatabasePath:(NSString *)path initializeImmediately:(BOOL)initializeImmediately error:(NSError **)error;
+ (void)setSharedManagerForTesting:(NLDataBaseManager *)manager;
- (void)performWrite:(BOOL (^)(WCTDatabase *database))write
     completionQueue:(dispatch_queue_t)completionQueue
          completion:(void (^)(BOOL success))completion;
@end

@interface NLSongRepository (NLRepositoryMigrationTesting)
+ (void)recordPlaybackStart:(NLSong *)song completion:(void (^)(BOOL success))completion;
+ (void)allPlayHistoryWithCompletion:(void (^)(NSArray<NLSong *> *songs))completion;
@end

@interface NLPlayListRepository (NLRepositoryMigrationTesting)
+ (void)savePlayList:(NLPlayList *)playList completion:(void (^)(BOOL success))completion;
+ (void)deletePlayList:(NSString *)playListId completion:(void (^)(BOOL success))completion;
+ (void)addSong:(NLSong *)song toPlayList:(NSString *)playListId completion:(void (^)(BOOL success))completion;
+ (void)removeSong:(NSString *)songId fromPlayList:(NSString *)playListId completion:(void (^)(BOOL success))completion;
@end

@interface NLDownloadRepository (NLRepositoryMigrationTesting)
+ (void)addDownloadItemWithSong:(NLSong *)song status:(NSString *)status completion:(void (^)(BOOL success))completion;
+ (void)completeDownloadWithSong:(NLSong *)song completion:(void (^)(BOOL success))completion;
@end

@interface NLPlayerManager (NLRepositoryMigrationTesting)
- (void)setPlaybackState:(NLPlaybackState)state;
@end

@interface WCTDatabase : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)createTable:(NSString *)tableName withClass:(Class)modelClass;
- (BOOL)insertOrReplaceObject:(id)object intoTable:(NSString *)tableName;
- (NSArray *)getObjectsOfClass:(Class)modelClass fromTable:(NSString *)tableName;
- (nullable id)getObjectOfClass:(Class)modelClass fromTable:(NSString *)tableName;
- (BOOL)rawExecute:(NSString *)sql;
- (void)close:(nullable void (^)(void))onClosed;
@end

@interface NLRepositoryMigrationTests : XCTestCase
@property (nonatomic, strong) NLDataBaseManager *previousManager;
@property (nonatomic, strong) NLDataBaseManager *testManager;
@property (nonatomic, copy) NSString *temporaryDirectory;
@property (nonatomic, copy) NSString *databasePath;
@end

@implementation NLRepositoryMigrationTests

- (void)setUp {
    [super setUp];
    self.previousManager = [NLDataBaseManager sharedManager];
    self.temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:self.temporaryDirectory
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:&error];
    XCTAssertTrue(created, @"%@", error.localizedDescription);
    self.databasePath = [self.temporaryDirectory stringByAppendingPathComponent:@"Repository.sqlite"];
}

- (void)tearDown {
    if ([NLDataBaseManager respondsToSelector:@selector(setSharedManagerForTesting:)]) {
        [NLDataBaseManager setSharedManagerForTesting:self.previousManager];
    }
    [self.testManager.database close:nil];
    [[NSFileManager defaultManager] removeItemAtPath:self.temporaryDirectory error:nil];
    [super tearDown];
}

- (NLDataBaseManager *)managerAtPath:(NSString *)path error:(NSError **)error {
    if (![NLDataBaseManager instancesRespondToSelector:@selector(initWithDatabasePath:error:)] ||
        ![NLDataBaseManager respondsToSelector:@selector(setSharedManagerForTesting:)]) {
        XCTFail(@"NLDataBaseManager must support isolated schema-migration databases");
        return nil;
    }
    return [[NLDataBaseManager alloc] initWithDatabasePath:path error:error];
}

- (NLDataBaseManager *)installManagerAtPath:(NSString *)path {
    NSError *error = nil;
    NLDataBaseManager *manager = [self managerAtPath:path error:&error];
    XCTAssertNotNil(manager, @"%@", error.localizedDescription);
    if (manager) {
        self.testManager = manager;
        [NLDataBaseManager setSharedManagerForTesting:manager];
    }
    return manager;
}

- (void)testRelocationPreservesLegacyHistoryAndRemovesOldDatabase {
    NLSong *song = [[NLSong alloc] initWithId:@"relocated" title:@"Preserved" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    WCTDatabase *legacy = [self createLegacyDatabaseWithSongs:@[song]];
    NSString *destination = [[self.temporaryDirectory stringByAppendingPathComponent:@"Application Support/NLSpotify"] stringByAppendingPathComponent:self.databasePath.lastPathComponent];
    self.testManager = [[NLDataBaseManager alloc] initWithDatabasePath:destination initializeImmediately:NO error:nil];
    [self.testManager setValue:self.databasePath forKey:@"legacyDatabasePath"];
    WCTDatabase *relocated = self.testManager.database;
    NSArray<NLSong *> *songs = [relocated getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"];
    XCTAssertEqualObjects([songs valueForKey:@"songId"], (@[@"relocated"]));
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:self.databasePath]);
    [legacy close:nil];
}

- (void)testRelocationDoesNotOverwriteExistingDestination {
    WCTDatabase *legacy = [self createLegacyDatabaseWithSongs:@[
        [[NLSong alloc] initWithId:@"old" title:@"Old" artist:@"Artist" coverURL:[self fixtureCoverURL]]
    ]];
    NSString *destination = [[self.temporaryDirectory stringByAppendingPathComponent:@"Support"] stringByAppendingPathComponent:self.databasePath.lastPathComponent];
    NLDataBaseManager *existing = [self managerAtPath:destination error:nil];
    NLSong *song = [[NLSong alloc] initWithId:@"current" title:@"Current" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    XCTAssertTrue([existing.database insertOrReplaceObject:song intoTable:@"PlaybackHistoryTable"]);
    [existing.database close:nil];
    self.testManager = [[NLDataBaseManager alloc] initWithDatabasePath:destination initializeImmediately:NO error:nil];
    [self.testManager setValue:self.databasePath forKey:@"legacyDatabasePath"];
    XCTAssertEqualObjects([[self.testManager.database getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"] valueForKey:@"songId"], (@[@"current"]));
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:self.databasePath]);
    [legacy close:nil];
}

- (void)testRelocationFailureKeepsLegacyDataAndCanRetry {
    WCTDatabase *legacy = [self createLegacyDatabaseWithSongs:@[
        [[NLSong alloc] initWithId:@"retry" title:@"Retry" artist:@"Artist" coverURL:[self fixtureCoverURL]]
    ]];
    NSString *blocked = [self.temporaryDirectory stringByAppendingPathComponent:@"Blocked"];
    XCTAssertTrue([[@"" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:blocked atomically:YES]);
    NSString *destination = [blocked stringByAppendingPathComponent:self.databasePath.lastPathComponent];
    self.testManager = [[NLDataBaseManager alloc] initWithDatabasePath:destination initializeImmediately:NO error:nil];
    [self.testManager setValue:self.databasePath forKey:@"legacyDatabasePath"];
    XCTAssertNil(self.testManager.database);
    XCTAssertEqualObjects([[legacy getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"] valueForKey:@"songId"], (@[@"retry"]));
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:blocked error:nil]);
    XCTAssertEqualObjects([[self.testManager.database getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"] valueForKey:@"songId"], (@[@"retry"]));
    [legacy close:nil];
}

- (WCTDatabase *)createLegacyDatabaseWithSongs:(NSArray<NLSong *> *)songs {
    WCTDatabase *database = [[WCTDatabase alloc] initWithPath:self.databasePath];
    XCTAssertTrue([database createTable:@"PlaybackHistoryTable" withClass:NLSong.class]);
    for (NLSong *song in songs) {
        XCTAssertTrue([database insertOrReplaceObject:song intoTable:@"PlaybackHistoryTable"]);
    }
    return database;
}

- (NSArray *)metadataRowsInDatabase:(WCTDatabase *)database {
    Class metadataClass = NSClassFromString(@"NLPlaybackHistoryMetadata");
    XCTAssertNotNil(metadataClass, @"playback metadata model must be linked");
    if (!metadataClass) return @[];
    return [database getObjectsOfClass:metadataClass fromTable:@"PlaybackHistoryMetadataTable"] ?: @[];
}

- (NSArray *)matchingObjectsOfClass:(Class)modelClass
                              table:(NSString *)table
                           database:(WCTDatabase *)database
                          predicate:(BOOL (^)(id object))predicate {
    NSArray *objects = [database getObjectsOfClass:modelClass fromTable:table] ?: @[];
    if (!predicate) return objects;
    NSIndexSet *indexes = [objects indexesOfObjectsPassingTest:^BOOL(id object, NSUInteger idx, BOOL *stop) {
        return predicate(object);
    }];
    return [objects objectsAtIndexes:indexes];
}

- (id)objectOfClass:(Class)modelClass
               table:(NSString *)table
            database:(WCTDatabase *)database
           predicate:(BOOL (^)(id object))predicate {
    return [self matchingObjectsOfClass:modelClass table:table database:database predicate:predicate].firstObject;
}

- (BOOL)runBooleanOperation:(void (^)(void (^completion)(BOOL success)))operation {
    XCTestExpectation *finished = [self expectationWithDescription:@"Repository operation finished"];
    __block BOOL result = NO;
    operation(^(BOOL success) {
        result = success;
        [finished fulfill];
    });
    [self waitForExpectationsWithTimeout:5 handler:nil];
    return result;
}

- (NSArray<NLSong *> *)playHistorySnapshot {
    XCTestExpectation *finished = [self expectationWithDescription:@"play history snapshot finished"];
    __block NSArray<NLSong *> *snapshot = nil;
    [NLSongRepository allPlayHistoryWithCompletion:^(NSArray<NLSong *> *songs) {
        snapshot = songs;
        [finished fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    return snapshot ?: @[];
}

- (NSString *)createFailureTriggerOnDatabase:(WCTDatabase *)database
                                       table:(NSString *)table
                                      songID:(NSString *)songID {
    NSString *triggerName = [NSString stringWithFormat:@"TestFailure%@", [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSString *escapedSongID = [songID stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSString *sql = [NSString stringWithFormat:
        @"CREATE TRIGGER %@ BEFORE INSERT ON %@ WHEN NEW.songId = '%@' BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
        triggerName, table, escapedSongID];
    XCTAssertTrue([database rawExecute:sql]);
    return triggerName;
}

- (NSArray *)objectsOfClass:(Class)modelClass table:(NSString *)table database:(WCTDatabase *)database {
    return [database getObjectsOfClass:modelClass fromTable:table] ?: @[];
}

- (NSURL *)fixtureCoverURL {
    return [NSURL URLWithString:@"https://example.com/cover.jpg"];
}

- (void)testLegacyPlaybackRowsMigrateWithUnknownTimestamp {
    NLSong *legacySong = [[NLSong alloc] initWithId:@"legacy-history"
                                               title:@"Legacy"
                                              artist:@"Artist"
                                            coverURL:[self fixtureCoverURL]];
    WCTDatabase *legacyDatabase = [self createLegacyDatabaseWithSongs:@[legacySong]];
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;

    NSArray<NLSong *> *preservedSongs = [legacyDatabase getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"];
    NSArray *metadata = [self metadataRowsInDatabase:manager.database];
    XCTAssertEqual(preservedSongs.count, 1u);
    XCTAssertEqualObjects(preservedSongs.firstObject.songId, legacySong.songId);
    XCTAssertEqual(metadata.count, 1u);
    XCTAssertEqualObjects([metadata.firstObject valueForKey:@"songId"], legacySong.songId);
    XCTAssertEqualWithAccuracy([[metadata.firstObject valueForKey:@"lastPlayedAt"] doubleValue], 0.0, DBL_EPSILON);
    XCTAssertEqual([[metadata.firstObject valueForKey:@"playCount"] integerValue], 1);
}

- (void)testInterruptedHistoryMigrationCanRetryWithoutLosingLegacyRows {
    NSString *blockedSongID = @"blocked-history-row";
    NLSong *firstSong = [[NLSong alloc] initWithId:@"legacy-history-a" title:@"A" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    NLSong *blockedSong = [[NLSong alloc] initWithId:blockedSongID title:@"B" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    WCTDatabase *legacyDatabase = [self createLegacyDatabaseWithSongs:@[firstSong, blockedSong]];
    Class metadataClass = NSClassFromString(@"NLPlaybackHistoryMetadata");
    XCTAssertNotNil(metadataClass);
    if (!metadataClass) return;
    XCTAssertTrue([legacyDatabase createTable:@"PlaybackHistoryMetadataTable" withClass:metadataClass]);
    NSString *triggerName = [self createFailureTriggerOnDatabase:legacyDatabase
                                                          table:@"PlaybackHistoryMetadataTable"
                                                         songID:blockedSongID];

    NSError *migrationError = nil;
    NLDataBaseManager *failedManager = [self managerAtPath:self.databasePath error:&migrationError];
    XCTAssertNil(failedManager);
    XCTAssertNotNil(migrationError);
    XCTAssertEqual([legacyDatabase getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"].count, 2u);
    XCTAssertEqual([self metadataRowsInDatabase:legacyDatabase].count, 0u);

    NSString *dropTriggerSQL = [NSString stringWithFormat:@"DROP TRIGGER IF EXISTS %@", triggerName];
    XCTAssertTrue([legacyDatabase rawExecute:dropTriggerSQL]);
    NLDataBaseManager *recoveredManager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(recoveredManager);
    if (!recoveredManager) return;
    XCTAssertEqual([legacyDatabase getObjectsOfClass:NLSong.class fromTable:@"PlaybackHistoryTable"].count, 2u);
    XCTAssertEqual([self metadataRowsInDatabase:recoveredManager.database].count, 2u);
}

- (void)testPlaybackStartIncrementsCountAndSortsByTimestamp {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLSong *olderSong = [[NLSong alloc] initWithId:@"history-older" title:@"Older" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    NLSong *newerSong = [[NLSong alloc] initWithId:@"history-newer" title:@"Newer" artist:@"Artist" coverURL:[self fixtureCoverURL]];

    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLSongRepository recordPlaybackStart:olderSong completion:completion];
    }]);
    [NSThread sleepForTimeInterval:0.02];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLSongRepository recordPlaybackStart:newerSong completion:completion];
    }]);
    [NSThread sleepForTimeInterval:0.02];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLSongRepository recordPlaybackStart:olderSong completion:completion];
    }]);

    NSArray<NLSong *> *history = [self playHistorySnapshot];
    XCTAssertEqual(history.count, 2u);
    XCTAssertEqualObjects(history[0].songId, olderSong.songId);
    XCTAssertEqualObjects(history[1].songId, newerSong.songId);
    NSArray *metadata = [self metadataRowsInDatabase:manager.database];
    id olderMetadata = [metadata filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"songId == %@", olderSong.songId]].firstObject;
    XCTAssertEqual([[olderMetadata valueForKey:@"playCount"] integerValue], 2);
    XCTAssertGreaterThan([[olderMetadata valueForKey:@"lastPlayedAt"] doubleValue], 0.0);
}

- (void)testPlaybackStartIsRecordedOncePerPlayingToken {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLPlayerManager *player = [[NLPlayerManager alloc] init];
    NLSong *failedSong = [[NLSong alloc] initWithId:@"not-played" title:@"Failed" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    NLSong *playedSong = [[NLSong alloc] initWithId:@"actually-played" title:@"Played" artist:@"Artist" coverURL:[self fixtureCoverURL]];

    [player setValue:failedSong forKey:@"currentSong"];
    [player setValue:@1 forKey:@"playSwitchToken"];
    [player setPlaybackState:NLPlaybackStateLoading];
    [player setPlaybackState:NLPlaybackStateError];
    [player setValue:playedSong forKey:@"currentSong"];
    [player setValue:@2 forKey:@"playSwitchToken"];
    [player setPlaybackState:NLPlaybackStateLoading];
    [player setPlaybackState:NLPlaybackStatePlaying];
    [player setPlaybackState:NLPlaybackStatePaused];
    [player setPlaybackState:NLPlaybackStatePlaying];
    [self playHistorySnapshot];

    NSArray<NLSong *> *history = [self playHistorySnapshot];
    XCTAssertEqual(history.count, 1u);
    XCTAssertEqualObjects(history.firstObject.songId, playedSong.songId);
    id metadata = [self metadataRowsInDatabase:manager.database].firstObject;
    XCTAssertEqualObjects([metadata valueForKey:@"songId"], playedSong.songId);
    XCTAssertEqual([[metadata valueForKey:@"playCount"] integerValue], 1);
}

- (void)testRepositoryWriteRunsOffMainAndCompletesOnRequestedQueue {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    static void *completionQueueKey = &completionQueueKey;
    dispatch_queue_t completionQueue = dispatch_queue_create("com.nlspotify.tests.repository-completion", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(completionQueue, completionQueueKey, completionQueueKey, NULL);
    XCTestExpectation *finished = [self expectationWithDescription:@"write completion queue"];
    __block BOOL writeRanOffMain = NO;

    [manager performWrite:^BOOL(WCTDatabase *database) {
        writeRanOffMain = !NSThread.isMainThread;
        NLSong *song = [[NLSong alloc] initWithId:@"queue-affinity" title:@"Queue" artist:@"Test" coverURL:[self fixtureCoverURL]];
        return [database insertOrReplaceObject:song intoTable:@"DownloadedSongsTable"];
    } completionQueue:completionQueue completion:^(BOOL success) {
        XCTAssertTrue(writeRanOffMain);
        XCTAssertTrue(success);
        XCTAssertEqual(dispatch_get_specific(completionQueueKey), completionQueueKey);
        [finished fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testPlaylistAddRollsBackSongAndRelationWhenRelationInsertFails {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLPlayList *playlist = [[NLPlayList alloc] initWithId:@"playlist-rollback" name:@"Rollback" isUserCreated:YES];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository savePlayList:playlist completion:completion];
    }]);
    NLSong *song = [[NLSong alloc] initWithId:@"song-rollback" title:@"Rollback" artist:@"Artist" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    [self createFailureTriggerOnDatabase:manager.database table:@"PlayListSongRelationTable" songID:song.songId];

    XCTAssertFalse([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository addSong:song toPlayList:playlist.playlistId completion:completion];
    }]);
    NSArray *localSongs = [self matchingObjectsOfClass:NLSong.class table:@"LocalSongsCacheTable" database:manager.database predicate:^BOOL(NLSong *candidate) {
        return [candidate.songId isEqualToString:song.songId];
    }];
    NSArray *relations = [self matchingObjectsOfClass:NLPlayListSongRelation.class table:@"PlayListSongRelationTable" database:manager.database predicate:^BOOL(NLPlayListSongRelation *candidate) {
        return [candidate.playlistId isEqualToString:playlist.playlistId];
    }];
    NLPlayList *unchanged = [self objectOfClass:NLPlayList.class table:@"PlayListTable" database:manager.database predicate:^BOOL(NLPlayList *candidate) {
        return [candidate.playlistId isEqualToString:playlist.playlistId];
    }];
    XCTAssertEqual(localSongs.count, 0u);
    XCTAssertEqual(relations.count, 0u);
    XCTAssertNil(unchanged.coverURL);
}

- (void)testPlaylistAddIsIdempotent {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLPlayList *playlist = [[NLPlayList alloc] initWithId:@"playlist-idempotent" name:@"Idempotent" isUserCreated:YES];
    NLSong *song = [[NLSong alloc] initWithId:@"song-idempotent" title:@"Song" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository savePlayList:playlist completion:completion];
    }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository addSong:song toPlayList:playlist.playlistId completion:completion];
    }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository addSong:song toPlayList:playlist.playlistId completion:completion];
    }]);

    NSArray *relations = [self matchingObjectsOfClass:NLPlayListSongRelation.class table:@"PlayListSongRelationTable" database:manager.database predicate:^BOOL(NLPlayListSongRelation *candidate) {
        return [candidate.playlistId isEqualToString:playlist.playlistId] && [candidate.songId isEqualToString:song.songId];
    }];
    XCTAssertEqual(relations.count, 1u);
}

- (void)testPlaylistDeleteRemovesRelationsAndOnlyOrphanedSongs {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLPlayList *first = [[NLPlayList alloc] initWithId:@"playlist-delete-a" name:@"A" isUserCreated:YES];
    NLPlayList *second = [[NLPlayList alloc] initWithId:@"playlist-delete-b" name:@"B" isUserCreated:YES];
    NLSong *orphan = [[NLSong alloc] initWithId:@"song-only-a" title:@"Only A" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    NLSong *shared = [[NLSong alloc] initWithId:@"song-shared" title:@"Shared" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) { [NLPlayListRepository savePlayList:first completion:completion]; }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) { [NLPlayListRepository savePlayList:second completion:completion]; }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) { [NLPlayListRepository addSong:orphan toPlayList:first.playlistId completion:completion]; }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) { [NLPlayListRepository addSong:shared toPlayList:first.playlistId completion:completion]; }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) { [NLPlayListRepository addSong:shared toPlayList:second.playlistId completion:completion]; }]);

    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository removeSong:orphan.songId fromPlayList:first.playlistId completion:completion];
    }]);
    XCTAssertNil([self objectOfClass:NLSong.class table:@"LocalSongsCacheTable" database:manager.database predicate:^BOOL(NLSong *candidate) {
        return [candidate.songId isEqualToString:orphan.songId];
    }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLPlayListRepository deletePlayList:first.playlistId completion:completion];
    }]);

    XCTAssertNil([self objectOfClass:NLPlayList.class table:@"PlayListTable" database:manager.database predicate:^BOOL(NLPlayList *candidate) {
        return [candidate.playlistId isEqualToString:first.playlistId];
    }]);
    XCTAssertEqual([self matchingObjectsOfClass:NLPlayListSongRelation.class table:@"PlayListSongRelationTable" database:manager.database predicate:^BOOL(NLPlayListSongRelation *candidate) {
        return [candidate.playlistId isEqualToString:first.playlistId];
    }].count, 0u);
    XCTAssertNotNil([self objectOfClass:NLSong.class table:@"LocalSongsCacheTable" database:manager.database predicate:^BOOL(NLSong *candidate) {
        return [candidate.songId isEqualToString:shared.songId];
    }]);
    XCTAssertEqual([self matchingObjectsOfClass:NLPlayListSongRelation.class table:@"PlayListSongRelationTable" database:manager.database predicate:^BOOL(NLPlayListSongRelation *candidate) {
        return [candidate.playlistId isEqualToString:second.playlistId] && [candidate.songId isEqualToString:shared.songId];
    }].count, 1u);
}

- (void)testDownloadCompletionCommitsQueueAndDownloadedSongTogether {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLSong *song = [[NLSong alloc] initWithId:@"download-complete" title:@"Downloaded" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    song.playURL = [NSURL URLWithString:@"https://example.com/audio.mp3"];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLDownloadRepository addDownloadItemWithSong:song status:@"downloading" completion:completion];
    }]);
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLDownloadRepository completeDownloadWithSong:song completion:completion];
    }]);

    NLDownloadItem *queueItem = [self objectOfClass:NLDownloadItem.class table:@"DownloadQueueTable" database:manager.database predicate:^BOOL(NLDownloadItem *candidate) {
        return [candidate.songId isEqualToString:song.songId];
    }];
    NLSong *downloadedSong = [self objectOfClass:NLSong.class table:@"DownloadedSongsTable" database:manager.database predicate:^BOOL(NLSong *candidate) {
        return [candidate.songId isEqualToString:song.songId];
    }];
    XCTAssertEqualObjects(queueItem.status, @"completed");
    XCTAssertEqualObjects(downloadedSong.songId, song.songId);
}

- (void)testDownloadCompletionFailureRollsBackQueueStatus {
    NLDataBaseManager *manager = [self installManagerAtPath:self.databasePath];
    XCTAssertNotNil(manager);
    if (!manager) return;
    NLSong *song = [[NLSong alloc] initWithId:@"download-rollback" title:@"Download" artist:@"Artist" coverURL:[self fixtureCoverURL]];
    song.playURL = [NSURL URLWithString:@"https://example.com/audio.mp3"];
    XCTAssertTrue([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLDownloadRepository addDownloadItemWithSong:song status:@"downloading" completion:completion];
    }]);
    [self createFailureTriggerOnDatabase:manager.database table:@"DownloadedSongsTable" songID:song.songId];

    XCTAssertFalse([self runBooleanOperation:^(void (^completion)(BOOL)) {
        [NLDownloadRepository completeDownloadWithSong:song completion:completion];
    }]);
    NLDownloadItem *queueItem = [self objectOfClass:NLDownloadItem.class table:@"DownloadQueueTable" database:manager.database predicate:^BOOL(NLDownloadItem *candidate) {
        return [candidate.songId isEqualToString:song.songId];
    }];
    XCTAssertEqualObjects(queueItem.status, @"downloading");
    XCTAssertNil([self objectOfClass:NLSong.class table:@"DownloadedSongsTable" database:manager.database predicate:^BOOL(NLSong *candidate) {
        return [candidate.songId isEqualToString:song.songId];
    }]);
}

@end
