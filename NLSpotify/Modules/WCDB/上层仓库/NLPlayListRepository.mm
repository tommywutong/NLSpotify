//
//  NLPlayListRepository.mm
//  NLSpotify
//

#import "NLPlayListRepository.h"
#import "NLDataBaseManager.h"
#import "NLPlayList.h"
#import "NLPlayListSongRelation.h"
#import "NLSong.h"
#import "NLPlayList+WCDB.h"
#import "NLPlayListSongRelation+WCDB.h"
#import "NLSong+WCDB.h"

static NSString * const kPlayListTableName = @"PlayListTable";
static NSString * const kRelationTableName = @"PlayListSongRelationTable";
static NSString * const kLocalSongsTableName = @"LocalSongsCacheTable";

static void NLCompletePlayListWrite(BOOL success, void (^completion)(BOOL)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

static NLPlayList *NLSnapshotPlayList(NLPlayList *source) {
    NLPlayList *snapshot = [[NLPlayList alloc] initWithId:source.playlistId
                                                     name:source.name ?: @""
                                            isUserCreated:source.isUserCreated];
    snapshot.coverURL = source.coverURL;
    snapshot.createTime = source.createTime;
    return snapshot;
}

static BOOL NLDeleteLocalSongIfOrphaned(WCTHandle *handle, NSString *songID) {
    if (songID.length == 0) return YES;
    NLPlayListSongRelation *remainingRelation = [handle getObjectOfClass:NLPlayListSongRelation.class
                                                                 fromTable:kRelationTableName
                                                                     where:NLPlayListSongRelation.songId == songID];
    if (remainingRelation) return YES;
    return [handle deleteFromTable:kLocalSongsTableName where:NLSong.songId == songID];
}

@implementation NLPlayListRepository

+ (WCTDatabase *)safeDatabase {
    return [NLDataBaseManager sharedManager].database;
}

+ (void)savePlayList:(NLPlayList *)playList completion:(void (^)(BOOL))completion {
    if (!playList.playlistId.length) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    NLPlayList *snapshot = NLSnapshotPlayList(playList);
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:snapshot intoTable:kPlayListTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)deletePlayList:(NSString *)playListId completion:(void (^)(BOOL))completion {
    if (playListId.length == 0) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        NSArray<NLPlayListSongRelation *> *relations = [transactionHandle getObjectsOfClass:NLPlayListSongRelation.class
                                                                                     fromTable:kRelationTableName
                                                                                         where:NLPlayListSongRelation.playlistId == playListId];
        if (!relations) return NO;
        BOOL relationsDeleted = [transactionHandle deleteFromTable:kRelationTableName
                                                               where:NLPlayListSongRelation.playlistId == playListId];
        BOOL playlistDeleted = [transactionHandle deleteFromTable:kPlayListTableName
                                                              where:NLPlayList.playlistId == playListId];
        if (!relationsDeleted || !playlistDeleted) return NO;
        for (NLPlayListSongRelation *relation in relations) {
            if (!NLDeleteLocalSongIfOrphaned(transactionHandle, relation.songId)) return NO;
        }
        return YES;
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (NSArray<NLPlayList *> *)getPlayListsByUserCreated:(BOOL)isUserCreated {
    WCTDatabase *database = [self safeDatabase];
    if (!database) return @[];
    NSArray<NLPlayList *> *lists = [database getObjectsOfClass:NLPlayList.class
                                                      fromTable:kPlayListTableName
                                                          where:NLPlayList.isUserCreated == isUserCreated];
    if (!lists) return @[];
    return [lists sortedArrayUsingComparator:^NSComparisonResult(NLPlayList *left, NLPlayList *right) {
        if (left.createTime > right.createTime) return NSOrderedAscending;
        if (left.createTime < right.createTime) return NSOrderedDescending;
        return [left.playlistId compare:right.playlistId];
    }];
}

+ (NSArray<NLPlayList *> *)allUserCreatedPlayLists {
    return [self getPlayListsByUserCreated:YES];
}

+ (NSArray<NLPlayList *> *)allLikedPlayLists {
    return [self getPlayListsByUserCreated:NO];
}

+ (void)markPlayList:(NLPlayList *)playList
         userCreated:(BOOL)isUserCreated
          completion:(void (^)(BOOL))completion {
    if (!playList.playlistId.length) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    NLPlayList *snapshot = NLSnapshotPlayList(playList);
    snapshot.isUserCreated = isUserCreated;
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:snapshot intoTable:kPlayListTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)setPlayList:(NLPlayList *)playList
              liked:(BOOL)liked
         completion:(void (^)(BOOL))completion {
    if (!playList.playlistId.length) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    if (!liked) {
        [self deletePlayList:playList.playlistId completion:completion];
        return;
    }
    NLPlayList *snapshot = NLSnapshotPlayList(playList);
    snapshot.isUserCreated = NO;
    if (snapshot.createTime <= 0) snapshot.createTime = [NSDate date].timeIntervalSince1970;
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:snapshot intoTable:kPlayListTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (BOOL)isPlayListLiked:(NSString *)playListId {
    if (playListId.length == 0) return NO;
    WCTDatabase *database = [self safeDatabase];
    if (!database) return NO;
    NLPlayList *playlist = [database getObjectOfClass:NLPlayList.class
                                             fromTable:kPlayListTableName
                                                 where:NLPlayList.playlistId == playListId && NLPlayList.isUserCreated == NO];
    return playlist != nil;
}

+ (void)addSong:(NLSong *)song toPlayList:(NSString *)playListId completion:(void (^)(BOOL))completion {
    if (!song.songId.length || playListId.length == 0) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        NLPlayList *playlist = [transactionHandle getObjectOfClass:NLPlayList.class
                                                          fromTable:kPlayListTableName
                                                              where:NLPlayList.playlistId == playListId];
        if (!playlist) return NO;
        if (![transactionHandle insertOrReplaceObject:song intoTable:kLocalSongsTableName]) return NO;

        NLPlayListSongRelation *existingRelation = [transactionHandle getObjectOfClass:NLPlayListSongRelation.class
                                                                               fromTable:kRelationTableName
                                                                                   where:NLPlayListSongRelation.playlistId == playListId && NLPlayListSongRelation.songId == song.songId];
        if (!existingRelation) {
            NLPlayListSongRelation *relation = [[NLPlayListSongRelation alloc] initWithPlaylistId:playListId songId:song.songId];
            if (![transactionHandle insertObject:relation intoTable:kRelationTableName]) return NO;
        }

        if (song.coverURL.absoluteString.length > 0) {
            playlist.coverURL = song.coverURL.absoluteString;
            if (![transactionHandle insertOrReplaceObject:playlist intoTable:kPlayListTableName]) return NO;
        }
        return YES;
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)removeSong:(NSString *)songId fromPlayList:(NSString *)playListId completion:(void (^)(BOOL))completion {
    if (songId.length == 0 || playListId.length == 0) {
        NLCompletePlayListWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWriteTransaction:^BOOL(WCTHandle *transactionHandle) {
        NLPlayListSongRelation *relation = [transactionHandle getObjectOfClass:NLPlayListSongRelation.class
                                                                       fromTable:kRelationTableName
                                                                           where:NLPlayListSongRelation.playlistId == playListId && NLPlayListSongRelation.songId == songId];
        if (!relation) return NO;
        if (![transactionHandle deleteFromTable:kRelationTableName
                                           where:NLPlayListSongRelation.playlistId == playListId && NLPlayListSongRelation.songId == songId]) return NO;
        return NLDeleteLocalSongIfOrphaned(transactionHandle, songId);
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (NSArray<NLSong *> *)songsInPlayList:(NSString *)playListId {
    if (playListId.length == 0) return @[];
    WCTDatabase *database = [self safeDatabase];
    if (!database) return @[];
    NSArray<NLPlayListSongRelation *> *relations = [database getObjectsOfClass:NLPlayListSongRelation.class
                                                                       fromTable:kRelationTableName
                                                                           where:NLPlayListSongRelation.playlistId == playListId];
    if (!relations || relations.count == 0) return @[];
    NSArray<NLPlayListSongRelation *> *sortedRelations = [relations sortedArrayUsingComparator:^NSComparisonResult(NLPlayListSongRelation *left, NLPlayListSongRelation *right) {
        if (left.addTime > right.addTime) return NSOrderedAscending;
        if (left.addTime < right.addTime) return NSOrderedDescending;
        return [left.songId compare:right.songId];
    }];
    NSMutableArray<NLSong *> *songs = [NSMutableArray arrayWithCapacity:sortedRelations.count];
    for (NLPlayListSongRelation *relation in sortedRelations) {
        NLSong *song = [database getObjectOfClass:NLSong.class
                                         fromTable:kLocalSongsTableName
                                             where:NLSong.songId == relation.songId];
        if (song) [songs addObject:song];
    }
    return songs;
}

+ (void)createUserPlayListWithName:(NSString *)name
                        completion:(void (^)(NLPlayList * _Nullable))completion {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        return;
    }
    long long timestamp = (long long)([NSDate date].timeIntervalSince1970 * 1000);
    NSString *playlistID = [NSString stringWithFormat:@"local_%lld", timestamp];
    NLPlayList *playlist = [[NLPlayList alloc] initWithId:playlistID name:trimmed isUserCreated:YES];
    playlist.createTime = [NSDate date].timeIntervalSince1970;
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:playlist intoTable:kPlayListTableName];
    } completionQueue:dispatch_get_main_queue() completion:^(BOOL success) {
        if (completion) completion(success ? playlist : nil);
    }];
}

@end
