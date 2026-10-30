#import <CommonCrypto/CommonDigest.h>
#import <XCTest/XCTest.h>
#import "NLCacheManager.h"
#import "NLSong.h"
#import "NLDownloadRepository.h"
#import <AVFoundation/AVFoundation.h>
#import "NLAudioMemoryCache.h"
#import <dispatch/dispatch.h>
#import "NLMusicLibraryListViewController.h"
#import "NLSongRepository.h"
#import "NLAudioCacheInfo.h"
#import "NLDataBaseManager.h"

@interface NLPlayerManager : NSObject
- (instancetype)init;
- (void)playWithURL:(NSURL *)url;
- (void)stop;
@end

@interface NLDownloadManager : NSObject
- (instancetype)init;
- (BOOL)isDownloadingSongId:(NSString *)songId;
- (void)addDownloadForSong:(NLSong *)song;
- (void)cancelAllDownloads;
- (void)removeOfflineDownloadForSongID:(NSString *)songID;
@end
@interface NLCacheManager (ReadinessTesting)
- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory
                  reconciliationBlock:(void (^)(NLCacheManager *manager))reconciliationBlock;
- (void)whenReadyOnQueue:(dispatch_queue_t)queue perform:(dispatch_block_t)block;
- (NSString *)identifierForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
@end

@interface NLCacheManager (ReconciliationTesting)
- (void)reconcileCacheDirectory;
@end

@interface WCTDatabase : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)rawExecute:(NSString *)sql;
- (BOOL)createTable:(NSString *)tableName withClass:(Class)modelClass;
- (BOOL)insertOrReplaceObject:(id)object intoTable:(NSString *)tableName;
- (NSArray *)getObjectsOfClass:(Class)cls fromTable:(NSString *)table;
- (void)close:(nullable void (^)(void))onClosed;
@end

@interface NLDataBaseManager (NLCacheMigrationTesting)
- (nullable instancetype)initWithDatabasePath:(NSString *)path error:(NSError **)error;
+ (void)setSharedManagerForTesting:(NLDataBaseManager *)manager;
@end

@interface NLDownloadManager (ReservationTesting)
- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation;
- (void)finishDownloadContext:(NSMutableDictionary<NSString *, id> *)context
                       taskID:(NSNumber *)taskID
                   fullyCached:(BOOL)fullyCached;
@end


@interface NLResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, strong) NSURL *originURL;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, strong) NLCacheManager *cacheManager;
- (void)invalidateAndCancelAll;
- (void)URLSession:(NSURLSession *)session
               task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error;
@end

@interface NLRecordingDataRequest : NSObject
@property (nonatomic, assign) long long requestedOffset;
@property (nonatomic, assign) NSInteger requestedLength;
@property (nonatomic, assign) long long currentOffset;
@property (nonatomic, assign) BOOL requestsAllDataToEndOfResource;
@property (nonatomic, strong) NSMutableData *receivedData;
- (void)respondWithData:(NSData *)data;
@end

@implementation NLRecordingDataRequest
- (void)respondWithData:(NSData *)data { [self.receivedData appendData:data]; }
@end

@interface NLRecordingLoadingRequest : NSObject
@property (nonatomic, strong) NLRecordingDataRequest *dataRequest;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSError *error;
- (id)contentInformationRequest;
- (void)finishLoading;
- (void)finishLoadingWithError:(NSError *)error;
@end

@implementation NLRecordingLoadingRequest
- (id)contentInformationRequest { return nil; }
- (void)finishLoading { self.finished = YES; }
- (void)finishLoadingWithError:(NSError *)error { self.error = error; }
@end

@interface NLCacheManagerTests : XCTestCase
@property (nonatomic, strong) NLCacheManager *cacheManager;
@property (nonatomic, strong) NLDataBaseManager *previousDatabaseManager;
@property (nonatomic, strong) NLDataBaseManager *legacyTestDatabaseManager;
@property (nonatomic, copy) NSString *legacyTestDirectory;
@end

@interface NLListTestCacheManager : NLCacheManager
@property (atomic, assign) BOOL queryOnMain;
@property (atomic, assign) BOOL lastAccessQueryOnMain;
@property (atomic, assign) NSUInteger fullQueryCount;
@property (atomic, assign) NSUInteger completedQueryCount;
@property (atomic, assign) NSUInteger lastAccessQueryCount;
@property (atomic, copy) NSSet<NSString *> *includedSongIDs;
@property (atomic, copy) NSDictionary<NSString *, NSNumber *> *accessTimesBySongID;
@property (atomic, assign) BOOL blockFirstQuery;
@property (nonatomic, strong) dispatch_semaphore_t queryEntered;
@property (nonatomic, strong) dispatch_semaphore_t releaseQuery;
@property (nonatomic, assign) BOOL didBlockQuery;
@property (atomic, assign) BOOL blockedQueryInFlight;
@end

@implementation NLListTestCacheManager

- (NSString *)songIDFromCacheKey:(NSString *)cacheKey {
    return [[cacheKey componentsSeparatedByString:@"\n"] firstObject];
}

- (BOOL)isFullyCachedForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *songID = [self songIDFromCacheKey:cacheKey];
    BOOL block = NO;
    BOOL cached = YES;
    @synchronized (self) {
        self.fullQueryCount += 1;
        if (NSThread.isMainThread) self.queryOnMain = YES;
        if (self.includedSongIDs) cached = [self.includedSongIDs containsObject:songID ?: @""];
        if (self.blockFirstQuery && !self.didBlockQuery) {
            self.didBlockQuery = YES;
            block = YES;
        }
    }
    if (block) {
        self.blockedQueryInFlight = YES;
        dispatch_semaphore_signal(self.queryEntered);
        dispatch_semaphore_wait(self.releaseQuery, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        self.blockedQueryInFlight = NO;
    }
    @synchronized (self) { self.completedQueryCount += 1; }
    return cached;
}

- (NSTimeInterval)lastAccessTimeForFullyCachedURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *songID = [self songIDFromCacheKey:cacheKey];
    @synchronized (self) {
        self.lastAccessQueryCount += 1;
        if (NSThread.isMainThread) self.lastAccessQueryOnMain = YES;
    }
    return self.accessTimesBySongID[songID].doubleValue;
}

@end

@interface NLMusicLibraryListViewController (CacheSnapshotTesting)
- (NSArray<NLSong *> *)cachedSongsSnapshot;
- (void)applyCachedSongs:(NSArray<NLSong *> *)songs forToken:(NSUInteger)token;

@end


