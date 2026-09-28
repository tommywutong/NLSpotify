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
@end
@interface NLCacheManager (ReadinessTesting)
- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory
                  reconciliationBlock:(void (^)(NLCacheManager *manager))reconciliationBlock;
- (void)whenReadyOnQueue:(dispatch_queue_t)queue perform:(dispatch_block_t)block;
@end

@interface NLCacheManager (ReconciliationTesting)
- (void)reconcileCacheDirectory;
@end

@interface WCTDatabase : NSObject
- (BOOL)rawExecute:(NSString *)sql;
- (NSArray *)getObjectsOfClass:(Class)cls fromTable:(NSString *)table;
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
    XCTAssertTrue([NLSongRepository addPlayHistory:song]);

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

    [NLSongRepository removePlayHistoryWithSongId:songID];
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
    XCTAssertTrue([NLSongRepository addPlayHistory:older]);
    XCTAssertTrue([NLSongRepository addPlayHistory:newer]);

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

    [NLSongRepository removePlayHistoryWithSongId:olderID];
    [NLSongRepository removePlayHistoryWithSongId:newerID];
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
    XCTAssertTrue([NLSongRepository addPlayHistory:historySong]);
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
    [NLSongRepository removePlayHistoryWithSongId:songID];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)setUp {
    [super setUp];
    self.cacheManager = [NLCacheManager sharedManager];
}

- (void)testCacheIdentityUsesStableURLPathButIgnoresExpiringQuery {
    NSURL *first = [NSURL URLWithString:@"https://cdn.example.com/audio/high.mp3?token=one&expires=1"];
    NSURL *sameVariant = [NSURL URLWithString:@"https://cdn.example.com/audio/high.mp3?token=two&expires=2"];
    NSURL *differentVariant = [NSURL URLWithString:@"https://cdn.example.com/audio/lossless.mp3?token=two"];
    NSString *firstIdentity = [self.cacheManager cacheIdentityForURL:first cacheKey:@"song-1"];
    XCTAssertEqualObjects(firstIdentity, [self.cacheManager cacheIdentityForURL:sameVariant cacheKey:@"song-1"]);
    XCTAssertNotEqualObjects(firstIdentity, [self.cacheManager cacheIdentityForURL:differentVariant cacheKey:@"song-1"]);
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

- (void)testPartialDiskCacheIsRemovedByPartialTierCleanup {
    NSURL *url = [self uniqueURL];
    NSData *data = [@"partial" dataUsingEncoding:NSUTF8StringEncoding];
    [self.cacheManager cacheData:data forURL:url atOffset:0 totalLength:100];

    [self waitUntil:^BOOL{
        return [[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:url]];
    } message:@"L2 temporary cache file should be written before cleanup"];

    [self.cacheManager cleanPartialCacheWithMaxSize:0];

    [self waitUntil:^BOOL{
        return ![[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:url]];
    } message:@"L2 cleanup should remove incomplete temporary files"];
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
}

- (void)testCompleteDiskCacheIsRemovedByCompleteTierCleanup {
    NSURL *url = [self uniqueURL];
    NSData *data = [@"complete" dataUsingEncoding:NSUTF8StringEncoding];
    [self.cacheManager cacheData:data forURL:url atOffset:0 totalLength:(long long)data.length];
    [self.cacheManager mergeAndSaveSessionRanges:@[[NSValue valueWithRange:NSMakeRange(0, data.length)]] forURL:url];

    [self waitUntil:^BOOL{
        return [self.cacheManager isFullyCachedForURL:url];
    } message:@"L3 complete cache should be promoted from L2 after full coverage"];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager tempFilePathForURL:url]]);

    [self.cacheManager cleanCompletedCacheWithMaxSize:0];

    [self waitUntil:^BOOL{
        return ![[NSFileManager defaultManager] fileExistsAtPath:[self.cacheManager cacheFilePathForURL:url]];
    } message:@"L3 cleanup should remove complete files independently"];
    XCTAssertFalse([self.cacheManager isFullyCachedForURL:url]);
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

    NLAudioMemoryCache *memoryCache = [NLAudioMemoryCache sharedCache];
    [memoryCache storeData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] forURL:url atOffset:0];
    [memoryCache storeData:[@"ghi" dataUsingEncoding:NSUTF8StringEncoding] forURL:url atOffset:6];
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
    [memoryCache removeDataForURL:url];
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
    NSString *sql = [NSString stringWithFormat:@"INSERT OR REPLACE INTO AudioCacheInfoTable (urlMD5, songId, totalLength, cachedRangesString, lastAccessTime, isFinished) VALUES ('%@', '%@', %lld, '%@', %.0f, %d)",
                     info.urlMD5, info.songId, info.totalLength, info.cachedRangesString, info.lastAccessTime, info.isFinished];
    return [[NLDataBaseManager sharedManager].database rawExecute:sql];
}

