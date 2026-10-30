#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import "NLCacheManager.h"
#import "NLAudioMemoryCache.h"

@interface NLResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
@property(nonatomic,strong) NSURL *originURL;
@property(nonatomic,copy) NSString *cacheKey;
@property(nonatomic,strong) NLCacheManager *cacheManager;
- (void)invalidateAndCancelAll;
@end
@interface NLCacheManager (HTTPTesting)
- (instancetype)initWithCacheDirectory:(NSString *)path reconciliationBlock:(void (^)(NLCacheManager *))block;
@end

@interface NLHTTPFixture : NSObject
@property(nonatomic) int socketFD;
@property(nonatomic) uint16_t port;
@property(nonatomic,copy) NSData *body;
@property(nonatomic,strong) NSMutableArray<NSString *> *requests;
- (void)stop;
- (NSURL *)URLForMode:(NSString *)mode;
@end
@implementation NLHTTPFixture
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (_socketFD < 0) return nil;
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address); address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(_socketFD, (void *)&address, sizeof(address)) || listen(_socketFD, 16)) { close(_socketFD); return nil; }
    socklen_t length = sizeof(address); getsockname(_socketFD, (void *)&address, &length); _port = ntohs(address.sin_port);
    _requests = [NSMutableArray array];
    int listener = _socketFD;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            int fd = accept(listener, NULL, NULL);
            if (fd < 0) break;
            int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            struct timeval timeout = {3, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [weakSelf respond:fd]; close(fd);
            });
        }
    });
    return self;
}
- (void)stop { if (_socketFD >= 0) { shutdown(_socketFD, SHUT_RDWR); close(_socketFD); _socketFD = -1; } }
- (void)dealloc { [self stop]; }
- (NSURL *)URLForMode:(NSString *)mode { return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/%@.mp3", self.port, mode]]; }
- (void)respond:(int)fd {
    NSMutableData *headerData = [NSMutableData data];
    char buffer[4096];
    while (headerData.length < 32768) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0); if (n <= 0) return;
        [headerData appendBytes:buffer length:(NSUInteger)n];
        if ([[[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] containsString:@"\r\n\r\n"]) break;
    }
    NSString *request = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    NSString *path = [[request componentsSeparatedByString:@" "] objectAtIndex:1];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"Range: bytes=([0-9]+)-([0-9]*)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:request options:0 range:NSMakeRange(0, request.length)];
    NSUInteger start = match ? [[request substringWithRange:[match rangeAtIndex:1]] integerValue] : 0;
    NSString *last = match ? [request substringWithRange:[match rangeAtIndex:2]] : @"";
    NSData *body = self.body;
    NSUInteger end = last.length ? MIN(last.integerValue, body.length - 1) : body.length - 1;
    @synchronized(self) { [self.requests addObject:[NSString stringWithFormat:@"%@:%lu-%lu", path, (unsigned long)start, (unsigned long)end]]; }
    NSInteger status = match ? 206 : 200;
    if ([path containsString:@"full"]) { status = 200; start = 0; end = body.length - 1; }
    NSString *header; NSData *data = nil;
    if ([path containsString:@"redirect"]) header = [NSString stringWithFormat:@"HTTP/1.1 302 Found\r\nLocation: %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", [self URLForMode:@"normal"].absoluteString];
    else if (start >= body.length || end < start) header = @"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    else {
        NSUInteger responseStart = [path containsString:@"wrong"] ? start + 1 : start;
        NSUInteger responseEnd = [path containsString:@"extra"] ? MIN(end + 1, body.length - 1) : end;
        data = [body subdataWithRange:NSMakeRange(start, responseEnd - start + 1)];
        NSString *range = status == 206 ? [NSString stringWithFormat:@"Content-Range: bytes %lu-%lu/%lu\r\n", (unsigned long)responseStart, (unsigned long)responseEnd, (unsigned long)body.length] : @"";
        header = [NSString stringWithFormat:@"HTTP/1.1 %ld OK\r\nContent-Type: audio/mpeg\r\nContent-Length: %lu\r\n%@Connection: close\r\n\r\n", (long)status, (unsigned long)data.length, range];
        if ([path containsString:@"short"]) data = [data subdataWithRange:NSMakeRange(0, data.length / 2)];
    }
    NSData *headers = [header dataUsingEncoding:NSUTF8StringEncoding]; send(fd, headers.bytes, headers.length, 0);
    const char *bytes = data.bytes; NSUInteger sent = 0;
    while (sent < data.length) {
        NSUInteger chunk = [path containsString:@"slow"] ? MIN((NSUInteger)1024, data.length - sent) : data.length - sent;
        ssize_t n = send(fd, bytes + sent, chunk, 0); if (n <= 0) break; sent += n;
        if ([path containsString:@"slow"]) usleep(30000);
    }
}
@end

