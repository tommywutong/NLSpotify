//
//  NLDownloadManager.m
//  NLSpotify
//

#import "NLDownloadManager.h"
#import "NLCacheManager.h"
#import "NLDownloadItem.h"
#import "NLDownloadRepository.h"
#import "NLSongRepository.h"
#import "NLSongService.h"
#import "NLSong.h"
#import "NLOfflineAudioStore.h"

static NSString * const NLDownloadBackgroundSessionIdentifier = @"com.nlspotify.offline-downloads";

NSNotificationName const NLDownloadManagerDidUpdateNotification = @"NLDownloadManagerDidUpdateNotification";
static void NLCompleteDownloadCommand(void (^completion)(BOOL), BOOL success) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

@interface NLDownloadManager () <NSURLSessionDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, id> *> *taskContextMap;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionTask *> *taskMap;
@property (nonatomic, strong) NSMutableSet<NSString *> *activeSongIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *reservationGenerations;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) NSUInteger nextReservationGeneration;
@property (nonatomic, copy) void (^backgroundEventsCompletionHandler)(void);
@property (nonatomic, strong) NLOfflineAudioStore *offlineStore;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NLSong *> *pendingSongsByID;
@property (nonatomic, assign) BOOL recoveringBackgroundTasks;
- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation;
- (void)releaseSongID:(NSString *)songID forGeneration:(NSUInteger)generation;
- (BOOL)isReservationActiveForSongID:(NSString *)songID generation:(NSUInteger)generation;
- (void)beginDownloadForSong:(NLSong *)song generation:(NSUInteger)generation;
- (NLSong *)songForDownloadItem:(NLDownloadItem *)item;
- (void)markDownloadItemFailed:(NLDownloadItem *)item;
- (void)startDownloadWithSong:(NLSong *)song generation:(NSUInteger)generation completion:(void (^ _Nullable)(BOOL success))completion;
- (void)finishDownloadContext:(NSMutableDictionary<NSString *, id> *)context
                        taskID:(NSNumber *)taskID
                   fullyCached:(BOOL)complete;
- (void)postUpdateNotificationForSongID:(NSString *)songID status:(NSString *)status receivedBytes:(long long)receivedBytes expectedBytes:(long long)expectedBytes;
- (nullable NSNumber *)taskIdentifierForSongID:(NSString *)songID context:(NSMutableDictionary<NSString *, id> * _Nullable * _Nullable)context;
- (void)removeActiveTaskForSongID:(NSString *)songID context:(NSMutableDictionary<NSString *, id> * _Nullable)context taskIdentifier:(NSNumber * _Nullable)taskIdentifier generation:(NSUInteger)generation;
- (void)migrateLegacyCompletedDownloads;
- (void)recoverBackgroundTasks;
- (void)finishRecoveringBackgroundTasks;
@end

@implementation NLDownloadManager

+ (instancetype)sharedManager {
    static NLDownloadManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:NLDownloadBackgroundSessionIdentifier];
    configuration.sessionSendsLaunchEvents = YES;
    configuration.HTTPMaximumConnectionsPerHost = 2;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    _taskContextMap = [NSMutableDictionary dictionary];
    _taskMap = [NSMutableDictionary dictionary];
    _activeSongIDs = [NSMutableSet set];
    _reservationGenerations = [NSMutableDictionary dictionary];
    _lock = [[NSLock alloc] init];
    _pendingSongsByID = [NSMutableDictionary dictionary];
    _recoveringBackgroundTasks = YES;
    _offlineStore = [NLOfflineAudioStore sharedStore];
    [self recoverBackgroundTasks];
    [self migrateLegacyCompletedDownloads];
    return self;
}
- (void)postUpdateNotification {
    [self postUpdateNotificationForSongID:@"" status:@"" receivedBytes:0 expectedBytes:0];
}

