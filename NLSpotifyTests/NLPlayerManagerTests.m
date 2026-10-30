#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "NLSong.h"

@interface NSObject (NLPlaybackTestSignal)
- (id)subscribeNext:(void (^)(id value))next;
- (void)dispose;
@end

// Audio route descriptions are system-created; supply only their read-only boundary data.
@interface NLTestAudioPort : NSObject
@property (nonatomic, copy) NSString *portType;
@end
@implementation NLTestAudioPort
@end
@interface NLTestAudioRoute : NSObject
@property (nonatomic, copy) NSArray<NLTestAudioPort *> *outputs;
@end
@implementation NLTestAudioRoute
@end

// Match the app's public state ABI without importing its app-only ReactiveObjC headers.
typedef NS_ENUM(NSUInteger, NLPlaybackState) {
    NLPlaybackStateIdle, NLPlaybackStateLoading, NLPlaybackStatePlaying,
    NLPlaybackStatePaused, NLPlaybackStateEnded, NLPlaybackStateError
};

@interface NLPlayerManager : NSObject
@property (nonatomic, strong, readonly) NLSong *currentSong;
@property (nonatomic, assign, readonly) NLPlaybackState playbackState;
@property (nonatomic, assign, readonly) NSTimeInterval currentTime;
@property (nonatomic, assign, readonly) NSTimeInterval totalTime;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekToProgress:(float)progress;
- (void)playFullyCachedSongAtPath:(NSString *)path;
@end

@interface NLPlayerManagerTests : XCTestCase
@property (nonatomic, strong) NLPlayerManager *manager;
@property (nonatomic, copy) NSString *audioPath;
@end

@implementation NLPlayerManagerTests
- (void)setUp {
    [super setUp];
    self.manager = [[NLPlayerManager alloc] init];
    self.audioPath = [[NSBundle bundleForClass:self.class] pathForResource:@"range-fixture" ofType:@"mp3"];
    XCTAssertNotNil(self.audioPath);
}

- (void)tearDown {
    [self.manager stop];
    self.manager = nil;
    [super tearDown];
}

- (void)waitFor:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(condition());
}

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"main playback callbacks drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:3];
}

- (AVPlayer *)engine {
    return [self.manager valueForKey:@"player"];
}

- (void)startLocalPlayback {
    NLSong *song = [[NLSong alloc] init]; // No song ID: isolate playback from persistent history.
    song.title = @"Lifecycle fixture";
    [self.manager setValue:song forKey:@"currentSong"];
    [self.manager setValue:@[song] forKey:@"playlist"];
    [self.manager setValue:@YES forKey:@"wantsToPlay"];
    [self.manager playFullyCachedSongAtPath:self.audioPath];
    [self waitFor:^BOOL{
        return self.manager.playbackState == NLPlaybackStatePlaying && self.engine.timeControlStatus == AVPlayerTimeControlStatusPlaying;
    }];
}

- (void)postInterruption:(AVAudioSessionInterruptionType)type options:(AVAudioSessionInterruptionOptions)options {
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionInterruptionNotification
                                                      object:AVAudioSession.sharedInstance
                                                    userInfo:@{AVAudioSessionInterruptionTypeKey:@(type), AVAudioSessionInterruptionOptionKey:@(options)}];
    [self drainMainQueue];
}

- (void)testActualEnginePauseAndResumeOverrideReadyItemState {
    [self startLocalPlayback];
    [self.engine pause]; // Engine/system pause, not a user pause command.
    [self waitFor:^BOOL{ return self.manager.playbackState == NLPlaybackStatePaused; }];
    XCTAssertTrue([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    [self.engine play];
    [self waitFor:^BOOL{ return self.manager.playbackState == NLPlaybackStatePlaying; }];
}

- (void)testInterruptionResumesOnlyWhenSystemRecommendsIt {
    [self startLocalPlayback];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertEqual(self.engine.rate, 0.f);
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:AVAudioSessionInterruptionOptionShouldResume];
    [self waitFor:^BOOL{ return self.manager.playbackState == NLPlaybackStatePlaying; }];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:0];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertEqual(self.engine.rate, 0.f);
}

- (void)testUserPauseDuringInterruptionCancelsAutomaticResume {
    [self startLocalPlayback];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    [self.manager pause];
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:AVAudioSessionInterruptionOptionShouldResume];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertEqual(self.engine.rate, 0.f);
}

- (void)testAlreadyPausedSongDoesNotResumeAfterInterruption {
    [self startLocalPlayback];
    [self.manager pause];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:AVAudioSessionInterruptionOptionShouldResume];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertEqual(self.engine.rate, 0.f);
}

- (void)testUnplugCancelsResumeAndReconnectDoesNotStartPlayback {
    [self startLocalPlayback];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center postNotificationName:AVAudioSessionRouteChangeNotification object:AVAudioSession.sharedInstance
                        userInfo:@{AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}];
    [self drainMainQueue];
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:AVAudioSessionInterruptionOptionShouldResume];
    [center postNotificationName:AVAudioSessionRouteChangeNotification object:AVAudioSession.sharedInstance
                        userInfo:@{AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonNewDeviceAvailable)}];
    [self drainMainQueue];
    XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertEqual(self.engine.rate, 0.f);
}

