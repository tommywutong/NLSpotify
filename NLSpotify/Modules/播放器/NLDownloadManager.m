//
//  NLDownloadManager.m
//  NLSpotify
//

#import "NLDownloadManager.h"
#import "NLCacheManager.h"
#import "NLHTTPRangeValidator.h"
#import "NLDownloadItem.h"
#import "NLDownloadRepository.h"
#import "NLSongRepository.h"
#import "NLSongService.h"
#import "NLSong.h"

NSNotificationName const NLDownloadManagerDidUpdateNotification = @"NLDownloadManagerDidUpdateNotification";

@interface NLDownloadManager () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, id> *> *taskContextMap;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *taskMap;
@property (nonatomic, strong) NSMutableSet<NSString *> *activeSongIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *reservationGenerations;
@property (nonatomic, strong) NSLock *lock;
@property (atomic, assign) NSUInteger downloadGeneration;
@property (nonatomic, strong) NLCacheManager *cacheManager;
- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation;
- (void)releaseSongID:(NSString *)songID forGeneration:(NSUInteger)generation;
- (BOOL)isReservationActiveForSongID:(NSString *)songID;
- (void)beginDownloadForSong:(NLSong *)song generation:(NSUInteger)generation;
- (void)startDownloadWithSong:(NLSong *)song generation:(NSUInteger)generation;
- (void)finishDownloadContext:(NSMutableDictionary<NSString *, id> *)context
                       taskID:(NSNumber *)taskID
                   fullyCached:(BOOL)fullyCached;
@end

@implementation NLDownloadManager

+ (instancetype)sharedManager {
    static NLDownloadManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _cacheManager = [NLCacheManager sharedManager];
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                              delegate:self
                                         delegateQueue:delegateQueue];
    _taskContextMap = [NSMutableDictionary dictionary];
    _activeSongIDs = [NSMutableSet set];
    _reservationGenerations = [NSMutableDictionary dictionary];
    _lock = [[NSLock alloc] init];
    [self recoverInterruptedDownloads];
    return self;
}

- (void)postUpdateNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NLDownloadManagerDidUpdateNotification object:self];
    });
}

- (void)recoverInterruptedDownloads {
    for (NLDownloadItem *item in [NLDownloadRepository allDownloadItems]) {
        if ([item.status isEqualToString:@"downloading"]) {
            [NLDownloadRepository updateStatus:@"interrupted" forSongId:item.songId];
        }
    }
}

- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation {
    if (songID.length == 0) return NO;
    [self.lock lock];
    BOOL reserved = ![self.activeSongIDs containsObject:songID];
    if (reserved) {
        NSUInteger currentGeneration = self.downloadGeneration;
        [self.activeSongIDs addObject:songID];
        self.reservationGenerations[songID] = @(currentGeneration);
        if (generation) *generation = currentGeneration;
    }
    [self.lock unlock];
    return reserved;
}

- (void)releaseSongID:(NSString *)songID forGeneration:(NSUInteger)generation {
    if (songID.length == 0) return;
    [self.lock lock];
    NSNumber *reservationGeneration = self.reservationGenerations[songID];
    if (reservationGeneration && reservationGeneration.unsignedIntegerValue == generation) {
        [self.reservationGenerations removeObjectForKey:songID];
        [self.activeSongIDs removeObject:songID];
    }
    [self.lock unlock];
}

- (BOOL)isReservationActiveForSongID:(NSString *)songID {
    [self.lock lock];
    BOOL active = [self.activeSongIDs containsObject:songID];
    [self.lock unlock];
    return active;
}

- (void)addDownloadForSong:(NLSong *)song {
    NSUInteger generation = 0;
    if (!song || song.songId.length == 0 || ![self reserveSongID:song.songId generation:&generation]) return;
    __weak typeof(self) weakSelf = self;
    [self.cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.downloadGeneration || ![strongSelf isReservationActiveForSongID:song.songId]) return;
        [strongSelf beginDownloadForSong:song generation:generation];
    }];
}

