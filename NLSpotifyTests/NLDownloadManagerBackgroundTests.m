#import <XCTest/XCTest.h>
#import "NLDownloadManager.h"
#import "NLOfflineAudioStore.h"
#import "NLDownloadRepository.h"
#import "NLDownloadItem.h"
#import "NLSong.h"
#import "NLSongRepository.h"
#import "NLSongListCell.h"


@interface NLTestDownloadTask : NSObject
@property (nonatomic, assign) NSUInteger taskIdentifier;
@property (nonatomic, copy) NSString *taskDescription;
@property (nonatomic, copy) NSData *resumeDataToProduce;
@property (nonatomic, assign) int64_t countOfBytesReceived;
@property (nonatomic, assign) int64_t countOfBytesExpectedToReceive;
@property (nonatomic, assign) BOOL resumed;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL createdFromResumeData;
- (void)cancelByProducingResumeData:(void (^)(NSData * _Nullable resumeData))completionHandler;
- (void)resume;
- (void)cancel;
@end

@implementation NLTestDownloadTask
- (void)cancelByProducingResumeData:(void (^)(NSData * _Nullable))completionHandler {
    self.cancelled = YES;
    completionHandler(self.resumeDataToProduce);
}
- (void)resume { self.resumed = YES; }
- (void)cancel { self.cancelled = YES; }
@end

@interface NLTestDownloadSession : NSObject
@property (nonatomic, strong) NSMutableArray<NLTestDownloadTask *> *tasks;
- (NLTestDownloadTask *)downloadTaskWithURL:(NSURL *)URL;
- (NLTestDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData;
@end

@implementation NLTestDownloadSession
- (instancetype)init {
    if (self = [super init]) _tasks = [NSMutableArray array];
    return self;
}
- (NLTestDownloadTask *)newTaskFromResumeData:(BOOL)fromResumeData {
    static NSUInteger nextIdentifier = 1000;
    NLTestDownloadTask *task = [[NLTestDownloadTask alloc] init];
    task.taskIdentifier = ++nextIdentifier;
    task.createdFromResumeData = fromResumeData;
    [self.tasks addObject:task];
    return task;
}
- (NLTestDownloadTask *)downloadTaskWithURL:(NSURL *)URL { return [self newTaskFromResumeData:NO]; }
- (NLTestDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData { return [self newTaskFromResumeData:YES]; }
@end

@interface NLDownloadManager (BackgroundTesting)
- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation;
- (void)releaseSongID:(NSString *)songID forGeneration:(NSUInteger)generation;
- (void)startDownloadWithSong:(NLSong *)song generation:(NSUInteger)generation completion:(void (^)(BOOL success))completion;
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
- (void)finishRecoveringBackgroundTasks;
@end

@interface NLDeferredRecoveryDownloadManager : NLDownloadManager @end
@implementation NLDeferredRecoveryDownloadManager
- (void)recoverBackgroundTasks {}
- (void)migrateLegacyCompletedDownloads {}
@end

@interface NLDownloadManagerBackgroundTests : XCTestCase @end
@implementation NLDownloadManagerBackgroundTests
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

- (BOOL)addDownloadItemForSongAndWait:(NLSong *)song {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLDownloadRepository addDownloadItemWithSong:song status:@"downloading" completion:completion];
    }];
}

- (BOOL)removeDownloadItemAndWaitForSongID:(NSString *)songID {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLDownloadRepository removeDownloadItemWithSongId:songID completion:completion];
    }];
}

- (BOOL)removeDownloadedSongAndWaitForSongID:(NSString *)songID {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLSongRepository removeDownloadedSong:songID completion:completion];
    }];
}
- (BOOL)updateDownloadStatusAndWait:(NSString *)status songID:(NSString *)songID {
    return [self performRepositoryWriteAndWait:^(void (^completion)(BOOL)) {
        [NLDownloadRepository updateStatus:status forSongId:songID completion:completion];
    }];
}

- (NLDeferredRecoveryDownloadManager *)managerWithStubSession:(NLTestDownloadSession **)sessionOut {
    NLDeferredRecoveryDownloadManager *manager = [[NLDeferredRecoveryDownloadManager alloc] init];
    NLTestDownloadSession *session = [[NLTestDownloadSession alloc] init];
    [manager setValue:session forKey:@"session"];
    if (sessionOut) *sessionOut = session;
    return manager;
}