- (void)postUpdateNotificationForSongID:(NSString *)songID
                                   status:(NSString *)status
                            receivedBytes:(long long)receivedBytes
                            expectedBytes:(long long)expectedBytes {
    NSDictionary *userInfo = @{
        @"songId": songID ?: @"",
        @"status": status ?: @"",
        @"receivedBytes": @(MAX(receivedBytes, 0)),
        @"expectedBytes": @(MAX(expectedBytes, 0))
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NLDownloadManagerDidUpdateNotification object:self userInfo:userInfo];
    });
}
- (NLSong *)songForDownloadItem:(NLDownloadItem *)item {
    if (!item.songId.length) return nil;
    NLSong *song = [[NLSong alloc] init];
    song.songId = item.songId;
    song.title = item.title ?: @"";
    song.artist = item.artist ?: @"";
    NSURL *coverURL = item.coverURLString.length ? [NSURL URLWithString:item.coverURLString] : nil;
    if (coverURL) song.coverURL = coverURL;
    NSURL *playURL = item.playURL;
    if (playURL) song.playURL = playURL;
    return song;
}

- (void)markDownloadItemFailed:(NLDownloadItem *)item {
    [NLDownloadRepository updateStatus:@"failed" forSongId:item.songId completion:^(BOOL updated) {
        if (!updated) {
            [self postUpdateNotification];
            return;
        }
        [NLSongRepository removeDownloadedSong:item.songId completion:^(BOOL removed) {
            (void)removed;
            [self postUpdateNotification];
        }];
    }];
}

- (void)recoverBackgroundTasks {
    __weak typeof(self) weakSelf = self;
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        for (NSURLSessionTask *task in tasks) {
            NSString *songID = task.taskDescription;
            NLDownloadItem *item = songID.length ? [NLDownloadRepository downloadItemForSongId:songID] : nil;
            NLSong *song = item ? [self songForDownloadItem:item] : nil;
            if (!song) continue;

            [self.lock lock];
            BOOL canRecover = ![self.activeSongIDs containsObject:songID];
            NSUInteger generation = canRecover ? ++self.nextReservationGeneration : 0;
            NSMutableDictionary *context = canRecover ? [@{
                @"generation": @(generation),
                @"songId": songID,
                @"url": song.playURL ?: [NSNull null],
                @"song": song,
                @"cancelled": @NO,
                @"usedResumeData": @NO,
                @"receivedBytes": @(task.countOfBytesReceived),
                @"expectedBytes": @(task.countOfBytesExpectedToReceive)
            } mutableCopy] : nil;
            if (canRecover) {
                [self.activeSongIDs addObject:songID];
                self.reservationGenerations[songID] = @(generation);
                self.taskContextMap[@(task.taskIdentifier)] = context;
                self.taskMap[@(task.taskIdentifier)] = task;
            }
            [self.lock unlock];
            if (!canRecover) continue;

            NSError *error = nil;
            BOOL stateSaved = [self.offlineStore recordTaskIdentifier:task.taskIdentifier forSongID:songID resumeData:nil receivedBytes:task.countOfBytesReceived expectedBytes:task.countOfBytesExpectedToReceive error:&error];
            if (!stateSaved) {
                [self removeActiveTaskForSongID:songID context:context taskIdentifier:@(task.taskIdentifier) generation:generation];
                [task cancel];
                [NLDownloadRepository updateStatus:@"failed" forSongId:songID completion:^(BOOL updated) {
                    (void)updated;
                    [self postUpdateNotificationForSongID:songID status:@"failed" receivedBytes:0 expectedBytes:0];
                }];
                continue;
            }
            [self postUpdateNotificationForSongID:songID
                                            status:item.status
                                     receivedBytes:task.countOfBytesReceived
                                     expectedBytes:task.countOfBytesExpectedToReceive];
        }
        [self finishRecoveringBackgroundTasks];
    }];
}

- (BOOL)reserveSongID:(NSString *)songID generation:(NSUInteger *)generation {
    if (songID.length == 0) return NO;
    [self.lock lock];
    BOOL reserved = ![self.activeSongIDs containsObject:songID];
    if (reserved) {
        NSUInteger currentGeneration = ++self.nextReservationGeneration;
        [self.activeSongIDs addObject:songID];
        self.reservationGenerations[songID] = @(currentGeneration);
        if (generation) *generation = currentGeneration;
    }
    [self.lock unlock];
    return reserved;
}


