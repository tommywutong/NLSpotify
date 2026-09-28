//
//  NLResourceLoader.m
//  NLSpotify
//

#import "NLResourceLoader.h"
#import "NLCacheManager.h"
#import "NLHTTPRangeValidator.h"
#import "NLAudioMemoryCache.h"
#import <fcntl.h>
#import <unistd.h>

@interface NLResourceLoader () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NLCacheManager *cacheManager;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *pendingRequestContextMap;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, AVAssetResourceLoadingRequest *> *taskRequestMap;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *tasksMap;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, id> *> *taskContextMap;
@property (nonatomic, strong) NSLock *mapLock;
- (long long)serveLocalDataForRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                   URL:(NSURL *)url
                              cacheKey:(NSString *)cacheKey
                             fromOffset:(long long)offset
                              endOffset:(long long)endOffset;
- (long long)nextLocalOffsetForURL:(NSURL *)url
                           cacheKey:(NSString *)cacheKey
                        afterOffset:(long long)offset
                          endOffset:(long long)endOffset;
- (void)continueLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest context:(NSMutableDictionary<NSString *, id> *)context;
- (void)finishLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                      context:(NSMutableDictionary<NSString *, id> *)context
                        error:(nullable NSError *)error;
- (NSString *)pendingKeyForRequest:(AVAssetResourceLoadingRequest *)request;
- (void)processLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                      context:(NSMutableDictionary<NSString *, id> *)context;
@end

@implementation NLResourceLoader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = 6;
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 600.0;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    _taskRequestMap = [NSMutableDictionary dictionary];
    _tasksMap = [NSMutableDictionary dictionary];
    _taskContextMap = [NSMutableDictionary dictionary];
    _pendingRequestContextMap = [NSMutableDictionary dictionary];
    _processingQueue = dispatch_queue_create("com.nlspotify.resource-loader.processing", DISPATCH_QUEUE_SERIAL);
    _mapLock = [[NSLock alloc] init];
    _cacheProgressSubject = [RACSubject subject];
    _cacheManager = [NLCacheManager sharedManager];
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

- (NSError *)errorWithDescription:(NSString *)description code:(NSInteger)code {
    return [NSError errorWithDomain:@"NLResourceLoader"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

- (void)invalidateAndCancelAll {
    [self.mapLock lock];
    NSArray<NSDictionary *> *contexts = [self.taskContextMap.allValues copy];
    NSArray<NSURLSessionDataTask *> *tasks = [self.tasksMap.allValues copy];
    NSMutableArray<AVAssetResourceLoadingRequest *> *requests = [NSMutableArray array];
    [self.taskRequestMap enumerateKeysAndObjectsUsingBlock:^(NSNumber *taskID, AVAssetResourceLoadingRequest *request, BOOL *stop) {
        NSMutableDictionary *context = self.taskContextMap[taskID];
        if (![context[@"cancelled"] boolValue]) [requests addObject:request];
    }];
    for (NSMutableDictionary *context in self.pendingRequestContextMap.allValues) {
        context[@"cancelled"] = @YES;
        AVAssetResourceLoadingRequest *request = context[@"loadingRequest"];
        if (request && ![requests containsObject:request]) [requests addObject:request];
    }
    for (NSMutableDictionary *context in contexts) context[@"cancelled"] = @YES;
    [self.pendingRequestContextMap removeAllObjects];
    [self.tasksMap removeAllObjects];
    [self.taskRequestMap removeAllObjects];
    [self.taskContextMap removeAllObjects];
    [self.mapLock unlock];

    for (NSURLSessionDataTask *task in tasks) [task cancel];
    NSError *error = [self errorWithDescription:@"播放请求已取消" code:NSURLErrorCancelled];
    for (AVAssetResourceLoadingRequest *request in requests) {
        [request finishLoadingWithError:error];
    }

    for (NSDictionary *context in contexts) {
        dispatch_group_t group = (dispatch_group_t)context[@"writeGroup"];
        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray *ranges = [context[@"sessionRanges"] copy];
            NSURL *url = context[@"url"];
            NSString *cacheKey = context[@"cacheKey"];
            if (url && ranges.count > 0) {
                [self.cacheManager mergeAndSaveSessionRanges:ranges
                                                       forURL:url
                                                     cacheKey:cacheKey
                                                   completion:nil];
            }
        });
    }
    [self.session invalidateAndCancel];
    self.session = nil;
}

