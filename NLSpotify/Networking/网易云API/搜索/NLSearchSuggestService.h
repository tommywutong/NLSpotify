//
//  NLSearchSuggestService.h
//  NLSpotify
//
//  Created by Cursor on 2026/3/6.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NLSearchType) {
    NLSearchTypeSong = 1,
    NLSearchTypeArtist = 100,
    NLSearchTypePlaylist = 1000,
    NLSearchTypeLyric = 1006,
    NLSearchTypeRadio = 1009,
};

@interface NLSearchSuggestService : NSObject

/// 搜索歌曲、歌单、艺人、歌词或电台。结果项为 NSDictionary，回调在主线程执行。
+ (void)searchWithKeywords:(NSString *)keywords
                      type:(NLSearchType)type
                    offset:(NSUInteger)offset
                     limit:(NSUInteger)limit
                   success:(void (^)(NSArray<NSDictionary *> *items, BOOL hasMore))success
                   failure:(void (^)(NSError *error))failure;

+ (NSArray<NSDictionary *> *)songsFromSearchResponse:(id)responseObject;
+ (NSArray<NSDictionary *> *)playlistsFromSearchResponse:(id)responseObject;
+ (NSArray<NSDictionary *> *)artistsFromSearchResponse:(id)responseObject;
+ (NSArray<NSDictionary *> *)radiosFromResponse:(id)responseObject;
+ (BOOL)hasMoreFromResponse:(id)responseObject type:(NLSearchType)type;

/// /search/suggest?keywords=xxx&type=mobile
+ (void)fetchSuggestWithKeywords:(NSString *)keywords
                      useMobile:(BOOL)useMobile
                        success:(void(^)(NSDictionary *responseObject))success
                        failure:(void(^)(NSError *error))failure;

@end

NS_ASSUME_NONNULL_END