- (NLTestDownloadTask *)attachTaskForSong:(NLSong *)song
                                  manager:(NLDownloadManager *)manager
                               generation:(NSUInteger *)generation {
    if (![manager reserveSongID:song.songId generation:generation]) return nil;
    NLTestDownloadSession *session = [manager valueForKey:@"session"];
    NLTestDownloadTask *task = [session downloadTaskWithURL:song.playURL];
    task.taskDescription = song.songId;
    NSMutableDictionary *taskMap = [manager valueForKey:@"taskMap"];
    NSMutableDictionary *contexts = [manager valueForKey:@"taskContextMap"];
    taskMap[@(task.taskIdentifier)] = (id)task;
    contexts[@(task.taskIdentifier)] = [@{
        @"generation": @(*generation),
        @"songId": song.songId,
        @"url": song.playURL,
        @"song": song,
        @"cancelled": @NO,
        @"usedResumeData": @NO
    } mutableCopy];
    return task;
}

- (NLDownloadItem *)downloadItemForSongIDOnBackgroundQueue:(NSString *)songID {
    XCTestExpectation *finished = [self expectationWithDescription:@"background Repository read finished"];
    __block NLDownloadItem *item = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        item = [NLDownloadRepository downloadItemForSongId:songID];
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:5];
    return item;
}

- (void)waitUntil:(BOOL (^)(void))condition message:(NSString *)message {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(condition(), @"%@", message);
}

- (void)setUp {
    [super setUp];
    [[NLOfflineAudioStore sharedStore] removeAllOfflineAudio];
}

- (void)tearDown {
    [[NLOfflineAudioStore sharedStore] removeAllOfflineAudio];
    [super tearDown];
}

- (void)testUsesStableBackgroundSessionConfiguration {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSURLSession *session = [manager valueForKey:@"session"];
    XCTAssertEqualObjects(session.configuration.identifier, @"com.nlspotify.offline-downloads");
    XCTAssertTrue(session.configuration.sessionSendsLaunchEvents);
}

- (void)testCompletedBackgroundDownloadMovesAudioToOfflineStore {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/offline.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Offline" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);

    NSUInteger generation = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&generation]);
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:remoteURL];
    task.taskDescription = songID;
    NSMutableDictionary *contexts = [manager valueForKey:@"taskContextMap"];
    contexts[@(task.taskIdentifier)] = [@{ @"generation": @(generation), @"songId": songID, @"url": remoteURL, @"song": song, @"cancelled": @NO } mutableCopy];

    NSString *sourcePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSData *audio = [@"background-offline-audio" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([audio writeToFile:sourcePath atomically:NO]);
    [manager URLSession:nil downloadTask:task didFinishDownloadingToURL:[NSURL fileURLWithPath:sourcePath]];
    [manager URLSession:nil task:task didCompleteWithError:nil];
    [self waitUntil:^BOOL{
        return [[self downloadItemForSongIDOnBackgroundQueue:songID].status isEqualToString:@"completed"];
    } message:@"completed download state should persist after the body import"];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[[NLOfflineAudioStore sharedStore] localFileURLForSongID:songID]], audio);
    [self removeDownloadItemAndWaitForSongID:songID];
    [self removeDownloadedSongAndWaitForSongID:songID];
}

- (void)testDefersNewDownloadsUntilBackgroundTaskRecoveryFinishes {
    NLDownloadManager *manager = [[NLDeferredRecoveryDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Deferred" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"http://127.0.0.1:1/deferred-download.mp3"];

    [manager addDownloadForSong:song];
    XCTAssertTrue([manager isDownloadingSongId:songID]);
    NSArray<NSURLSessionTask *> *beforeRecovery = [[manager valueForKey:@"taskMap"] allValues];
    XCTAssertEqual([beforeRecovery filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLSessionTask *task, NSDictionary *bindings) {
        return [task.taskDescription isEqualToString:songID];
    }]].count, 0u);

    [manager finishRecoveringBackgroundTasks];
    [self waitUntil:^BOOL{
        NSArray<NSURLSessionTask *> *tasks = [[manager valueForKey:@"taskMap"] allValues];
        return [tasks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLSessionTask *task, NSDictionary *bindings) {
            return [task.taskDescription isEqualToString:songID];
        }]].count == 1;
    } message:@"download task should start only after its queue record is written"];
    NSArray<NSURLSessionTask *> *afterRecovery = [[manager valueForKey:@"taskMap"] allValues];
    XCTAssertEqual([afterRecovery filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLSessionTask *task, NSDictionary *bindings) {
        return [task.taskDescription isEqualToString:songID];
    }]].count, 1u);
    [self waitUntil:^BOOL{
        return [[self downloadItemForSongIDOnBackgroundQueue:songID].status isEqualToString:@"downloading"];
    } message:@"download queue should be persisted before starting the task"];
    [manager cancelAllDownloads];
    [manager removeOfflineDownloadForSongID:songID];
    [self removeDownloadItemAndWaitForSongID:songID];
}

