#import "NLCommentLayoutCoordinator.h"

@interface NLCommentLayoutWork : NSObject
@property (nonatomic, strong) NSBlockOperation *operation;
@property (nonatomic, strong) NSMutableArray<void (^)(NLCommentTextLayout *)> *completions;
@end
@implementation NLCommentLayoutWork
@end

@interface NLCommentLayoutCoordinator ()
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) NSCache<NSString *, NLCommentTextLayout *> *cache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NLCommentLayoutWork *> *inFlight;
@property (nonatomic) NSUInteger generation;
@end

@implementation NLCommentLayoutCoordinator
- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSOperationQueue new];
        _queue.name = @"com.nlspotify.comment-layout";
        _queue.maxConcurrentOperationCount = 2;
        _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        _cache = [NSCache new];
        _cache.countLimit = 256;
        _cache.totalCostLimit = 8 * 1024 * 1024;
        _inFlight = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [_queue cancelAllOperations];
}

- (void)requestLayoutForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale completion:(void (^)(NLCommentTextLayout *))completion {
    NSAssert(NSThread.isMainThread, @"Layout requests belong to the main thread");
    NSString *snapshot = [text copy] ?: @"";
    NSString *key = [NLCommentTextLayout cacheKeyForText:snapshot width:width font:font displayScale:displayScale];
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    NLCommentTextLayout *cached = [self.cache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf && weakSelf.generation == generation) completion(cached);
        });
        return;
    }
    NLCommentLayoutWork *work = self.inFlight[key];
    if (work) {
        [work.completions addObject:[completion copy]];
        return;
    }
    work = [NLCommentLayoutWork new];
    work.completions = [NSMutableArray arrayWithObject:[completion copy]];
    work.operation = [NSBlockOperation new];
    self.inFlight[key] = work;
    __weak NLCommentLayoutWork *weakWork = work;
    [work.operation addExecutionBlock:^{
        @autoreleasepool {
            NLCommentLayoutWork *current = weakWork;
            if (!current || current.operation.cancelled) return;
            NLCommentTextLayout *layout = [NLCommentTextLayout layoutForText:snapshot width:width font:font displayScale:displayScale];
            if (current.operation.cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.generation || self.inFlight[key] != current) return;
                [self.inFlight removeObjectForKey:key];
                NSUInteger cost = (layout.sourceText.length + layout.collapsedText.length + layout.expandedText.length) * sizeof(unichar);
                [self.cache setObject:layout forKey:key cost:cost];
                NSArray *callbacks = [current.completions copy];
                [current.completions removeAllObjects];
                for (void (^callback)(NLCommentTextLayout *) in callbacks) {
                    // A previous callback may have invalidated this page.
                    if (self.generation != generation) break;
                    callback(layout);
                }
            });
        }
    }];
    [self.queue addOperation:work.operation];
}

- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Layout invalidation belongs to the main thread");
    self.generation += 1;
    [self.queue cancelAllOperations];
    [self.inFlight removeAllObjects];
    [self.cache removeAllObjects];
}
@end
