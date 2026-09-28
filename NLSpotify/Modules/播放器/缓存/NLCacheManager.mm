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

static NSString * const kAudioCacheTableName = @"AudioCacheInfoTable";
static const NSUInteger kCacheQueueCount = 8;
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
- (void)cleanCacheTierWithMaxSize:(long long)maxSize finished:(BOOL)finished;
- (nullable NLAudioCacheInfo *)fullyCachedInfoForSongId:(NSString *)songId;
- (NSArray<NSValue *> *)parseRangesFromString:(NSString *)string;
- (NSString *)stringFromRanges:(NSArray<NSValue *> *)ranges;
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path atOffset:(long long)offset;
- (BOOL)syncFileAtPath:(NSString *)path;
- (long long)fileSizeAtPath:(NSString *)path;
- (NSArray<NSValue *> *)mergeRanges:(NSArray<NSValue *> *)ranges totalLength:(long long)totalLength;
- (BOOL)ranges:(NSArray<NSValue *> *)ranges coverTotalLength:(long long)totalLength;
- (BOOL)promoteURL:(NSURL *)url cacheKey:(NSString *)cacheKey info:(NLAudioCacheInfo *)info;
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

    void (^reconcile)(NLCacheManager *) = [reconciliationBlock copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            BOOL directoryReady = [[NSFileManager defaultManager] createDirectoryAtPath:self.cacheDirectory
                                                             withIntermediateDirectories:YES
                                                                              attributes:nil
                                                                                   error:nil];
            WCTDatabase *db = [NLDataBaseManager sharedManager].database;
            BOOL tableReady = directoryReady && db && [db createTable:kAudioCacheTableName withClass:NLAudioCacheInfo.class];
            if (tableReady) {
                if (reconcile) reconcile(self);
                else [self reconcileCacheDirectory];
            }
        } @catch (NSException *exception) {
            NSLog(@"[缓存] 启动对账异常，跳过后续修复: %@", exception);
        } @finally {
            [self markReady];
        }
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

#pragma mark - Identity

- (NSString *)md5StringFromString:(NSString *)value {
    if (value.length == 0) return @"";
    const char *bytes = value.UTF8String;
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(bytes, (CC_LONG)strlen(bytes), result);
    NSMutableString *md5 = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) {
        [md5 appendFormat:@"%02x", result[index]];
    }
    return md5;
}

- (NSString *)md5StringFromURL:(NSURL *)url {
    return [self md5StringFromString:url.absoluteString ?: @""];
}

- (NSString *)cacheIdentityForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    NSString *variant = [host stringByAppendingString:path];
    return variant.length > 0 ? [cacheKey stringByAppendingFormat:@"\n%@", variant] : cacheKey;
}

- (NSString *)identifierForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    return cacheKey.length > 0 ? [self md5StringFromString:cacheKey] : [self md5StringFromURL:url];
}

#pragma mark - Paths and metadata

- (NSString *)tempFilePathForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *identifier = [self identifierForURL:url cacheKey:cacheKey];
    return identifier.length == 0 ? @"" : [self.cacheDirectory stringByAppendingPathComponent:[identifier stringByAppendingString:@".tmp"]];
}

- (NSString *)cacheFilePathForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NSString *identifier = url ? [self identifierForURL:url cacheKey:cacheKey]
                               : ([self fullyCachedInfoForSongId:cacheKey].urlMD5 ?: [self identifierForURL:url cacheKey:cacheKey]);
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
        if (!info.isFinished || info.totalLength <= 0 || (latest && info.lastAccessTime <= latest.lastAccessTime)) continue;
        NSString *path = [self.cacheDirectory stringByAppendingPathComponent:[info.urlMD5 stringByAppendingString:@".mp3"]];
        if ([self fileSizeAtPath:path] == info.totalLength) latest = info;
    }
    if (latest) return latest;
    NLAudioCacheInfo *legacy = [db getObjectOfClass:NLAudioCacheInfo.class
                                          fromTable:kAudioCacheTableName
                                              where:NLAudioCacheInfo.urlMD5 == [self md5StringFromString:songId]];
    if (!legacy) return nil;
    NSString *legacyPath = [self.cacheDirectory stringByAppendingPathComponent:[legacy.urlMD5 stringByAppendingString:@".mp3"]];
    return legacy.isFinished && legacy.totalLength > 0 && [self fileSizeAtPath:legacyPath] == legacy.totalLength ? legacy : nil;
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
            where:NLAudioCacheInfo.urlMD5 == identifier];
}

