//
//  NLCacheManager.mm
//  NLSpotify
//

#import "NLCacheManager.h"
#import "NLAudioCacheInfo+WCDB.h"
#import "NLDataBaseManager.h"
#import "NLDownloadRepository.h"
#import "NLDownloadItem.h"
#import "NLAudioMemoryCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <unistd.h>

static NSString * const kAudioCacheTableName = @"AudioCacheInfoTable_v3";
static const NSUInteger kCacheQueueCount = 8;
static const long long kPartialCacheHighWatermark = 128LL * 1024 * 1024;
static const long long kCompletedCacheHighWatermark = 500LL * 1024 * 1024;
static dispatch_queue_t gCacheQueues[kCacheQueueCount];
static dispatch_once_t gCacheQueuesOnce;

NSNotificationName const NLCacheManagerDidFinishCachingNotification = @"NLCacheManagerDidFinishCachingNotification";

static void NLInitCacheQueues(void) {
    dispatch_once(&gCacheQueuesOnce, ^{
        for (NSUInteger index = 0; index < kCacheQueueCount; index++) {
            NSString *name = [NSString stringWithFormat:@"com.nlspotify.cache.%lu", (unsigned long)index];
            gCacheQueues[index] = dispatch_queue_create(name.UTF8String, DISPATCH_QUEUE_SERIAL);
        }
    });
}

static dispatch_queue_t NLQueueForIdentifier(NSString *identifier) {
    NLInitCacheQueues();
    return gCacheQueues[(NSUInteger)identifier.hash % kCacheQueueCount];
}

static BOOL NLFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

@interface NLCacheManager ()
@property (nonatomic, copy) NSString *cacheDirectory;
@property (atomic, assign) NSUInteger cacheGeneration;
@property (nonatomic, strong) NSLock *ownershipLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *activeWriteCounts;
@property (nonatomic, strong) NSLock *readinessLock;
@property (nonatomic, assign) BOOL cacheReady;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *pendingReadinessCallbacks;
@property (nonatomic, strong) dispatch_queue_t admissionQueue;
@property (nonatomic, assign) NSUInteger inFlightCacheOperationCount;
@property (nonatomic, assign) BOOL clearBarrierActive;
@property (nonatomic, assign) BOOL clearInProgress;
@property (nonatomic, assign) NSUInteger pendingClearCount;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *deferredCacheOperations;
// Capacity accounting belongs to admissionQueue; sizes are logical file lengths, not bytes received.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *partialFileSizes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *completedFileSizes;
@property (nonatomic, assign) long long partialCacheSize;
@property (nonatomic, assign) long long completedCacheSize;
@property (nonatomic, assign) BOOL capacityCleanupScheduled;
@property (nonatomic, assign) BOOL capacityCheckPending;
- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory
                  reconciliationBlock:(void (^ _Nullable)(NLCacheManager *manager))reconciliationBlock;
- (void)reconcileCacheDirectory;
- (void)beginWriteForIdentifier:(NSString *)identifier;
- (void)endWriteForIdentifier:(NSString *)identifier;
- (NSUInteger)currentCacheGeneration;
- (NSUInteger)advanceCacheGeneration;
- (void)markReady;
- (void)enqueueCacheOperation:(void (^)(dispatch_block_t finish))operation;
- (void)startClearIfIdle;
- (void)trimCacheTierWithHighWatermark:(long long)high lowWatermark:(long long)low finished:(BOOL)finished;
- (void)rebuildCapacityAccounting;
- (void)recordCacheSizesForIdentifier:(NSString *)identifier requestCleanup:(BOOL)requestCleanup;
- (void)scheduleCapacityCleanupIfNeeded;
- (nullable NLAudioCacheInfo *)fullyCachedInfoForSongId:(NSString *)songId;
- (BOOL)hasCompleteLedger:(NLAudioCacheInfo *)info;
- (BOOL)hasMatchingBody:(NLAudioCacheInfo *)info finished:(BOOL)finished;
- (BOOL)isCommittedCacheInfo:(NLAudioCacheInfo *)info;
- (BOOL)promoteCacheInfo:(NLAudioCacheInfo *)info notificationURL:(nullable NSURL *)url;
- (NSArray<NSValue *> *)parseRangesFromString:(NSString *)string;
- (NSString *)stringFromRanges:(NSArray<NSValue *> *)ranges;
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path atOffset:(long long)offset;
- (BOOL)syncFileAtPath:(NSString *)path;
- (long long)fileSizeAtPath:(NSString *)path;
- (NSArray<NSValue *> *)mergeRanges:(NSArray<NSValue *> *)ranges totalLength:(long long)totalLength;
- (BOOL)ranges:(NSArray<NSValue *> *)ranges coverTotalLength:(long long)totalLength;
- (NSSet<NSString *> *)protectedIdentifiers;
@end

@implementation NLCacheManager

