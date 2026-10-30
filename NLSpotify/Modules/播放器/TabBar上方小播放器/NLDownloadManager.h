//
//  NLDownloadManager.h
//  NLSpotify
//
//  后台显式下载到独立离线存储；完成后写入 DownloadedSongsTable
//

#import <Foundation/Foundation.h>

@class NLSong, NLDownloadItem;

NS_ASSUME_NONNULL_BEGIN

/// 下载进度或状态变更通知。
/// - Discussion: `userInfo` 总含 `songId`、`status`、`receivedBytes` 与 `expectedBytes`；全局更新时前两项为空字符串。
extern NSNotificationName const NLDownloadManagerDidUpdateNotification;

@interface NLDownloadManager : NSObject

/// 全局下载管理单例。
/// - Returns: 全局共享的 `NLDownloadManager` 实例。
+ (instancetype)sharedManager;
/// 为指定歌曲添加一个后台下载任务。若启动仍在重建系统任务，会按 songId 去重后延迟准入。
/// - Parameter song: 需要下载到独立离线存储的歌曲。
- (void)addDownloadForSong:(NLSong *)song;
/// 暂停指定下载。只有恢复数据已持久化后 completion 才返回成功。
- (void)pauseDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL success))completion;
/// 使用已持久化的 resumeData 继续下载；恢复失败不会自动从头下载。
- (void)resumeDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL success))completion;
/// 取消指定下载、清除恢复数据，并保留可重试的下载队列项。
- (void)cancelDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL success))completion;
/// 用户明确重试时清除旧恢复数据并创建新的下载任务。
- (void)retryDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL success))completion;
/// 在后台合并下载队列与离线状态账本，完成回调在主队列返回快照。
- (void)loadDownloadItemsWithCompletion:(void (^)(NSArray<NLDownloadItem *> *items))completion;
/// 是否正在下载指定歌曲。
/// - Parameter songId: 歌曲的唯一标识。
/// - Returns: 若该歌曲存在进行中的下载任务则为 YES。
- (BOOL)isDownloadingSongId:(NSString *)songId;
/// 取消所有进行中的下载，并保留系统可用的 resumeData。
- (void)cancelAllDownloads;
/// AppDelegate 转交后台 URLSession 的完成事件。
- (void)handleBackgroundEventsForSessionIdentifier:(NSString *)identifier completionHandler:(void (^)(void))completionHandler;
/// 删除指定歌曲的离线正文及其恢复元数据。
- (void)removeOfflineDownloadForSongID:(NSString *)songID;
/// 删除所有离线正文及其恢复元数据。
- (void)removeAllOfflineDownloads;

@end

NS_ASSUME_NONNULL_END