#pragma mark - Resource loading

- (NSURL *)realURLFromLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *components = [NSURLComponents componentsWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:NO];
    components.scheme = self.originURL.scheme;
    return components.URL;
}

- (NSString *)pendingKeyForRequest:(AVAssetResourceLoadingRequest *)request {
    return [NSString stringWithFormat:@"%p", request];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *originURL = self.originURL;
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if (!originURL || !dataRequest || dataRequest.requestedOffset < 0 || dataRequest.requestedLength <= 0) {
        [loadingRequest finishLoadingWithError:[self errorWithDescription:@"无效的音频 Range 请求" code:NSURLErrorBadURL]];
        return YES;
    }

    long long requestedOffset = dataRequest.requestedOffset;
    long long endOffset = requestedOffset + (long long)dataRequest.requestedLength;
    if (endOffset <= requestedOffset) {
        [loadingRequest finishLoadingWithError:[self errorWithDescription:@"音频 Range 溢出" code:NSURLErrorBadURL]];
        return YES;
    }

    NSURL *realURL = [self realURLFromLoadingRequest:loadingRequest];
    if (!realURL) {
        [loadingRequest finishLoadingWithError:[self errorWithDescription:@"无效的音频播放地址" code:NSURLErrorBadURL]];
        return YES;
    }
    NSMutableDictionary *context = [@{
        @"url": originURL,
        @"cacheKey": self.cacheKey ?: @"",
        @"realURL": realURL,
        @"requestedOffset": @(requestedOffset),
        @"endOffset": @(endOffset),
        @"loadingRequest": loadingRequest,
        @"sessionRanges": [NSMutableArray array],
        @"writeGroup": (id)dispatch_group_create(),
        @"cancelled": @NO
    } mutableCopy];
    NSString *pendingKey = [self pendingKeyForRequest:loadingRequest];
    [self.mapLock lock];
    self.pendingRequestContextMap[pendingKey] = context;
    [self.mapLock unlock];

    __weak typeof(self) weakSelf = self;
    [self.cacheManager whenReadyOnQueue:self.processingQueue perform:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf processLoadingRequest:loadingRequest context:context];
    }];
    return YES;
}

- (void)processLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                      context:(NSMutableDictionary<NSString *, id> *)context {
    NSString *pendingKey = [self pendingKeyForRequest:loadingRequest];
    [self.mapLock lock];
    BOOL stillPending = self.pendingRequestContextMap[pendingKey] == context && ![context[@"cancelled"] boolValue];
    [self.mapLock unlock];
    if (!stillPending) return;

    NSURL *originURL = context[@"url"];
    long long requestedOffset = [context[@"requestedOffset"] longLongValue];
    long long endOffset = [context[@"endOffset"] longLongValue];
    long long dbTotalLength = [self.cacheManager totalLengthForURL:originURL cacheKey:context[@"cacheKey"]];
    context[@"totalLength"] = @(dbTotalLength);
    if (dbTotalLength > 0 && loadingRequest.contentInformationRequest) {
        loadingRequest.contentInformationRequest.contentLength = dbTotalLength;
        loadingRequest.contentInformationRequest.contentType = @"public.audio";
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    }

    long long cursor = [self serveLocalDataForRequest:loadingRequest
                                                  URL:originURL
                                             cacheKey:context[@"cacheKey"]
                                            fromOffset:requestedOffset
                                             endOffset:endOffset];
    context[@"cursor"] = @(cursor);
    if (cursor >= endOffset) {
        [self finishLoadingRequest:loadingRequest context:context error:nil];
        return;
    }
    [self continueLoadingRequest:loadingRequest context:context];
}