- (void)migrateLegacyCompletedDownloads {
    NLCacheManager *cacheManager = [NLCacheManager sharedManager];
    __weak typeof(self) weakSelf = self;
    [cacheManager whenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) perform:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        for (NLDownloadItem *item in [NLDownloadRepository allDownloadItems]) {
            if (![item.status isEqualToString:@"completed"] || [self.offlineStore localFileURLForSongID:item.songId]) continue;
            NSString *cacheKey = [cacheManager cacheIdentityForURL:item.playURL cacheKey:item.songId];
            NSString *cachePath = [cacheManager cacheFilePathForURL:item.playURL cacheKey:cacheKey];
            if (![cacheManager isFullyCachedForURL:item.playURL cacheKey:cacheKey] || ![[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
                [self markDownloadItemFailed:item];
                continue;
            }
            NSURL *temporaryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            NSError *copyError = nil;
            if (![[NSFileManager defaultManager] copyItemAtURL:[NSURL fileURLWithPath:cachePath] toURL:temporaryURL error:&copyError] ||
                ![self.offlineStore importCompleteAudioAtURL:temporaryURL forSongID:item.songId error:&copyError]) {
                [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
                [self markDownloadItemFailed:item];
            }
        }
        [self postUpdateNotification];
    }];
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

- (BOOL)isReservationActiveForSongID:(NSString *)songID generation:(NSUInteger)generation {
    if (songID.length == 0 || generation == 0) return NO;
    [self.lock lock];
    BOOL active = [self.activeSongIDs containsObject:songID] && self.reservationGenerations[songID].unsignedIntegerValue == generation;
    [self.lock unlock];
    return active;
}

- (nullable NSNumber *)taskIdentifierForSongID:(NSString *)songID context:(NSMutableDictionary<NSString *,id> * _Nullable * _Nullable)contextOut {
    if (songID.length == 0) return nil;
    [self.lock lock];
    NSNumber *taskID = nil;
    NSMutableDictionary *matchedContext = nil;
    for (NSNumber *candidateID in self.taskContextMap) {
        NSMutableDictionary *candidate = self.taskContextMap[candidateID];
        if ([candidate[@"songId"] isEqualToString:songID] && ![candidate[@"cancelled"] boolValue]) {
            taskID = candidateID;
            matchedContext = candidate;
            break;
        }
    }
    if (contextOut) *contextOut = matchedContext;
    [self.lock unlock];
    return taskID;
}

- (void)removeActiveTaskForSongID:(NSString *)songID context:(NSMutableDictionary<NSString *,id> *)context taskIdentifier:(NSNumber *)taskIdentifier generation:(NSUInteger)generation {
    if (songID.length == 0) return;
    [self.lock lock];
    if (context) context[@"cancelled"] = @YES;
    if (taskIdentifier && self.taskContextMap[taskIdentifier] == context) [self.taskContextMap removeObjectForKey:taskIdentifier];
    if (taskIdentifier) [self.taskMap removeObjectForKey:taskIdentifier];
    NSNumber *activeGeneration = self.reservationGenerations[songID];
    if (activeGeneration.unsignedIntegerValue == generation) {
        [self.reservationGenerations removeObjectForKey:songID];
        [self.activeSongIDs removeObject:songID];
    }
    [self.lock unlock];
}

- (void)addDownloadForSong:(NLSong *)song {
    if (!song || song.songId.length == 0) return;
    [self.lock lock];
    if (self.recoveringBackgroundTasks) {
        if (![self.activeSongIDs containsObject:song.songId] && !self.pendingSongsByID[song.songId]) self.pendingSongsByID[song.songId] = song;
        [self.lock unlock];
        [self postUpdateNotification];
        return;
    }
    [self.lock unlock];
    NSUInteger generation = 0;
    if (![self reserveSongID:song.songId generation:&generation]) return;
    [self beginDownloadForSong:song generation:generation];
}

- (void)finishRecoveringBackgroundTasks {
    [self.lock lock];
    NSArray<NLSong *> *pendingSongs = self.pendingSongsByID.allValues;
    [self.pendingSongsByID removeAllObjects];
    self.recoveringBackgroundTasks = NO;
    [self.lock unlock];
    for (NLSong *song in pendingSongs) [self addDownloadForSong:song];
    [self postUpdateNotification];
}

- (void)beginDownloadForSong:(NLSong *)song generation:(NSUInteger)generation {
    if (![self isReservationActiveForSongID:song.songId generation:generation]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL hasOfflineFile = [self.offlineStore localFileURLForSongID:song.songId] != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || ![self isReservationActiveForSongID:song.songId generation:generation]) return;
            if (hasOfflineFile) {
                [NLDownloadRepository addDownloadItemWithSong:song status:@"downloading" completion:^(BOOL queued) {
                    if (!queued) {
                        [self releaseSongID:song.songId forGeneration:generation];
                        [self postUpdateNotification];
                        return;
                    }
                    if (![self isReservationActiveForSongID:song.songId generation:generation]) {
                        [NLDownloadRepository updateStatus:@"cancelled" forSongId:song.songId completion:^(BOOL updated) {
                            (void)updated;
                            [self releaseSongID:song.songId forGeneration:generation];
                            [self postUpdateNotification];
                        }];
                        return;
                    }
                    [NLDownloadRepository completeDownloadWithSong:song completion:^(BOOL completed) {
                        if (completed) {
                            [self releaseSongID:song.songId forGeneration:generation];
                            [self postUpdateNotification];
                            return;
                        }
                        [NLDownloadRepository updateStatus:@"failed" forSongId:song.songId completion:^(BOOL updated) {
                            (void)updated;
                            [self releaseSongID:song.songId forGeneration:generation];
                            [self postUpdateNotification];
                        }];
                    }];
                }];
                return;
            }
            if (song.playURL) {
                [self startDownloadWithSong:song generation:generation completion:nil];
                return;
            }

            [[NLSongService sharedService] fetchPlayableURLWithSongId:song.songId success:^(NSURL *playURL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self isReservationActiveForSongID:song.songId generation:generation] || !playURL) return;
                    song.playURL = playURL;
                    [self startDownloadWithSong:song generation:generation completion:nil];
                });
            } failure:^(NSError *error) {
                if (![self isReservationActiveForSongID:song.songId generation:generation]) return;
                [NLDownloadRepository updateStatus:@"failed" forSongId:song.songId completion:^(BOOL updated) {
                    (void)updated;
                    [self releaseSongID:song.songId forGeneration:generation];
                    [self postUpdateNotification];
                }];
            }];
        });
    });
}

