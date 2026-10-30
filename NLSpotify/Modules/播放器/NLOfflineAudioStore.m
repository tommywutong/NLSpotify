#import "NLOfflineAudioStore.h"

static NSString * const NLOfflineAudioStoreErrorDomain = @"NLOfflineAudioStore";

@interface NLOfflineAudioStore ()
@property (nonatomic, strong) NSURL *directoryURL;
@property (nonatomic, strong) NSURL *metadataURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *statesBySongID;
@property (nonatomic) dispatch_queue_t queue;
@end

@implementation NLOfflineAudioStore

+ (instancetype)sharedStore {
    static NLOfflineAudioStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.nlspotify.offline-audio-store", DISPATCH_QUEUE_SERIAL);
    NSString *applicationSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    _directoryURL = [NSURL fileURLWithPath:[applicationSupport stringByAppendingPathComponent:@"NLOfflineAudio"] isDirectory:YES];
    _metadataURL = [_directoryURL URLByAppendingPathComponent:@"downloads.json"];
    [self ensureDirectory];
    _statesBySongID = [[self readMetadata] mutableCopy] ?: [NSMutableDictionary dictionary];
    return self;
}

- (void)ensureDirectory {
    [[NSFileManager defaultManager] createDirectoryAtURL:self.directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    [self.directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
}

- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *)readMetadata {
    NSData *data = [NSData dataWithContentsOfURL:self.metadataURL];
    NSDictionary *decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![decoded isKindOfClass:NSDictionary.class]) return [NSMutableDictionary dictionary];
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    [decoded enumerateKeysAndObjectsUsingBlock:^(NSString *songID, NSDictionary *value, BOOL *stop) {
        if (![songID isKindOfClass:NSString.class] || ![value isKindOfClass:NSDictionary.class]) return;
        NSMutableDictionary *state = [value mutableCopy];
        NSString *encodedResumeData = state[@"resumeData"];
        if ([encodedResumeData isKindOfClass:NSString.class]) {
            NSData *resumeData = [[NSData alloc] initWithBase64EncodedString:encodedResumeData options:0];
            if (resumeData) state[@"resumeData"] = resumeData;
            else [state removeObjectForKey:@"resumeData"];
        }
        states[songID] = state;
    }];
    return states;
}