@implementation NLCacheManagerTests
- (NSArray<NLSong *> *)cachedSnapshotForControllerOnUtilityQueue:(NLMusicLibraryListViewController *)controller {
    XCTestExpectation *finished = [self expectationWithDescription:@"utility snapshot finished"];
    __block NSArray<NLSong *> *snapshot = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        snapshot = [controller cachedSongsSnapshot];
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:3];
    return snapshot;
}
- (void)testCachedSongQueryDoesNotBlockMainQueue {
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"queue-responsive" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    song.playURL = [self uniqueURL];
    XCTAssertTrue([self recordPlaybackStartAndWaitForSong:song]);

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NLListTestCacheManager *fake = [[NLListTestCacheManager alloc] initWithCacheDirectory:directory reconciliationBlock:nil];
    fake.includedSongIDs = [NSSet setWithObject:songID];
    fake.blockFirstQuery = YES;
    fake.queryEntered = dispatch_semaphore_create(0);
    fake.releaseQuery = dispatch_semaphore_create(0);
    NLMusicLibraryListViewController *controller = [[NLMusicLibraryListViewController alloc] initWithMode:NLMusicLibraryListModeCachedSongs];
    [controller setValue:fake forKey:@"cacheManager"];
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(0, 0, 320, 568);
    window.rootViewController = controller;
    [window makeKeyAndVisible];

    XCTestExpectation *heartbeat = [self expectationWithDescription:@"main queue heartbeat while cache query blocks"];
    __block BOOL heartbeatWhileQueryBlocked = NO;
    dispatch_semaphore_t heartbeatProcessed = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (dispatch_semaphore_wait(fake.queryEntered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                heartbeatWhileQueryBlocked = fake.blockedQueryInFlight && !fake.queryOnMain;
                [heartbeat fulfill];
                dispatch_semaphore_signal(heartbeatProcessed);
            });
            dispatch_semaphore_wait(heartbeatProcessed, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
            dispatch_semaphore_signal(fake.releaseQuery);
        } else {
            dispatch_semaphore_signal(fake.releaseQuery);
        }
    });
    [controller loadViewIfNeeded];
    [self waitForExpectations:@[heartbeat] timeout:5];
    XCTAssertTrue(heartbeatWhileQueryBlocked);
    XCTAssertFalse(fake.queryOnMain);
    [self waitUntil:^BOOL{ return fake.completedQueryCount > 0; } message:@"blocked cache query should finish after the heartbeat"];
    [self waitUntil:^BOOL{ return [[controller valueForKey:@"songs"] count] == 1; } message:@"current cached snapshot should reach the list"];

    [self removePlayHistoryAndWaitForSongID:songID];
    window.hidden = YES;
    window.rootViewController = nil;
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testCachedSongSnapshotReadsRecencyOnceAndSortsWithoutDatabaseComparatorReads {
    NSString *olderID = NSUUID.UUID.UUIDString;
    NSString *newerID = NSUUID.UUID.UUIDString;
    NLSong *older = [[NLSong alloc] initWithId:olderID title:@"older" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    NLSong *newer = [[NLSong alloc] initWithId:newerID title:@"newer" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    older.playURL = [self uniqueURL];
    newer.playURL = [self uniqueURL];
    XCTAssertTrue([self recordPlaybackStartAndWaitForSong:older]);
    XCTAssertTrue([self recordPlaybackStartAndWaitForSong:newer]);

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NLListTestCacheManager *fake = [[NLListTestCacheManager alloc] initWithCacheDirectory:directory reconciliationBlock:nil];
    fake.includedSongIDs = [NSSet setWithObjects:olderID, newerID, nil];
    fake.accessTimesBySongID = @{olderID: @10, newerID: @20};
    NLMusicLibraryListViewController *controller = [[NLMusicLibraryListViewController alloc] initWithMode:NLMusicLibraryListModeCachedSongs];
    [controller setValue:fake forKey:@"cacheManager"];
    XCTestExpectation *ready = [self expectationWithDescription:@"isolated cache manager ready"];
    [fake whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    [self waitForExpectations:@[ready] timeout:3];
    NSArray<NLSong *> *snapshot = [self cachedSnapshotForControllerOnUtilityQueue:controller];

    XCTAssertEqual(snapshot.count, 2u);
    XCTAssertEqualObjects(snapshot.firstObject.songId, newerID);
    XCTAssertEqualObjects(snapshot.lastObject.songId, olderID);
    XCTAssertEqual(fake.lastAccessQueryCount, 2u);
    XCTAssertFalse(fake.lastAccessQueryOnMain);
    fake.lastAccessQueryCount = 0;
    fake.includedSongIDs = [NSSet setWithObject:newerID];
    NSArray<NLSong *> *singleSong = [self cachedSnapshotForControllerOnUtilityQueue:controller];
    XCTAssertEqual(singleSong.count, 1u);
    XCTAssertEqualObjects(singleSong.firstObject.songId, newerID);
    XCTAssertEqual(fake.lastAccessQueryCount, 1u);

    fake.lastAccessQueryCount = 0;
    fake.includedSongIDs = [NSSet set];
    NSArray<NLSong *> *emptySnapshot = [self cachedSnapshotForControllerOnUtilityQueue:controller];
    XCTAssertEqual(emptySnapshot.count, 0u);
    XCTAssertEqual(fake.lastAccessQueryCount, 0u);

    [self removePlayHistoryAndWaitForSongID:olderID];
    [self removePlayHistoryAndWaitForSongID:newerID];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testStaleCachedSongResultsAreRejectedForTokenModeAndDetachedView {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NLListTestCacheManager *fake = [[NLListTestCacheManager alloc] initWithCacheDirectory:directory reconciliationBlock:nil];
    fake.includedSongIDs = [NSSet set];
    fake.blockFirstQuery = YES;
    fake.queryEntered = dispatch_semaphore_create(0);
    fake.releaseQuery = dispatch_semaphore_create(0);
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *historySong = [[NLSong alloc] initWithId:songID title:@"pending stale" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    historySong.playURL = [self uniqueURL];
    XCTAssertTrue([self recordPlaybackStartAndWaitForSong:historySong]);
    NLMusicLibraryListViewController *controller = [[NLMusicLibraryListViewController alloc] initWithMode:NLMusicLibraryListModeCachedSongs];
    [controller setValue:fake forKey:@"cacheManager"];
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(0, 0, 320, 568);
    window.rootViewController = controller;
    [window makeKeyAndVisible];
    [controller loadViewIfNeeded];
    [self waitUntil:^BOOL{ return fake.blockedQueryInFlight; } message:@"initial cached query should reach the blocking point"];
    [controller setValue:@2 forKey:@"cachedReloadToken"];
    NLSong *sentinel = [[NLSong alloc] initWithId:NSUUID.UUID.UUIDString title:@"sentinel" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    NLSong *stale = [[NLSong alloc] initWithId:NSUUID.UUID.UUIDString title:@"stale" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.png"]];
    [controller setValue:@[sentinel] forKey:@"songs"];

    [controller applyCachedSongs:@[stale] forToken:1];
    XCTAssertEqualObjects([controller valueForKey:@"songs"], (@[sentinel]));

    [controller setValue:@(NLMusicLibraryListModeRecentPlay) forKey:@"mode"];
    [controller applyCachedSongs:@[stale] forToken:2];
    XCTAssertEqualObjects([controller valueForKey:@"songs"], (@[sentinel]));

    [controller setValue:@(NLMusicLibraryListModeCachedSongs) forKey:@"mode"];
    [controller viewWillDisappear:NO];
    [controller applyCachedSongs:@[stale] forToken:2];
    XCTAssertEqualObjects([controller valueForKey:@"songs"], (@[sentinel]));

    window.rootViewController = nil;
    [controller applyCachedSongs:@[stale] forToken:3];
    XCTAssertEqualObjects([controller valueForKey:@"songs"], (@[sentinel]));
    window.hidden = YES;
    dispatch_semaphore_signal(fake.releaseQuery);
    [self waitUntil:^BOOL{ return !fake.blockedQueryInFlight; } message:@"stale cache query should finish after release"];
    [self removePlayHistoryAndWaitForSongID:songID];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)setUp {
    [super setUp];
    self.cacheManager = [NLCacheManager sharedManager];
    self.previousDatabaseManager = [NLDataBaseManager sharedManager];
}

- (void)tearDown {
    if (self.legacyTestDatabaseManager) {
        [NLDataBaseManager setSharedManagerForTesting:self.previousDatabaseManager];
        [self.legacyTestDatabaseManager.database close:nil];
        [[NSFileManager defaultManager] removeItemAtPath:self.legacyTestDirectory error:nil];
    }
    [super tearDown];
}

- (void)testCacheIdentityUsesStableURLPathButIgnoresExpiringQuery {
    NSURL *first = [NSURL URLWithString:@"https://cdn.example.com/audio/high.mp3?token=one&expires=1"];
    NSURL *sameVariant = [NSURL URLWithString:@"https://cdn.example.com/audio/high.mp3?token=two&expires=2"];
    NSURL *differentVariant = [NSURL URLWithString:@"https://cdn.example.com/audio/lossless.mp3?token=two"];
    NSString *firstIdentity = [self.cacheManager cacheIdentityForURL:first cacheKey:@"song-1"];
    XCTAssertEqualObjects(firstIdentity, [self.cacheManager cacheIdentityForURL:sameVariant cacheKey:@"song-1"]);
    XCTAssertNotEqualObjects(firstIdentity, [self.cacheManager cacheIdentityForURL:differentVariant cacheKey:@"song-1"]);
}
- (BOOL)performRepositoryWriteAndWait:(void (^)(void (^completion)(BOOL success)))write {
    XCTestExpectation *finished = [self expectationWithDescription:@"Repository write finished"];
    __block BOOL result = NO;
    write(^(BOOL success) {
        result = success;
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:5];
    return result;
}

- (BOOL)recordPlaybackStartAndWaitForSong:(NLSong *)song {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLSongRepository recordPlaybackStart:song completion:completion];
    }];
}

- (BOOL)removePlayHistoryAndWaitForSongID:(NSString *)songID {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLSongRepository removePlayHistoryWithSongId:songID completion:completion];
    }];
}

- (BOOL)removeDownloadAndWaitForSongID:(NSString *)songID {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLDownloadRepository removeDownloadItemWithSongId:songID completion:completion];
    }];
}