- (void)startDownloadWithSong:(NLSong *)song generation:(NSUInteger)generation completion:(void (^)(BOOL))completion {
    if (!song.playURL || ![self isReservationActiveForSongID:song.songId generation:generation]) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }
    __weak typeof(self) weakSelf = self;
    [NLDownloadRepository addDownloadItemWithSong:song status:@"downloading" completion:^(BOOL saved) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!saved) {
            [self releaseSongID:song.songId forGeneration:generation];
            [self postUpdateNotification];
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        if (![self isReservationActiveForSongID:song.songId generation:generation]) {
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSDictionary *state = [self.offlineStore stateForSongID:song.songId];
            NSData *resumeData = [state[@"resumeData"] isKindOfClass:NSData.class] ? state[@"resumeData"] : nil;
            BOOL usedResumeData = resumeData.length > 0;
            NSURLSessionDownloadTask *task = usedResumeData ? [self.session downloadTaskWithResumeData:resumeData] : [self.session downloadTaskWithURL:song.playURL];
            if (!task) {
                if (![self isReservationActiveForSongID:song.songId generation:generation]) {
                    NLCompleteDownloadCommand(completion, NO);
                    return;
                }
                [NLDownloadRepository updateStatus:@"failed" forSongId:song.songId completion:^(BOOL updated) {
                    (void)updated;
                    [self releaseSongID:song.songId forGeneration:generation];
                    [self postUpdateNotificationForSongID:song.songId status:@"failed" receivedBytes:0 expectedBytes:0];
                    NLCompleteDownloadCommand(completion, NO);
                }];
                return;
            }
            task.taskDescription = song.songId;
            NSMutableDictionary *context = [@{
                @"generation": @(generation),
                @"songId": song.songId,
                @"url": song.playURL,
                @"song": song,
                @"cancelled": @NO,
                @"usedResumeData": @(usedResumeData),
                @"receivedBytes": @0,
                @"expectedBytes": @0
            } mutableCopy];
            [self.lock lock];
            BOOL ownsReservation = [self.activeSongIDs containsObject:song.songId] &&
                self.reservationGenerations[song.songId].unsignedIntegerValue == generation;
            if (ownsReservation) {
                self.taskContextMap[@(task.taskIdentifier)] = context;
                self.taskMap[@(task.taskIdentifier)] = task;
            }
            [self.lock unlock];
            if (!ownsReservation) {
                [task cancel];
                [NLDownloadRepository updateStatus:@"cancelled" forSongId:song.songId completion:^(BOOL updated) {
                    (void)updated;
                    [self releaseSongID:song.songId forGeneration:generation];
                    [self postUpdateNotification];
                    NLCompleteDownloadCommand(completion, NO);
                }];
                return;
            }

            NSError *persistenceError = nil;
            BOOL stateSaved = [self.offlineStore recordTaskIdentifier:task.taskIdentifier
                                                             forSongID:song.songId
                                                            resumeData:nil
                                                         receivedBytes:task.countOfBytesReceived
                                                         expectedBytes:task.countOfBytesExpectedToReceive
                                                                 error:&persistenceError];
            [self.lock lock];
            BOOL reservationCurrent = [self.activeSongIDs containsObject:song.songId] &&
                self.reservationGenerations[song.songId].unsignedIntegerValue == generation;
            BOOL stillOwnsTask = self.taskContextMap[@(task.taskIdentifier)] == context && reservationCurrent;
            if (!stateSaved || !stillOwnsTask) {
                if (self.taskContextMap[@(task.taskIdentifier)] == context) [self.taskContextMap removeObjectForKey:@(task.taskIdentifier)];
                [self.taskMap removeObjectForKey:@(task.taskIdentifier)];
                if (reservationCurrent) {
                    [self.activeSongIDs removeObject:song.songId];
                    [self.reservationGenerations removeObjectForKey:song.songId];
                }
            }
            [self.lock unlock];
            if (!stateSaved || !stillOwnsTask) {
                [task cancel];
                if (!reservationCurrent) {
                    NLCompleteDownloadCommand(completion, NO);
                    return;
                }
                if (stateSaved) [self.offlineStore recordTaskIdentifier:0 forSongID:song.songId resumeData:nil receivedBytes:0 expectedBytes:0 error:nil];
                NSString *status = stateSaved ? @"cancelled" : @"failed";
                [NLDownloadRepository updateStatus:status forSongId:song.songId completion:^(BOOL updated) {
                    (void)updated;
                    [self postUpdateNotificationForSongID:song.songId status:status receivedBytes:0 expectedBytes:0];
                    NLCompleteDownloadCommand(completion, NO);
                }];
                return;
            }

            [task resume];
            [self postUpdateNotificationForSongID:song.songId status:@"downloading" receivedBytes:task.countOfBytesReceived expectedBytes:task.countOfBytesExpectedToReceive];
            NLCompleteDownloadCommand(completion, YES);
        });
    }];
}