+ (instancetype)sharedManager {
    static NLCacheManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init {
    NSString *cacheDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [self initWithCacheDirectory:[cacheDir stringByAppendingPathComponent:@"NLAudioCache"]
                    reconciliationBlock:nil];
}

- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory
                  reconciliationBlock:(void (^)(NLCacheManager *))reconciliationBlock {
    self = [super init];
    if (!self) return nil;

    _cacheDirectory = [cacheDirectory copy];
    _ownershipLock = [[NSLock alloc] init];
    _activeWriteCounts = [NSMutableDictionary dictionary];
    _readinessLock = [[NSLock alloc] init];
    _pendingReadinessCallbacks = [NSMutableArray array];
    _admissionQueue = dispatch_queue_create("com.nlspotify.cache.admission", DISPATCH_QUEUE_SERIAL);
    _deferredCacheOperations = [NSMutableArray array];
    _partialFileSizes = [NSMutableDictionary dictionary];
    _completedFileSizes = [NSMutableDictionary dictionary];

    void (^reconcile)(NLCacheManager *) = [reconciliationBlock copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL directoryReady = [[NSFileManager defaultManager] createDirectoryAtPath:self.cacheDirectory
                                                       withIntermediateDirectories:YES
                                                                        attributes:nil
                                                                             error:nil];
        NLDataBaseManager *databaseManager = [NLDataBaseManager sharedManager];
        if (!directoryReady) {
            [self markReady];
            return;
        }

        [databaseManager migrateCacheLedgerIfNeededWithCompletion:^(BOOL migrated) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try {
                    BOOL tableReady = migrated;
                    if (tableReady) {
                        if (reconcile) reconcile(self);
                        else [self reconcileCacheDirectory];
                        [self rebuildCapacityAccounting];
                    } else {
                        NSLog(@"[缓存] 缓存账本迁移失败，跳过启动对账");
                    }
                } @catch (NSException *exception) {
                    NSLog(@"[缓存] 启动对账异常，跳过后续修复: %@", exception);
                } @finally {
                    [self markReady];
                }
            });
        }];
    });
    return self;
}

- (void)whenReadyOnQueue:(dispatch_queue_t)queue perform:(dispatch_block_t)block {
    if (!block) return;
    [self.readinessLock lock];
    if (self.cacheReady) {
        dispatch_async(queue, block);
    } else {
        [self.pendingReadinessCallbacks addObject:@{@"queue": queue, @"block": [block copy]}];
    }
    [self.readinessLock unlock];
}

- (void)markReady {
    [self.readinessLock lock];
    self.cacheReady = YES;
    for (NSDictionary<NSString *, id> *entry in self.pendingReadinessCallbacks) {
        dispatch_async(entry[@"queue"], entry[@"block"]);
    }
    [self.pendingReadinessCallbacks removeAllObjects];
    [self.readinessLock unlock];
}

- (NSUInteger)currentCacheGeneration {
    @synchronized (self) {
        return self.cacheGeneration;
    }
}

- (NSUInteger)advanceCacheGeneration {
    @synchronized (self) {
        self.cacheGeneration += 1;
        return self.cacheGeneration;
    }
}

- (void)enqueueCacheOperation:(void (^)(dispatch_block_t))operation {
    [self whenReadyOnQueue:self.admissionQueue perform:^{
        dispatch_block_t start = ^{
            self.inFlightCacheOperationCount += 1;
            operation(^{
                dispatch_async(self.admissionQueue, ^{
                    NSAssert(self.inFlightCacheOperationCount > 0, @"Unbalanced cache operation completion");
                    self.inFlightCacheOperationCount -= 1;
                    [self startClearIfIdle];
                });
            });
        };
        if (self.clearBarrierActive) {
            [self.deferredCacheOperations addObject:[start copy]];
        } else {
            start();
        }
    }];
}

- (void)startClearIfIdle {
    if (!self.clearBarrierActive || self.clearInProgress || self.inFlightCacheOperationCount != 0 || self.pendingClearCount == 0) return;
    self.clearInProgress = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in [fm contentsOfDirectoryAtPath:self.cacheDirectory error:nil]) {
            [fm removeItemAtPath:[self.cacheDirectory stringByAppendingPathComponent:name] error:nil];
        }
        [[NLAudioMemoryCache sharedCache] removeAllData];
        [[NLDataBaseManager sharedManager].database deleteFromTable:kAudioCacheTableName];
        [self rebuildCapacityAccounting];

        dispatch_async(self.admissionQueue, ^{
            self.clearInProgress = NO;
            self.pendingClearCount -= 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:NLCacheManagerDidFinishCachingNotification object:self];
            });
            if (self.pendingClearCount > 0) {
                [self startClearIfIdle];
                return;
            }

            self.clearBarrierActive = NO;
            NSArray<dispatch_block_t> *deferred = [self.deferredCacheOperations copy];
            [self.deferredCacheOperations removeAllObjects];
            for (dispatch_block_t operation in deferred) operation();
        });
    });
}

