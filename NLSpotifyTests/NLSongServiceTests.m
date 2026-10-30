#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "NLSongService.h"

@interface NLStubNetworkManager : NetWorkManager
@property (nonatomic, strong) id responseObject;
@end

@implementation NLStubNetworkManager

- (void)GET:(NSString *)url
 parameters:(NSDictionary *)params
    success:(SuccessBlock)success
    failure:(FailureBlock)failure {
    success(self.responseObject);
}

@end

static NLStubNetworkManager *NLNetworkManagerForSongServiceTest;

static id NLStubNetworkManagerSharedManager(id receiver, SEL selector) {
    return NLNetworkManagerForSongServiceTest;
}

@interface NLSongServiceTests : XCTestCase
@property (nonatomic, strong) NLStubNetworkManager *networkManager;
@property (nonatomic, assign) IMP originalSharedManagerImplementation;
@property (nonatomic, assign) Method sharedManagerMethod;
@end

@implementation NLSongServiceTests

- (void)setUp {
    [super setUp];
    self.networkManager = [[NLStubNetworkManager alloc] init];
    NLNetworkManagerForSongServiceTest = self.networkManager;
    self.sharedManagerMethod = class_getClassMethod(NetWorkManager.class, @selector(sharedManager));
    self.originalSharedManagerImplementation = method_getImplementation(self.sharedManagerMethod);
    method_setImplementation(self.sharedManagerMethod, (IMP)NLStubNetworkManagerSharedManager);
}

- (void)tearDown {
    method_setImplementation(self.sharedManagerMethod, self.originalSharedManagerImplementation);
    NLNetworkManagerForSongServiceTest = nil;
    [super tearDown];
}

- (void)testMissingPlayableURLReturnsFailureWithoutConstructingFallback {
    self.networkManager.responseObject = @{@"data": @[]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedURL);
    XCTAssertNotNil(receivedError);
    XCTAssertEqualObjects(receivedError.domain, @"NLSongService");
    XCTAssertNotEqual(receivedError.code, 0);
}

- (void)testNonHTTPSPlayableURLIsRejected {
    self.networkManager.responseObject = @{@"data": @[@{@"url": @"ftp://music.example.com/track.mp3"}]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedURL);
    XCTAssertNotNil(receivedError);
}

- (void)testNonStringPlayableURLIsRejected {
    self.networkManager.responseObject = @{@"data": @[@{@"url": @123}]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedURL);
    XCTAssertNotNil(receivedError);
}

- (void)testMalformedPlayableURLReturnsFailure {
    self.networkManager.responseObject = @{@"data": @[@{@"url": @"not a URL"}]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedURL);
    XCTAssertNotNil(receivedError);
}

- (void)testHTTPPlayableURLIsAccepted {
    NSString *expected = @"http://music.example.com/track.mp3";
    self.networkManager.responseObject = @{@"data": @[@{@"url": expected}]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedError);
    XCTAssertEqualObjects(receivedURL.absoluteString, expected);
}

- (void)testHTTPSPlayableURLWhosePathContains403IsAccepted {
    NSString *expected = @"https://music.example.com/audio/403-version.mp3";
    self.networkManager.responseObject = @{@"data": @[@{@"url": expected}]};
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedError);
    XCTAssertEqualObjects(receivedURL.absoluteString, expected);
}

- (void)testNonDictionaryResponseReturnsFailure {
    self.networkManager.responseObject = @[@"unexpected"];
    __block NSURL *receivedURL = nil;
    __block NSError *receivedError = nil;

    [[NLSongService sharedService] fetchPlayableURLWithSongId:@"123"
        success:^(NSURL *playURL) { receivedURL = playURL; }
        failure:^(NSError *error) { receivedError = error; }];

    XCTAssertNil(receivedURL);
    XCTAssertNotNil(receivedError);
}

@end
