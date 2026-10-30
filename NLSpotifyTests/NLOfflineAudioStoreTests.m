#import <XCTest/XCTest.h>
#import "NLOfflineAudioStore.h"

@interface NLOfflineAudioStoreTests : XCTestCase
@property (nonatomic, strong) NLOfflineAudioStore *store;
@end

@implementation NLOfflineAudioStoreTests
- (void)setUp {
    [super setUp];
    self.store = [NLOfflineAudioStore sharedStore];
    [self.store removeAllOfflineAudio];
}

- (void)tearDown {
    [self.store removeAllOfflineAudio];
    [super tearDown];
}

- (void)testImportMovesCompleteAudioToIndependentOfflineDirectory {
    NSString *songID = @"offline-song";
    NSString *source = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSData *bytes = [@"offline-audio" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([bytes writeToFile:source atomically:NO]);

    NSError *error = nil;
    XCTAssertTrue([self.store importCompleteAudioAtURL:[NSURL fileURLWithPath:source] forSongID:songID error:&error]);
    XCTAssertNil(error);
    NSURL *offlineURL = [self.store localFileURLForSongID:songID];
    XCTAssertNotNil(offlineURL);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:offlineURL], bytes);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:source]);
}

- (void)testTaskMetadataAndResumeDataPersistBySongID {
    NSData *resumeData = [@"resume" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([self.store recordTaskIdentifier:42
                                         forSongID:@"resume-song"
                                        resumeData:resumeData
                                     receivedBytes:100
                                     expectedBytes:200
                                             error:nil]);
    NSDictionary *state = [self.store stateForSongID:@"resume-song"];
    XCTAssertEqual([state[@"taskIdentifier"] integerValue], 42);
    XCTAssertEqual([state[@"receivedBytes"] longLongValue], 100);
    XCTAssertEqual([state[@"expectedBytes"] longLongValue], 200);
    XCTAssertEqualObjects(state[@"resumeData"], resumeData);
}

- (void)testStaleTaskProgressCannotOverwriteCurrentTaskSnapshot {
    XCTAssertTrue([self.store recordTaskIdentifier:1002
                                          forSongID:@"generation-song"
                                         resumeData:nil
                                      receivedBytes:5
                                      expectedBytes:10
                                              error:nil]);

    BOOL recorded = [self.store recordProgressForTaskIdentifier:1001
                                                       forSongID:@"generation-song"
                                                   receivedBytes:90
                                                   expectedBytes:100
                                                           error:nil];

    XCTAssertFalse(recorded);
    NSDictionary *state = [self.store stateForSongID:@"generation-song"];
    XCTAssertEqual([state[@"taskIdentifier"] unsignedIntegerValue], 1002u);
    XCTAssertEqual([state[@"receivedBytes"] longLongValue], 5);
    XCTAssertEqual([state[@"expectedBytes"] longLongValue], 10);
}

- (void)testRemovingOfflineAudioDeletesMetadataAndFile {
    NSString *source = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[@"audio" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:source atomically:NO]);
    XCTAssertTrue([self.store importCompleteAudioAtURL:[NSURL fileURLWithPath:source] forSongID:@"remove-song" error:nil]);
    NSURL *offlineURL = [self.store localFileURLForSongID:@"remove-song"];
    [self.store removeOfflineAudioForSongID:@"remove-song"];
    XCTAssertNil([self.store localFileURLForSongID:@"remove-song"]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:offlineURL.path]);
}
- (void)testTaskMetadataWriteFailureIsReportedAndDoesNotPublishUnpersistedState {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *blockingFile = [directory stringByAppendingPathComponent:@"not-a-directory"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:blockingFile atomically:NO]);

    NLOfflineAudioStore *isolatedStore = [[NLOfflineAudioStore alloc] init];
    NSURL *invalidMetadataURL = [[NSURL fileURLWithPath:blockingFile] URLByAppendingPathComponent:@"downloads.json"];
    [isolatedStore setValue:invalidMetadataURL forKey:@"metadataURL"];

    NSError *error = nil;
    BOOL persisted = [isolatedStore recordTaskIdentifier:42
                                               forSongID:@"unpersisted-task"
                                              resumeData:[@"resume" dataUsingEncoding:NSUTF8StringEncoding]
                                           receivedBytes:64
                                           expectedBytes:128
                                                   error:&error];
    XCTAssertFalse(persisted);
    XCTAssertNotNil(error);
    XCTAssertNil([isolatedStore stateForSongID:@"unpersisted-task"]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}
@end