- (void)testStaleReservationCannotReleaseReaddedSong {
    NLDownloadManager *manager = [self managerWithStubSession:nil];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSUInteger firstGeneration = 0;
    NSUInteger secondGeneration = 0;
    NSUInteger thirdGeneration = 0;

    XCTAssertTrue([manager reserveSongID:songID generation:&firstGeneration]);
    [manager releaseSongID:songID forGeneration:firstGeneration];
    XCTAssertTrue([manager reserveSongID:songID generation:&secondGeneration]);
    XCTAssertNotEqual(firstGeneration, secondGeneration);

    [manager releaseSongID:songID forGeneration:firstGeneration];
    XCTAssertFalse([manager reserveSongID:songID generation:&thirdGeneration]);
    [manager releaseSongID:songID forGeneration:secondGeneration];
    XCTAssertTrue([manager reserveSongID:songID generation:&thirdGeneration]);
    [manager releaseSongID:songID forGeneration:thirdGeneration];
}

- (void)testTaskDoesNotResumeWhenIdentifierPersistenceFails {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *blockingFile = [directory stringByAppendingPathComponent:@"not-a-directory"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:blockingFile atomically:NO]);

    NLOfflineAudioStore *isolatedStore = [[NLOfflineAudioStore alloc] init];
    NSURL *invalidMetadataURL = [[NSURL fileURLWithPath:blockingFile] URLByAppendingPathComponent:@"downloads.json"];
    [isolatedStore setValue:invalidMetadataURL forKey:@"metadataURL"];
    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    [manager setValue:isolatedStore forKey:@"offlineStore"];

    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Unpersisted" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/unpersisted.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    NSUInteger generation = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&generation]);

    XCTestExpectation *finished = [self expectationWithDescription:@"failed metadata write prevents task resume"];
    [manager startDownloadWithSong:song generation:generation completion:^(BOOL success) {
        XCTAssertFalse(success);
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];

    XCTAssertEqual(session.tasks.count, 1u);
    XCTAssertFalse(session.tasks.firstObject.resumed);
    XCTAssertTrue(session.tasks.firstObject.cancelled);
    XCTAssertNil([isolatedStore stateForSongID:songID]);
    XCTAssertEqualObjects([self downloadItemForSongIDOnBackgroundQueue:songID].status, @"failed");
    XCTAssertTrue([self removeDownloadItemAndWaitForSongID:songID]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testDeletedDownloadCompletionCannotRestoreQueueItem {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/deleted.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Deleted" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    NSUInteger generation = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&generation]);
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:remoteURL];
    task.taskDescription = songID;
    NSMutableDictionary *contexts = [manager valueForKey:@"taskContextMap"];
    contexts[@(task.taskIdentifier)] = [@{ @"generation": @(generation), @"songId": songID, @"url": remoteURL, @"song": song, @"cancelled": @NO } mutableCopy];

    NSString *sourcePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSData dataWithBytes:"audio" length:5] writeToFile:sourcePath atomically:NO]);
    [manager URLSession:nil downloadTask:task didFinishDownloadingToURL:[NSURL fileURLWithPath:sourcePath]];
    [manager removeOfflineDownloadForSongID:songID];
    [self removeDownloadItemAndWaitForSongID:songID];
    [manager URLSession:nil task:task didCompleteWithError:nil];

    [self waitUntil:^BOOL{
        return [self downloadItemForSongIDOnBackgroundQueue:songID] == nil;
    } message:@"deleted queue row must remain absent after a late completion callback"];
    XCTAssertNil([[NLOfflineAudioStore sharedStore] localFileURLForSongID:songID]);
}

