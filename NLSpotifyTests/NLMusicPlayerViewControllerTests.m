#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "NLMusicPlayerViewController.h"
#import "NLSongService.h"

@interface NLPlayerManager : NSObject
+ (instancetype)sharedManager;
@end

@interface RACSubject<__covariant ObjectType> : NSObject
- (void)sendNext:(ObjectType)value;
@end

@interface NLMusicPlayerViewController (PlayerBindingTesting)
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)showLyricView:(BOOL)show;
- (void)musicPlayerViewDidTapCover:(id)view;
@end

@interface NLDeferredLyricService : NLSongService
@property (nonatomic, strong) NSMutableArray *successCallbacks;
@property (nonatomic, strong) NSMutableArray *failureCallbacks;
@end

@implementation NLDeferredLyricService

- (void)fetchLyricWithSongId:(NSString *)songId
                     success:(SongLyricFetchSuccess)success
                     failure:(SongFetchFailure)failure {
    if (!self.successCallbacks) self.successCallbacks = [NSMutableArray array];
    if (!self.failureCallbacks) self.failureCallbacks = [NSMutableArray array];
    [self.successCallbacks addObject:[success copy]];
    [self.failureCallbacks addObject:[failure copy]];
}

@end

static NLSongService *NLServiceForControllerTest;

static id NLControllerTestSharedService(id receiver, SEL selector) {
    return NLServiceForControllerTest;
}

@interface NLMusicPlayerViewControllerTests : XCTestCase
@property (nonatomic, strong) NLPlayerManager *manager;
@property (nonatomic, strong) NLSong *previousSong;
@property (nonatomic, strong) RACSubject<NLSong *> *songSubject;
@property (nonatomic, strong) id previousSongSubject;
@property (nonatomic, strong) id previousSongSignal;
@property (nonatomic, strong) NLDeferredLyricService *service;
@property (nonatomic, strong) NLMusicPlayerViewController *controller;
@property (nonatomic, assign) Method sharedServiceMethod;
@property (nonatomic, assign) IMP originalSharedServiceImplementation;
@end

@implementation NLMusicPlayerViewControllerTests

- (void)setUp {
    [super setUp];
    self.manager = [NLPlayerManager sharedManager];
    self.previousSong = [self.manager valueForKey:@"currentSong"];
    self.previousSongSubject = [self.manager valueForKey:@"songSubject"];
    self.previousSongSignal = [self.manager valueForKey:@"songSignal"];
    self.songSubject = [RACSubject new];
    [self.manager setValue:self.songSubject forKey:@"songSubject"];
    [self.manager setValue:self.songSubject forKey:@"songSignal"];
    self.service = [[NLDeferredLyricService alloc] init];
    self.controller = [[NLMusicPlayerViewController alloc] init];

    NLServiceForControllerTest = self.service;
    self.sharedServiceMethod = class_getClassMethod(NLSongService.class, @selector(sharedService));
    self.originalSharedServiceImplementation = method_getImplementation(self.sharedServiceMethod);
    method_setImplementation(self.sharedServiceMethod, (IMP)NLControllerTestSharedService);

    [self.controller loadViewIfNeeded];
    [self.controller viewWillAppear:NO];
}

- (void)tearDown {
    method_setImplementation(self.sharedServiceMethod, self.originalSharedServiceImplementation);
    NLServiceForControllerTest = nil;
    self.controller = nil;
    [self.manager setValue:self.previousSong forKey:@"currentSong"];
    [self.manager setValue:self.previousSongSubject forKey:@"songSubject"];
    [self.manager setValue:self.previousSongSignal forKey:@"songSignal"];
    [super tearDown];
}

- (void)publishSongWithID:(NSString *)songID {
    NLSong *song = [[NLSong alloc] init];
    song.songId = songID;
    song.title = songID;
    [self.manager setValue:song forKey:@"currentSong"];
    [self.songSubject sendNext:song];
}

- (void)drainMainQueue {
    XCTestExpectation *mainQueueDrained = [self expectationWithDescription:@"lyric callback processed on main queue"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [mainQueueDrained fulfill];
    });
    [self waitForExpectations:@[mainQueueDrained] timeout:2.0];
}

