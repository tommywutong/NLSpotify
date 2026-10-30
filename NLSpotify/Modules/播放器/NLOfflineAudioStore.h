#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 用户主动下载的离线音频正文与后台下载恢复元数据。
/// 与 NLCacheManager 的 Caches/Ranges 分离；缓存清理不会删除这里的文件。
@interface NLOfflineAudioStore : NSObject

+ (instancetype)sharedStore;

- (nullable NSURL *)localFileURLForSongID:(NSString *)songID;
- (BOOL)importCompleteAudioAtURL:(NSURL *)sourceURL
                       forSongID:(NSString *)songID
                           error:(NSError * _Nullable * _Nullable)error;

- (BOOL)recordTaskIdentifier:(NSUInteger)taskIdentifier
                   forSongID:(NSString *)songID
                  resumeData:(nullable NSData *)resumeData
               receivedBytes:(long long)receivedBytes
               expectedBytes:(long long)expectedBytes
                       error:(NSError * _Nullable * _Nullable)error;
- (BOOL)clearResumeDataForSongID:(NSString *)songID
                ifTaskIdentifier:(NSUInteger)taskIdentifier
                           error:(NSError * _Nullable * _Nullable)error;
- (BOOL)recordProgressForTaskIdentifier:(NSUInteger)taskIdentifier
                                forSongID:(NSString *)songID
                            receivedBytes:(long long)receivedBytes
                            expectedBytes:(long long)expectedBytes
                                    error:(NSError * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, id> *)stateForSongID:(NSString *)songID;

- (void)removeOfflineAudioForSongID:(NSString *)songID;
- (void)removeAllOfflineAudio;

@end

NS_ASSUME_NONNULL_END