- (long long)serveLocalDataForRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                   URL:(NSURL *)url
                              cacheKey:(NSString *)cacheKey
                             fromOffset:(long long)offset
                              endOffset:(long long)endOffset {
    NLCacheManager *cacheManager = self.cacheManager;
    NSArray<NSValue *> *cachedRanges = [cacheManager cachedRangesForURL:url cacheKey:cacheKey];
    long long cursor = offset;
    const NSUInteger chunkSize = 512 * 1024;
    while (cursor < endOffset) {
        NSUInteger requestedLength = (NSUInteger)MIN(endOffset - cursor, (long long)chunkSize);
        NSData *memoryData = [[NLAudioMemoryCache sharedCache] dataForURL:url offset:cursor length:requestedLength];
        if (memoryData.length > 0) {
            [loadingRequest.dataRequest respondWithData:memoryData];
            cursor += memoryData.length;
            continue;
        }

        NSRange targetRange = NSMakeRange(NSNotFound, 0);
        for (NSValue *value in cachedRanges) {
            NSRange range = value.rangeValue;
            if (cursor >= range.location && cursor < NSMaxRange(range)) {
                targetRange = range;
                break;
            }
        }
        if (targetRange.location == NSNotFound) break;

        long long available = (long long)NSMaxRange(targetRange) - cursor;
        NSUInteger serveLength = (NSUInteger)MIN(MIN(endOffset - cursor, available), (long long)chunkSize);
        NSString *path = [cacheManager isFullyCachedForURL:url cacheKey:cacheKey]
            ? [cacheManager cacheFilePathForURL:url cacheKey:cacheKey]
            : [cacheManager tempFilePathForURL:url cacheKey:cacheKey];
        int fd = open(path.UTF8String, O_RDONLY);
        if (fd < 0 || serveLength == 0) {
            if (fd >= 0) close(fd);
            break;
        }
        void *buffer = malloc(serveLength);
        if (!buffer) {
            close(fd);
            break;
        }
        ssize_t readSize = pread(fd, buffer, serveLength, cursor);
        close(fd);
        if (readSize <= 0) {
            free(buffer);
            break;
        }
        NSData *localData = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)readSize freeWhenDone:YES];
        [[NLAudioMemoryCache sharedCache] storeData:localData forURL:url atOffset:cursor];
        [loadingRequest.dataRequest respondWithData:localData];
        cursor += readSize;
    }
    return cursor;
}

- (long long)nextLocalOffsetForURL:(NSURL *)url
                           cacheKey:(NSString *)cacheKey
                        afterOffset:(long long)offset
                          endOffset:(long long)endOffset {
    long long nextOffset = endOffset;
    long long memoryOffset = [[NLAudioMemoryCache sharedCache] nextCachedOffsetForURL:url afterOffset:offset];
    if (memoryOffset != NSNotFound) nextOffset = MIN(nextOffset, memoryOffset);
    for (NSValue *value in [self.cacheManager cachedRangesForURL:url cacheKey:cacheKey]) {
        NSRange range = value.rangeValue;
        if ((long long)range.location > offset) nextOffset = MIN(nextOffset, (long long)range.location);
    }
    return nextOffset;
}

- (void)continueLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest context:(NSMutableDictionary<NSString *,id> *)context {
    [self.mapLock lock];
    BOOL cancelledBeforeRead = [context[@"cancelled"] boolValue] || self.pendingRequestContextMap[[self pendingKeyForRequest:loadingRequest]] != context;
    [self.mapLock unlock];
    if (cancelledBeforeRead) return;
    NSURL *url = context[@"url"];
    NSString *cacheKey = context[@"cacheKey"];
    long long endOffset = [context[@"endOffset"] longLongValue];
    long long cursor = [self serveLocalDataForRequest:loadingRequest URL:url cacheKey:cacheKey fromOffset:[context[@"cursor"] longLongValue] endOffset:endOffset];
    context[@"cursor"] = @(cursor);
    if (cursor >= endOffset) {
        [self finishLoadingRequest:loadingRequest context:context error:nil];
        return;
    }

    long long nextOffset = [self nextLocalOffsetForURL:url cacheKey:cacheKey afterOffset:cursor endOffset:endOffset];
    long long fetchLength = nextOffset - cursor;
    if (fetchLength <= 0 || !self.session) {
        [self finishLoadingRequest:loadingRequest context:context error:[self errorWithDescription:@"无法创建音频 Range 请求" code:NSURLErrorCannotConnectToHost]];
        return;
    }
    context[@"startOffset"] = @(cursor);
    context[@"currentOffset"] = @(cursor);
    context[@"requestedLength"] = @(fetchLength);
    context[@"respondedLength"] = @(0LL);
    context[@"validResponse"] = @NO;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:context[@"realURL"]];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", cursor, cursor + fetchLength - 1] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    NSNumber *taskID = @(task.taskIdentifier);
    [self.mapLock lock];
    BOOL cancelled = [context[@"cancelled"] boolValue] || self.pendingRequestContextMap[[self pendingKeyForRequest:loadingRequest]] != context;
    if (!cancelled) {
        self.taskRequestMap[taskID] = loadingRequest;
        self.tasksMap[taskID] = task;
        self.taskContextMap[taskID] = context;
    }
    [self.mapLock unlock];
    if (cancelled) return;
    [task resume];
}