@interface NLHTTPDataRequest : NSObject
@property(nonatomic) long long requestedOffset;
@property(nonatomic) NSInteger requestedLength;
@property(nonatomic) long long currentOffset;
@property(nonatomic) BOOL requestsAllDataToEndOfResource;
@property(nonatomic,strong) NSMutableData *data;
@end
@implementation NLHTTPDataRequest
- (void)respondWithData:(NSData *)data { [self.data appendData:data]; self.currentOffset += data.length; }
@end
@interface NLHTTPInformation : NSObject
@property(nonatomic) long long contentLength;
@property(nonatomic,copy) NSString *contentType;
@property(nonatomic) BOOL byteRangeAccessSupported;
@end
@implementation NLHTTPInformation @end
@interface NLHTTPLoadingRequest : NSObject
@property(nonatomic,strong) NSURLRequest *request;
@property(nonatomic,strong) NLHTTPDataRequest *dataRequest;
@property(nonatomic,strong) NLHTTPInformation *contentInformationRequest;
@property(atomic) BOOL finished;
@property(atomic,strong) NSError *error;
@end
@implementation NLHTTPLoadingRequest
- (void)finishLoading { self.finished = YES; }
- (void)finishLoadingWithError:(NSError *)error { self.error = error; self.finished = YES; }
@end

