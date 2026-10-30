#import <XCTest/XCTest.h>
#import "NLAudioMemoryCache.h"

@interface NLAudioMemoryCacheTests : XCTestCase
@property (nonatomic, strong) NLAudioMemoryCache *cache;
@property (nonatomic, strong) NSURL *url;
@end

@implementation NLAudioMemoryCacheTests

- (void)setUp {
    [super setUp];
    self.cache = NLAudioMemoryCache.sharedCache;
    [self.cache removeAllData];
    self.url = [NSURL URLWithString:@"https://example.com/audio.mp3"];
}

- (void)tearDown {
    [self.cache removeAllData];
    [super tearDown];
}

- (void)testReturnsStoredSegmentForExactRange {
    NSData *data = [@"abcdef" dataUsingEncoding:NSUTF8StringEncoding];
    [self.cache storeData:data forURL:self.url atOffset:100];

    XCTAssertEqualObjects([self.cache dataForURL:self.url offset:100 length:6], data);
}

- (void)testReturnsContiguousPrefixWithoutCrossingGap {
    [self.cache storeData:[@"abcdef" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:100];
    [self.cache storeData:[@"ghij" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:110];

    NSData *result = [self.cache dataForURL:self.url offset:102 length:12];

    XCTAssertEqualObjects(result, [@"cdef" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testFindsNextStoredOffsetAfterMemoryGap {
    [self.cache storeData:[@"abcdef" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:100];
    [self.cache storeData:[@"ghij" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:110];

    XCTAssertEqual([self.cache nextCachedOffsetForURL:self.url afterOffset:106], 110);
}

- (void)testOverlappingWritePreservesExistingBytesOutsideReplacement {
    [self.cache storeData:[@"abcdefghij" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:100];
    [self.cache storeData:[@"WXYZ" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:103];

    NSData *result = [self.cache dataForURL:self.url offset:100 length:10];

    XCTAssertEqualObjects(result, [@"abcWXYZhij" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testRemovingURLRemovesAllItsSegments {
    [self.cache storeData:[@"abcdef" dataUsingEncoding:NSUTF8StringEncoding] forURL:self.url atOffset:100];

    [self.cache removeDataForURL:self.url];

    XCTAssertNil([self.cache dataForURL:self.url offset:100 length:1]);
}

- (void)testStableIdentityReusesSegmentsAcrossSignedURLs {
    NSURL *first = [NSURL URLWithString:@"https://cdn.example.com/audio.mp3?token=first"];
    NSURL *refreshed = [NSURL URLWithString:@"https://cdn.example.com/audio.mp3?token=second"];
    [self.cache storeData:[@"abcdef" dataUsingEncoding:NSUTF8StringEncoding] cacheKey:@"song-1\ncdn.example.com/audio.mp3" atOffset:42];

    XCTAssertEqualObjects([self.cache dataForCacheKey:@"song-1\ncdn.example.com/audio.mp3" offset:42 length:6], [@"abcdef" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertNil([self.cache dataForCacheKey:@"song-1\ncdn.example.com/audio-lossless.mp3" offset:42 length:1]);
    XCTAssertEqualObjects(first.host, refreshed.host);
}

@end