- (void)beginWriteForIdentifier:(NSString *)identifier {
    [self.ownershipLock lock];
    NSUInteger count = self.activeWriteCounts[identifier].unsignedIntegerValue;
    self.activeWriteCounts[identifier] = @(count + 1);
    [self.ownershipLock unlock];
}

- (void)endWriteForIdentifier:(NSString *)identifier {
    [self.ownershipLock lock];
    NSUInteger count = self.activeWriteCounts[identifier].unsignedIntegerValue;
    if (count <= 1) [self.activeWriteCounts removeObjectForKey:identifier];
    else self.activeWriteCounts[identifier] = @(count - 1);
    [self.ownershipLock unlock];
}

#pragma mark - Capacity accounting

- (void)rebuildCapacityAccounting {
    NSMutableDictionary<NSString *, NSNumber *> *partial = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *completed = [NSMutableDictionary dictionary];
    long long partialSize = 0, completedSize = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.cacheDirectory error:nil]) {
        BOOL finished = [name.pathExtension isEqualToString:@"mp3"];
        if (!finished && ![name.pathExtension isEqualToString:@"tmp"]) continue;
        long long size = [self fileSizeAtPath:[self.cacheDirectory stringByAppendingPathComponent:name]];
        if (size <= 0) continue;
        NSString *identifier = name.stringByDeletingPathExtension;
        if (finished) {
            completed[identifier] = @(size);
            completedSize += size;
        } else {
            partial[identifier] = @(size);
            partialSize += size;
        }
    }
    dispatch_sync(self.admissionQueue, ^{
        self.partialFileSizes = partial;
        self.completedFileSizes = completed;
        self.partialCacheSize = partialSize;
        self.completedCacheSize = completedSize;
    });
}

// Called on the identifier's serial queue, so measurements and deletion reports retain file order.
- (void)recordCacheSizesForIdentifier:(NSString *)identifier requestCleanup:(BOOL)requestCleanup {
    NSString *basePath = [self.cacheDirectory stringByAppendingPathComponent:identifier];
    long long partialSize = [self fileSizeAtPath:[basePath stringByAppendingString:@".tmp"]];
    long long completedSize = [self fileSizeAtPath:[basePath stringByAppendingString:@".mp3"]];
    dispatch_async(self.admissionQueue, ^{
        long long oldPartialSize = self.partialFileSizes[identifier].longLongValue;
        long long oldCompletedSize = self.completedFileSizes[identifier].longLongValue;
        self.partialCacheSize += partialSize - oldPartialSize;
        self.completedCacheSize += completedSize - oldCompletedSize;
        if (partialSize != oldPartialSize) {
            if (partialSize > 0) self.partialFileSizes[identifier] = @(partialSize);
            else [self.partialFileSizes removeObjectForKey:identifier];
        }
        if (completedSize != oldCompletedSize) {
            if (completedSize > 0) self.completedFileSizes[identifier] = @(completedSize);
            else [self.completedFileSizes removeObjectForKey:identifier];
        }
        if (requestCleanup) [self scheduleCapacityCleanupIfNeeded];
    });
}

- (void)scheduleCapacityCleanupIfNeeded {
    if (self.clearBarrierActive) return;
    if (self.partialCacheSize < kPartialCacheHighWatermark &&
        self.completedCacheSize < kCompletedCacheHighWatermark) return;
    if (self.capacityCleanupScheduled) {
        self.capacityCheckPending = YES;
        return;
    }
    self.capacityCleanupScheduled = YES;
    self.capacityCheckPending = NO;
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        BOOL trimPartial = self.partialCacheSize >= kPartialCacheHighWatermark;
        BOOL trimCompleted = self.completedCacheSize >= kCompletedCacheHighWatermark;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                if (trimPartial) [self trimCacheTierWithHighWatermark:kPartialCacheHighWatermark
                                                       lowWatermark:kPartialCacheHighWatermark * 9 / 10 finished:NO];
                if (trimCompleted) [self trimCacheTierWithHighWatermark:kCompletedCacheHighWatermark
                                                         lowWatermark:kCompletedCacheHighWatermark * 9 / 10 finished:YES];
            } @finally {
                dispatch_async(self.admissionQueue, ^{
                    self.capacityCleanupScheduled = NO;
                    BOOL checkAgain = self.capacityCheckPending;
                    self.capacityCheckPending = NO;
                    operationFinished();
                    // New writes during a pass may cross a watermark again. A protected-only pass
                    // without new writes stops here rather than rescheduling itself indefinitely.
                    if (checkAgain) [self scheduleCapacityCleanupIfNeeded];
                });
            }
        });
    }];
}

#pragma mark - Identity

- (NSString *)sha256StringFromString:(NSString *)value {
    if (value.length == 0) return @"";
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, result);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", result[index]];
    }
    return [@"sha256-" stringByAppendingString:hex];
}

- (NSString *)sha256StringFromURL:(NSURL *)url {
    return [self sha256StringFromString:url.absoluteString ?: @""];
}

- (NSString *)cacheIdentityForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    NSString *variant = [host stringByAppendingString:path];
    return variant.length > 0 ? [cacheKey stringByAppendingFormat:@"\n%@", variant] : cacheKey;
}

