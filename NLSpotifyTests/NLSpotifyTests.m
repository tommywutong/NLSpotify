//
//  NLSpotifyTests.m
//  NLSpotifyTests
//
//  Created by 吴桐 on 2025/12/6.
//

#import <XCTest/XCTest.h>
#import "NLSearchSuggestService.h"

@interface NLSpotifyTests : XCTestCase
@end

@interface NLSearchSuggestService (ContentDiscoveryTesting)
+ (NSArray *)songsFromSearchResponse:(id)responseObject;
+ (NSArray *)playlistsFromSearchResponse:(id)responseObject;
+ (NSArray *)artistsFromSearchResponse:(id)responseObject;
+ (NSArray *)radiosFromResponse:(id)responseObject;
+ (BOOL)hasMoreFromResponse:(id)responseObject type:(NSInteger)type;
@end

@implementation NLSpotifyTests
- (void)testSearchServiceParsesSongAndUsesPlaceholderForMissingCover {
    NSDictionary *response = @{
        @"result": @{
            @"songs": @[@{
                @"id": @123,
                @"name": @"那时雨",
                @"duration": @214400,
                @"artists": @[@{@"id": @5929, @"name": @"徐良"}],
                @"album": @{@"id": @2449015, @"name": @"情话"}
            }]
        }
    };
    NSArray *songs = [NLSearchSuggestService songsFromSearchResponse:response];
    XCTAssertEqual(songs.count, 1u);
    NSDictionary *song = songs.firstObject;
    XCTAssertEqualObjects(song[@"songId"], @"123");
    XCTAssertEqualObjects(song[@"title"], @"那时雨");
    XCTAssertEqualObjects(song[@"artist"], @"徐良");
    XCTAssertEqualObjects(song[@"coverURL"], [NSNull null]);
}

- (void)testSearchServiceParsesPlaylistArtistAndRadioItems {
    NSDictionary *response = @{
        @"result": @{
            @"playlists": @[@{@"id": @1, @"name": @"歌单", @"coverImgUrl": @"https://cover", @"trackCount": @9}],
            @"artists": @[@{@"id": @2, @"name": @"艺人", @"picUrl": @"https://artist"}],
            @"djRadios": @[@{@"id": @3, @"name": @"电台", @"picUrl": @"https://radio", @"category": @"情感"}]
        }
    };
    XCTAssertEqual([NLSearchSuggestService playlistsFromSearchResponse:response].count, 1u);
    XCTAssertEqualObjects([NLSearchSuggestService artistsFromSearchResponse:response].firstObject[@"artistId"], @"2");
    XCTAssertEqualObjects([NLSearchSuggestService radiosFromResponse:response].firstObject[@"radioId"], @"3");
}

- (void)testSearchServiceInvalidResponseIsEmptyAndHasMoreReadsFlag {
    XCTAssertEqual([NLSearchSuggestService songsFromSearchResponse:@[]].count, 0u);
    NSDictionary *response = @{@"result": @{@"hasMore": @YES}};
    XCTAssertTrue([NLSearchSuggestService hasMoreFromResponse:response type:1]);
    XCTAssertFalse([NLSearchSuggestService hasMoreFromResponse:@{} type:1]);
}
@end