- (void)beginDownloadForSong:(NLSong *)song generation:(NSUInteger)generation {
    if (generation != self.downloadGeneration || ![self isReservationActiveForSongID:song.songId]) return;
    NLDownloadItem *existing = [NLDownloadRepository downloadItemForSongId:song.songId];
    NLCacheManager *cacheManager = self.cacheManager;
    NSString *cacheKey = [cacheManager cacheIdentityForURL:song.playURL cacheKey:song.songId];
    if ([cacheManager isFullyCachedForURL:song.playURL cacheKey:cacheKey]) {
        if (![existing.status isEqualToString:@"completed"] &&
            [NLDownloadRepository addDownloadItemWithSong:song status:@"completed"]) {
            [NLSongRepository addDownloadedSong:song];
            [self postUpdateNotification];
        }
        [self releaseSongID:song.songId forGeneration:generation];
        return;
    }

    if (song.playURL) {
        [self startDownloadWithSong:song generation:generation];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[NLSongService sharedService] fetchPlayableURLWithSongId:song.songId
        success:^(NSURL *playURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || generation != strongSelf.downloadGeneration || ![strongSelf isReservationActiveForSongID:song.songId]) return;
                if (!playURL) {
                    [strongSelf releaseSongID:song.songId forGeneration:generation];
                    return;
                }
                song.playURL = playURL;
                [strongSelf startDownloadWithSong:song generation:generation];
            });
        }
        failure:^(NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.downloadGeneration || ![strongSelf isReservationActiveForSongID:song.songId]) return;
            [NLDownloadRepository updateStatus:@"failed" forSongId:song.songId];
            [strongSelf releaseSongID:song.songId forGeneration:generation];
            [strongSelf postUpdateNotification];
        }];
}

- (void)startDownloadWithSong:(NLSong *)song generation:(NSUInteger)generation {
    if (generation != self.downloadGeneration || ![self isReservationActiveForSongID:song.songId]) return;
    if (!song.playURL) {
        [NLDownloadRepository updateStatus:@"failed" forSongId:song.songId];
        [self releaseSongID:song.songId forGeneration:generation];
        return;
    }
    if (![NLDownloadRepository addDownloadItemWithSong:song status:@"downloading"]) {
        [self releaseSongID:song.songId forGeneration:generation];
        return;
    }
    [self postUpdateNotification];
    NLCacheManager *cacheManager = self.cacheManager;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:song.playURL];
    [request setValue:@"bytes=0-" forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    NSMutableDictionary *context = [@{
        @"generation": @(generation),
        @"url": song.playURL,
        @"cacheKey": [cacheManager cacheIdentityForURL:song.playURL cacheKey:song.songId],
        @"songId": song.songId,
        @"currentOffset": @(0LL),
        @"totalLength": @(0LL),
        @"requestedLength": @(NSIntegerMax),
        @"sessionRanges": [NSMutableArray array],
        @"writeGroup": (id)dispatch_group_create(),
        @"validResponse": @NO,
        @"cancelled": @NO
    } mutableCopy];
    [self.lock lock];
    self.taskContextMap[@(task.taskIdentifier)] = context;
    self.taskMap[@(task.taskIdentifier)] = task;
    [self.lock unlock];
    [task resume];
}

- (BOOL)isDownloadingSongId:(NSString *)songId {
    if (songId.length == 0) return NO;
    [self.lock lock];
    BOOL result = [self.activeSongIDs containsObject:songId];
    [self.lock unlock];
    return result;
}

- (void)cancelAllDownloads {
    [self.lock lock];
    self.downloadGeneration += 1;
    NSArray<NSMutableDictionary *> *contexts = [self.taskContextMap.allValues copy];
    NSArray<NSURLSessionDataTask *> *tasks = [self.taskMap.allValues copy];
    NSMutableSet<NSString *> *runningIDs = [NSMutableSet set];
    for (NSMutableDictionary *context in contexts) {
        if (![context[@"finishing"] boolValue]) context[@"cancelled"] = @YES;
        if ([context[@"songId"] length]) [runningIDs addObject:context[@"songId"]];
    }
    for (NSString *songID in [self.reservationGenerations.allKeys copy]) {
        if (![runningIDs containsObject:songID]) [self.reservationGenerations removeObjectForKey:songID];
    }
    [self.activeSongIDs intersectSet:runningIDs];
    [self.lock unlock];
    for (NSURLSessionDataTask *task in tasks) [task cancel];
    [self postUpdateNotification];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSNumber *taskID = @(dataTask.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    [self.lock unlock];
    if (!context) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    long long totalLength = 0;
    BOOL valid = [NLHTTPRangeValidator validateResponse:(NSHTTPURLResponse *)response
                                        requestedOffset:0
                                        requestedLength:NSIntegerMax
                                          responseStart:NULL
                                           totalLength:&totalLength];
    [self.lock lock];
    context[@"validResponse"] = @(valid);
    context[@"totalLength"] = @(totalLength);
    [self.lock unlock];
    if (!valid) {
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (data.length == 0) return;
    NSNumber *taskID = @(dataTask.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    BOOL valid = [context[@"validResponse"] boolValue] && ![context[@"cancelled"] boolValue];
    long long offset = [context[@"currentOffset"] longLongValue];
    context[@"currentOffset"] = @(offset + (long long)data.length);
    dispatch_group_t group = (dispatch_group_t)context[@"writeGroup"];
    NSURL *url = context[@"url"];
    NSString *cacheKey = context[@"cacheKey"];
    long long totalLength = [context[@"totalLength"] longLongValue];
    [self.lock unlock];
    if (!valid || !url) return;

    dispatch_group_enter(group);
    [self.cacheManager cacheData:data
                                      forURL:url
                                    cacheKey:cacheKey
                                   atOffset:offset
                                totalLength:totalLength
                                  completion:^(BOOL success) {
        [self.lock lock];
        if (success) {
            NSMutableArray *ranges = context[@"sessionRanges"];
            [ranges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)offset, data.length)]];
        }
        [self.lock unlock];
        dispatch_group_leave(group);
    }];
}