- (void)finishReconciliationFixtureWithManager:(NLCacheManager *)manager
                                           info:(NLAudioCacheInfo *)info
                                      directory:(NSString *)directory {
    if (info.urlMD5.length) {
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM AudioCacheInfoTable WHERE urlMD5 = '%@'", info.urlMD5];
        [[NLDataBaseManager sharedManager].database rawExecute:sql];
    }
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
    info.urlMD5 = [[path lastPathComponent] stringByDeletingPathExtension];
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
    info.urlMD5 = [[path lastPathComponent] stringByDeletingPathExtension];
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
    info.urlMD5 = [[path lastPathComponent] stringByDeletingPathExtension];
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
    info.urlMD5 = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    info.isFinished = NO;
    XCTAssertTrue([self insertCacheInfoForTest:info]);

    NSString *triggerName = [NSString stringWithFormat:@"TestAudioRepair%@", [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSString *triggerSQL = [NSString stringWithFormat:@"CREATE TRIGGER %@ BEFORE INSERT ON AudioCacheInfoTable WHEN NEW.urlMD5 = '%@' AND NEW.isFinished = 1 BEGIN SELECT RAISE(ABORT, 'test repair failure'); END", triggerName, info.urlMD5];
    XCTAssertTrue([[NLDataBaseManager sharedManager].database rawExecute:triggerSQL]);

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    NLAudioCacheInfo *persisted = nil;
    for (NLAudioCacheInfo *candidate in [[NLDataBaseManager sharedManager].database getObjectsOfClass:NLAudioCacheInfo.class fromTable:@"AudioCacheInfoTable"]) {
        if ([candidate.urlMD5 isEqualToString:info.urlMD5]) {
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

- (void)testCancelAllBeforeCacheReadyDoesNotStartDownload {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"download reconciliation entered"];
    dispatch_semaphore_t resume = nil;
    NLCacheManager *cacheManager = [self newCacheManagerAtPath:directory entered:entered resume:&resume];
    [self waitForExpectations:@[entered] timeout:3];

    NLDownloadManager *manager = nil;
    XCTAssertNoThrow(manager = [[NLDownloadManager alloc] init]);
    if (!manager) {
        dispatch_semaphore_signal(resume);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        return;
    }
    [manager setValue:cacheManager forKey:@"cacheManager"];
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"pending" artist:@"test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"http://127.0.0.1:1/should-not-start.mp3"];
    [manager addDownloadForSong:song];
    XCTAssertTrue([manager isDownloadingSongId:songID]);

    [manager cancelAllDownloads];
    XCTAssertFalse([manager isDownloadingSongId:songID]);
    XCTestExpectation *ready = [self expectationWithDescription:@"download callback drained after reconciliation"];
    [cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertFalse([manager isDownloadingSongId:songID]);
    XCTAssertNil([NLDownloadRepository downloadItemForSongId:songID]);
    XCTAssertEqual([[manager valueForKey:@"taskMap"] count], 0u);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
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
@end