- (NSString *)identifierForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    return cacheKey.length > 0 ? [self sha256StringFromString:cacheKey] : [self sha256StringFromURL:url];
}

#pragma mark - Paths and metadata

- (NSString *)tempFilePathForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    return identifier.length == 0 ? @"" : [self.cacheDirectory stringByAppendingPathComponent:[identifier stringByAppendingString:@".tmp"]];
}

- (NSString *)cacheFilePathForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *identifier = url ? [self identifierForURL:url cacheKey:cacheKey]
                               : ([self fullyCachedInfoForSongId:cacheKey].cacheIdentifier ?: [self identifierForURL:url cacheKey:cacheKey]);
    return identifier.length == 0 ? @"" : [self.cacheDirectory stringByAppendingPathComponent:[identifier stringByAppendingString:@".mp3"]];
}

- (NLAudioCacheInfo *)fullyCachedInfoForSongId:(NSString *)songId {
    if (songId.length == 0) return nil;
    WCTDatabase *db = [NLDataBaseManager sharedManager].database;
    NSArray<NLAudioCacheInfo *> *infos = [db getObjectsOfClass:NLAudioCacheInfo.class
                                                    fromTable:kAudioCacheTableName
                                                        where:NLAudioCacheInfo.songId == songId];
    NLAudioCacheInfo *latest = nil;
    for (NLAudioCacheInfo *info in infos) {
        if (latest && info.lastAccessTime <= latest.lastAccessTime) continue;
        if ([self isCommittedCacheInfo:info]) latest = info;
    }
    return latest;
}

- (NSString *)tempFilePathForURL:(NSURL *)url {
    return [self tempFilePathForURL:url cacheKey:nil];
}

- (NSString *)cacheFilePathForURL:(NSURL *)url {
    return [self cacheFilePathForURL:url cacheKey:nil];
}

- (NLAudioCacheInfo *)infoForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (!url && cacheKey.length > 0) return [self fullyCachedInfoForSongId:cacheKey];
    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    if (identifier.length == 0) return nil;
    return [[NLDataBaseManager sharedManager].database
            getObjectOfClass:NLAudioCacheInfo.class
            fromTable:kAudioCacheTableName
            where:NLAudioCacheInfo.cacheIdentifier == identifier];
}
- (BOOL)hasCompleteLedger:(NLAudioCacheInfo *)info {
    return info && [self ranges:[self parseRangesFromString:info.cachedRangesString]
                     coverTotalLength:info.totalLength];
}

- (BOOL)hasMatchingBody:(NLAudioCacheInfo *)info finished:(BOOL)finished {
    if (info.cacheIdentifier.length == 0 || info.totalLength <= 0) return NO;
    NSString *path = [self.cacheDirectory stringByAppendingPathComponent:
        [info.cacheIdentifier stringByAppendingString:finished ? @".mp3" : @".tmp"]];
    return [self fileSizeAtPath:path] == info.totalLength;
}

- (BOOL)isCommittedCacheInfo:(NLAudioCacheInfo *)info {
    return info.isFinished && [self hasCompleteLedger:info] && [self hasMatchingBody:info finished:YES];
}


- (BOOL)isFullyCachedForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    return [self isCommittedCacheInfo:[self infoForURL:url cacheKey:cacheKey]];
}

- (BOOL)isFullyCachedForURL:(NSURL *)url {
    return [self isFullyCachedForURL:url cacheKey:nil];
}

- (long long)totalLengthForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    return [self infoForURL:url cacheKey:cacheKey].totalLength;
}

- (long long)totalLengthForURL:(NSURL *)url {
    return [self totalLengthForURL:url cacheKey:nil];
}

- (NSArray<NSValue *> *)cachedRangesForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NLAudioCacheInfo *info = [self infoForURL:url cacheKey:cacheKey];
    return info ? [self parseRangesFromString:info.cachedRangesString] : @[];
}

- (NSArray<NSValue *> *)cachedRangesForURL:(NSURL *)url {
    return [self cachedRangesForURL:url cacheKey:nil];
}

- (float)cacheProgressForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (!url && cacheKey.length == 0) return 0.f;
    if ([self isFullyCachedForURL:url cacheKey:cacheKey]) return 1.f;
    long long total = [self totalLengthForURL:url cacheKey:cacheKey];
    if (total <= 0) return 0.f;
    unsigned long long covered = 0;
    for (NSValue *value in [self cachedRangesForURL:url cacheKey:cacheKey]) {
        covered += value.rangeValue.length;
    }
    return MIN(MAX((float)((double)covered / (double)total), 0.f), 1.f);
}

- (float)cacheProgressForURL:(NSURL *)url {
    return [self cacheProgressForURL:url cacheKey:nil];
}

- (NSTimeInterval)lastAccessTimeForFullyCachedURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (![self isFullyCachedForURL:url cacheKey:cacheKey]) return 0;
    return [self infoForURL:url cacheKey:cacheKey].lastAccessTime;
}