- (void)testFailedResumedDownloadClearsResumeDataForFreshRetry {
    NLDownloadManager *manager = [[NLDownloadManager alloc] init];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/retry.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Retry" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    NSUInteger generation = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&generation]);
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:remoteURL];
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:task.taskIdentifier forSongID:songID resumeData:[NSData dataWithBytes:"stale" length:5] receivedBytes:1 expectedBytes:2 error:nil]);
    task.taskDescription = songID;
    NSMutableDictionary *contexts = [manager valueForKey:@"taskContextMap"];
    contexts[@(task.taskIdentifier)] = [@{ @"generation": @(generation), @"songId": songID, @"url": remoteURL, @"song": song, @"cancelled": @NO, @"usedResumeData": @YES } mutableCopy];

    [manager URLSession:nil task:task didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];

    XCTAssertNil([[NLOfflineAudioStore sharedStore] stateForSongID:songID][@"resumeData"]);
    [self waitUntil:^BOOL{
        return [[self downloadItemForSongIDOnBackgroundQueue:songID].status isEqualToString:@"failed"];
    } message:@"failed resumed transfer should persist its failed status"];
    [self removeDownloadItemAndWaitForSongID:songID];
}
- (void)testStaleResumeFailureCannotClearNewReservationTaskState {
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"New generation" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/new-generation.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    NSUInteger oldGeneration = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&oldGeneration]);
    NLTestDownloadTask *oldTask = [session downloadTaskWithResumeData:[@"old-resume" dataUsingEncoding:NSUTF8StringEncoding]];
    oldTask.taskDescription = songID;
    NSMutableDictionary *taskMap = [manager valueForKey:@"taskMap"];
    NSMutableDictionary *contexts = [manager valueForKey:@"taskContextMap"];
    taskMap[@(oldTask.taskIdentifier)] = (id)oldTask;
    contexts[@(oldTask.taskIdentifier)] = [@{
        @"generation": @(oldGeneration),
        @"songId": songID,
        @"url": song.playURL,
        @"song": song,
        @"cancelled": @NO,
        @"usedResumeData": @YES
    } mutableCopy];
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:oldTask.taskIdentifier
                                                                  forSongID:songID
                                                                 resumeData:[@"old-resume" dataUsingEncoding:NSUTF8StringEncoding]
                                                              receivedBytes:100
                                                              expectedBytes:200
                                                                      error:nil]);

    [manager releaseSongID:songID forGeneration:oldGeneration];
    NSUInteger newGeneration = 0;
    XCTAssertTrue([manager reserveSongID:songID generation:&newGeneration]);
    NLTestDownloadTask *newTask = [session downloadTaskWithURL:song.playURL];
    newTask.taskDescription = songID;
    taskMap[@(newTask.taskIdentifier)] = (id)newTask;
    contexts[@(newTask.taskIdentifier)] = [@{
        @"generation": @(newGeneration),
        @"songId": songID,
        @"url": song.playURL,
        @"song": song,
        @"cancelled": @NO,
        @"usedResumeData": @NO
    } mutableCopy];
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:newTask.taskIdentifier
                                                                  forSongID:songID
                                                                 resumeData:nil
                                                              receivedBytes:5
                                                              expectedBytes:10
                                                                      error:nil]);

    [manager URLSession:nil task:(id)oldTask didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];

    NSDictionary *state = [[NLOfflineAudioStore sharedStore] stateForSongID:songID];
    XCTAssertEqual([state[@"taskIdentifier"] unsignedIntegerValue], newTask.taskIdentifier);
    XCTAssertEqual([state[@"receivedBytes"] longLongValue], 5);
    XCTAssertEqual([state[@"expectedBytes"] longLongValue], 10);
    XCTAssertNil(state[@"resumeData"]);

    [manager removeOfflineDownloadForSongID:songID];
    XCTAssertTrue([self removeDownloadItemAndWaitForSongID:songID]);
}
- (void)testPausePersistsResumeDataBeforeReportingPaused {
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/pause.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Pause" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    NSUInteger generation = 0;
    NLTestDownloadTask *task = [self attachTaskForSong:song manager:manager generation:&generation];
    NSData *resumeData = [@"valid-resume-data" dataUsingEncoding:NSUTF8StringEncoding];
    task.resumeDataToProduce = resumeData;

    XCTestExpectation *finished = [self expectationWithDescription:@"pause persisted before completion"];
    [manager pauseDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertTrue(success);
        XCTAssertTrue(task.cancelled);
        XCTAssertEqualObjects([NLOfflineAudioStore.sharedStore stateForSongID:songID][@"resumeData"], resumeData);
        XCTAssertEqualObjects([self downloadItemForSongIDOnBackgroundQueue:songID].status, @"paused");
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];
    [self removeDownloadItemAndWaitForSongID:songID];
}