- (void)testMediaResetWaitsForUserThenRestoresPositionWithNewEngine {
    [self startLocalPlayback];
    [self.engine seekToTime:CMTimeMakeWithSeconds(1, 600)];
    [self waitFor:^BOOL{ return self.manager.currentTime >= 0.95; }];
    [self.manager pause];
    NSTimeInterval position = self.manager.currentTime;
    AVPlayer *oldEngine = self.engine;
    NLSong *song = self.manager.currentSong;
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionMediaServicesWereResetNotification object:AVAudioSession.sharedInstance];
    [self drainMainQueue];
    XCTAssertEqual(self.manager.currentSong, song);
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertNil(self.engine.currentItem);
    [self.manager play];
    [self waitFor:^BOOL{
        return self.engine != oldEngine && self.manager.playbackState == NLPlaybackStatePlaying && self.manager.currentTime >= position - 0.1;
    }];
}

- (void)testStopDuringInterruptionCannotBeResurrectedByEndNotification {
    [self startLocalPlayback];
    [self postInterruption:AVAudioSessionInterruptionTypeBegan options:0];
    [self.manager stop];
    [self postInterruption:AVAudioSessionInterruptionTypeEnded options:AVAudioSessionInterruptionOptionShouldResume];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStateIdle);
    XCTAssertNil(self.engine);
    XCTAssertNil(self.manager.currentSong);
}

- (void)testStopReleasesObservedItemAndCanStartFreshPlayback {
    __weak AVPlayerItem *oldItem;
    @autoreleasepool {
        [self startLocalPlayback];
        oldItem = self.engine.currentItem;
        [self.manager stop];
    }
    [self waitFor:^BOOL{ return oldItem == nil; }];
    [self startLocalPlayback];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePlaying);
    XCTAssertGreaterThan(self.manager.totalTime, 1.0);
}

- (void)testPausedSeekPublishesActualPositionToNowPlayingAndProgress {
    [self startLocalPlayback];
    [self.manager pause];
    __block double reportedProgress = -1;
    id subscription = [[self.manager valueForKey:@"progressSignal"] subscribeNext:^(NSNumber *value) {
        reportedProgress = value.doubleValue;
    }];
    NSTimeInterval target = self.manager.totalTime * 0.6;
    [self.manager seekToProgress:0.6];
    [self waitFor:^BOOL{
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        return fabs([info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] - target) < 0.1 &&
            fabs(reportedProgress - 0.6) < 0.02;
    }];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertEqual(self.engine.rate, 0.f);
    XCTAssertEqualObjects(MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate], @0);
    [subscription dispose];
}

- (void)testForegroundReconcilesStaleStateWithoutRestartingPausedEngine {
    [self startLocalPlayback];
    [self.manager pause];
    [self.engine seekToTime:CMTimeMakeWithSeconds(1, 600)];
    [self waitFor:^BOOL{ return self.manager.currentTime >= 0.95; }];
    // Model a stale UI snapshot while retaining the real paused engine and user intent.
    [self.manager setValue:@(NLPlaybackStatePlaying) forKey:@"playbackState"];
    __block double reportedProgress = -1;
    id subscription = [[self.manager valueForKey:@"progressSignal"] subscribeNext:^(NSNumber *value) {
        reportedProgress = value.doubleValue;
    }];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:UIApplication.sharedApplication];
    [self drainMainQueue];
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePaused);
    XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertEqual(self.engine.rate, 0.f);
    XCTAssertEqualWithAccuracy(reportedProgress, self.manager.currentTime / self.manager.totalTime, 0.02);
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    XCTAssertEqualObjects(info[MPNowPlayingInfoPropertyPlaybackRate], @0);
    XCTAssertEqualWithAccuracy([info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue], 1, 0.1);
    [subscription dispose];
}

- (void)testRouteLossDistinguishesBuiltInOutputFromPrivateExternalOutputs {
    [self startLocalPlayback];
    NLTestAudioPort *port = [NLTestAudioPort new];
    NLTestAudioRoute *route = [NLTestAudioRoute new];
    route.outputs = @[port];
    NSDictionary *info = @{
        AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonOldDeviceUnavailable),
        AVAudioSessionRouteChangePreviousRouteKey:route
    };
    port.portType = AVAudioSessionPortBuiltInSpeaker;
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionRouteChangeNotification
                                                     object:AVAudioSession.sharedInstance userInfo:info];
    [self drainMainQueue];
    XCTAssertTrue([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
    XCTAssertEqual(self.manager.playbackState, NLPlaybackStatePlaying);
    for (NSString *type in @[AVAudioSessionPortHeadphones, AVAudioSessionPortBluetoothA2DP,
                             AVAudioSessionPortBluetoothHFP, AVAudioSessionPortBluetoothLE]) {
        port.portType = type;
        [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionRouteChangeNotification
                                                         object:AVAudioSession.sharedInstance userInfo:info];
        [self drainMainQueue];
        XCTAssertFalse([[self.manager valueForKey:@"wantsToPlay"] boolValue]);
        XCTAssertEqual(self.engine.rate, 0.f);
        [self.manager play];
        [self waitFor:^BOOL{ return self.manager.playbackState == NLPlaybackStatePlaying; }];
    }
}
@end