- (NSTimeInterval)lastAccessTimeForFullyCachedURL:(NSURL *)url {
    return [self lastAccessTimeForFullyCachedURL:url cacheKey:nil];
}

- (void)touchAccessTimeForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (!url && cacheKey.length == 0) return;
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        NSString *identifier = url ? [self identifierForURL:url cacheKey:cacheKey]
                                   : [self fullyCachedInfoForSongId:cacheKey].cacheIdentifier;
        if (identifier.length == 0) {
            operationFinished();
            return;
        }
        [self beginWriteForIdentifier:identifier];
        dispatch_async(NLQueueForIdentifier(identifier), ^{
            WCTDatabase *db = [NLDataBaseManager sharedManager].database;
            NLAudioCacheInfo *info = [db getObjectOfClass:NLAudioCacheInfo.class
                                                 fromTable:kAudioCacheTableName
                                                      where:NLAudioCacheInfo.cacheIdentifier == identifier];
            if (info) {
                info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
                [db insertOrReplaceObject:info intoTable:kAudioCacheTableName];
            }
            [self endWriteForIdentifier:identifier];
            operationFinished();
        });
    }];
}

- (void)touchAccessTimeForURL:(NSURL *)url {
    [self touchAccessTimeForURL:url cacheKey:nil];
}

#pragma mark - Writes

- (BOOL)writeData:(NSData *)data toPath:(NSString *)path atOffset:(long long)offset {
    if (data.length == 0 || path.length == 0 || offset < 0) return NO;
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    int fd = open(path.UTF8String, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return NO;

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t written = 0;
    BOOL success = YES;
    while (written < data.length) {
        ssize_t result = pwrite(fd, bytes + written, data.length - written, offset + (long long)written);
        if (result <= 0) {
            success = NO;
            break;
        }
        written += (size_t)result;
    }
    close(fd);
    return success && written == data.length;
}

- (BOOL)syncFileAtPath:(NSString *)path {
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) return NO;
    int result = fsync(fd);
    close(fd);
    return result == 0;
}

- (void)cacheData:(NSData *)data
         forURL:(NSURL *)url
       cacheKey:(NSString *)cacheKey
      atOffset:(long long)offset
   totalLength:(long long)totalLength
     completion:(void (^)(BOOL))completion {
    if (!data || data.length == 0 || !url || offset < 0) {
        if (completion) completion(NO);
        return;
    }

    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    NSData *dataCopy = [data copy];
    NSUInteger generation = [self currentCacheGeneration];
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        [self beginWriteForIdentifier:identifier];
        dispatch_async(NLQueueForIdentifier(identifier), ^{
            void (^finish)(BOOL) = ^(BOOL success) {
                [self endWriteForIdentifier:identifier];
                [self recordCacheSizesForIdentifier:identifier requestCleanup:YES];
                @try {
                    if (completion) completion(success);
                } @finally {
                    operationFinished();
                }
            };
            if (generation != [self currentCacheGeneration]) {
                finish(NO);
                return;
            }

            WCTDatabase *db = [NLDataBaseManager sharedManager].database;
            NLAudioCacheInfo *info = [db getObjectOfClass:NLAudioCacheInfo.class
                                                 fromTable:kAudioCacheTableName
                                                      where:NLAudioCacheInfo.cacheIdentifier == identifier];
            if (!info) {
                info = [[NLAudioCacheInfo alloc] init];
                info.cacheIdentifier = identifier;
                info.cachedRangesString = @"[]";
                info.isFinished = NO;
            }
            if (cacheKey.length > 0) {
                NSRange variantSeparator = [cacheKey rangeOfString:@"\n"];
                info.songId = variantSeparator.location == NSNotFound ? cacheKey : [cacheKey substringToIndex:variantSeparator.location];
            }
            if (info.isFinished) {
                if ([self isCommittedCacheInfo:info]) {
                    [[NSFileManager defaultManager] removeItemAtPath:[self tempFilePathForURL:url cacheKey:cacheKey] error:nil];
                    finish(NO);
                    return;
                }
                info.isFinished = NO;
                info.cachedRangesString = @"[]";
                if (totalLength > 0) info.totalLength = totalLength;
            }
            if (totalLength > 0 && info.totalLength <= 0) info.totalLength = totalLength;
            info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
            if (![db insertOrReplaceObject:info intoTable:kAudioCacheTableName]) {
                finish(NO);
                return;
            }

            BOOL success = [self writeData:dataCopy
                                    toPath:[self tempFilePathForURL:url cacheKey:cacheKey]
                                  atOffset:offset];
            finish(success);
        });
    }];
}

- (void)cacheData:(NSData *)data
         forURL:(NSURL *)url
      atOffset:(long long)offset
   totalLength:(long long)totalLength {
    [self cacheData:data forURL:url cacheKey:nil atOffset:offset totalLength:totalLength completion:nil];
}

#pragma mark - Range merge and promotion