- (NSURL *)uniqueURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://example.com/audio-%@.mp3", NSUUID.UUID.UUIDString]];
}

- (void)waitUntil:(BOOL (^)(void))condition message:(NSString *)message {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(condition(), @"%@", message);
}

- (NSString *)prepareCapacityCacheDirectory {
    self.legacyTestDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *directory = [self.legacyTestDirectory stringByAppendingPathComponent:@"AudioCache"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    self.legacyTestDatabaseManager = [[NLDataBaseManager alloc] initWithDatabasePath:[self.legacyTestDirectory stringByAppendingPathComponent:@"Quota.sqlite"] error:nil];
    XCTAssertNotNil(self.legacyTestDatabaseManager);
    [NLDataBaseManager setSharedManagerForTesting:self.legacyTestDatabaseManager];
    XCTAssertTrue([self.legacyTestDatabaseManager.database createTable:NLAudioCacheInfoTableName withClass:NLAudioCacheInfo.class]);
    return directory;
}

- (NSString *)seedCapacityFileAtDirectory:(NSString *)directory URL:(NSURL *)url size:(NSUInteger)size finished:(BOOL)finished recency:(NSTimeInterval)recency {
    NSString *identifier = [self.cacheManager identifierForURL:url cacheKey:nil];
    NSString *path = [directory stringByAppendingPathComponent:[identifier stringByAppendingString:finished ? @".mp3" : @".tmp"]];
    XCTAssertTrue([[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]);
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    [file truncateFileAtOffset:size]; // Sparse fixtures exercise quotas without allocating hundreds of MiB.
    [file closeFile];
    NSString *ranges = finished ? [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)size] : @"[]";
    NLAudioCacheInfo *info = [self infoWithIdentifier:identifier songID:NSUUID.UUID.UUIDString totalLength:(long long)size cachedRangesString:ranges isFinished:finished];
    info.lastAccessTime = recency;
    XCTAssertTrue([self.legacyTestDatabaseManager.database insertOrReplaceObject:info intoTable:NLAudioCacheInfoTableName]);
    return path;
}

- (void)startCapacityManagerAtDirectory:(NSString *)directory {
    self.cacheManager = [[NLCacheManager alloc] initWithCacheDirectory:directory reconciliationBlock:nil];
    XCTestExpectation *ready = [self expectationWithDescription:@"capacity manager ready"];
    [self.cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    [self waitForExpectations:@[ready] timeout:5];
}

- (void)waitForCapacityOperations {
    dispatch_queue_t queue = [self.cacheManager valueForKey:@"admissionQueue"];
    [self waitUntil:^BOOL{
        __block BOOL idle = NO;
        dispatch_sync(queue, ^{
            BOOL scheduled = [self.cacheManager respondsToSelector:NSSelectorFromString(@"capacityCleanupScheduled")] &&
                [[self.cacheManager valueForKey:@"capacityCleanupScheduled"] boolValue];
            idle = [[self.cacheManager valueForKey:@"inFlightCacheOperationCount"] unsignedIntegerValue] == 0 && !scheduled;
        });
        return idle;
    } message:@"cache writes and capacity cleanup should settle"];
}

- (void)writeCapacityByteForURL:(NSURL *)url offset:(long long)offset totalLength:(long long)totalLength {
    XCTestExpectation *written = [self expectationWithDescription:@"capacity byte written"];
    [self.cacheManager cacheData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] forURL:url cacheKey:nil atOffset:offset totalLength:totalLength completion:^(BOOL success) {
        XCTAssertTrue(success);
        [written fulfill];
    }];
    [self waitForExpectations:@[written] timeout:5];
    [self waitForCapacityOperations];
}

- (void)testPromotionCommitFailureIsNotSuccessAndRetryIsIdempotent {
    NSString *directory = [self prepareCapacityCacheDirectory];
    [self startCapacityManagerAtDirectory:directory];
    NSURL *url = [self uniqueURL];
    NSData *audio = [@"committed-audio" dataUsingEncoding:NSUTF8StringEncoding];
    XCTestExpectation *written = [self expectationWithDescription:@"body written"];
    [self.cacheManager cacheData:audio forURL:url cacheKey:nil atOffset:0 totalLength:audio.length completion:^(BOOL success) {
        XCTAssertTrue(success);
        [written fulfill];
    }];
    [self waitForExpectations:@[written] timeout:5];
    WCTDatabase *database = self.legacyTestDatabaseManager.database;
    XCTAssertTrue([database rawExecute:@"CREATE TRIGGER TestPromotionCommit BEFORE INSERT ON AudioCacheInfoTable_v3 WHEN NEW.isFinished = 1 BEGIN SELECT RAISE(ABORT, 'commit failure'); END"]);
    XCTestExpectation *failed = [self expectationWithDescription:@"commit rejected"];
    [self.cacheManager mergeAndSaveSessionRanges:@[[NSValue valueWithRange:NSMakeRange(0, audio.length)]] forURL:url cacheKey:nil completion:^(BOOL complete) {
        XCTAssertFalse(complete);
        [failed fulfill];
    }];
    [self waitForExpectations:@[failed] timeout:5];
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager tempFilePathForURL:url]], audio);
    XCTAssertFalse([[[database getObjectsOfClass:NLAudioCacheInfo.class fromTable:NLAudioCacheInfoTableName] firstObject] isFinished]);
    XCTAssertTrue([database rawExecute:@"DROP TRIGGER TestPromotionCommit"]);
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        XCTestExpectation *finished = [self expectationWithDescription:@"commit or repeat completion"];
        [self.cacheManager finishCacheForURL:url cacheKey:nil completion:^(BOOL complete) {
            XCTAssertTrue(complete);
            [finished fulfill];
        }];
        [self waitForExpectations:@[finished] timeout:5];
        XCTAssertTrue([self.cacheManager isFullyCachedForURL:url]);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager cacheFilePathForURL:url]], audio);
    }
    [self waitForCapacityOperations];
}

- (void)testCommittedFlagCannotOverrideIncompleteLedger {
    NSString *directory = [self prepareCapacityCacheDirectory];
    [self startCapacityManagerAtDirectory:directory];
    NSURL *url = [self uniqueURL];
    NSString *identifier = [self.cacheManager identifierForURL:url cacheKey:nil];
    NLAudioCacheInfo *info = [self infoWithIdentifier:identifier songID:@"incomplete" totalLength:5 cachedRangesString:@"[{\"loc\":0,\"len\":4}]" isFinished:YES];
    XCTAssertTrue([self insertCacheInfoForTest:info]);
    NSString *path = [self.cacheManager cacheFilePathForURL:url];
    XCTAssertTrue([[@"audio" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO]);
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:nil cacheKey:info.songId]);
    [self.cacheManager reconcileCacheDirectory];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    XCTAssertEqual([self.legacyTestDatabaseManager.database getObjectsOfClass:NLAudioCacheInfo.class fromTable:NLAudioCacheInfoTableName].count, 0u);
}