- (void)pauseDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL))completion {
    NSMutableDictionary *context = nil;
    NSNumber *taskID = [self taskIdentifierForSongID:songID context:&context];
    if (!taskID || !context) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }
    [self.lock lock];
    NSURLSessionDownloadTask *task = (id)self.taskMap[taskID];
    NSUInteger generation = [context[@"generation"] unsignedIntegerValue];
    BOOL current = task && self.taskContextMap[taskID] == context && self.reservationGenerations[songID].unsignedIntegerValue == generation;
    if (current) {
        context[@"cancelled"] = @YES;
        [self.taskContextMap removeObjectForKey:taskID];
        [self.taskMap removeObjectForKey:taskID];
    }
    [self.lock unlock];
    if (!current) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }

    [task cancelByProducingResumeData:^(NSData *resumeData) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (![self isReservationActiveForSongID:songID generation:generation]) {
                NLCompleteDownloadCommand(completion, NO);
                return;
            }
            NSError *error = nil;
            BOOL saved = [self.offlineStore recordTaskIdentifier:0
                                                       forSongID:songID
                                                      resumeData:resumeData
                                                   receivedBytes:task.countOfBytesReceived
                                                   expectedBytes:task.countOfBytesExpectedToReceive
                                                           error:&error];
            BOOL paused = saved && resumeData.length > 0 && [self isReservationActiveForSongID:songID generation:generation];
            NSString *status = paused ? @"paused" : @"failed";
            if (!saved && [self isReservationActiveForSongID:songID generation:generation]) {
                [self.offlineStore recordTaskIdentifier:0 forSongID:songID resumeData:nil receivedBytes:0 expectedBytes:0 error:nil];
            }
            if (![self isReservationActiveForSongID:songID generation:generation]) {
                NLCompleteDownloadCommand(completion, NO);
                return;
            }
            [NLDownloadRepository updateStatus:status forSongId:songID completion:^(BOOL updated) {
                [self releaseSongID:songID forGeneration:generation];
                [self postUpdateNotificationForSongID:songID status:status receivedBytes:task.countOfBytesReceived expectedBytes:task.countOfBytesExpectedToReceive];
                NLCompleteDownloadCommand(completion, paused && updated);
            }];
        });
    }];
}