- (void)testPauseMetadataPersistenceFailureDoesNotReportPaused {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *blockingFile = [directory stringByAppendingPathComponent:@"not-a-directory"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:blockingFile atomically:NO]);
    NLOfflineAudioStore *isolatedStore = [[NLOfflineAudioStore alloc] init];
    NSURL *invalidMetadataURL = [[NSURL fileURLWithPath:blockingFile] URLByAppendingPathComponent:@"downloads.json"];
    [isolatedStore setValue:invalidMetadataURL forKey:@"metadataURL"];

    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Pause failure" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/pause-failure.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    [manager setValue:isolatedStore forKey:@"offlineStore"];
    NSUInteger generation = 0;
    NLTestDownloadTask *task = [self attachTaskForSong:song manager:manager generation:&generation];
    task.resumeDataToProduce = [@"resume" dataUsingEncoding:NSUTF8StringEncoding];

    XCTestExpectation *finished = [self expectationWithDescription:@"pause reports failure when resume data was not persisted"];
    [manager pauseDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertFalse(success);
        XCTAssertTrue(task.cancelled);
        XCTAssertNil([isolatedStore stateForSongID:songID][@"resumeData"]);
        XCTAssertEqualObjects([self downloadItemForSongIDOnBackgroundQueue:songID].status, @"failed");
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];
    XCTAssertEqual(session.tasks.count, 1u);
    XCTAssertTrue([self removeDownloadItemAndWaitForSongID:songID]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testInvalidResumeDataReportsFailureWithoutStartingAnotherTask {
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/invalid-resume.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Invalid Resume" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    XCTAssertTrue([self updateDownloadStatusAndWait:@"paused" songID:songID]);
    NSData *invalidResumeData = [@"invalid-resume-data" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:0 forSongID:songID resumeData:invalidResumeData receivedBytes:100 expectedBytes:200 error:nil]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    XCTestExpectation *started = [self expectationWithDescription:@"invalid resume task created"];
    [manager resumeDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertTrue(success);
        [started fulfill];
    }];
    [self waitForExpectations:@[started] timeout:5];
    XCTAssertEqual(session.tasks.count, 1u);
    XCTAssertTrue(session.tasks.firstObject.createdFromResumeData);
    [manager URLSession:nil task:(id)session.tasks.firstObject didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];

    [self waitUntil:^BOOL{
        return [[self downloadItemForSongIDOnBackgroundQueue:songID].status isEqualToString:@"failed"];
    } message:@"rejected resume data should persist failed status without starting a fresh task"];
    XCTAssertEqual(session.tasks.count, 1u);
    XCTAssertNil([NLOfflineAudioStore.sharedStore stateForSongID:songID][@"resumeData"]);
    [self removeDownloadItemAndWaitForSongID:songID];
}

- (void)testExplicitRetryAfterResumeFailureStartsFreshTask {
    NSString *songID = NSUUID.UUID.UUIDString;
    NSURL *remoteURL = [NSURL URLWithString:@"https://example.com/retry-explicit.mp3"];
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Retry" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = remoteURL;
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    XCTAssertTrue([self updateDownloadStatusAndWait:@"paused" songID:songID]);
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:0 forSongID:songID resumeData:[@"bad-resume" dataUsingEncoding:NSUTF8StringEncoding] receivedBytes:5 expectedBytes:10 error:nil]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];

    XCTestExpectation *resumeStarted = [self expectationWithDescription:@"resume attempt started"];
    [manager resumeDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertTrue(success);
        [resumeStarted fulfill];
    }];
    [self waitForExpectations:@[resumeStarted] timeout:5];
    [manager URLSession:nil task:(id)session.tasks.firstObject didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
    [self waitUntil:^BOOL{
        return [[self downloadItemForSongIDOnBackgroundQueue:songID].status isEqualToString:@"failed"];
    } message:@"failed resume should be visible before explicit retry"];

    XCTestExpectation *retryStarted = [self expectationWithDescription:@"explicit retry started"];
    [manager retryDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertTrue(success);
        [retryStarted fulfill];
    }];
    [self waitForExpectations:@[retryStarted] timeout:5];
    XCTAssertEqual(session.tasks.count, 2u);
    XCTAssertFalse(session.tasks.lastObject.createdFromResumeData);
    XCTAssertTrue(session.tasks.lastObject.resumed);
    XCTAssertEqualObjects([self downloadItemForSongIDOnBackgroundQueue:songID].status, @"downloading");
    [manager cancelAllDownloads];
    [manager removeOfflineDownloadForSongID:songID];
    [self removeDownloadItemAndWaitForSongID:songID];
}