- (void)testReconcileRemovesTruncatedCommittedBody {
    NSString *directory = [self prepareCapacityCacheDirectory];
    [self startCapacityManagerAtDirectory:directory];
    NSURL *url = [self uniqueURL];
    NLAudioCacheInfo *info = [self infoWithIdentifier:[self.cacheManager identifierForURL:url cacheKey:nil] songID:@"truncated" totalLength:5 cachedRangesString:@"[{\"loc\":0,\"len\":5}]" isFinished:YES];
    XCTAssertTrue([self insertCacheInfoForTest:info]);
    NSString *path = [self.cacheManager cacheFilePathForURL:url];
    XCTAssertTrue([[@"bad" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO]);
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
    [self.cacheManager reconcileCacheDirectory];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    XCTAssertEqual([self.legacyTestDatabaseManager.database getObjectsOfClass:NLAudioCacheInfo.class fromTable:NLAudioCacheInfoTableName].count, 0u);
}

- (void)testStartupCommitsCompletePartialBody {
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *url = [self uniqueURL];
    NSString *identifier = [self.cacheManager identifierForURL:url cacheKey:nil];
    NSData *audio = [@"audio" dataUsingEncoding:NSUTF8StringEncoding];
    NLAudioCacheInfo *info = [self infoWithIdentifier:identifier songID:@"startup-complete" totalLength:audio.length cachedRangesString:@"[{\"loc\":0,\"len\":5}]" isFinished:NO];
    XCTAssertTrue([self insertCacheInfoForTest:info]);
    NSString *partial = [directory stringByAppendingPathComponent:[identifier stringByAppendingString:@".tmp"]];
    XCTAssertTrue([audio writeToFile:partial atomically:NO]);
    [self startCapacityManagerAtDirectory:directory];
    XCTAssertTrue([self.cacheManager isFullyCachedForURL:url]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager cacheFilePathForURL:url]], audio);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:partial]);
}

- (void)testRenamedUncommittedBodyCanFinishWithoutTempFile {
    NSString *directory = [self prepareCapacityCacheDirectory];
    [self startCapacityManagerAtDirectory:directory];
    NSURL *url = [self uniqueURL];
    NSData *audio = [@"audio" dataUsingEncoding:NSUTF8StringEncoding];
    NLAudioCacheInfo *info = [self infoWithIdentifier:[self.cacheManager identifierForURL:url cacheKey:nil] songID:@"pending-commit" totalLength:audio.length cachedRangesString:@"[{\"loc\":0,\"len\":5}]" isFinished:NO];
    XCTAssertTrue([self insertCacheInfoForTest:info]);
    XCTAssertTrue([audio writeToFile:[self.cacheManager cacheFilePathForURL:url] atomically:NO]);
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
    XCTestExpectation *finished = [self expectationWithDescription:@"renamed body committed"];
    [self.cacheManager finishCacheForURL:url cacheKey:nil completion:^(BOOL complete) {
        XCTAssertTrue(complete);
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];
    XCTAssertTrue([self.cacheManager isFullyCachedForURL:url]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager cacheFilePathForURL:url]], audio);
    [self waitForCapacityOperations];
}

- (void)testPartialCapacityCrossingTrimsToLowWatermarkAndProtectsCurrentPlayback {
    NSUInteger mib = 1024 * 1024;
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *oldest = [self uniqueURL], *older = [self uniqueURL], *playing = [self uniqueURL], *newest = [self uniqueURL];
    NSString *firstPath = [self seedCapacityFileAtDirectory:directory URL:oldest size:10 * mib finished:NO recency:1];
    NSString *secondPath = [self seedCapacityFileAtDirectory:directory URL:older size:10 * mib finished:NO recency:2];
    NSString *playingPath = [self seedCapacityFileAtDirectory:directory URL:playing size:88 * mib finished:NO recency:0];
    [self startCapacityManagerAtDirectory:directory];
    self.cacheManager.currentPlayingURL = playing;
    [self writeCapacityByteForURL:newest offset:20 * mib - 1 totalLength:40 * mib];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:firstPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:secondPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:playingPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:newest]]);
    // 128 MiB must fall below 115.2 MiB, not stop at 118 MiB after deleting only one file.
}

- (void)testPromotionTriggersCompletedCapacityCleanupWithoutEvictingPartialTier {
    NSUInteger mib = 1024 * 1024;
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *first = [self uniqueURL], *second = [self uniqueURL], *playing = [self uniqueURL], *promoting = [self uniqueURL], *partial = [self uniqueURL];
    NSString *firstPath = [self seedCapacityFileAtDirectory:directory URL:first size:30 * mib finished:YES recency:1];
    NSString *secondPath = [self seedCapacityFileAtDirectory:directory URL:second size:30 * mib finished:YES recency:2];
    NSString *playingPath = [self seedCapacityFileAtDirectory:directory URL:playing size:430 * mib finished:YES recency:0];
    NSString *partialPath = [self seedCapacityFileAtDirectory:directory URL:partial size:2 * mib finished:NO recency:0];
    [self startCapacityManagerAtDirectory:directory];
    self.cacheManager.currentPlayingURL = playing;
    [self writeCapacityByteForURL:promoting offset:10 * mib - 1 totalLength:10 * mib];
    XCTestExpectation *promoted = [self expectationWithDescription:@"quota promotion"];
    [self.cacheManager mergeAndSaveSessionRanges:@[[NSValue valueWithRange:NSMakeRange(0, 10 * mib)]] forURL:promoting cacheKey:nil completion:^(BOOL completed) {
        XCTAssertTrue(completed);
        [promoted fulfill];
    }];
    [self waitForExpectations:@[promoted] timeout:5];
    [self waitForCapacityOperations];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:firstPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:secondPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:playingPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:partialPath]);
    XCTAssertTrue([self.cacheManager isFullyCachedForURL:promoting]);
}

- (void)testOverwriteDoesNotCountAlreadyCachedBytesTwice {
    NSUInteger mib = 1024 * 1024;
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *old = [self uniqueURL], *current = [self uniqueURL];
    NSString *oldPath = [self seedCapacityFileAtDirectory:directory URL:old size:100 * mib finished:NO recency:1];
    [self startCapacityManagerAtDirectory:directory];
    [self writeCapacityByteForURL:current offset:27 * mib - 1 totalLength:40 * mib];
    [self writeCapacityByteForURL:current offset:27 * mib - 1 totalLength:40 * mib];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
    XCTAssertEqual([[[NSFileManager defaultManager] attributesOfItemAtPath:[self.cacheManager tempFilePathForURL:current] error:nil][NSFileSize] unsignedLongLongValue], 27ULL * mib);
}

- (void)testStartupOverQuotaWaitsForMutationAndProtectedFilesMayRemainOverQuota {
    NSUInteger mib = 1024 * 1024;
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *old = [self uniqueURL], *playing = [self uniqueURL], *newest = [self uniqueURL];
    NSString *oldPath = [self seedCapacityFileAtDirectory:directory URL:old size:10 * mib finished:NO recency:1];
    NSString *playingPath = [self seedCapacityFileAtDirectory:directory URL:playing size:130 * mib finished:NO recency:0];
    [self startCapacityManagerAtDirectory:directory];
    [self waitForCapacityOperations];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
    self.cacheManager.currentPlayingURL = playing;
    [self writeCapacityByteForURL:newest offset:0 totalLength:10];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:playingPath]);
}

