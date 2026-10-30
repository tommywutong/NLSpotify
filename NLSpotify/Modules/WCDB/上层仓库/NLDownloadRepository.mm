//
//  NLDownloadRepository.mm
//  NLSpotify
//

#import "NLDownloadRepository.h"
#import "NLDownloadItem.h"
#import "NLDownloadItem+WCDB.h"
#import "NLDataBaseManager.h"
#import "NLSong.h"
#import "NLSong+WCDB.h"

static NSString * const kDownloadQueueTableName = @"DownloadQueueTable";
static NSString * const kDownloadedSongsTableName = @"DownloadedSongsTable";

static void NLCompleteDownloadRepositoryWrite(BOOL success, void (^completion)(BOOL)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

@implementation NLDownloadRepository

+ (WCTDatabase *)safeDatabase {
    return [NLDataBaseManager sharedManager].database;
}

+ (NSArray<NLDownloadItem *> *)allDownloadItems {
    WCTDatabase *database = [self safeDatabase];
    NSArray<NLDownloadItem *> *items = database ? [database getObjectsOfClass:NLDownloadItem.class fromTable:kDownloadQueueTableName] : nil;
    if (!items) return @[];
    return [items sortedArrayUsingComparator:^NSComparisonResult(NLDownloadItem *left, NLDownloadItem *right) {
        if (left.addedTime > right.addedTime) return NSOrderedAscending;
        if (left.addedTime < right.addedTime) return NSOrderedDescending;
        return [left.songId compare:right.songId];
    }];
}

+ (NLDownloadItem *)downloadItemForSongId:(NSString *)songId {
    if (songId.length == 0) return nil;
    WCTDatabase *database = [self safeDatabase];
    if (!database) return nil;
    return [database getObjectOfClass:NLDownloadItem.class
                             fromTable:kDownloadQueueTableName
                                 where:NLDownloadItem.songId == songId];
}

+ (void)addDownloadItemWithSong:(NLSong *)song
                         status:(NSString *)status
                     completion:(void (^)(BOOL))completion {
    if (song.songId.length == 0) {
        NLCompleteDownloadRepositoryWrite(NO, completion);
        return;
    }
    NLDownloadItem *item = [[NLDownloadItem alloc] init];
    item.songId = song.songId;
    item.playURLString = song.playURL.absoluteString ?: @"";
    item.title = song.title ?: @"";
    item.artist = song.artist ?: @"";
    item.coverURLString = song.coverURL.absoluteString ?: @"";
    item.addedTime = [NSDate date].timeIntervalSince1970;
    item.status = status.length ? status : @"downloading";
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:item intoTable:kDownloadQueueTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)updateStatus:(NSString *)status
           forSongId:(NSString *)songId
          completion:(void (^)(BOOL))completion {
    if (songId.length == 0 || status.length == 0) {
        NLCompleteDownloadRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        NLDownloadItem *item = [transactionHandle getObjectOfClass:NLDownloadItem.class
                                                           fromTable:kDownloadQueueTableName
                                                               where:NLDownloadItem.songId == songId];
        if (!item) return NO;
        item.status = status;
        return [transactionHandle insertOrReplaceObject:item intoTable:kDownloadQueueTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)completeDownloadWithSong:(NLSong *)song completion:(void (^)(BOOL))completion {
    if (song.songId.length == 0) {
        NLCompleteDownloadRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        NLDownloadItem *item = [transactionHandle getObjectOfClass:NLDownloadItem.class
                                                           fromTable:kDownloadQueueTableName
                                                               where:NLDownloadItem.songId == song.songId];
        if (!item) return NO;
        item.status = @"completed";
        if (![transactionHandle insertOrReplaceObject:item intoTable:kDownloadQueueTableName]) return NO;
        return [transactionHandle insertOrReplaceObject:song intoTable:kDownloadedSongsTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)removeDownloadItemWithSongId:(NSString *)songId completion:(void (^)(BOOL))completion {
    if (songId.length == 0) {
        NLCompleteDownloadRepositoryWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kDownloadQueueTableName where:NLDownloadItem.songId == songId];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)clearAllDownloadItemsWithCompletion:(void (^)(BOOL))completion {
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kDownloadQueueTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

@end