- (void)testUnknownExpectedBytesDoesNotReportFraction {
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Unknown Size" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/unknown-size.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:88 forSongID:songID resumeData:nil receivedBytes:256 expectedBytes:0 error:nil]);

    NLDownloadManager *manager = [self managerWithStubSession:nil];
    XCTestExpectation *loaded = [self expectationWithDescription:@"download snapshot loaded"];
    [manager loadDownloadItemsWithCompletion:^(NSArray<NLDownloadItem *> *items) {
        XCTAssertTrue(NSThread.isMainThread);
        NLDownloadItem *item = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NLDownloadItem *candidate, NSDictionary *bindings) {
            return [candidate.songId isEqualToString:songID];
        }]].firstObject;
        XCTAssertNotNil(item);
        XCTAssertEqual(item.receivedBytes, 256);
        XCTAssertEqual(item.expectedBytes, 0);
        [loaded fulfill];
    }];
    [self waitForExpectations:@[loaded] timeout:5];
    [self removeDownloadItemAndWaitForSongID:songID];
}

- (void)testDeleteDuringDownloadCannotResurrectQueueOrOfflineFile {
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Delete Race" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/delete-race.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    NSUInteger generation = 0;
    NLTestDownloadTask *task = [self attachTaskForSong:song manager:manager generation:&generation];
    [manager removeOfflineDownloadForSongID:songID];
    XCTAssertTrue(task.cancelled);
    XCTAssertTrue([self removeDownloadItemAndWaitForSongID:songID]);

    NSString *sourcePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSData dataWithBytes:"late-audio" length:10] writeToFile:sourcePath atomically:NO]);
    [manager URLSession:nil downloadTask:(id)task didFinishDownloadingToURL:[NSURL fileURLWithPath:sourcePath]];
    [manager URLSession:nil task:(id)task didCompleteWithError:nil];

    [self waitUntil:^BOOL{
        return [self downloadItemForSongIDOnBackgroundQueue:songID] == nil;
    } message:@"a late transfer callback must not restore a deleted queue item"];
    XCTAssertNil([NLOfflineAudioStore.sharedStore localFileURLForSongID:songID]);
    [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}
- (void)testCancelClearsResumeDataAndRetainsRetryableQueueItem {
    NSString *songID = NSUUID.UUID.UUIDString;
    NLSong *song = [[NLSong alloc] initWithId:songID title:@"Cancel" artist:@"Test" coverURL:[NSURL URLWithString:@"https://example.com/cover.jpg"]];
    song.playURL = [NSURL URLWithString:@"https://example.com/cancel.mp3"];
    XCTAssertTrue([self addDownloadItemForSongAndWait:song]);
    NSData *oldResumeData = [@"old-resume" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([[NLOfflineAudioStore sharedStore] recordTaskIdentifier:12 forSongID:songID resumeData:oldResumeData receivedBytes:20 expectedBytes:40 error:nil]);

    NLTestDownloadSession *session = nil;
    NLDownloadManager *manager = [self managerWithStubSession:&session];
    NSUInteger generation = 0;
    NLTestDownloadTask *task = [self attachTaskForSong:song manager:manager generation:&generation];
    XCTestExpectation *finished = [self expectationWithDescription:@"cancel state persisted"];
    [manager cancelDownloadForSongID:songID completion:^(BOOL success) {
        XCTAssertTrue(success);
        XCTAssertTrue(task.cancelled);
        XCTAssertEqualObjects([self downloadItemForSongIDOnBackgroundQueue:songID].status, @"cancelled");
        XCTAssertNil([NLOfflineAudioStore.sharedStore stateForSongID:songID][@"resumeData"]);
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];
    XCTAssertNotNil([self downloadItemForSongIDOnBackgroundQueue:songID]);
    [self removeDownloadItemAndWaitForSongID:songID];
}
@end