- (BOOL)writeMetadataLocked:(NSError **)error {
    NSMutableDictionary *encoded = [NSMutableDictionary dictionaryWithCapacity:self.statesBySongID.count];
    [self.statesBySongID enumerateKeysAndObjectsUsingBlock:^(NSString *songID, NSMutableDictionary *state, BOOL *stop) {
        NSMutableDictionary *value = [state mutableCopy];
        NSData *resumeData = value[@"resumeData"];
        if ([resumeData isKindOfClass:NSData.class]) value[@"resumeData"] = [resumeData base64EncodedStringWithOptions:0];
        [encoded setObject:value forKey:songID];
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:encoded options:0 error:error];
    return data && [data writeToURL:self.metadataURL options:NSDataWritingAtomic error:error];
}

- (NSString *)fileNameForSongID:(NSString *)songID {
    NSString *name = [[songID dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    name = [[name stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    name = [name stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return [name stringByAppendingPathExtension:@"audio"];
}

- (NSURL *)localFileURLForSongID:(NSString *)songID {
    if (songID.length == 0) return nil;
    __block NSURL *URL = nil;
    dispatch_sync(self.queue, ^{
        NSString *fileName = self.statesBySongID[songID][@"fileName"];
        if (fileName.length == 0) return;
        NSURL *candidate = [self.directoryURL URLByAppendingPathComponent:fileName];
        NSNumber *size = nil;
        [candidate getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.longLongValue > 0) URL = candidate;
    });
    return URL;
}

- (BOOL)importCompleteAudioAtURL:(NSURL *)sourceURL forSongID:(NSString *)songID error:(NSError **)error {
    if (!sourceURL.isFileURL || songID.length == 0) {
        if (error) *error = [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"无效的离线音频文件或歌曲 ID"}];
        return NO;
    }
    __block BOOL success = NO;
    __block NSError *operationError = nil;
    dispatch_sync(self.queue, ^{
        [self ensureDirectory];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:sourceURL.path error:&operationError];
        NSNumber *fileSize = attributes[NSFileSize];
        if (fileSize.longLongValue <= 0) {
            if (!operationError) operationError = [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"离线音频文件为空"}];
            return;
        }
        NSString *fileName = [self fileNameForSongID:songID];
        NSURL *destinationURL = [self.directoryURL URLByAppendingPathComponent:fileName];
        NSDictionary *previousState = [self.statesBySongID[songID] copy];
        NSMutableDictionary *state = [previousState mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"fileName"] = fileName;
        [state removeObjectForKey:@"resumeData"];
        state[@"taskIdentifier"] = @0;
        self.statesBySongID[songID] = state;
        if (![self writeMetadataLocked:&operationError]) {
            if (previousState) self.statesBySongID[songID] = [previousState mutableCopy];
            else [self.statesBySongID removeObjectForKey:songID];
            return;
        }
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager removeItemAtURL:destinationURL error:nil];
        if (![manager moveItemAtURL:sourceURL toURL:destinationURL error:&operationError]) {
            if (previousState) self.statesBySongID[songID] = [previousState mutableCopy];
            else [self.statesBySongID removeObjectForKey:songID];
            [self writeMetadataLocked:nil];
            return;
        }
        [destinationURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        success = YES;
    });
    if (!success && error) *error = operationError;
    return success;
}

- (BOOL)recordTaskIdentifier:(NSUInteger)taskIdentifier
                   forSongID:(NSString *)songID
                  resumeData:(NSData *)resumeData
               receivedBytes:(long long)receivedBytes
               expectedBytes:(long long)expectedBytes
                       error:(NSError **)error {
    if (songID.length == 0) {
        if (error) *error = [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"歌曲 ID 不能为空"}];
        return NO;
    }
    __block BOOL persisted = NO;
    __block NSError *operationError = nil;
    dispatch_sync(self.queue, ^{
        NSMutableDictionary *previousState = [self.statesBySongID[songID] mutableCopy];
        NSMutableDictionary *state = [previousState mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"taskIdentifier"] = @(taskIdentifier);
        state[@"receivedBytes"] = @(MAX(receivedBytes, 0));
        state[@"expectedBytes"] = @(MAX(expectedBytes, 0));
        if (resumeData) state[@"resumeData"] = resumeData;
        else [state removeObjectForKey:@"resumeData"];
        self.statesBySongID[songID] = state;
        if (![self writeMetadataLocked:&operationError]) {
            if (previousState) self.statesBySongID[songID] = previousState;
            else [self.statesBySongID removeObjectForKey:songID];
            return;
        }
        persisted = YES;
    });
    if (!persisted && error) {
        *error = operationError ?: [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain
                                                       code:4
                                                   userInfo:@{NSLocalizedDescriptionKey: @"下载恢复状态无法持久化"}];
    }
    return persisted;
}

- (BOOL)clearResumeDataForSongID:(NSString *)songID
                ifTaskIdentifier:(NSUInteger)taskIdentifier
                           error:(NSError **)error {
    if (songID.length == 0 || taskIdentifier == 0) {
        if (error) *error = [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"歌曲 ID 或下载任务 ID 无效"}];
        return NO;
    }
    __block BOOL persisted = YES;
    __block NSError *operationError = nil;
    dispatch_sync(self.queue, ^{
        NSMutableDictionary *previousState = [self.statesBySongID[songID] mutableCopy];
        if ([previousState[@"taskIdentifier"] unsignedIntegerValue] != taskIdentifier) return;
        NSMutableDictionary *state = [previousState mutableCopy];
        state[@"taskIdentifier"] = @0;
        state[@"receivedBytes"] = @0;
        state[@"expectedBytes"] = @0;
        [state removeObjectForKey:@"resumeData"];
        self.statesBySongID[songID] = state;
        if (![self writeMetadataLocked:&operationError]) {
            self.statesBySongID[songID] = previousState;
            persisted = NO;
        }
    });
    if (!persisted && error) *error = operationError ?: [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain
                                                                             code:4
                                                                         userInfo:@{NSLocalizedDescriptionKey: @"下载恢复状态无法持久化"}];
    return persisted;
}

- (BOOL)recordProgressForTaskIdentifier:(NSUInteger)taskIdentifier
                                forSongID:(NSString *)songID
                            receivedBytes:(long long)receivedBytes
                            expectedBytes:(long long)expectedBytes
                                    error:(NSError **)error {
    if (songID.length == 0 || taskIdentifier == 0) {
        if (error) *error = [NSError errorWithDomain:NLOfflineAudioStoreErrorDomain
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"歌曲 ID 或下载任务 ID 无效"}];
        return NO;
    }
    __block BOOL persisted = NO;
    __block NSError *operationError = nil;
    dispatch_sync(self.queue, ^{
        NSMutableDictionary *previousState = [self.statesBySongID[songID] mutableCopy];
        if ([previousState[@"taskIdentifier"] unsignedIntegerValue] != taskIdentifier) return;
        NSMutableDictionary *state = [previousState mutableCopy];
        state[@"receivedBytes"] = @(MAX(receivedBytes, 0));
        state[@"expectedBytes"] = @(MAX(expectedBytes, 0));
        self.statesBySongID[songID] = state;
        if (![self writeMetadataLocked:&operationError]) {
            self.statesBySongID[songID] = previousState;
            return;
        }
        persisted = YES;
    });
    if (!persisted && error && operationError) *error = operationError;
    return persisted;
}

- (NSDictionary<NSString *,id> *)stateForSongID:(NSString *)songID {
    if (songID.length == 0) return nil;
    __block NSDictionary *state = nil;
    dispatch_sync(self.queue, ^{ state = [self.statesBySongID[songID] copy]; });
    return state;
}

- (void)removeOfflineAudioForSongID:(NSString *)songID {
    if (songID.length == 0) return;
    dispatch_sync(self.queue, ^{
        NSString *fileName = self.statesBySongID[songID][@"fileName"];
        if (fileName.length > 0) [[NSFileManager defaultManager] removeItemAtURL:[self.directoryURL URLByAppendingPathComponent:fileName] error:nil];
        [self.statesBySongID removeObjectForKey:songID];
        [self writeMetadataLocked:nil];
    });
}

- (void)removeAllOfflineAudio {
    dispatch_sync(self.queue, ^{
        [[NSFileManager defaultManager] removeItemAtURL:self.directoryURL error:nil];
        [self ensureDirectory];
        [self.statesBySongID removeAllObjects];
    });
}

@end
