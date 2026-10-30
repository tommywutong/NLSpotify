#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// L1 进程内音频分片缓存。仅保存可从 L2 磁盘或网络重新获取的热点字节。
@interface NLAudioMemoryCache : NSObject

+ (instancetype)sharedCache;

/// 保存从 offset 开始的连续音频字节。相交或相邻的分片会合并，新数据覆盖重叠字节。
- (void)storeData:(NSData *)data forURL:(NSURL *)url atOffset:(long long)offset;
/// 使用稳定业务身份保存分片，避免签名 URL query 变化导致 L1 重复缓存。
- (void)storeData:(NSData *)data cacheKey:(NSString *)cacheKey atOffset:(long long)offset;

/// 返回从 offset 开始、长度不超过 length 的连续内存数据；未命中返回 nil。
- (nullable NSData *)dataForURL:(NSURL *)url offset:(long long)offset length:(NSUInteger)length;
/// 从稳定业务身份读取连续分片。
- (nullable NSData *)dataForCacheKey:(NSString *)cacheKey offset:(long long)offset length:(NSUInteger)length;

/// 返回 offset 后第一个仍驻留在 L1 的分片起点；没有时返回 NSNotFound。
- (long long)nextCachedOffsetForURL:(NSURL *)url afterOffset:(long long)offset;
/// 返回稳定业务身份在 offset 后的下一个驻留分片起点。
- (long long)nextCachedOffsetForCacheKey:(NSString *)cacheKey afterOffset:(long long)offset;

/// 删除一首歌的所有内存分片，不影响 L2 磁盘文件或 WCDB 元数据。
- (void)removeDataForURL:(NSURL *)url;
/// 删除稳定业务身份对应的所有内存分片。
- (void)removeDataForCacheKey:(NSString *)cacheKey;

/// 清空所有 L1 音频分片，不影响 L2 磁盘文件或 WCDB 元数据。
- (void)removeAllData;

@end

NS_ASSUME_NONNULL_END