@interface NLResourceLoaderIntegrationTests : XCTestCase
@property(nonatomic,strong) NLHTTPFixture *server;
@property(nonatomic,strong) NLCacheManager *cache;
@property(nonatomic,strong) NLResourceLoader *loader;
@property(nonatomic,strong) AVURLAsset *asset;
@property(nonatomic,copy) NSString *directory;
@end
@implementation NLResourceLoaderIntegrationTests
- (void)setUp {
    [super setUp]; self.server = [NLHTTPFixture new]; XCTAssertNotNil(self.server);
    self.server.body = [NSData dataWithContentsOfURL:[[NSBundle bundleForClass:self.class] URLForResource:@"range-fixture" withExtension:@"mp3"]];
    XCTAssertGreaterThan(self.server.body.length, 1000u);
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    self.cache = [[NLCacheManager alloc] initWithCacheDirectory:self.directory reconciliationBlock:nil];
    self.loader = [NLResourceLoader new]; self.loader.cacheManager = self.cache;
    self.loader.cacheKey = NSUUID.UUID.UUIDString;
}
- (void)tearDown {
    [self.loader invalidateAndCancelAll]; [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
    [super tearDown];
}
- (BOOL)until:(BOOL (^)(void))predicate timeout:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!predicate() && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return predicate();
}
- (AVAssetResourceLoader *)resourceLoader {
    self.asset = [AVURLAsset URLAssetWithURL:self.loader.originURL options:nil];
    return self.asset.resourceLoader;
}
- (NLHTTPLoadingRequest *)request:(NSString *)mode offset:(NSUInteger)offset length:(NSUInteger)length {
    self.loader.originURL = [self.server URLForMode:mode];
    NLHTTPLoadingRequest *request = [NLHTTPLoadingRequest new];
    NSURLComponents *parts = [NSURLComponents componentsWithURL:self.loader.originURL resolvingAgainstBaseURL:NO]; parts.scheme = @"streaming";
    request.request = [NSURLRequest requestWithURL:parts.URL]; request.contentInformationRequest = [NLHTTPInformation new];
    request.dataRequest = [NLHTTPDataRequest new]; request.dataRequest.requestedOffset = offset; request.dataRequest.currentOffset = offset; request.dataRequest.requestedLength = length; request.dataRequest.data = [NSMutableData data];
    return request;
}
- (void)runRequest:(NLHTTPLoadingRequest *)request {
    [self.loader resourceLoader:[self resourceLoader] shouldWaitForLoadingOfRequestedResource:(id)request];
    XCTAssertTrue([self until:^BOOL{ return request.finished; } timeout:8]);
}
- (void)test206DeliversExactRequestedBytesAndUTI {
    NLHTTPLoadingRequest *r = [self request:@"normal" offset:100 length:300]; [self runRequest:r];
    XCTAssertNil(r.error); XCTAssertEqualObjects(r.dataRequest.data, [self.server.body subdataWithRange:NSMakeRange(100, 300)]);
    XCTAssertEqualObjects(r.contentInformationRequest.contentType, @"public.mp3");
}
- (void)testRedirectPreservesExactRange {
    NLHTTPLoadingRequest *r = [self request:@"redirect" offset:40 length:100]; [self runRequest:r];
    XCTAssertNil(r.error); XCTAssertEqualObjects(r.dataRequest.data, [self.server.body subdataWithRange:NSMakeRange(40, 100)]);
}
- (void)test200AtZeroDeliversOnlyRequestedPrefix {
    NLHTTPLoadingRequest *r = [self request:@"full" offset:0 length:100]; [self runRequest:r];
    XCTAssertNil(r.error); XCTAssertEqualObjects(r.dataRequest.data, [self.server.body subdataWithRange:NSMakeRange(0, 100)]);
}
- (void)test200AtNonzeroOffsetIsRejected {
    NLHTTPLoadingRequest *r = [self request:@"full" offset:50 length:100]; [self runRequest:r]; XCTAssertNotNil(r.error); XCTAssertEqual(r.dataRequest.data.length, 0u);
}
- (void)testWrongRangeIsRejectedBeforeBytesAreServed {
    NLHTTPLoadingRequest *r = [self request:@"wrong" offset:50 length:100]; [self runRequest:r]; XCTAssertNotNil(r.error); XCTAssertEqual(r.dataRequest.data.length, 0u);
}
- (void)testOversizedRangeIsRejected {
    NLHTTPLoadingRequest *r = [self request:@"extra" offset:50 length:100]; [self runRequest:r]; XCTAssertNotNil(r.error); XCTAssertEqual(r.dataRequest.data.length, 0u);
}
- (void)testTruncatedConnectionNeverReportsCompleteCache {
    NLHTTPLoadingRequest *r = [self request:@"short" offset:0 length:self.server.body.length]; [self runRequest:r];
    XCTAssertNotNil(r.error); XCTAssertFalse([self.cache isFullyCachedForURL:self.loader.originURL cacheKey:self.loader.cacheKey]);
}
- (void)testRequestBeyondEOFCompletesAtResourceEnd {
    NLHTTPLoadingRequest *r = [self request:@"normal" offset:self.server.body.length - 100 length:1000]; [self runRequest:r];
    XCTAssertNil(r.error); XCTAssertEqualObjects(r.dataRequest.data, [self.server.body subdataWithRange:NSMakeRange(self.server.body.length - 100, 100)]);
}
- (void)testContentInformationOnlyRequestSucceeds {
    NLHTTPLoadingRequest *r = [self request:@"normal" offset:0 length:2]; r.dataRequest = nil; [self runRequest:r];
    XCTAssertNil(r.error); XCTAssertEqual(r.contentInformationRequest.contentLength, self.server.body.length);
}
- (void)testCancellationKeepsOnlySuccessfulWrittenRanges {
    NLHTTPLoadingRequest *r = [self request:@"slow" offset:0 length:self.server.body.length];
    [self.loader resourceLoader:[self resourceLoader] shouldWaitForLoadingOfRequestedResource:(id)r];
    XCTAssertTrue([self until:^BOOL{ return r.dataRequest.data.length >= 1024; } timeout:5]);
    [self.loader resourceLoader:[self resourceLoader] didCancelLoadingRequest:(id)r];
    XCTAssertTrue([self until:^BOOL{ return [self.cache cachedRangesForURL:self.loader.originURL cacheKey:self.loader.cacheKey].count > 0; } timeout:5]);
    XCTAssertFalse([self.cache isFullyCachedForURL:self.loader.originURL cacheKey:self.loader.cacheKey]);
    for (NSValue *v in [self.cache cachedRangesForURL:self.loader.originURL cacheKey:self.loader.cacheKey]) XCTAssertLessThanOrEqual(NSMaxRange(v.rangeValue), r.dataRequest.data.length);
}
- (void)testRealMP3PlaysSeeksAndReplaysFromLocalFile {
    self.loader.originURL = [self.server URLForMode:@"normal"];
    NSURLComponents *parts = [NSURLComponents componentsWithURL:self.loader.originURL resolvingAgainstBaseURL:NO]; parts.scheme = @"streaming";
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:parts.URL options:nil];
    [asset.resourceLoader setDelegate:self.loader queue:dispatch_queue_create("test.loader", DISPATCH_QUEUE_SERIAL)];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset]; AVPlayer *player = [AVPlayer playerWithPlayerItem:item]; player.muted = YES; [player play];
    XCTAssertTrue([self until:^BOOL{ return CMTimeGetSeconds(player.currentTime) > 0.2 || item.status == AVPlayerItemStatusFailed; } timeout:15]);
    XCTAssertNil(item.error); XCTAssertGreaterThan(CMTimeGetSeconds(player.currentTime), 0.2);
    __block BOOL seeked = NO; [player seekToTime:CMTimeMakeWithSeconds(2, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) { seeked = finished; }];
    XCTAssertTrue([self until:^BOOL{ return seeked && CMTimeGetSeconds(player.currentTime) >= 1.9; } timeout:5]); [player pause]; [player replaceCurrentItemWithPlayerItem:nil];
    NSURL *file = [[NSBundle bundleForClass:self.class] URLForResource:@"range-fixture" withExtension:@"mp3"];
    AVPlayer *offline = [AVPlayer playerWithURL:file]; offline.muted = YES; [self.server stop]; [offline play];
    XCTAssertTrue([self until:^BOOL{ return CMTimeGetSeconds(offline.currentTime) > 0.2; } timeout:5]); [offline pause]; [offline replaceCurrentItemWithPlayerItem:nil];
}
@end