- (NSArray<NSValue *> *)mergeRanges:(NSArray<NSValue *> *)ranges totalLength:(long long)totalLength {
    NSMutableArray<NSValue *> *valid = [NSMutableArray array];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        if (range.location == NSNotFound || range.length == 0) continue;
        unsigned long long end = (unsigned long long)range.location + range.length;
        if (totalLength > 0) {
            if ((long long)range.location >= totalLength) continue;
            end = MIN(end, (unsigned long long)totalLength);
        }
        if (end > range.location) {
            [valid addObject:[NSValue valueWithRange:NSMakeRange(range.location, (NSUInteger)(end - range.location))]];
        }
    }
    if (valid.count <= 1) return valid;
    [valid sortUsingComparator:^NSComparisonResult(NSValue *left, NSValue *right) {
        return [@(left.rangeValue.location) compare:@(right.rangeValue.location)];
    }];

    NSMutableArray<NSValue *> *merged = [NSMutableArray array];
    NSRange current = valid.firstObject.rangeValue;
    for (NSUInteger index = 1; index < valid.count; index++) {
        NSRange next = valid[index].rangeValue;
        if (next.location <= NSMaxRange(current)) {
            unsigned long long end = MAX((unsigned long long)NSMaxRange(current), (unsigned long long)NSMaxRange(next));
            current.length = (NSUInteger)(end - current.location);
        } else {
            [merged addObject:[NSValue valueWithRange:current]];
            current = next;
        }
    }
    [merged addObject:[NSValue valueWithRange:current]];
    return merged;
}

- (BOOL)ranges:(NSArray<NSValue *> *)ranges coverTotalLength:(long long)totalLength {
    if (totalLength <= 0 || ranges.count == 0) return NO;
    long long position = 0;
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        if ((long long)range.location > position) return NO;
        position = MAX(position, (long long)NSMaxRange(range));
        if (position >= totalLength) return YES;
    }
    return NO;
}

- (BOOL)promoteCacheInfo:(NLAudioCacheInfo *)info notificationURL:(NSURL *)url {
    // Idempotence is based on the committed record AND its valid body, never a flag alone.
    if ([self isCommittedCacheInfo:info]) return YES;
    if (![self hasCompleteLedger:info]) return NO;
    NSString *tempPath = [self.cacheDirectory stringByAppendingPathComponent:
        [info.cacheIdentifier stringByAppendingString:@".tmp"]];
    NSString *cachePath = [self.cacheDirectory stringByAppendingPathComponent:
        [info.cacheIdentifier stringByAppendingString:@".mp3"]];
    BOOL renamed = NO;
    if (NLFileExists(tempPath)) {
        if (![self hasMatchingBody:info finished:NO] || ![self syncFileAtPath:tempPath]) return NO;
        if (rename(tempPath.UTF8String, cachePath.UTF8String) != 0) return NO;
        renamed = YES;
    } else {
        // Recover the rename-before-commit window, including a failed reverse rename.
        if (![self hasMatchingBody:info finished:YES] || ![self syncFileAtPath:cachePath]) return NO;
    }

    BOOL previousFinished = info.isFinished;
    NSTimeInterval previousAccessTime = info.lastAccessTime;
    info.isFinished = YES;
    info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
    BOOL saved = [[NLDataBaseManager sharedManager].database insertOrReplaceObject:info intoTable:kAudioCacheTableName];
    if (!saved) {
        info.isFinished = previousFinished;
        info.lastAccessTime = previousAccessTime;
        // Best-effort rollback; if it fails, keep the complete ledger and renamed body for retry.
        if (renamed) rename(cachePath.UTF8String, tempPath.UTF8String);
        return NO;
    }

    if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:NLCacheManagerDidFinishCachingNotification
                                                                object:self userInfo:@{ @"url": url }];
        });
    }
    return YES;
}

- (void)mergeAndSaveSessionRanges:(NSArray<NSValue *> *)sessionRanges
                           forURL:(NSURL *)url
                         cacheKey:(NSString *)cacheKey
                       completion:(void (^)(BOOL))completion {
    if (!url || sessionRanges.count == 0) {
        if (completion) completion(NO);
        return;
    }
    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    NSUInteger generation = [self currentCacheGeneration];
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        [self beginWriteForIdentifier:identifier];
        dispatch_async(NLQueueForIdentifier(identifier), ^{
            void (^finish)(BOOL) = ^(BOOL result) {
                [self endWriteForIdentifier:identifier];
                [self recordCacheSizesForIdentifier:identifier requestCleanup:YES];
                @try {
                    if (completion) completion(result);
                } @finally {
                    operationFinished();
                }
            };
            if (generation != [self currentCacheGeneration]) {
                finish(NO);
                return;
            }
            WCTDatabase *db = [NLDataBaseManager sharedManager].database;
            NLAudioCacheInfo *info = [db getObjectOfClass:NLAudioCacheInfo.class
                                                 fromTable:kAudioCacheTableName
                                                      where:NLAudioCacheInfo.cacheIdentifier == identifier];
            if (!info) {
                finish(NO);
                return;
            }
            if ([self isCommittedCacheInfo:info]) {
                finish(YES);
                return;
            }

            NSString *tempPath = [self tempFilePathForURL:url cacheKey:cacheKey];
            if (NLFileExists(tempPath) && ![self syncFileAtPath:tempPath]) {
                finish(NO);
                return;
            }

            NSMutableArray<NSValue *> *allRanges = [[self parseRangesFromString:info.cachedRangesString] mutableCopy] ?: [NSMutableArray array];
            [allRanges addObjectsFromArray:sessionRanges];
            NSArray<NSValue *> *merged = [self mergeRanges:allRanges totalLength:info.totalLength];
            info.cachedRangesString = [self stringFromRanges:merged];
            info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
            if (![db insertOrReplaceObject:info intoTable:kAudioCacheTableName]) {
                finish(NO);
                return;
            }

            finish([self promoteCacheInfo:info notificationURL:url]);
        });
    }];
}