- (BOOL)view:(UIView *)view containsLabelWithText:(NSString *)text {
    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:text]) return YES;
    for (UIView *subview in view.subviews) {
        if ([self view:subview containsLabelWithText:text]) return YES;
    }
    return NO;
}

- (void)testStaleManualLyricResponseCannotReplaceCurrentSong {
    [self publishSongWithID:@"old-song"];
    [self.controller musicPlayerViewDidTapCover:nil];
    XCTAssertEqual(self.service.successCallbacks.count, 1u);

    [self publishSongWithID:@"current-song"];
    SongLyricFetchSuccess oldResponse = self.service.successCallbacks[0];
    oldResponse(@"[00:01.00]stale lyric");
    [self drainMainQueue];

    XCTAssertEqualObjects([self.controller valueForKey:@"currentLyricSongId"], @"current-song");
    XCTAssertEqual(((NSArray *)[self.controller valueForKey:@"lyricLines"]).count, 0u);
    XCTAssertFalse([[self.controller valueForKey:@"lyricVisible"] boolValue]);
}

- (void)testOlderManualLyricResponseCannotReplaceNewerRequestForSameSong {
    [self publishSongWithID:@"same-song"];
    [self.controller musicPlayerViewDidTapCover:nil];
    [self.controller musicPlayerViewDidTapCover:nil];
    XCTAssertEqual(self.service.successCallbacks.count, 2u);

    SongLyricFetchSuccess oldResponse = self.service.successCallbacks[0];
    oldResponse(@"[00:01.00]old response");
    [self drainMainQueue];
    XCTAssertEqual(((NSArray *)[self.controller valueForKey:@"lyricLines"]).count, 0u);

    SongLyricFetchSuccess currentResponse = self.service.successCallbacks[1];
    currentResponse(@"[00:02.00]current response");
    [self drainMainQueue];
    NSArray *lines = [self.controller valueForKey:@"lyricLines"];
    XCTAssertEqual(lines.count, 1u);
    XCTAssertEqualObjects([lines.firstObject valueForKey:@"text"], @"current response");
}

- (void)testAutomaticLyricResponseAfterPanelClosesIsIgnored {
    [self.controller showLyricView:YES];
    [self publishSongWithID:@"automatic-song"];
    XCTAssertEqual(self.service.successCallbacks.count, 1u);

    [self.controller showLyricView:NO];
    SongLyricFetchSuccess response = self.service.successCallbacks[0];
    response(@"[00:01.00]stale lyric");
    [self drainMainQueue];

    XCTAssertEqual(((NSArray *)[self.controller valueForKey:@"lyricLines"]).count, 0u);
    XCTAssertFalse([[self.controller valueForKey:@"lyricVisible"] boolValue]);
}

- (void)testManualLyricResponseAfterPlayerPageDisappearsIsIgnored {
    [self publishSongWithID:@"dismissed-song"];
    [self.controller musicPlayerViewDidTapCover:nil];
    XCTAssertEqual(self.service.successCallbacks.count, 1u);

    [self.controller viewWillDisappear:NO];
    SongLyricFetchSuccess response = self.service.successCallbacks[0];
    response(@"[00:01.00]stale lyric");
    [self drainMainQueue];

    XCTAssertEqual(((NSArray *)[self.controller valueForKey:@"lyricLines"]).count, 0u);
    XCTAssertFalse([[self.controller valueForKey:@"lyricVisible"] boolValue]);
}

- (void)testStaleManualLyricFailureDoesNotShowToast {
    [self publishSongWithID:@"same-song"];
    [self.controller musicPlayerViewDidTapCover:nil];
    [self.controller musicPlayerViewDidTapCover:nil];
    XCTAssertEqual(self.service.failureCallbacks.count, 2u);

    SongFetchFailure oldFailure = self.service.failureCallbacks[0];
    oldFailure([NSError errorWithDomain:@"test" code:1 userInfo:nil]);
    [self drainMainQueue];

    XCTAssertFalse([self view:self.controller.view containsLabelWithText:@"歌词加载失败"]);
}

@end