- (BOOL)isFullyCachedForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    NLAudioCacheInfo *info = [self infoForURL:url cacheKey:cacheKey];
    if (!info || !info.isFinished || info.totalLength <= 0) return NO;
    NSString *path = [self cacheFilePathForURL:url cacheKey:cacheKey];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileSize] longLongValue] == info.totalLength;
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
                                   : [self fullyCachedInfoForSongId:cacheKey].urlMD5;
        if (identifier.length == 0) {
            operationFinished();
            return;
        }
        [self beginWriteForIdentifier:identifier];
        dispatch_async(NLQueueForIdentifier(identifier), ^{
            WCTDatabase *db = [NLDataBaseManager sharedManager].database;
            NLAudioCacheInfo *info = [db getObjectOfClass:NLAudioCacheInfo.class
                                                 fromTable:kAudioCacheTableName
                                                      where:NLAudioCacheInfo.urlMD5 == identifier];
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
                                                      where:NLAudioCacheInfo.urlMD5 == identifier];
            if (!info) {
                info = [[NLAudioCacheInfo alloc] init];
                info.urlMD5 = identifier;
                info.cachedRangesString = @"[]";
                info.isFinished = NO;
            }
            if (cacheKey.length > 0) {
                NSRange variantSeparator = [cacheKey rangeOfString:@"\n"];
                info.songId = variantSeparator.location == NSNotFound ? cacheKey : [cacheKey substringToIndex:variantSeparator.location];
            }
            if (info.isFinished) {
                NSString *cachePath = [self cacheFilePathForURL:url cacheKey:cacheKey];
                if ([self fileSizeAtPath:cachePath] == info.totalLength && info.totalLength > 0) {
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

- (BOOL)promoteURL:(NSURL *)url cacheKey:(NSString *)cacheKey info:(NLAudioCacheInfo *)info {
    NSString *tempPath = [self tempFilePathForURL:url cacheKey:cacheKey];
    NSString *cachePath = [self cacheFilePathForURL:url cacheKey:cacheKey];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:tempPath error:nil];
    if (!attributes || info.totalLength <= 0 || [attributes[NSFileSize] longLongValue] != info.totalLength) return NO;
    if (![self syncFileAtPath:tempPath]) return NO;
    if (rename(tempPath.UTF8String, cachePath.UTF8String) != 0) return NO;

    info.isFinished = YES;
    info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
    BOOL saved = [[NLDataBaseManager sharedManager].database insertOrReplaceObject:info intoTable:kAudioCacheTableName];
    if (!saved) {
        rename(cachePath.UTF8String, tempPath.UTF8String);
        return NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NLCacheManagerDidFinishCachingNotification
                                                            object:self
                                                          userInfo:url ? @{ @"url": url } : nil];
    });
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
                                                      where:NLAudioCacheInfo.urlMD5 == identifier];
            if (!info) {
                finish(NO);
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

            BOOL complete = [self ranges:merged coverTotalLength:info.totalLength];
            BOOL promoted = complete && [self promoteURL:url cacheKey:cacheKey info:info];
            finish(promoted || (complete && info.isFinished));
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
                                                          where:NLAudioCacheInfo.urlMD5 == identifier];
                success = info && [self ranges:[self parseRangesFromString:info.cachedRangesString] coverTotalLength:info.totalLength] &&
                    [self promoteURL:url cacheKey:cacheKey info:info];
            }
            [self endWriteForIdentifier:identifier];
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
        NSString *identifier = self.currentPlayingURL ? [self md5StringFromString:self.currentPlayingCacheKey]
                                                      : [self fullyCachedInfoForSongId:self.currentPlayingCacheKey].urlMD5;
        if (identifier.length) [protectedIdentifiers addObject:identifier];
    }
    if (self.currentPlayingURL) [protectedIdentifiers addObject:[self md5StringFromURL:self.currentPlayingURL]];
    [self.ownershipLock lock];
    [protectedIdentifiers addObjectsFromArray:self.activeWriteCounts.allKeys];
    [self.ownershipLock unlock];
    for (NLDownloadItem *item in [NLDownloadRepository allDownloadItems]) {
        if (![item.status isEqualToString:@"downloading"] && ![item.status isEqualToString:@"completed"]) continue;
        NSString *cacheKey = [self cacheIdentityForURL:item.playURL cacheKey:item.songId];
        NSString *identifier = item.playURL ? [self identifierForURL:item.playURL cacheKey:cacheKey]
                                            : [self fullyCachedInfoForSongId:item.songId].urlMD5;
        if (identifier.length) [protectedIdentifiers addObject:identifier];
    }
    return protectedIdentifiers;
}