- (void)mergeAndSaveSessionRanges:(NSArray<NSValue *> *)sessionRanges forURL:(NSURL *)url {
    [self mergeAndSaveSessionRanges:sessionRanges forURL:url cacheKey:nil completion:nil];
}

- (BOOL)cachedRangesCoverFullLengthForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NLAudioCacheInfo *info = [self infoForURL:url cacheKey:cacheKey];
    return info && [self ranges:[self parseRangesFromString:info.cachedRangesString] coverTotalLength:info.totalLength];
}

- (BOOL)cachedRangesCoverFullLengthForURL:(NSURL *)url {
    return [self cachedRangesCoverFullLengthForURL:url cacheKey:nil];
}

- (void)finishCacheForURL:(NSURL *)url
                 cacheKey:(NSString *)cacheKey
               completion:(void (^)(BOOL))completion {
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    NSUInteger generation = [self currentCacheGeneration];
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        [self beginWriteForIdentifier:identifier];
        dispatch_async(NLQueueForIdentifier(identifier), ^{
            BOOL success = NO;
            if (generation == [self currentCacheGeneration]) {
                WCTDatabase *db = [NLDataBaseManager sharedManager].database;
                NLAudioCacheInfo *info = [db getObjectOfClass:NLAudioCacheInfo.class
                                                     fromTable:kAudioCacheTableName
                                                          where:NLAudioCacheInfo.cacheIdentifier == identifier];
                success = info && [self promoteCacheInfo:info notificationURL:url];
            }
            [self endWriteForIdentifier:identifier];
            [self recordCacheSizesForIdentifier:identifier requestCleanup:YES];
            @try {
                if (completion) completion(success);
            } @finally {
                operationFinished();
            }
        });
    }];
}

- (void)finishCacheForURL:(NSURL *)url {
    [self finishCacheForURL:url cacheKey:nil completion:nil];
}

#pragma mark - Cleanup and recovery

- (long long)fileSizeAtPath:(NSString *)path {
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] longLongValue];
}

- (NSSet<NSString *> *)protectedIdentifiers {
    NSMutableSet<NSString *> *protectedIdentifiers = [NSMutableSet set];
    if (self.currentPlayingCacheKey.length) {
        NSString *identifier = self.currentPlayingURL ? [self sha256StringFromString:self.currentPlayingCacheKey]
                                                      : [self fullyCachedInfoForSongId:self.currentPlayingCacheKey].cacheIdentifier;
        if (identifier.length) [protectedIdentifiers addObject:identifier];
    }
    if (self.currentPlayingURL) [protectedIdentifiers addObject:[self sha256StringFromURL:self.currentPlayingURL]];
    [self.ownershipLock lock];
    [protectedIdentifiers addObjectsFromArray:self.activeWriteCounts.allKeys];
    [self.ownershipLock unlock];
    for (NLDownloadItem *item in [NLDownloadRepository allDownloadItems]) {
        if (![item.status isEqualToString:@"downloading"] && ![item.status isEqualToString:@"completed"]) continue;
        NSString *cacheKey = [self cacheIdentityForURL:item.playURL cacheKey:item.songId];
        NSString *identifier = item.playURL ? [self identifierForURL:item.playURL cacheKey:cacheKey]
                                            : [self fullyCachedInfoForSongId:item.songId].cacheIdentifier;
        if (identifier.length) [protectedIdentifiers addObject:identifier];
    }
    return protectedIdentifiers;
}

