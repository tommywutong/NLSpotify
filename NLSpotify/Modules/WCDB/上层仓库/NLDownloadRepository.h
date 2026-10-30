//
//  NLDownloadRepository.h
//  NLSpotify
//

#import <Foundation/Foundation.h>

@class NLDownloadItem, NLSong;

NS_ASSUME_NONNULL_BEGIN

@interface NLDownloadRepository : NSObject

/// 查询所有下载记录，按 addedTime 从新到旧排序。调用方须在后台读取。
+ (NSArray<NLDownloadItem *> *)allDownloadItems;

/// 根据歌曲 ID 查询对应的下载记录。调用方须在后台读取。
+ (nullable NLDownloadItem *)downloadItemForSongId:(NSString *)songId;

/// 新增一条下载记录。
+ (void)addDownloadItemWithSong:(NLSong *)song
                         status:(NSString *)status
                     completion:(void (^)(BOOL success))completion;

/// 更新指定歌曲的下载状态。
+ (void)updateStatus:(NSString *)status
           forSongId:(NSString *)songId
          completion:(void (^)(BOOL success))completion;

/// 在一个 WCDB 事务中提交下载完成状态和已下载歌曲记录。
+ (void)completeDownloadWithSong:(NLSong *)song completion:(void (^)(BOOL success))completion;

/// 删除指定歌曲的下载记录。
+ (void)removeDownloadItemWithSongId:(NSString *)songId completion:(void (^)(BOOL success))completion;

/// 清空所有下载记录。
+ (void)clearAllDownloadItemsWithCompletion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