- (void)testClearResetsCapacityAccountingBeforeNewWrites {
    NSUInteger mib = 1024 * 1024;
    NSString *directory = [self prepareCapacityCacheDirectory];
    NSURL *old = [self uniqueURL], *newest = [self uniqueURL];
    NSString *oldPath = [self seedCapacityFileAtDirectory:directory URL:old size:120 * mib finished:NO recency:1];
    [self startCapacityManagerAtDirectory:directory];
    XCTestExpectation *cleared = [self expectationWithDescription:@"capacity cleared"];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NLCacheManagerDidFinishCachingNotification object:self.cacheManager queue:nil usingBlock:^(NSNotification *note) { [cleared fulfill]; }];
    [self.cacheManager clearAllCache];
    [self waitForExpectations:@[cleared] timeout:5];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [self writeCapacityByteForURL:newest offset:20 * mib - 1 totalLength:40 * mib];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:newest]]);
}


- (void)testLateWriteCannotReplaceCompletedAudioBytes {
    NSURL *url = [self uniqueURL];
    NSData *original = [@"first" dataUsingEncoding:NSUTF8StringEncoding];
    XCTestExpectation *write = [self expectationWithDescription:@"original write"];
    [self.cacheManager cacheData:original forURL:url cacheKey:nil atOffset:0 totalLength:original.length completion:^(BOOL success) {
        XCTAssertTrue(success);
        [write fulfill];
    }];
    [self waitForExpectations:@[write] timeout:5];
    XCTestExpectation *promote = [self expectationWithDescription:@"original promotion"];
    [self.cacheManager mergeAndSaveSessionRanges:@[[NSValue valueWithRange:NSMakeRange(0, original.length)]]
                                          forURL:url cacheKey:nil completion:^(BOOL complete) {
        XCTAssertTrue(complete);
        [promote fulfill];
    }];
    [self waitForExpectations:@[promote] timeout:5];

    XCTestExpectation *lateWrite = [self expectationWithDescription:@"late write handled"];
    [self.cacheManager cacheData:[@"other" dataUsingEncoding:NSUTF8StringEncoding]
                         forURL:url cacheKey:nil atOffset:0 totalLength:original.length completion:^(BOOL success) {
        [lateWrite fulfill];
    }];
    [self waitForExpectations:@[lateWrite] timeout:5];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager cacheFilePathForURL:url]], original);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:url]]);
}

- (void)testResourceLoaderServesAlternatingMemoryAndDiskRangesWithoutNetwork {
    NSURL *url = [self uniqueURL];
    NSString *cacheKey = [self.cacheManager cacheIdentityForURL:url cacheKey:NSUUID.UUID.UUIDString];
    NSArray<NSValue *> *ranges = @[[NSValue valueWithRange:NSMakeRange(3, 3)],
                                    [NSValue valueWithRange:NSMakeRange(9, 1)]];
    XCTestExpectation *firstWrite = [self expectationWithDescription:@"disk middle"];
    XCTestExpectation *secondWrite = [self expectationWithDescription:@"disk end"];
    [self.cacheManager cacheData:[@"def" dataUsingEncoding:NSUTF8StringEncoding]
                         forURL:url cacheKey:cacheKey atOffset:3 totalLength:11 completion:^(BOOL success) {
        XCTAssertTrue(success);
        [firstWrite fulfill];
    }];
    [self.cacheManager cacheData:[@"j" dataUsingEncoding:NSUTF8StringEncoding]
                         forURL:url cacheKey:cacheKey atOffset:9 totalLength:11 completion:^(BOOL success) {
        XCTAssertTrue(success);
        [secondWrite fulfill];
    }];
    [self waitForExpectations:@[firstWrite, secondWrite] timeout:5];
    XCTestExpectation *merged = [self expectationWithDescription:@"disk ranges indexed"];
    [self.cacheManager mergeAndSaveSessionRanges:ranges forURL:url cacheKey:cacheKey completion:^(BOOL completed) {
        XCTAssertFalse(completed);
        [merged fulfill];
    }];
    [self waitForExpectations:@[merged] timeout:5];
    XCTAssertEqual([self.cacheManager cachedRangesForURL:url cacheKey:cacheKey].count, 2u);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:url cacheKey:cacheKey]]);
    NLAudioMemoryCache *memoryCache = [NLAudioMemoryCache sharedCache];
    [memoryCache storeData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] cacheKey:cacheKey atOffset:0];
    [memoryCache storeData:[@"ghi" dataUsingEncoding:NSUTF8StringEncoding] cacheKey:cacheKey atOffset:6];
    NLRecordingDataRequest *dataRequest = [[NLRecordingDataRequest alloc] init];
    dataRequest.requestedOffset = 0;
    dataRequest.requestedLength = 10;
    dataRequest.receivedData = [NSMutableData data];
    NLRecordingLoadingRequest *request = [[NLRecordingLoadingRequest alloc] init];
    request.dataRequest = dataRequest;
    request.request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"streaming://example.com/audio-test.mp3"]];
    NLResourceLoader *loader = [[NLResourceLoader alloc] init];
    loader.originURL = url;
    loader.cacheKey = cacheKey;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [loader resourceLoader:asset.resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request];
    [self waitUntil:^BOOL{
        return request.finished;
    } message:@"ready loader should finish the cached request asynchronously"];

    XCTAssertTrue(request.finished);
    XCTAssertNil(request.error);
    XCTAssertEqualObjects(request.dataRequest.receivedData, [@"abcdefghij" dataUsingEncoding:NSUTF8StringEncoding]);
    [loader invalidateAndCancelAll];
    [memoryCache removeDataForCacheKey:cacheKey];
}


- (void)testCompletedSongCanBeFoundOfflineWithoutPlaybackURL {
    NSURL *url = [self uniqueURL];
    NSString *songId = NSUUID.UUID.UUIDString;
    NSString *identity = [self.cacheManager cacheIdentityForURL:url cacheKey:songId];
    NSData *audio = [@"offline-audio" dataUsingEncoding:NSUTF8StringEncoding];
    XCTestExpectation *write = [self expectationWithDescription:@"audio written"];
    [self.cacheManager cacheData:audio forURL:url cacheKey:identity atOffset:0 totalLength:audio.length completion:^(BOOL success) {
        XCTAssertTrue(success);
        [write fulfill];
    }];
    [self waitForExpectations:@[write] timeout:5];
    XCTestExpectation *promote = [self expectationWithDescription:@"audio promoted"];
    [self.cacheManager mergeAndSaveSessionRanges:@[[NSValue valueWithRange:NSMakeRange(0, audio.length)]]
                                          forURL:url cacheKey:identity completion:^(BOOL completed) {
        XCTAssertTrue(completed);
        [promote fulfill];
    }];
    [self waitForExpectations:@[promote] timeout:5];

    XCTAssertTrue([self.cacheManager isFullyCachedForURL:nil cacheKey:songId]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.cacheManager cacheFilePathForURL:nil cacheKey:songId]], audio);
}

- (NLCacheManager *)newReconciliationManagerAtPath:(NSString *)directory
                                           entered:(XCTestExpectation *)entered
                                             resume:(dispatch_semaphore_t)resume {
    return [[NLCacheManager alloc] initWithCacheDirectory:directory
                                       reconciliationBlock:^(NLCacheManager *cacheManager) {
        [entered fulfill];
        if (dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0) {
            [cacheManager reconcileCacheDirectory];
        }
    }];
}

- (BOOL)insertCacheInfoForTest:(NLAudioCacheInfo *)info {
    return [[NLDataBaseManager sharedManager].database insertOrReplaceObject:info intoTable:@"AudioCacheInfoTable_v3"];
}