- (void)trimCacheTierWithHighWatermark:(long long)high lowWatermark:(long long)low finished:(BOOL)finished {
    WCTDatabase *db = [NLDataBaseManager sharedManager].database;
    NSArray<NLAudioCacheInfo *> *infos = [db getObjectsOfClass:NLAudioCacheInfo.class fromTable:kAudioCacheTableName];
    if (!infos) return;

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    long long size = 0;
    NSString *suffix = finished ? @".mp3" : @".tmp";
    for (NLAudioCacheInfo *info in infos) {
        NSString *path = [self.cacheDirectory stringByAppendingPathComponent:[info.cacheIdentifier stringByAppendingString:suffix]];
        long long fileSize = [self fileSizeAtPath:path];
        if (fileSize <= 0) continue;
        size += fileSize;
        [candidates addObject:@{@"info": info, @"path": path}];
    }
    if (size < high) return;

    NSSet *protectedIdentifiers = [self protectedIdentifiers];
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [@([left[@"info"] lastAccessTime]) compare:@([right[@"info"] lastAccessTime])];
    }];
    for (NSDictionary *candidate in candidates) {
        NLAudioCacheInfo *info = candidate[@"info"];
        if ([protectedIdentifiers containsObject:info.cacheIdentifier]) continue;
        __block long long removedSize = 0;
        dispatch_sync(NLQueueForIdentifier(info.cacheIdentifier), ^{
            // Playback or download ownership may have changed while candidates were sorted.
            if ([[self protectedIdentifiers] containsObject:info.cacheIdentifier]) return;
            [self.ownershipLock lock];
            if (self.activeWriteCounts[info.cacheIdentifier].unsignedIntegerValue == 0) {
                long long currentSize = [self fileSizeAtPath:candidate[@"path"]];
                if ([[NSFileManager defaultManager] removeItemAtPath:candidate[@"path"] error:nil]) {
                    removedSize = currentSize;
                    [db deleteFromTable:kAudioCacheTableName where:NLAudioCacheInfo.cacheIdentifier == info.cacheIdentifier];
                }
            }
            [self.ownershipLock unlock];
            [self recordCacheSizesForIdentifier:info.cacheIdentifier requestCleanup:NO];
        });
        size -= removedSize;
        if (size <= low) break;
    }
}

- (void)clearAllCache {
    [self advanceCacheGeneration];
    self.currentPlayingURL = nil;
    self.currentPlayingCacheKey = nil;
    [self whenReadyOnQueue:self.admissionQueue perform:^{
        self.clearBarrierActive = YES;
        self.pendingClearCount += 1;
        [self startClearIfIdle];
    }];
}

- (void)reconcileCacheDirectory {
    WCTDatabase *db = [NLDataBaseManager sharedManager].database;
    NSArray<NLAudioCacheInfo *> *infos = [db getObjectsOfClass:NLAudioCacheInfo.class fromTable:kAudioCacheTableName];
    NSError *directoryError = nil;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.cacheDirectory error:&directoryError];
    if (!infos || !names || directoryError) return;

    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (NLAudioCacheInfo *info in infos) {
        if (info.cacheIdentifier.length == 0) continue;
        NSString *tempPath = [self.cacheDirectory stringByAppendingPathComponent:[info.cacheIdentifier stringByAppendingString:@".tmp"]];
        if ([self isCommittedCacheInfo:info]) {
            [known addObject:info.cacheIdentifier];
            // A valid committed body supersedes any leftover temporary file.
            if (NLFileExists(tempPath)) [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            continue;
        }

        BOOL hasTemp = NLFileExists(tempPath);
        BOOL completeLedger = [self hasCompleteLedger:info];
        BOOL recoverable = completeLedger &&
            (hasTemp ? [self hasMatchingBody:info finished:NO] : [self hasMatchingBody:info finished:YES]);
        if (recoverable) {
            [self promoteCacheInfo:info notificationURL:nil];
            // Keep a valid candidate even when the metadata commit fails; it is not a cache hit yet.
            [known addObject:info.cacheIdentifier];
            continue;
        }
        if (hasTemp) {
            if (info.isFinished) {
                info.isFinished = NO;
                [db insertOrReplaceObject:info intoTable:kAudioCacheTableName];
            }
            [known addObject:info.cacheIdentifier];
            continue;
        }

        [db deleteFromTable:kAudioCacheTableName where:NLAudioCacheInfo.cacheIdentifier == info.cacheIdentifier];
    }
    for (NSString *name in names) {
        NSString *identifier = [name stringByDeletingPathExtension];
        if (![known containsObject:identifier]) {
            [[NSFileManager defaultManager] removeItemAtPath:[self.cacheDirectory stringByAppendingPathComponent:name] error:nil];
        }
    }
}

#pragma mark - Range serialization

- (NSArray<NSValue *> *)parseRangesFromString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *array = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![array isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSDictionary *dictionary in array) {
        if (![dictionary isKindOfClass:NSDictionary.class]) continue;
        long long location = [dictionary[@"loc"] longLongValue];
        long long length = [dictionary[@"len"] longLongValue];
        if (location < 0 || length <= 0 || location > NSUIntegerMax || length > NSUIntegerMax ||
            (unsigned long long)location + (unsigned long long)length > NSUIntegerMax) continue;
        [ranges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)location, (NSUInteger)length)]];
    }
    return ranges;
}

- (NSString *)stringFromRanges:(NSArray<NSValue *> *)ranges {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:ranges.count];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        [array addObject:@{ @"loc": @(range.location), @"len": @(range.length) }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
}

@end
