//
//  NLSongRepository.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/23.
//

#import <Foundation/Foundation.h>

@class NLSong;

NS_ASSUME_NONNULL_BEGIN

@interface NLSongRepository : NSObject

/// 将歌曲标记为「已下载」并写入本地表。
+ (void)addDownloadedSong:(NLSong *)song completion:(void (^)(BOOL success))completion;

/// 移除一条已下载歌曲记录。
+ (void)removeDownloadedSong:(NSString *)songId completion:(void (^)(BOOL success))completion;

/// 判断歌曲是否已被下载。调用方须在后台读取。
+ (BOOL)isSongDownloaded:(NSString *)songId;

/// 查询所有已下载歌曲。调用方须在后台读取。
+ (NSArray<NLSong *> *)allDownloadedSongs;

/// 清空所有已下载歌曲记录。
+ (void)clearAllDownloadedSongsWithCompletion:(void (^)(BOOL success))completion;

/// 当前歌曲首次进入 Playing 时记录一次播放启动。
+ (void)recordPlaybackStart:(NLSong *)song completion:(void (^)(BOOL success))completion;

/// 移除指定歌曲的播放历史及其元数据。
+ (void)removePlayHistoryWithSongId:(NSString *)songId completion:(void (^)(BOOL success))completion;

/// 查询所有播放历史；只允许从后台调用。
+ (NSArray<NLSong *> *)allPlayHistory;

/// 异步读取按 `lastPlayedAt` 降序、`songId` 升序排序的历史快照。
+ (void)allPlayHistoryWithCompletion:(void (^)(NSArray<NLSong *> *songs))completion;

/// 查询所有已收藏歌曲。调用方须在后台读取。
+ (NSArray<NLSong *> *)allLikedSongs;

/// 收藏或取消收藏一首歌曲。
+ (void)likeSong:(NLSong *)song isLike:(BOOL)isLike completion:(void (^)(BOOL success))completion;

/// 判断歌曲是否已被收藏。调用方须在后台读取。
+ (BOOL)isSongLiked:(NSString *)songId;

@end

NS_ASSUME_NONNULL_END