- (void)finishLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                      context:(NSMutableDictionary<NSString *,id> *)context
                        error:(NSError *)error {
    NSString *pendingKey = [self pendingKeyForRequest:loadingRequest];
    [self.mapLock lock];
    BOOL cancelled = [context[@"cancelled"] boolValue];
    if (self.pendingRequestContextMap[pendingKey] == context) {
        [self.pendingRequestContextMap removeObjectForKey:pendingKey];
    }
    [self.mapLock unlock];
    if (cancelled) return;

    NSArray<NSValue *> *ranges = [context[@"sessionRanges"] copy];
    NSURL *url = context[@"url"];
    if (url && ranges.count > 0) {
        [self.cacheManager mergeAndSaveSessionRanges:ranges forURL:url cacheKey:context[@"cacheKey"] completion:nil];
    }
    if (error) [loadingRequest finishLoadingWithError:error];
    else [loadingRequest finishLoading];
}
#pragma mark - Cancellation

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
 didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    [self.mapLock lock];
    NSString *pendingKey = [self pendingKeyForRequest:loadingRequest];
    NSNumber *targetTaskID = nil;
    NSMutableDictionary *context = self.pendingRequestContextMap[pendingKey];
    if (context) {
        context[@"cancelled"] = @YES;
        [self.pendingRequestContextMap removeObjectForKey:pendingKey];
    }
    for (NSNumber *taskID in self.taskRequestMap) {
        if (self.taskRequestMap[taskID] == loadingRequest) {
            targetTaskID = taskID;
            break;
        }
    }
    if (!context && targetTaskID) context = self.taskContextMap[targetTaskID];
    if (context) context[@"cancelled"] = @YES;
    NSURLSessionDataTask *task = targetTaskID ? self.tasksMap[targetTaskID] : nil;
    [self.mapLock unlock];
    [task cancel];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSNumber *taskID = @(dataTask.taskIdentifier);
    [self.mapLock lock];
    AVAssetResourceLoadingRequest *loadingRequest = self.taskRequestMap[taskID];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    [self.mapLock unlock];
    if (!context) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    long long requestedOffset = [context[@"startOffset"] longLongValue];
    long long requestedLength = [context[@"requestedLength"] longLongValue];
    long long responseStart = 0;
    long long totalLength = 0;
    BOOL valid = [NLHTTPRangeValidator validateResponse:(NSHTTPURLResponse *)response
                                        requestedOffset:requestedOffset
                                        requestedLength:(NSInteger)MIN(requestedLength, NSIntegerMax)
                                          responseStart:&responseStart
                                           totalLength:&totalLength];
    if (!valid) {
        NSError *error = [self errorWithDescription:@"音频服务器返回了无效的 Range 响应" code:NSURLErrorCannotParseResponse];
        [self.mapLock lock];
        context[@"validResponse"] = @NO;
        context[@"terminalError"] = error;
        [self.mapLock unlock];
        completionHandler(NSURLSessionResponseCancel);
        [dataTask cancel];
        return;
    }

    [self.mapLock lock];
    context[@"validResponse"] = @YES;
    context[@"responseStart"] = @(responseStart);
    context[@"totalLength"] = @(totalLength);
    [self.mapLock unlock];
    if (loadingRequest.contentInformationRequest) {
        loadingRequest.contentInformationRequest.contentLength = totalLength;
        loadingRequest.contentInformationRequest.contentType = ((NSHTTPURLResponse *)response).MIMEType ?: @"public.audio";
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveData:(NSData *)data {
    if (data.length == 0) return;
    NSNumber *taskID = @(dataTask.taskIdentifier);
    [self.mapLock lock];
    AVAssetResourceLoadingRequest *loadingRequest = self.taskRequestMap[taskID];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    if (!context || ![context[@"validResponse"] boolValue] || [context[@"cancelled"] boolValue]) {
        [self.mapLock unlock];
        return;
    }

    long long offset = [context[@"currentOffset"] longLongValue];
    long long requestStart = [context[@"startOffset"] longLongValue];
    long long requestedLength = [context[@"requestedLength"] longLongValue];
    long long respondedLength = [context[@"respondedLength"] longLongValue];
    long long totalLength = [context[@"totalLength"] longLongValue];
    context[@"currentOffset"] = @(offset + (long long)data.length);

    NSData *responseData = nil;
    long long responseStart = MAX(offset, requestStart + respondedLength);
    long long responseEnd = MIN(offset + (long long)data.length, requestStart + requestedLength);
    if (responseEnd > responseStart) {
        NSRange dataRange = NSMakeRange((NSUInteger)(responseStart - offset), (NSUInteger)(responseEnd - responseStart));
        responseData = dataRange.length == data.length ? data : [data subdataWithRange:dataRange];
        context[@"respondedLength"] = @(respondedLength + (long long)responseData.length);
    }

    dispatch_group_t group = (dispatch_group_t)context[@"writeGroup"];
    NSURL *url = context[@"url"];
    NSString *cacheKey = context[@"cacheKey"];
    if (!url || responseData.length == 0) {
        [self.mapLock unlock];
        return;
    }
    dispatch_group_enter(group);
    [self.mapLock unlock];

    if (loadingRequest) [loadingRequest.dataRequest respondWithData:responseData];
    [[NLAudioMemoryCache sharedCache] storeData:responseData forURL:url atOffset:responseStart];
    [self.cacheManager cacheData:responseData
                                      forURL:url
                                    cacheKey:cacheKey
                                   atOffset:responseStart
                                totalLength:totalLength
                                  completion:^(BOOL success) {
        float progress = 0.f;
        BOOL shouldSendProgress = NO;
        [self.mapLock lock];
        NSMutableArray *ranges = context[@"sessionRanges"];
        if (success) {
            [ranges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)responseStart, responseData.length)]];
            long long total = [context[@"totalLength"] longLongValue];
            if (total > 0) {
                progress = MIN(MAX((float)((double)(responseStart + responseData.length) / (double)total), 0.f), 1.f);
                shouldSendProgress = YES;
            }
        }
        [self.mapLock unlock];
        if (shouldSendProgress) [self.cacheProgressSubject sendNext:@(progress)];
        dispatch_group_leave(group);
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *taskID = @(task.taskIdentifier);
    [self.mapLock lock];
    NSMutableDictionary *context = self.taskContextMap[taskID];
    AVAssetResourceLoadingRequest *loadingRequest = self.taskRequestMap[taskID];
    [self.taskContextMap removeObjectForKey:taskID];
    [self.taskRequestMap removeObjectForKey:taskID];
    [self.tasksMap removeObjectForKey:taskID];
    [self.mapLock unlock];
    if (!context) return;

    dispatch_group_notify((dispatch_group_t)context[@"writeGroup"], self.processingQueue, ^{
        BOOL cancelled = [context[@"cancelled"] boolValue] || (error.code == NSURLErrorCancelled && !context[@"terminalError"]);
        if (cancelled) {
            NSString *pendingKey = [self pendingKeyForRequest:context[@"loadingRequest"]];
            [self.mapLock lock];
            if (self.pendingRequestContextMap[pendingKey] == context) {
                [self.pendingRequestContextMap removeObjectForKey:pendingKey];
            }
            [self.mapLock unlock];
            NSArray<NSValue *> *ranges = [context[@"sessionRanges"] copy];
            NSURL *url = context[@"url"];
            if (url && ranges.count > 0) {
                [self.cacheManager mergeAndSaveSessionRanges:ranges forURL:url cacheKey:context[@"cacheKey"] completion:nil];
            }
            return;
        }

        NSError *terminalError = context[@"terminalError"];
        if (terminalError) {
            [self finishLoadingRequest:loadingRequest context:context error:terminalError];
            return;
        }
        if (error) {
            [self finishLoadingRequest:loadingRequest context:context error:error];
            return;
        }

        long long startOffset = [context[@"startOffset"] longLongValue];
        long long totalLength = [context[@"totalLength"] longLongValue];
        long long expected = MIN([context[@"requestedLength"] longLongValue], totalLength - startOffset);
        if (![context[@"validResponse"] boolValue] || expected <= 0 || [context[@"respondedLength"] longLongValue] < expected) {
            [self finishLoadingRequest:loadingRequest
                               context:context
                                 error:[self errorWithDescription:@"音频 Range 数据不足" code:NSURLErrorCannotParseResponse]];
            return;
        }

        context[@"cursor"] = @(startOffset + expected);
        [self continueLoadingRequest:loadingRequest context:context];
    });
}

@end