- (void)finishDownloadContext:(NSMutableDictionary<NSString *, id> *)context
                       taskID:(NSNumber *)taskID
                   fullyCached:(BOOL)fullyCached {
    NSString *songID = context[@"songId"];
    NSURL *url = context[@"url"];
    NSUInteger generation = [context[@"generation"] unsignedIntegerValue];

    [self.lock lock];
    NSNumber *activeGeneration = self.reservationGenerations[songID];
    BOOL superseded = activeGeneration && activeGeneration.unsignedIntegerValue != generation;
    BOOL cancelled = [context[@"cancelled"] boolValue] || generation != self.downloadGeneration || !activeGeneration;
    BOOL complete = fullyCached && !cancelled && !superseded;
    BOOL shouldRelease = activeGeneration && activeGeneration.unsignedIntegerValue == generation;
    BOOL ownsContext = self.taskContextMap[taskID] == context;
    if (!superseded && ownsContext) context[@"finishing"] = @YES;
    if (superseded && ownsContext) [self.taskContextMap removeObjectForKey:taskID];
    [self.lock unlock];
    if (superseded || !ownsContext) return;

    NSString *status = complete ? @"completed" : (cancelled ? @"cancelled" : @"failed");
    [NLDownloadRepository updateStatus:status forSongId:songID];
    if (complete) {
        NLDownloadItem *item = [NLDownloadRepository downloadItemForSongId:songID];
        if (item) {
            NLSong *song = [[NLSong alloc] initWithId:item.songId
                                                title:item.title ?: @""
                                               artist:item.artist ?: @""
                                             coverURL:item.coverURLString.length ? [NSURL URLWithString:item.coverURLString] : nil];
            song.playURL = url;
            [NLSongRepository addDownloadedSong:song];
        }
    }

    [self.lock lock];
    if (self.taskContextMap[taskID] == context) [self.taskContextMap removeObjectForKey:taskID];
    [self.lock unlock];
    if (shouldRelease) [self releaseSongID:songID forGeneration:generation];
    [self postUpdateNotification];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *taskID = @(task.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    [self.taskMap removeObjectForKey:taskID];
    [self.lock unlock];
    if (!context) return;

    dispatch_group_t group = (dispatch_group_t)context[@"writeGroup"];
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *url = context[@"url"];
        NSArray *ranges = [context[@"sessionRanges"] copy];
        BOOL valid = [context[@"validResponse"] boolValue];
        BOOL cancelled = [context[@"cancelled"] boolValue] || error.code == NSURLErrorCancelled;
        if (!valid || (error && !cancelled) || !url || ranges.count == 0) {
            [self finishDownloadContext:context taskID:taskID fullyCached:NO];
            return;
        }

        [self.cacheManager mergeAndSaveSessionRanges:ranges
                                                           forURL:url
                                                         cacheKey:context[@"cacheKey"]
                                                       completion:^(BOOL fullyCached) {
            BOOL complete = fullyCached && [self.cacheManager isFullyCachedForURL:url cacheKey:context[@"cacheKey"]];
            [self finishDownloadContext:context taskID:taskID fullyCached:complete];
        }];
    });
}

@end
