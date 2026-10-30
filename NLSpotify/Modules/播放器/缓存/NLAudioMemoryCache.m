#import "NLAudioMemoryCache.h"
#import <UIKit/UIKit.h>

static const NSUInteger kNLAudioMemoryCacheCostLimit = 12 * 1024 * 1024;
static const NSUInteger kNLAudioMemoryCacheCountLimit = 512;

@interface NLAudioMemorySegment : NSObject
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, copy) NSString *urlKey;
@property (nonatomic, assign) long long offset;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, readonly) long long endOffset;
@end

@implementation NLAudioMemorySegment

- (long long)endOffset {
    return self.offset + (long long)self.data.length;
}

@end

/// 索引只记录 Range 与 key，绝不持有 NSData，保证 NSCache 的淘汰能真正释放音频内存。
@interface NLAudioMemorySegmentDescriptor : NSObject
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, assign) long long offset;
@property (nonatomic, assign) long long endOffset;
@end

@implementation NLAudioMemorySegmentDescriptor
@end

@interface NLAudioMemoryCache () <NSCacheDelegate>
@property (nonatomic, strong) NSCache<NSString *, NLAudioMemorySegment *> *segments;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NLAudioMemorySegmentDescriptor *> *> *descriptorsByURL;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation NLAudioMemoryCache

