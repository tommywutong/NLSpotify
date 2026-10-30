//
//  NLSongService.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/19.
//

#import "NLSongService.h"

static NSString *firstSongIdFromString(NSString *ids) {
    NSArray *parts = [ids componentsSeparatedByString:@","];
    NSString *first = [parts.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return first.length > 0 ? first : ids;
}

static NSString *NLSongServiceDescriptionForCode(NSInteger code, NSString *fallbackMessage) {
    switch (code) {
        case NLSongServiceResponseBodyInvalid:
            return @"播放链接响应格式非法";
        case NLSongServiceResponseMissingPlayableURL:
            return @"接口未返回可播放链接";
        case NLSongServicePlayableURLInvalid:
            return fallbackMessage.length ? fallbackMessage : @"可播放链接无效";
        default:
            return fallbackMessage;
    }
}

@implementation NLSongService

+ (instancetype)sharedService {
    static NLSongService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[NLSongService alloc] init];
    });
    return service;
}

- (void)fetchPlayableURLWithSongId:(NSString *)songId
                           success:(SongURLFetchSuccess)success
                           failure:(SongFetchFailure)failure {
    if (!songId || songId.length == 0) {
        NSLog(@"[NLSongService] 歌曲 ID 为空");
        if (failure) failure([NSError errorWithDomain:@"NLSongService" code:400 userInfo:@{NSLocalizedDescriptionKey: @"歌曲 ID 为空"}]);
        return;
    }
    NSLog(@"[NLSongService] 开始获取播放链接 songId=%@", songId);
    NSDictionary *params = @{@"id": songId};

    [[NetWorkManager sharedManager] GET:@"/song/url" parameters:params success:^(id _Nonnull responseObject) {
        NSString *resolvedId = firstSongIdFromString(songId);
        NSError *parseError = nil;
        NSURL *playURL = [NLSongService playableURLFromResponseObject:responseObject error:&parseError];
        if (!playURL) {
            NSLog(@"[NLSongService] 播放链接不可用 songId=%@ error=%@", resolvedId, parseError.localizedDescription);
            if (failure) failure(parseError);
            return;
        }

        NSLog(@"[NLSongService] 获取播放 URL 成功 songId=%@", resolvedId);
        if (success) success(playURL);
    } failure:^(NSError * _Nonnull error) {
        NSLog(@"[NLSongService] 请求失败 songId=%@ error=%@", songId, error);
        if (failure) failure(error);
    }];
}

+ (NSURL *)playableURLFromResponseObject:(id)responseObject error:(NSError **)error {
    if (![responseObject isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NLSongService playableURLErrorWithCode:NLSongServiceResponseBodyInvalid userInfo:nil];
        return nil;
    }

    NSDictionary *response = (NSDictionary *)responseObject;
    NSArray *dataArray = response[@"data"];
    if (![dataArray isKindOfClass:[NSArray class]] || dataArray.count == 0) {
        if (error) *error = [NLSongService playableURLErrorWithCode:NLSongServiceResponseMissingPlayableURL userInfo:nil];
        return nil;
    }

    id item = dataArray[0];
    if (![item isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NLSongService playableURLErrorWithCode:NLSongServiceResponseMissingPlayableURL userInfo:nil];
        return nil;
    }

    id urlObject = ((NSDictionary *)item)[@"url"];
    if (![urlObject isKindOfClass:[NSString class]] || ((NSString *)urlObject).length == 0) {
        if (error) *error = [NLSongService playableURLErrorWithCode:NLSongServiceResponseMissingPlayableURL userInfo:nil];
        return nil;
    }

    NSURL *playURL = [NSURL URLWithString:(NSString *)urlObject];
    if (!playURL || !playURL.scheme.length || !playURL.host.length) {
        if (error) *error = [NLSongService playableURLErrorWithCode:NLSongServicePlayableURLInvalid userInfo:nil];
        return nil;
    }

    NSString *scheme = playURL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        if (error) {
            *error = [NLSongService playableURLErrorWithCode:NLSongServicePlayableURLInvalid
                                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"不支持的播放链接协议: %@", scheme]}];
        }
        return nil;
    }

    return playURL;
}

+ (NSError *)playableURLErrorWithCode:(NSInteger)code userInfo:(NSDictionary *)userInfo {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    if (userInfo) [merged addEntriesFromDictionary:userInfo];
    if (!merged[NSLocalizedDescriptionKey]) {
        merged[NSLocalizedDescriptionKey] = NLSongServiceDescriptionForCode(code, @"播放链接不可用");
    }
    return [NSError errorWithDomain:@"NLSongService" code:code userInfo:merged];
}

- (void)fetchLyricWithSongId:(NSString *)songId
                     success:(SongLyricFetchSuccess)success
                     failure:(SongFetchFailure)failure {
    if (!songId || songId.length == 0) {
        NSLog(@"[NLSongService] 歌曲 ID 为空，无法拉取歌词");
        if (failure) {
            failure([NSError errorWithDomain:@"NLSongService"
                                        code:400
                                    userInfo:@{NSLocalizedDescriptionKey : @"歌曲 ID 为空"}]);
        }
        return;
    }
    NSLog(@"[NLSongService] 开始获取歌词 songId=%@", songId);
    NSDictionary *params = @{@"id": songId};

    [[NetWorkManager sharedManager] GET:@"/lyric" parameters:params success:^(id  _Nonnull responseObject) {
        NSString *lyric = nil;
        NSDictionary *lrc = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject[@"lrc"] : nil;
        if ([lrc isKindOfClass:[NSDictionary class]]) {
            id lyricObj = lrc[@"lyric"];
            if ([lyricObj isKindOfClass:[NSString class]]) {
                lyric = (NSString *)lyricObj;
            }
        }
        if (!lyric) {
            lyric = @"";
        }
        NSLog(@"[NLSongService] 获取歌词成功，长度=%lu", (unsigned long)lyric.length);
        if (success) {
            success(lyric);
        }
    } failure:^(NSError * _Nonnull error) {
        NSLog(@"[NLSongService] 获取歌词失败 songId=%@ error=%@", songId, error);
        if (failure) {
            failure(error);
        }
    }];
}

@end
