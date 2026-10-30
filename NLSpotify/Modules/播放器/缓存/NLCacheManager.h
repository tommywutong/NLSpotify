//
//  NLCacheManager.h
//  NLSpotify
//

#import <Foundation/Foundation.h>
#import "NLAudioCacheInfo.h"

NS_ASSUME_NONNULL_BEGIN

/// Writes/promotion trigger L2/L3 cleanup at 128/500 MiB, trimming the affected tier to 90%.
/// Protected files may keep a tier above its target. Startup only reconciles and measures files.
@interface NLCacheManager : NSObject

+ (instancetype)sharedManager;

/// Reconciliation completes on a utility queue; the block is always enqueued asynchronously on `queue`.
- (void)whenReadyOnQueue:(dispatch_queue_t)queue perform:(dispatch_block_t)block;

#pragma mark - Stable cache identity

/// Returns `cacheKey` combined with the URL host/path variant. Query tokens are ignored.
/// A nil key keeps legacy URL-hash behavior.
- (nullable NSString *)cacheIdentityForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (NSString *)tempFilePathForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (NSString *)cacheFilePathForURL:(nullable NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (BOOL)isFullyCachedForURL:(nullable NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (long long)totalLengthForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (NSArray<NSValue *> *)cachedRangesForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (float)cacheProgressForURL:(nullable NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (NSTimeInterval)lastAccessTimeForFullyCachedURL:(nullable NSURL *)url cacheKey:(nullable NSString *)cacheKey;

#pragma mark - Legacy URL wrappers

- (NSString *)tempFilePathForURL:(NSURL *)url;
- (NSString *)cacheFilePathForURL:(NSURL *)url;
- (BOOL)isFullyCachedForURL:(NSURL *)url;
- (long long)totalLengthForURL:(NSURL *)url;
- (NSArray<NSValue *> *)cachedRangesForURL:(NSURL *)url;
- (float)cacheProgressForURL:(NSURL *)url;
- (NSTimeInterval)lastAccessTimeForFullyCachedURL:(NSURL *)url;

/// Refreshes recency without creating a new cache record.
- (void)touchAccessTimeForURL:(nullable NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (void)touchAccessTimeForURL:(NSURL *)url;

@property (atomic, strong, nullable) NSURL *currentPlayingURL;
@property (atomic, copy, nullable) NSString *currentPlayingCacheKey;

extern NSNotificationName const NLCacheManagerDidFinishCachingNotification;

#pragma mark - Asynchronous cache writes

- (void)cacheData:(NSData *)data
         forURL:(NSURL *)url
       cacheKey:(nullable NSString *)cacheKey
      atOffset:(long long)offset
   totalLength:(long long)totalLength
     completion:(void (^ _Nullable)(BOOL success))completion;

- (void)cacheData:(NSData *)data
         forURL:(NSURL *)url
      atOffset:(long long)offset
   totalLength:(long long)totalLength;

- (void)mergeAndSaveSessionRanges:(NSArray<NSValue *> *)sessionRanges
                           forURL:(NSURL *)url
                         cacheKey:(nullable NSString *)cacheKey
                       completion:(void (^ _Nullable)(BOOL fullyCached))completion;

- (void)mergeAndSaveSessionRanges:(NSArray<NSValue *> *)sessionRanges forURL:(NSURL *)url;

- (BOOL)cachedRangesCoverFullLengthForURL:(NSURL *)url cacheKey:(nullable NSString *)cacheKey;
- (BOOL)cachedRangesCoverFullLengthForURL:(NSURL *)url;

- (void)finishCacheForURL:(NSURL *)url
                 cacheKey:(nullable NSString *)cacheKey
               completion:(void (^ _Nullable)(BOOL success))completion;
- (void)finishCacheForURL:(NSURL *)url;

#pragma mark - Cleanup

/// Explicitly clear ordinary disk/memory caches and their ledger, preserving offline downloads.
- (void)clearAllCache;

@end

NS_ASSUME_NONNULL_END