- (void)cleanCacheTierWithMaxSize:(long long)maxSize finished:(BOOL)finished {
    [self enqueueCacheOperation:^(dispatch_block_t operationFinished) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                WCTDatabase *db = [NLDataBaseManager sharedManager].database;
                NSArray<NLAudioCacheInfo *> *infos = [db getObjectsOfClass:NLAudioCacheInfo.class fromTable:kAudioCacheTableName];
                if (!infos) return;

                NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
                long long size = 0;
                NSString *suffix = finished ? @".mp3" : @".tmp";
                for (NLAudioCacheInfo *info in infos) {
                    if (info.isFinished != finished) continue;
                    NSString *path = [self.cacheDirectory stringByAppendingPathComponent:[info.urlMD5 stringByAppendingString:suffix]];
                    long long fileSize = [self fileSizeAtPath:path];
                    if (fileSize <= 0) continue;
                    size += fileSize;
                    [candidates addObject:@{@"info": info, @"path": path, @"size": @(fileSize)}];
                }
                if (size <= maxSize) return;

                NSSet *protectedIdentifiers = [self protectedIdentifiers];
                [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
                    return [@([left[@"info"] lastAccessTime]) compare:@([right[@"info"] lastAccessTime])];
                }];
                for (NSDictionary *candidate in candidates) {
                    NLAudioCacheInfo *info = candidate[@"info"];
                    if ([protectedIdentifiers containsObject:info.urlMD5]) continue;
                    __block BOOL deleted = NO;
                    dispatch_sync(NLQueueForIdentifier(info.urlMD5), ^{
                        [self.ownershipLock lock];
                        if (self.activeWriteCounts[info.urlMD5].unsignedIntegerValue == 0) {
                            deleted = [[NSFileManager defaultManager] removeItemAtPath:candidate[@"path"] error:nil];
                            if (deleted) [db deleteFromTable:kAudioCacheTableName where:NLAudioCacheInfo.urlMD5 == info.urlMD5];
                        }
                        [self.ownershipLock unlock];
                    });
                    if (deleted) size -= [candidate[@"size"] longLongValue];
                    if (size <= maxSize) break;
                }
            } @finally {
                operationFinished();
            }
        });
    }];
}

- (void)cleanPartialCacheWithMaxSize:(long long)maxSize {
    [self cleanCacheTierWithMaxSize:maxSize finished:NO];
}

- (void)cleanCompletedCacheWithMaxSize:(long long)maxSize {
    [self cleanCacheTierWithMaxSize:maxSize finished:YES];
}

- (void)cleanCacheWithMaxSize:(long long)maxSize {
    [self cleanPartialCacheWithMaxSize:128 * 1024 * 1024];
    [self cleanCompletedCacheWithMaxSize:maxSize];
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
        if (info.urlMD5.length == 0) continue;
        NSString *tempPath = [self.cacheDirectory stringByAppendingPathComponent:[info.urlMD5 stringByAppendingString:@".tmp"]];
        NSString *cachePath = [self.cacheDirectory stringByAppendingPathComponent:[info.urlMD5 stringByAppendingString:@".mp3"]];
        if (info.isFinished) {
            if (NLFileExists(cachePath)) {
                [known addObject:info.urlMD5];
            } else {
                [db deleteFromTable:kAudioCacheTableName where:NLAudioCacheInfo.urlMD5 == info.urlMD5];
            }
            continue;
        }

        if (NLFileExists(tempPath)) {
            [known addObject:info.urlMD5];
            continue;
        }

        BOOL hasRenamedAudio = NLFileExists(cachePath);
        BOOL completeLedger = [self ranges:[self parseRangesFromString:info.cachedRangesString] coverTotalLength:info.totalLength];
        BOOL matchingLength = hasRenamedAudio && [self fileSizeAtPath:cachePath] == info.totalLength;
        if (info.totalLength > 0 && completeLedger && matchingLength) {
            NSTimeInterval previousAccessTime = info.lastAccessTime;
            info.isFinished = YES;
            info.lastAccessTime = [NSDate date].timeIntervalSince1970 * 1000.0;
            if ([db insertOrReplaceObject:info intoTable:kAudioCacheTableName]) {
                [known addObject:info.urlMD5];
                continue;
            }
            info.isFinished = NO;
            info.lastAccessTime = previousAccessTime;
            [known addObject:info.urlMD5];
            continue;
        }

        [db deleteFromTable:kAudioCacheTableName where:NLAudioCacheInfo.urlMD5 == info.urlMD5];
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