- (void)finishReconciliationFixtureWithManager:(NLCacheManager *)manager
                                           info:(NLAudioCacheInfo *)info
                                      directory:(NSString *)directory {
    NSString *deleteSQL = [NSString stringWithFormat:@"DELETE FROM AudioCacheInfoTable_v3 WHERE cacheIdentifier = '%@'", info.cacheIdentifier];
    [[NLDataBaseManager sharedManager].database rawExecute:deleteSQL];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testReconcileRecoversRenamedAudioWithCompleteRangeLedger {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    NLCacheManager *manager = [self newReconciliationManagerAtPath:directory entered:entered resume:resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [self uniqueURL];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSData *audio = [@"recovered-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [manager cacheFilePathForURL:url cacheKey:songID];
    XCTAssertTrue([audio writeToFile:path atomically:NO]);

    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.cacheIdentifier = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    info.isFinished = NO;
    info.lastAccessTime = 1;
    XCTAssertTrue([self insertCacheInfoForTest:info]);

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertTrue([manager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], audio);
    [self finishReconciliationFixtureWithManager:manager info:info directory:directory];
}

- (void)testReconcileDoesNotRecoverSameLengthFileWithIncompleteRangeLedger {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    NLCacheManager *manager = [self newReconciliationManagerAtPath:directory entered:entered resume:resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [self uniqueURL];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSData *audio = [@"same-length-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [manager cacheFilePathForURL:url cacheKey:songID];
    XCTAssertTrue([audio writeToFile:path atomically:NO]);
    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.cacheIdentifier = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length - 1];
    info.isFinished = NO;
    XCTAssertTrue([self insertCacheInfoForTest:info]);

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertFalse([manager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    [self finishReconciliationFixtureWithManager:manager info:info directory:directory];
}

- (void)testReconcileDoesNotRecoverCompleteLedgerWithWrongFileLength {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    NLCacheManager *manager = [self newReconciliationManagerAtPath:directory entered:entered resume:resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [self uniqueURL];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSData *audio = [@"wrong-length-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [manager cacheFilePathForURL:url cacheKey:songID];
    XCTAssertTrue([[audio subdataWithRange:NSMakeRange(0, audio.length - 1)] writeToFile:path atomically:NO]);
    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.cacheIdentifier = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    info.isFinished = NO;
    XCTAssertTrue([self insertCacheInfoForTest:info]);

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertFalse([manager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    [self finishReconciliationFixtureWithManager:manager info:info directory:directory];
}

- (void)testReconcilePreservesCandidateWhenLedgerRepairFails {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    NLCacheManager *manager = [self newReconciliationManagerAtPath:directory entered:entered resume:resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [self uniqueURL];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSData *audio = [@"repair-failure-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [manager cacheFilePathForURL:url cacheKey:songID];
    XCTAssertTrue([audio writeToFile:path atomically:NO]);
    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.cacheIdentifier = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    info.isFinished = NO;
    XCTAssertTrue([self insertCacheInfoForTest:info]);

    NSString *triggerName = [NSString stringWithFormat:@"TestAudioRepair%@", [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSString *triggerSQL = [NSString stringWithFormat:@"CREATE TRIGGER %@ BEFORE INSERT ON AudioCacheInfoTable_v3 WHEN NEW.cacheIdentifier = '%@' AND NEW.isFinished = 1 BEGIN SELECT RAISE(ABORT, 'test repair failure'); END", triggerName, info.cacheIdentifier];
    XCTAssertTrue([[NLDataBaseManager sharedManager].database rawExecute:triggerSQL]);

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    NLAudioCacheInfo *persisted = nil;
    for (NLAudioCacheInfo *candidate in [[NLDataBaseManager sharedManager].database getObjectsOfClass:NLAudioCacheInfo.class fromTable:@"AudioCacheInfoTable_v3"]) {
        if ([candidate.cacheIdentifier isEqualToString:info.cacheIdentifier]) {
            persisted = candidate;
            break;
        }
    }
    WCTDatabase *database = [NLDataBaseManager sharedManager].database;
    NSString *dropTriggerSQL = [NSString stringWithFormat:@"DROP TRIGGER IF EXISTS %@", triggerName];
    BOOL droppedTrigger = [database rawExecute:dropTriggerSQL];
    XCTAssertTrue(droppedTrigger);
    XCTAssertNotNil(persisted);
    XCTAssertFalse(persisted.isFinished);
    XCTAssertFalse([manager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path]);
    [self finishReconciliationFixtureWithManager:manager info:info directory:directory];
}

- (NLCacheManager *)newCacheManagerAtPath:(NSString *)path
                                   entered:(XCTestExpectation *)entered
                                    resume:(dispatch_semaphore_t *)resume {
    dispatch_semaphore_t resumeSemaphore = dispatch_semaphore_create(0);
    if (resume) *resume = resumeSemaphore;

    __block NLCacheManager *manager = nil;
    XCTAssertNoThrow(manager = [[NLCacheManager alloc] initWithCacheDirectory:path
                                                          reconciliationBlock:^(NLCacheManager *cacheManager) {
        [entered fulfill];
        dispatch_semaphore_wait(resumeSemaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }]);
    return manager;
}

- (void)testCacheOperationsWaitForReconciliationWithoutBlockingMainQueue {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = nil;
    NLCacheManager *manager = [self newCacheManagerAtPath:directory entered:entered resume:&resume];
    [self waitForExpectations:@[entered] timeout:3];

    XCTestExpectation *firstReady = [self expectationWithDescription:@"first ready callback"];
    XCTestExpectation *secondReady = [self expectationWithDescription:@"second ready callback"];
    XCTestExpectation *writeFinished = [self expectationWithDescription:@"write after reconciliation"];
    XCTestExpectation *mainQueueResponsive = [self expectationWithDescription:@"main queue remains responsive"];
    __block BOOL firstCallbackRan = NO;
    __block BOOL secondCallbackRan = NO;
    NSURL *url = [NSURL URLWithString:@"https://example.com/pending-cache.mp3"];
    NSData *audio = [@"after-ready" dataUsingEncoding:NSUTF8StringEncoding];

    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        XCTAssertTrue(NSThread.isMainThread);
        firstCallbackRan = YES;
        [firstReady fulfill];
    }];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        XCTAssertTrue(NSThread.isMainThread);
        secondCallbackRan = YES;
        [secondReady fulfill];
    }];
    [manager cacheData:audio forURL:url cacheKey:nil atOffset:0 totalLength:(long long)audio.length completion:^(BOOL success) {
        XCTAssertTrue(success);
        [writeFinished fulfill];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ [mainQueueResponsive fulfill]; });

    [self waitForExpectations:@[mainQueueResponsive] timeout:3];
    XCTAssertFalse(firstCallbackRan);
    XCTAssertFalse(secondCallbackRan);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[manager tempFilePathForURL:url]]);

    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[firstReady, secondReady, writeFinished] timeout:5];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[manager tempFilePathForURL:url]]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testReadyCallbackIsAlwaysDeliveredAsynchronously {
    NLCacheManager *manager = self.cacheManager;
    XCTestExpectation *ready = [self expectationWithDescription:@"ready callback"];
    __block BOOL callReturned = NO;
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        XCTAssertTrue(callReturned);
        [ready fulfill];
    }];
    callReturned = YES;
    [self waitForExpectations:@[ready] timeout:5];
}

- (void)testClearBeforeReadyRejectsOldWriteAndAllowsPostClearWrite {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = nil;
    NLCacheManager *manager = [self newCacheManagerAtPath:directory entered:entered resume:&resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [NSURL URLWithString:@"https://example.com/clear-barrier.mp3"];
    NSData *oldAudio = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *newAudio = [@"new" dataUsingEncoding:NSUTF8StringEncoding];
    XCTestExpectation *oldWriteRejected = [self expectationWithDescription:@"pre-clear generation rejected"];
    XCTestExpectation *clearFinished = [self expectationWithDescription:@"clear finished"];
    XCTestExpectation *newWriteFinished = [self expectationWithDescription:@"post-clear write finished"];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NLCacheManagerDidFinishCachingNotification
                                                                    object:manager
                                                                     queue:nil
                                                                usingBlock:^(NSNotification *note) {
        [clearFinished fulfill];
    }];

    [manager cacheData:oldAudio forURL:url cacheKey:nil atOffset:0 totalLength:(long long)oldAudio.length completion:^(BOOL success) {
        XCTAssertFalse(success);
        [oldWriteRejected fulfill];
    }];
    [manager clearAllCache];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        [manager cacheData:newAudio forURL:url cacheKey:nil atOffset:0 totalLength:(long long)newAudio.length completion:^(BOOL success) {
            XCTAssertTrue(success);
            [newWriteFinished fulfill];
        }];
    }];

    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[oldWriteRejected, clearFinished, newWriteFinished] timeout:8];

    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[manager tempFilePathForURL:url]], newAudio);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}
- (void)testStaleDownloadCompletionCannotReleaseNewReservation {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSUInteger oldGeneration = NSUIntegerMax;
    XCTAssertTrue([manager reserveSongID:songID generation:&oldGeneration]);

    [manager cancelAllDownloads];

    NSUInteger newGeneration = NSUIntegerMax;
    XCTAssertTrue([manager reserveSongID:songID generation:&newGeneration]);
    XCTAssertNotEqual(oldGeneration, newGeneration);

    NSNumber *taskID = @1;
    NSMutableDictionary *context = [@{
        @"songId": songID,
        @"generation": @(oldGeneration),
        @"url": [NSURL URLWithString:@"https://example.com/stale-download.mp3"],
        @"cancelled": @NO
    } mutableCopy];
    NSMutableDictionary *taskContexts = [manager valueForKey:@"taskContextMap"];
    taskContexts[taskID] = context;
    [manager finishDownloadContext:context taskID:taskID fullyCached:NO];

    XCTAssertTrue([manager isDownloadingSongId:songID]);
}

- (void)testPlayerStopBeforeCacheReadyDropsPendingPlayback {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"player reconciliation entered"];
    dispatch_semaphore_t resume = nil;
    NLCacheManager *cacheManager = [self newCacheManagerAtPath:directory entered:entered resume:&resume];
    [self waitForExpectations:@[entered] timeout:3];

    NLPlayerManager *player = nil;
    XCTAssertNoThrow(player = [[NLPlayerManager alloc] init]);
    if (!player) {
        dispatch_semaphore_signal(resume);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        return;
    }
    [player setValue:cacheManager forKey:@"cacheManager"];
    [player playWithURL:[NSURL URLWithString:@"https://127.0.0.1:1/stale-player.mp3"]];
    [player stop];
    XCTAssertNil([player valueForKey:@"currentPlayerItem"]);

    XCTestExpectation *ready = [self expectationWithDescription:@"player callback drained after reconciliation"];
    [cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];
    XCTAssertNil([player valueForKey:@"currentPlayerItem"]);
    [player stop];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testCancelAllReleasesActiveBackgroundDownloads {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"pending" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"http://127.0.0.1:1/cancelled-download.mp3"];
    [manager addDownloadForSong:song];
    XCTAssertTrue([manager isDownloadingSongId:songID]);

    [manager cancelAllDownloads];
    [self waitUntil:^BOOL { return ![manager isDownloadingSongId:songID] && [[manager valueForKey:@"taskMap"] count] == 0; }
             message:@"cancelled background download should release its active task"];

    [manager removeOfflineDownloadForSongID:songID];
    [self removeDownloadAndWaitForSongID:songID];
}