- (void)resumeDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL))completion {
    if (songID.length == 0) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NLDownloadItem *item = [NLDownloadRepository downloadItemForSongId:songID];
        NSDictionary *state = [self.offlineStore stateForSongID:songID];
        NSData *resumeData = [state[@"resumeData"] isKindOfClass:NSData.class] ? state[@"resumeData"] : nil;
        if (!item || !resumeData.length || ![item.status isEqualToString:@"paused"]) {
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        NLSong *song = [self songForDownloadItem:item];
        NSUInteger generation = 0;
        if (!song.playURL || ![self reserveSongID:songID generation:&generation]) {
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        [self startDownloadWithSong:song generation:generation completion:completion];
    });
}

- (void)cancelDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL))completion {
    if (songID.length == 0) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }
    NSMutableDictionary *context = nil;
    NSNumber *taskID = [self taskIdentifierForSongID:songID context:&context];
    [self.lock lock];
    NSURLSessionTask *task = taskID ? self.taskMap[taskID] : nil;
    NSUInteger generation = self.reservationGenerations[songID].unsignedIntegerValue;
    [self.pendingSongsByID removeObjectForKey:songID];
    [self.lock unlock];
    if (taskID || generation) [self removeActiveTaskForSongID:songID context:context taskIdentifier:taskID generation:generation];
    [task cancel];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NLDownloadItem *item = [NLDownloadRepository downloadItemForSongId:songID];
        if (!item) {
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        NSError *error = nil;
        BOOL saved = [self.offlineStore recordTaskIdentifier:0 forSongID:songID resumeData:nil receivedBytes:0 expectedBytes:0 error:&error];
        NSString *status = saved ? @"cancelled" : @"failed";
        [NLDownloadRepository updateStatus:status forSongId:songID completion:^(BOOL updated) {
            [self postUpdateNotificationForSongID:songID status:status receivedBytes:0 expectedBytes:0];
            NLCompleteDownloadCommand(completion, saved && updated);
        }];
    });
}

- (void)retryDownloadForSongID:(NSString *)songID completion:(void (^)(BOOL))completion {
    if (songID.length == 0) {
        NLCompleteDownloadCommand(completion, NO);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NLDownloadItem *item = [NLDownloadRepository downloadItemForSongId:songID];
        BOOL retryable = [item.status isEqualToString:@"failed"] || [item.status isEqualToString:@"cancelled"] || [item.status isEqualToString:@"paused"];
        NLSong *song = retryable ? [self songForDownloadItem:item] : nil;
        NSUInteger generation = 0;
        if (!song || !song.playURL || ![self reserveSongID:songID generation:&generation]) {
            NLCompleteDownloadCommand(completion, NO);
            return;
        }
        NSError *error = nil;
        BOOL cleared = [self.offlineStore recordTaskIdentifier:0 forSongID:songID resumeData:nil receivedBytes:0 expectedBytes:0 error:&error];
        if (!cleared) {
            [self releaseSongID:songID forGeneration:generation];
            [NLDownloadRepository updateStatus:@"failed" forSongId:songID completion:^(BOOL updated) {
                (void)updated;
                [self postUpdateNotificationForSongID:songID status:@"failed" receivedBytes:0 expectedBytes:0];
                NLCompleteDownloadCommand(completion, NO);
            }];
            return;
        }
        [self startDownloadWithSong:song generation:generation completion:completion];
    });
}

- (void)loadDownloadItemsWithCompletion:(void (^)(NSArray<NLDownloadItem *> *))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NLDownloadItem *> *items = [NLDownloadRepository allDownloadItems];
        for (NLDownloadItem *item in items) {
            NSDictionary *state = [self.offlineStore stateForSongID:item.songId];
            item.receivedBytes = [state[@"receivedBytes"] longLongValue];
            item.expectedBytes = [state[@"expectedBytes"] longLongValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(items ?: @[]); });
    });
}

- (BOOL)isDownloadingSongId:(NSString *)songId {
    if (songId.length == 0) return NO;
    [self.lock lock];
    BOOL downloading = [self.activeSongIDs containsObject:songId] || self.pendingSongsByID[songId] != nil;
    [self.lock unlock];
    return downloading;
}

