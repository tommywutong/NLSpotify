//
//  NLSearchSuggestService.m
//  NLSpotify
//
//  Created by Cursor on 2026/3/6.
//

#import "NLSearchSuggestService.h"
#import "NetWorkManager.h"

@implementation NLSearchSuggestService

+ (NSArray<NSDictionary *> *)itemsForResponse:(id)response key:(NSString *)key {
    if (![response isKindOfClass:NSDictionary.class]) return @[];
    id result = response[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) return @[];
    id items = result[key];
    return [items isKindOfClass:NSArray.class] ? items : @[];
}

+ (NSArray<NSDictionary *> *)songsFromSearchResponse:(id)responseObject {
    NSMutableArray *songs = [NSMutableArray array];
    for (NSDictionary *raw in [self itemsForResponse:responseObject key:@"songs"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *artist = [raw[@"artists"] isKindOfClass:NSArray.class] ? [raw[@"artists"] firstObject] : nil;
        NSDictionary *album = [raw[@"album"] isKindOfClass:NSDictionary.class] ? raw[@"album"] : nil;
        [songs addObject:@{
            @"songId": [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""],
            @"title": raw[@"name"] ?: @"",
            @"artist": artist[@"name"] ?: @"",
            @"artistId": [NSString stringWithFormat:@"%@", artist[@"id"] ?: @""],
            @"albumId": [NSString stringWithFormat:@"%@", album[@"id"] ?: @""],
            @"albumName": album[@"name"] ?: @"",
            @"duration": raw[@"duration"] ?: @0,
            @"coverURL": album[@"picUrl"] ?: [NSNull null]
        }];
    }
    return songs;
}

+ (NSArray<NSDictionary *> *)playlistsFromSearchResponse:(id)responseObject {
    return [self itemsForResponse:responseObject key:@"playlists"];
}

+ (NSArray<NSDictionary *> *)artistsFromSearchResponse:(id)responseObject {
    NSMutableArray *artists = [NSMutableArray array];
    for (NSDictionary *raw in [self itemsForResponse:responseObject key:@"artists"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        [artists addObject:@{
            @"artistId": [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""],
            @"name": raw[@"name"] ?: @"",
            @"picUrl": raw[@"picUrl"] ?: [NSNull null],
            @"albumSize": raw[@"albumSize"] ?: @0,
            @"musicSize": raw[@"musicSize"] ?: @0
        }];
    }
    return artists;
}

+ (NSArray<NSDictionary *> *)radiosFromResponse:(id)responseObject {
    NSMutableArray *radios = [NSMutableArray array];
    for (NSDictionary *raw in [self itemsForResponse:responseObject key:@"djRadios"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        [radios addObject:@{
            @"radioId": [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""],
            @"name": raw[@"name"] ?: @"",
            @"picUrl": raw[@"picUrl"] ?: [NSNull null],
            @"category": raw[@"category"] ?: @"",
            @"programCount": raw[@"programCount"] ?: @0
        }];
    }
    return radios;
}

+ (BOOL)hasMoreFromResponse:(id)responseObject type:(NLSearchType)type {
    if (![responseObject isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *result = responseObject[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) return NO;
    if ([result[@"hasMore"] respondsToSelector:@selector(boolValue)]) return [result[@"hasMore"] boolValue];
    NSString *countKey = type == NLSearchTypeArtist ? @"artistCount" : (type == NLSearchTypePlaylist ? @"playlistCount" : @"songCount");
    return [result[countKey] integerValue] > 0;
}

+ (void)searchWithKeywords:(NSString *)keywords
                      type:(NLSearchType)type
                    offset:(NSUInteger)offset
                     limit:(NSUInteger)limit
                   success:(void (^)(NSArray<NSDictionary *> *, BOOL))success
                   failure:(void (^)(NSError *))failure {
    NSString *trimmed = [keywords stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (success) success(@[], NO); });
        return;
    }
    NSDictionary *params = @{ @"keywords": trimmed, @"type": @(type), @"offset": @(offset), @"limit": @(limit ?: 20) };
    [[NetWorkManager sharedManager] GET:@"/search" parameters:params success:^(id responseObject) {
        NSArray *items = type == NLSearchTypeSong || type == NLSearchTypeLyric ? [self songsFromSearchResponse:responseObject] :
                         type == NLSearchTypePlaylist ? [self playlistsFromSearchResponse:responseObject] :
                         type == NLSearchTypeArtist ? [self artistsFromSearchResponse:responseObject] : [self radiosFromResponse:responseObject];
        BOOL hasMore = [self hasMoreFromResponse:responseObject type:type];
        dispatch_async(dispatch_get_main_queue(), ^{ if (success) success(items, hasMore); });
    } failure:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (failure) failure(error); });
    }];
}

+ (void)fetchSuggestWithKeywords:(NSString *)keywords
                      useMobile:(BOOL)useMobile
                        success:(void(^)(NSDictionary *))success
                        failure:(void(^)(NSError *))failure {
    if (keywords.length == 0) { if (success) success(@{ @"code": @200, @"result": @{} }); return; }
    NSMutableDictionary *params = [@{ @"keywords": keywords } mutableCopy];
    if (useMobile) params[@"type"] = @"mobile";
    [[NetWorkManager sharedManager] GET:@"/search/suggest" parameters:params success:^(id responseObject) {
        if (![responseObject isKindOfClass:NSDictionary.class]) {
            if (failure) failure([NSError errorWithDomain:@"NLSearchSuggestService" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"返回数据格式错误"}]);
            return;
        }
        if (success) success(responseObject);
    } failure:failure];
}

@end