- (void)testCancelledLoadingRequestDoesNotReadMemoryBeforeReconciliationCompletes {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = nil;
    NLCacheManager *manager = [self newCacheManagerAtPath:directory entered:entered resume:&resume];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [NSURL URLWithString:@"https://example.com/cancelled-before-ready.mp3"];
    [[NLAudioMemoryCache sharedCache] storeData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] forURL:url atOffset:0];
    NLRecordingDataRequest *dataRequest = [[NLRecordingDataRequest alloc] init];
    dataRequest.requestedOffset = 0;
    dataRequest.requestedLength = 3;
    dataRequest.receivedData = [NSMutableData data];
    NLRecordingLoadingRequest *request = [[NLRecordingLoadingRequest alloc] init];
    request.dataRequest = dataRequest;
    request.request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"streaming://example.com/cancelled-before-ready.mp3"]];

    NLResourceLoader *loader = [[NLResourceLoader alloc] init];
    loader.cacheManager = manager;
    loader.originURL = url;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [loader resourceLoader:asset.resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request];
    XCTAssertFalse(request.finished);
    XCTAssertEqual(request.dataRequest.receivedData.length, 0);

    [loader resourceLoader:asset.resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request];
    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation released"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertFalse(request.finished);
    XCTAssertNil(request.error);
    XCTAssertEqual(request.dataRequest.receivedData.length, 0);
    [loader invalidateAndCancelAll];
    [[NLAudioMemoryCache sharedCache] removeDataForURL:url];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testCancelledURLSessionCompletionRemovesPendingLoaderContext {
    NLResourceLoader *loader = [[NLResourceLoader alloc] init];
    NSURL *url = [NSURL URLWithString:@"https://example.com/cancelled-completion.mp3"];
    NLRecordingLoadingRequest *request = [[NLRecordingLoadingRequest alloc] init];
    request.request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"streaming://example.com/cancelled-completion.mp3"]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url];
    NSMutableDictionary *context = [@{
        @"url": url,
        @"cacheKey": @"cancelled-completion",
        @"loadingRequest": request,
        @"sessionRanges": [NSMutableArray array],
        @"writeGroup": (id)dispatch_group_create(),
        @"cancelled": @YES
    } mutableCopy];
    NSString *pendingKey = [NSString stringWithFormat:@"%p", request];
    NSMutableDictionary *pending = [loader valueForKey:@"pendingRequestContextMap"];
    NSMutableDictionary *taskContexts = [loader valueForKey:@"taskContextMap"];
    NSMutableDictionary *taskRequests = [loader valueForKey:@"taskRequestMap"];
    NSMutableDictionary *tasks = [loader valueForKey:@"tasksMap"];
    pending[pendingKey] = context;
    taskContexts[@(task.taskIdentifier)] = context;
    taskRequests[@(task.taskIdentifier)] = request;
    tasks[@(task.taskIdentifier)] = task;

    [loader URLSession:nil task:task didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];

    [self waitUntil:^BOOL{
        return pending.count == 0;
    } message:@"cancelled URLSession completion should remove pending loader context"];
    [loader invalidateAndCancelAll];
}

- (NLAudioCacheInfo *)infoWithIdentifier:(NSString *)identifier
                                  songID:(NSString *)songID
                             totalLength:(long long)totalLength
                       cachedRangesString:(NSString *)cachedRangesString
                             isFinished:(BOOL)isFinished {
    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.cacheIdentifier = identifier;
    info.songId = songID;
    info.totalLength = totalLength;
    info.cachedRangesString = cachedRangesString;
    info.lastAccessTime = 1234;
    info.isFinished = isFinished;
    return info;
}