- (void)cancelAllDownloads {
    [self.lock lock];
    NSArray<NSURLSessionTask *> *tasks = [self.taskMap.allValues copy];
    NSArray<NSMutableDictionary *> *contexts = [self.taskContextMap.allValues copy];
    for (NSMutableDictionary *context in contexts) context[@"cancelled"] = @YES;
    [self.pendingSongsByID removeAllObjects];
    [self.activeSongIDs removeAllObjects];
    [self.reservationGenerations removeAllObjects];
    [self.taskMap removeAllObjects];
    [self.taskContextMap removeAllObjects];
    [self.lock unlock];
    dispatch_group_t writeGroup = dispatch_group_create();
    for (NSMutableDictionary *context in contexts) {
        dispatch_group_enter(writeGroup);
        [NLDownloadRepository updateStatus:@"cancelled" forSongId:context[@"songId"] completion:^(BOOL updated) {
            (void)updated;
            dispatch_group_leave(writeGroup);
        }];
    }
    for (NSURLSessionTask *task in tasks) {
        NSString *songID = task.taskDescription;
        if ([task isKindOfClass:NSURLSessionDownloadTask.class]) {
            [(NSURLSessionDownloadTask *)task cancelByProducingResumeData:^(NSData *resumeData) {
                [self.offlineStore recordTaskIdentifier:0 forSongID:songID resumeData:resumeData receivedBytes:task.countOfBytesReceived expectedBytes:task.countOfBytesExpectedToReceive error:nil];
            }];
        } else {
            [task cancel];
        }
    }
    dispatch_group_notify(writeGroup, dispatch_get_main_queue(), ^{
        [self postUpdateNotification];
    });
}
- (void)handleBackgroundEventsForSessionIdentifier:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    if (![identifier isEqualToString:NLDownloadBackgroundSessionIdentifier]) {
        if (completionHandler) completionHandler();
        return;
    }
    self.backgroundEventsCompletionHandler = completionHandler;
}

- (void)removeOfflineDownloadForSongID:(NSString *)songID {
    if (songID.length == 0) return;
    NSMutableArray<NSURLSessionTask *> *tasks = [NSMutableArray array];
    [self.lock lock];
    [self.pendingSongsByID removeObjectForKey:songID];
    NSArray<NSNumber *> *taskIDs = [self.taskContextMap.allKeys copy];
    for (NSNumber *taskID in taskIDs) {
        NSMutableDictionary *context = self.taskContextMap[taskID];
        if (![context[@"songId"] isEqualToString:songID]) continue;
        context[@"cancelled"] = @YES;
        NSURLSessionTask *task = self.taskMap[taskID];
        if (task) [tasks addObject:task];
        [self.taskContextMap removeObjectForKey:taskID];
        [self.taskMap removeObjectForKey:taskID];
    }
    [self.activeSongIDs removeObject:songID];
    [self.reservationGenerations removeObjectForKey:songID];
    [self.lock unlock];
    for (NSURLSessionTask *task in tasks) [task cancel];
    [self.offlineStore removeOfflineAudioForSongID:songID];
}

