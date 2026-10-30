//
//  NLSongService.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/19.
//

#import <Foundation/Foundation.h>
#import "NLSong.h"
#import "NetWorkManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NLSongServicePlayableURLError) {
    NLSongServiceResponseBodyInvalid = 1001,
    NLSongServiceResponseMissingPlayableURL = 1002,
    NLSongServicePlayableURLInvalid = 1003
};

typedef void(^SongURLFetchSuccess)(NSURL *playURL);
typedef void(^SongFetchFailure)(NSError *error);
typedef void(^SongLyricFetchSuccess)(NSString *lyric);
/// 歌曲播放 URL 与 LRC 歌词服务。
@interface NLSongService : NSObject

/// 返回全局共享的歌曲服务。
/// - Returns: 唯一的 `NLSongService` 实例。
+ (instancetype)sharedService;

/// 请求歌曲的可播放 URL。
/// - Parameters:
///   - songId: 网易云歌曲标识，不能为空。
///   - success: 解析成功后返回播放 URL；仅接受可解析的 HTTP(S) URL。
///   - failure: 参数非法、响应格式非法、接口未返回可用链接或链接不是 HTTP(S) 时调用。
/// - Discussion: 本方法不负责取消和切歌代际校验；调用方应以播放 token 丢弃过期回调。
- (void)fetchPlayableURLWithSongId:(NSString *)songId
                           success:(SongURLFetchSuccess)success
                           failure:(SongFetchFailure)failure;

/// 从 `/song/url` 响应中解析可播放 URL。
/// - Parameters:
///   - responseObject: 上游返回的 JSON 对象。
///   - error: 解析失败时返回带错误域/码的 `NSError`。
/// - Returns: 可播放的 HTTP(S) URL；解析失败返回 `nil`。
/// - Discussion: 不构造外链兜底；URL 路径中的 `403` 不是拒绝依据。
+ (nullable NSURL *)playableURLFromResponseObject:(id)responseObject error:(NSError **)error;

/// 请求歌曲的原始 LRC 文本。
/// - Parameters:
///   - songId: 网易云歌曲标识，不能为空。
///   - success: 成功时返回 LRC 字符串；服务端无歌词时返回空字符串。
///   - failure: 参数非法或网络请求失败时调用。
- (void)fetchLyricWithSongId:(NSString *)songId
                     success:(SongLyricFetchSuccess)success
                     failure:(SongFetchFailure)failure;

@end

NS_ASSUME_NONNULL_END