- (NSString *)sha256HexForString:(NSString *)value {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *hex = [NSMutableString stringWithCapacity:bytes.length * 2];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

- (void)installLegacyCacheDatabaseWithSongID:(NSString *)songID
                              cacheIdentifier:(NSString *)cacheIdentifier
                                        audio:(NSData *)audio
                                  totalLength:(long long)totalLength
                              cachedRangesJSON:(NSString *)rangesJSON
                                    isFinished:(BOOL)isFinished {
    self.legacyTestDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *cacheDirectory = [self.legacyTestDirectory stringByAppendingPathComponent:@"AudioCache"];
    NSString *databasePath = [self.legacyTestDirectory stringByAppendingPathComponent:@"Legacy.sqlite"];
    NSError *directoryError = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectory
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&directoryError];
    XCTAssertTrue(created, @"%@", directoryError.localizedDescription);

    WCTDatabase *legacyDatabase = [[WCTDatabase alloc] initWithPath:databasePath];
    XCTAssertTrue([legacyDatabase rawExecute:@"CREATE TABLE AudioCacheInfoTable (urlMD5 TEXT PRIMARY KEY, songId TEXT, totalLength INTEGER, cachedRangesString TEXT, lastAccessTime REAL, isFinished INTEGER)"]);
    NSString *escapedRanges = [rangesJSON stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSString *insertSQL = [NSString stringWithFormat:@"INSERT INTO AudioCacheInfoTable (urlMD5, songId, totalLength, cachedRangesString, lastAccessTime, isFinished) VALUES ('%@', '%@', %lld, '%@', 1234, %d)",
                           cacheIdentifier, songID, totalLength, escapedRanges, isFinished];
    XCTAssertTrue([legacyDatabase rawExecute:insertSQL]);
    NSString *suffix = isFinished ? @".mp3" : @".tmp";
    NSString *audioPath = [cacheDirectory stringByAppendingPathComponent:[cacheIdentifier stringByAppendingString:suffix]];
    XCTAssertTrue([audio writeToFile:audioPath atomically:NO]);
    [legacyDatabase close:nil];

    NSError *databaseError = nil;
    self.legacyTestDatabaseManager = [[NLDataBaseManager alloc] initWithDatabasePath:databasePath error:&databaseError];
    XCTAssertNotNil(self.legacyTestDatabaseManager, @"%@", databaseError.localizedDescription);
    [NLDataBaseManager setSharedManagerForTesting:self.legacyTestDatabaseManager];
    self.cacheManager = [[NLCacheManager alloc] initWithCacheDirectory:cacheDirectory reconciliationBlock:nil];

    XCTestExpectation *ready = [self expectationWithDescription:@"legacy cache migration and reconciliation finished"];
    [self.cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    [self waitForExpectations:@[ready] timeout:5];
}

- (void)assertLegacyCacheTableWasRemoved {
    NSString *sql = @"INSERT INTO AudioCacheInfoTable (urlMD5) VALUES ('must-not-exist')";
    XCTAssertFalse([self.legacyTestDatabaseManager.database rawExecute:sql]);
}

- (void)testNewCacheIdentifierUsesSHA256PrefixAndStableIdentity {
    NSURL *url = [NSURL URLWithString:@"https://cdn.example.com/audio/high.mp3?token=one"];
    NSString *identifier = [self.cacheManager identifierForURL:url cacheKey:@"song-1"];

    XCTAssertTrue([identifier hasPrefix:@"sha256-"], @"identifier should carry the algorithm prefix: %@", identifier);
    NSString *hex = [identifier substringFromIndex:@"sha256-".length];
    XCTAssertEqual(hex.length, 64u);
    XCTAssertEqualObjects(hex, hex.lowercaseString);
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    XCTAssertEqualObjects([hex stringByTrimmingCharactersInSet:invalid], hex);
    XCTAssertEqualObjects(identifier, [self.cacheManager identifierForURL:url cacheKey:@"song-1"]);
    XCTAssertNotEqualObjects(identifier, [self.cacheManager identifierForURL:url cacheKey:@"song-2"]);
    NSString *expectedHex = [self sha256HexForString:@"song-1"];
    XCTAssertEqualObjects(identifier, [@"sha256-" stringByAppendingString:expectedHex]);
    NSString *legacyURLHex = [self sha256HexForString:url.absoluteString];
    XCTAssertEqualObjects([self.cacheManager identifierForURL:url cacheKey:nil], [@"sha256-" stringByAppendingString:legacyURLHex]);
}

- (void)testLegacyCompleteCacheRemainsPlayableBySongIDAfterMigration {
    NSString *songID = NSUUID.UUID.UUIDString;
    NSString *legacyIdentifier = @"legacy-md5-identifier";
    NSData *audio = [@"legacy-complete-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *rangesJSON = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    [self installLegacyCacheDatabaseWithSongID:songID
                               cacheIdentifier:legacyIdentifier
                                         audio:audio
                                   totalLength:(long long)audio.length
                               cachedRangesJSON:rangesJSON
                                     isFinished:YES];

    NSString *audioPath = [[self.legacyTestDirectory stringByAppendingPathComponent:@"AudioCache"] stringByAppendingPathComponent:[legacyIdentifier stringByAppendingString:@".mp3"]];
    NSURL *url = [self uniqueURL];
    NSString *identity = [self.cacheManager cacheIdentityForURL:url cacheKey:songID];
    NSString *newIdentifier = [self.cacheManager identifierForURL:url cacheKey:identity];
    XCTAssertTrue([self.cacheManager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertEqualObjects([self.cacheManager cacheFilePathForURL:nil cacheKey:songID], audioPath);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:audioPath], audio);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[[audioPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[newIdentifier stringByAppendingString:@".mp3"]]]);

    NSArray<NLAudioCacheInfo *> *rows = [self.legacyTestDatabaseManager.database getObjectsOfClass:NLAudioCacheInfo.class fromTable:NLAudioCacheInfoTableName];
    NLAudioCacheInfo *persisted = nil;
    for (NLAudioCacheInfo *candidate in rows) {
        if ([candidate.cacheIdentifier isEqualToString:legacyIdentifier]) persisted = candidate;
    }
    XCTAssertNotNil(persisted);
    XCTAssertEqualObjects(persisted.songId, songID);
    XCTAssertEqualObjects(persisted.cachedRangesString, rangesJSON);
    XCTAssertEqual(persisted.lastAccessTime, 1234);
    XCTAssertTrue(persisted.isFinished);
    XCTAssertEqual(persisted.totalLength, (long long)audio.length);
    [self assertLegacyCacheTableWasRemoved];
}

- (void)testLegacyPartialRangeIsNotMergedIntoDifferentVariant {
    NSString *songID = NSUUID.UUID.UUIDString;
    NSData *audio = [@"legacy-partial-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *legacyIdentifier = @"legacy-partial-identifier";
    long long totalLength = (long long)audio.length + 10;
    NSString *rangesJSON = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    [self installLegacyCacheDatabaseWithSongID:songID
                               cacheIdentifier:legacyIdentifier
                                         audio:audio
                                   totalLength:totalLength
                               cachedRangesJSON:rangesJSON
                                     isFinished:NO];

    NSURL *losslessURL = [NSURL URLWithString:@"https://cdn.example.com/audio/lossless.mp3"];
    NSString *losslessIdentity = [self.cacheManager cacheIdentityForURL:losslessURL cacheKey:songID];
    NSString *legacyPath = [[self.legacyTestDirectory stringByAppendingPathComponent:@"AudioCache"] stringByAppendingPathComponent:[legacyIdentifier stringByAppendingString:@".tmp"]];
    XCTAssertEqual([self.cacheManager cachedRangesForURL:losslessURL cacheKey:losslessIdentity].count, 0u);
    XCTAssertEqual([self.cacheManager totalLengthForURL:losslessURL cacheKey:losslessIdentity], 0);
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:losslessURL cacheKey:losslessIdentity]);
    XCTAssertNotEqualObjects([self.cacheManager tempFilePathForURL:losslessURL cacheKey:losslessIdentity], legacyPath);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:legacyPath], audio);

    NSArray<NLAudioCacheInfo *> *rows = [self.legacyTestDatabaseManager.database getObjectsOfClass:NLAudioCacheInfo.class fromTable:NLAudioCacheInfoTableName];
    NLAudioCacheInfo *persisted = nil;
    for (NLAudioCacheInfo *candidate in rows) {
        if ([candidate.cacheIdentifier isEqualToString:legacyIdentifier]) persisted = candidate;
    }
    XCTAssertNotNil(persisted);
    XCTAssertEqual(persisted.totalLength, totalLength);
    XCTAssertEqualObjects(persisted.cachedRangesString, rangesJSON);
    XCTAssertFalse(persisted.isFinished);
    [self assertLegacyCacheTableWasRemoved];
}
@end
