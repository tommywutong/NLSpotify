//
//  NLSongRepository.mm
//  NLSpotify
//

#import "NLSongRepository.h"
#import "NLDataBaseManager.h"
#import "NLSong+WCDB.h"
#import "NLPlaybackHistoryMetadata+WCDB.h"

static NSString * const kDownloadedSongsTableName = @"DownloadedSongsTable";
static NSString * const kHistoryTableName = @"PlaybackHistoryTable";
static NSString * const kHistoryMetadataTableName = @"PlaybackHistoryMetadataTable";
static NSString * const kLikedSongsTableName = @"LikedSongsTable";

static void NLCompleteRepositoryWrite(BOOL success, void (^completion)(BOOL)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

@implementation NLSongRepository

+ (WCTDatabase *)safeDatabase {
    return [NLDataBaseManager sharedManager].database;
}

+ (void)addDownloadedSong:(NLSong *)song completion:(void (^)(BOOL))completion {
    if (song.songId.length == 0) {
        NLCompleteRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:song intoTable:kDownloadedSongsTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)removeDownloadedSong:(NSString *)songId completion:(void (^)(BOOL))completion {
    if (songId.length == 0) {
        NLCompleteRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kDownloadedSongsTableName where:NLSong.songId == songId];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (BOOL)isSongDownloaded:(NSString *)songId {
    if (songId.length == 0) return NO;
    WCTDatabase *database = [self safeDatabase];
    if (!database) return NO;
    NLSong *song = [database getObjectOfClass:NLSong.class
                                     fromTable:kDownloadedSongsTableName
                                         where:NLSong.songId == songId];
    return song != nil;
}

+ (NSArray<NLSong *> *)allDownloadedSongs {
    WCTDatabase *database = [self safeDatabase];
    return database ? ([database getObjectsOfClass:NLSong.class fromTable:kDownloadedSongsTableName] ?: @[]) : @[];
}

+ (void)clearAllDownloadedSongsWithCompletion:(void (^)(BOOL))completion {
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kDownloadedSongsTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)recordPlaybackStart:(NLSong *)song completion:(void (^)(BOOL))completion {
    if (song.songId.length == 0) {
        NLCompleteRepositoryWrite(NO, completion);
        return;
    }
    NSTimeInterval startedAt = [NSDate date].timeIntervalSince1970;
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        if (![transactionHandle insertOrReplaceObject:song intoTable:kHistoryTableName]) return NO;

        NLPlaybackHistoryMetadata *metadata = [transactionHandle getObjectOfClass:NLPlaybackHistoryMetadata.class
                                                                           fromTable:kHistoryMetadataTableName
                                                                               where:NLPlaybackHistoryMetadata.songId == song.songId];
        if (!metadata) {
            metadata = [[NLPlaybackHistoryMetadata alloc] init];
            metadata.songId = song.songId;
            metadata.playCount = 0;
        }
        metadata.playCount += 1;
        metadata.lastPlayedAt = startedAt;
        return [transactionHandle insertOrReplaceObject:metadata intoTable:kHistoryMetadataTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)removePlayHistoryWithSongId:(NSString *)songId completion:(void (^)(BOOL))completion {
    if (songId.length == 0) {
        NLCompleteRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        BOOL removedSong = [transactionHandle deleteFromTable:kHistoryTableName where:NLSong.songId == songId];
        BOOL removedMetadata = [transactionHandle deleteFromTable:kHistoryMetadataTableName
                                                            where:NLPlaybackHistoryMetadata.songId == songId];
        return removedSong && removedMetadata;
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (NSArray<NLSong *> *)historySnapshotForDatabase:(WCTDatabase *)database {
    if (!database) return @[];
    NSArray<NLSong *> *songs = [database getObjectsOfClass:NLSong.class fromTable:kHistoryTableName];
    NSArray<NLPlaybackHistoryMetadata *> *metadata = [database getObjectsOfClass:NLPlaybackHistoryMetadata.class
                                                                         fromTable:kHistoryMetadataTableName];
    if (!songs || !metadata) return @[];

    NSMutableDictionary<NSString *, NLPlaybackHistoryMetadata *> *metadataBySongID = [NSMutableDictionary dictionaryWithCapacity:metadata.count];
    for (NLPlaybackHistoryMetadata *item in metadata) {
        if (item.songId.length) metadataBySongID[item.songId] = item;
    }
    return [songs sortedArrayUsingComparator:^NSComparisonResult(NLSong *left, NLSong *right) {
        NSTimeInterval leftTime = metadataBySongID[left.songId].lastPlayedAt;
        NSTimeInterval rightTime = metadataBySongID[right.songId].lastPlayedAt;
        if (leftTime > rightTime) return NSOrderedAscending;
        if (leftTime < rightTime) return NSOrderedDescending;
        return [left.songId compare:right.songId];
    }];
}

+ (NSArray<NLSong *> *)allPlayHistory {
    return [self historySnapshotForDatabase:[self safeDatabase]];
}

+ (void)allPlayHistoryWithCompletion:(void (^)(NSArray<NLSong *> *))completion {
    if (!completion) return;
    [[NLDataBaseManager sharedManager] performRead:^id(WCTDatabase *database) {
        return [self historySnapshotForDatabase:database];
    } completionQueue:dispatch_get_main_queue() completion:^(id result) {
        NSArray<NLSong *> *songs = [result isKindOfClass:NSArray.class] ? result : @[];
        completion(songs);
    }];
}

+ (NSArray<NLSong *> *)allLikedSongs {
    WCTDatabase *database = [self safeDatabase];
    return database ? ([database getObjectsOfClass:NLSong.class fromTable:kLikedSongsTableName] ?: @[]) : @[];
}

+ (void)likeSong:(NLSong *)song isLike:(BOOL)isLike completion:(void (^)(BOOL))completion {
    if (song.songId.length == 0) {
        NLCompleteRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        if (isLike) return [database insertOrReplaceObject:song intoTable:kLikedSongsTableName];
        return [database deleteFromTable:kLikedSongsTableName where:NLSong.songId == song.songId];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (BOOL)isSongLiked:(NSString *)songId {
    if (songId.length == 0) return NO;
    WCTDatabase *database = [self safeDatabase];
    if (!database) return NO;
    return [database getObjectOfClass:NLSong.class
                              fromTable:kLikedSongsTableName
                                  where:NLSong.songId == songId] != nil;
}

@end