+ (instancetype)sharedCache {
    static NLAudioMemoryCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[self alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _segments = [[NSCache alloc] init];
        _segments.name = @"com.nlspotify.audio-memory-cache";
        _segments.totalCostLimit = kNLAudioMemoryCacheCostLimit;
        _segments.countLimit = kNLAudioMemoryCacheCountLimit;
        _segments.delegate = self;
        _descriptorsByURL = [NSMutableDictionary dictionary];
        _stateQueue = dispatch_queue_create("com.nlspotify.audio-memory-cache.state", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)storeData:(NSData *)data forURL:(NSURL *)url atOffset:(long long)offset {
    [self storeData:data cacheKey:url.absoluteString atOffset:offset];
}

- (void)storeData:(NSData *)data cacheKey:(NSString *)cacheKey atOffset:(long long)offset {
    if (data.length == 0 || cacheKey.length == 0 || offset < 0) return;

    NSString *urlKey = cacheKey;
    NSData *newData = [data copy];
    dispatch_sync(self.stateQueue, ^{
        NSMutableArray<NLAudioMemorySegmentDescriptor *> *descriptors = self.descriptorsByURL[urlKey];
        if (!descriptors) {
            descriptors = [NSMutableArray array];
            self.descriptorsByURL[urlKey] = descriptors;
        }

        long long mergedStart = offset;
        long long mergedEnd = offset + (long long)newData.length;
        NSMutableArray<NLAudioMemorySegment *> *overlappingSegments = [NSMutableArray array];
        NSMutableArray<NLAudioMemorySegmentDescriptor *> *staleDescriptors = [NSMutableArray array];

        for (NLAudioMemorySegmentDescriptor *descriptor in descriptors) {
            if (descriptor.endOffset < mergedStart || descriptor.offset > mergedEnd) continue;
            NLAudioMemorySegment *candidate = [self.segments objectForKey:descriptor.cacheKey];
            if (!candidate) {
                [staleDescriptors addObject:descriptor];
                continue;
            }
            [overlappingSegments addObject:candidate];
            mergedStart = MIN(mergedStart, candidate.offset);
            mergedEnd = MAX(mergedEnd, candidate.endOffset);
        }

        NSMutableData *mergedData = [NSMutableData dataWithLength:(NSUInteger)(mergedEnd - mergedStart)];
        for (NLAudioMemorySegment *candidate in overlappingSegments) {
            [mergedData replaceBytesInRange:NSMakeRange((NSUInteger)(candidate.offset - mergedStart), candidate.data.length) withBytes:candidate.data.bytes];
        }
        [mergedData replaceBytesInRange:NSMakeRange((NSUInteger)(offset - mergedStart), newData.length) withBytes:newData.bytes];

        NSMutableSet<NSString *> *removedKeys = [NSMutableSet set];
        for (NLAudioMemorySegmentDescriptor *descriptor in staleDescriptors) {
            [removedKeys addObject:descriptor.cacheKey];
        }
        for (NLAudioMemorySegment *candidate in overlappingSegments) {
            [removedKeys addObject:candidate.cacheKey];
            [self.segments removeObjectForKey:candidate.cacheKey];
        }
        if (removedKeys.count > 0) {
            [descriptors filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NLAudioMemorySegmentDescriptor *descriptor, NSDictionary *bindings) {
                return ![removedKeys containsObject:descriptor.cacheKey];
            }]];
        }

        NLAudioMemorySegment *segment = [[NLAudioMemorySegment alloc] init];
        segment.urlKey = urlKey;
        segment.offset = mergedStart;
        segment.data = [mergedData copy];
        segment.cacheKey = [self cacheKeyForURLKey:urlKey offset:mergedStart];

        NLAudioMemorySegmentDescriptor *descriptor = [[NLAudioMemorySegmentDescriptor alloc] init];
        descriptor.cacheKey = segment.cacheKey;
        descriptor.offset = segment.offset;
        descriptor.endOffset = segment.endOffset;
        NSUInteger insertionIndex = [descriptors indexOfObject:descriptor inSortedRange:NSMakeRange(0, descriptors.count) options:NSBinarySearchingInsertionIndex usingComparator:^NSComparisonResult(NLAudioMemorySegmentDescriptor *left, NLAudioMemorySegmentDescriptor *right) {
            if (left.offset < right.offset) return NSOrderedAscending;
            if (left.offset > right.offset) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        [descriptors insertObject:descriptor atIndex:insertionIndex];
        [self.segments setObject:segment forKey:segment.cacheKey cost:segment.data.length];
    });
}

- (NSData *)dataForURL:(NSURL *)url offset:(long long)offset length:(NSUInteger)length {
    return [self dataForCacheKey:url.absoluteString offset:offset length:length];
}

- (NSData *)dataForCacheKey:(NSString *)cacheKey offset:(long long)offset length:(NSUInteger)length {
    if (length == 0 || cacheKey.length == 0 || offset < 0) return nil;

    NSString *urlKey = cacheKey;
    __block NSArray<NLAudioMemorySegmentDescriptor *> *descriptors = nil;
    dispatch_sync(self.stateQueue, ^{
        descriptors = [self.descriptorsByURL[urlKey] copy];
    });

    NSMutableData *result = nil;
    long long cursor = offset;
    NSUInteger remaining = length;
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    for (NLAudioMemorySegmentDescriptor *descriptor in descriptors) {
        if (descriptor.endOffset <= cursor) continue;
        if (descriptor.offset > cursor) break;

        NLAudioMemorySegment *segment = [self.segments objectForKey:descriptor.cacheKey];
        if (!segment) {
            [staleKeys addObject:descriptor.cacheKey];
            continue;
        }
        NSUInteger segmentOffset = (NSUInteger)(cursor - segment.offset);
        NSUInteger available = segment.data.length - segmentOffset;
        NSUInteger takeLength = MIN(available, remaining);
        if (!result) {
            result = [NSMutableData dataWithData:[segment.data subdataWithRange:NSMakeRange(segmentOffset, takeLength)]];
        } else {
            [result appendData:[segment.data subdataWithRange:NSMakeRange(segmentOffset, takeLength)]];
        }
        cursor += (long long)takeLength;
        remaining -= takeLength;
        if (remaining == 0) break;
    }

    if (staleKeys.count > 0) {
        dispatch_async(self.stateQueue, ^{
            [self removeDescriptorsWithKeys:[NSSet setWithArray:staleKeys] forURLKey:urlKey];
        });
    }
    return result.length > 0 ? [result copy] : nil;
}

- (long long)nextCachedOffsetForURL:(NSURL *)url afterOffset:(long long)offset {
    return [self nextCachedOffsetForCacheKey:url.absoluteString afterOffset:offset];
}

- (long long)nextCachedOffsetForCacheKey:(NSString *)cacheKey afterOffset:(long long)offset {
    if (cacheKey.length == 0 || offset < 0) return NSNotFound;

    NSString *urlKey = cacheKey;
    __block NSArray<NLAudioMemorySegmentDescriptor *> *descriptors = nil;
    dispatch_sync(self.stateQueue, ^{
        descriptors = [self.descriptorsByURL[urlKey] copy];
    });
    for (NLAudioMemorySegmentDescriptor *descriptor in descriptors) {
        if (descriptor.offset <= offset) continue;
        if ([self.segments objectForKey:descriptor.cacheKey]) return descriptor.offset;
    }
    return NSNotFound;
}

- (void)removeDataForURL:(NSURL *)url {
    [self removeDataForCacheKey:url.absoluteString];
}

- (void)removeDataForCacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return;
    NSString *urlKey = cacheKey;
    dispatch_sync(self.stateQueue, ^{
        NSArray<NLAudioMemorySegmentDescriptor *> *descriptors = [self.descriptorsByURL[urlKey] copy];
        [self.descriptorsByURL removeObjectForKey:urlKey];
        for (NLAudioMemorySegmentDescriptor *descriptor in descriptors) {
            [self.segments removeObjectForKey:descriptor.cacheKey];
        }
    });
}

- (void)removeAllData {
    dispatch_sync(self.stateQueue, ^{
        [self.segments removeAllObjects];
        [self.descriptorsByURL removeAllObjects];
    });
}

- (void)handleMemoryWarning:(NSNotification *)notification {
    [self removeAllData];
}

- (void)cache:(NSCache *)cache willEvictObject:(id)obj {
    if (![obj isKindOfClass:NLAudioMemorySegment.class]) return;
    NLAudioMemorySegment *segment = obj;
    dispatch_async(self.stateQueue, ^{
        // 若同 key 已被新对象替换，旧对象的淘汰通知不得删除新 Range 描述符。
        if ([self.segments objectForKey:segment.cacheKey]) return;
        [self removeDescriptorsWithKeys:[NSSet setWithObject:segment.cacheKey] forURLKey:segment.urlKey];
    });
}

- (void)removeDescriptorsWithKeys:(NSSet<NSString *> *)keys forURLKey:(NSString *)urlKey {
    NSMutableArray<NLAudioMemorySegmentDescriptor *> *descriptors = self.descriptorsByURL[urlKey];
    if (!descriptors) return;
    [descriptors filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NLAudioMemorySegmentDescriptor *descriptor, NSDictionary *bindings) {
        return ![keys containsObject:descriptor.cacheKey];
    }]];
    if (descriptors.count == 0) {
        [self.descriptorsByURL removeObjectForKey:urlKey];
    }
}

- (NSString *)cacheKeyForURLKey:(NSString *)urlKey offset:(long long)offset {
    return [NSString stringWithFormat:@"%@\n%lld", urlKey, offset];
}

@end