- (void)removeAllOfflineDownloads {
    [self.lock lock];
    NSArray<NSURLSessionTask *> *tasks = [self.taskMap.allValues copy];
    for (NSMutableDictionary *context in self.taskContextMap.allValues) context[@"cancelled"] = @YES;
    [self.activeSongIDs removeAllObjects];
    [self.reservationGenerations removeAllObjects];
    [self.pendingSongsByID removeAllObjects];
    [self.taskMap removeAllObjects];
    [self.taskContextMap removeAllObjects];
    [self.lock unlock];
    for (NSURLSessionTask *task in tasks) [task cancel];
    [self.offlineStore removeAllOfflineAudio];
    [self postUpdateNotification];
}
#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSString *songID = downloadTask.taskDescription;
    NSNumber *taskID = @(downloadTask.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    NSUInteger generation = [context[@"generation"] unsignedIntegerValue];
    BOOL current = context && ![context[@"cancelled"] boolValue] && self.reservationGenerations[songID].unsignedIntegerValue == generation;
    if (current) {
        context[@"receivedBytes"] = @(totalBytesWritten);
        context[@"expectedBytes"] = @(totalBytesExpectedToWrite);
    }
    [self.lock unlock];
    if (!current) return;
    NSError *error = nil;
    BOOL persisted = [self.offlineStore recordProgressForTaskIdentifier:downloadTask.taskIdentifier
                                                               forSongID:songID
                                                           receivedBytes:totalBytesWritten
                                                           expectedBytes:totalBytesExpectedToWrite
                                                                   error:&error];
    if (!persisted && !error) return;
    [self postUpdateNotificationForSongID:songID status:@"downloading" receivedBytes:totalBytesWritten expectedBytes:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSNumber *taskID = @(downloadTask.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    NSString *songID = context[@"songId"];
    NSUInteger generation = [context[@"generation"] unsignedIntegerValue];
    BOOL current = context && ![context[@"cancelled"] boolValue] && self.reservationGenerations[songID].unsignedIntegerValue == generation;
    [self.lock unlock];
    if (!current) return;
    NSError *error = nil;
    BOOL imported = [self.offlineStore importCompleteAudioAtURL:location forSongID:songID error:&error];
    [self.lock lock];
    BOOL stillCurrent = self.taskContextMap[taskID] == context && ![context[@"cancelled"] boolValue] && self.reservationGenerations[songID].unsignedIntegerValue == generation;
    if (stillCurrent) {
        context[@"imported"] = @(imported);
        if (!imported) context[@"importError"] = error ?: [NSError errorWithDomain:@"NLDownloadManager" code:NSURLErrorCannotCreateFile userInfo:nil];
    }
    [self.lock unlock];
    if (!stillCurrent && imported) [self.offlineStore removeOfflineAudioForSongID:songID];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *taskID = @(task.taskIdentifier);
    [self.lock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    [self.taskMap removeObjectForKey:taskID];
    [self.lock unlock];
    if (!context) return;
    if (error && [context[@"usedResumeData"] boolValue]) {
        [self.offlineStore clearResumeDataForSongID:context[@"songId"] ifTaskIdentifier:task.taskIdentifier error:nil];
    }
    [self finishDownloadContext:context taskID:taskID fullyCached:(!error && [context[@"imported"] boolValue])];
}

- (void)finishDownloadContext:(NSMutableDictionary<NSString *, id> *)context taskID:(NSNumber *)taskID fullyCached:(BOOL)complete {
    NSString *songID = context[@"songId"];
    NSUInteger generation = [context[@"generation"] unsignedIntegerValue];
    NLSong *song = [context[@"song"] isKindOfClass:NLSong.class] ? context[@"song"] : nil;
    long long receivedBytes = [context[@"receivedBytes"] longLongValue];
    long long expectedBytes = [context[@"expectedBytes"] longLongValue];
    [self.lock lock];
    NSNumber *activeGeneration = self.reservationGenerations[songID];
    BOOL superseded = activeGeneration && activeGeneration.unsignedIntegerValue != generation;
    BOOL cancelled = [context[@"cancelled"] boolValue] || !activeGeneration || activeGeneration.unsignedIntegerValue != generation;
    BOOL ownsContext = self.taskContextMap[taskID] == context;
    if (ownsContext) [self.taskContextMap removeObjectForKey:taskID];
    [self.lock unlock];
    if (superseded || !ownsContext) return;

    __weak typeof(self) weakSelf = self;
    void (^finishStateWrite)(NSString *) = ^(NSString *status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self releaseSongID:songID forGeneration:generation];
        [self postUpdateNotificationForSongID:songID status:status receivedBytes:receivedBytes expectedBytes:expectedBytes];
    };
    BOOL hasOfflineFile = [self.offlineStore localFileURLForSongID:songID] != nil;
    if (complete && !cancelled && song && hasOfflineFile) {
        [NLDownloadRepository completeDownloadWithSong:song completion:^(BOOL completed) {
            if (completed) {
                finishStateWrite(@"completed");
                return;
            }
            [NLDownloadRepository updateStatus:@"failed" forSongId:songID completion:^(BOOL updated) {
                (void)updated;
                finishStateWrite(@"failed");
            }];
        }];
    } else {
        NSString *status = cancelled ? @"cancelled" : @"failed";
        [NLDownloadRepository updateStatus:status forSongId:songID completion:^(BOOL updated) {
            (void)updated;
            finishStateWrite(status);
        }];
    }
}


- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^completion)(void) = self.backgroundEventsCompletionHandler;
    self.backgroundEventsCompletionHandler = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), completion);
}

@end
