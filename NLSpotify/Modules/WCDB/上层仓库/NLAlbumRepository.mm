//
//  NLAlbumRepository.mm
//  NLSpotify
//

#import "NLAlbumRepository.h"
#import "NLDataBaseManager.h"
#import "NLAlbum.h"
#import "NLAlbum+WCDB.h"

static NSString * const kLikedAlbumsTableName = @"LikedAlbumsTable";

static void NLCompleteAlbumWrite(BOOL success, void (^completion)(BOOL)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

@implementation NLAlbumRepository

+ (WCTDatabase *)safeDatabase {
    return [NLDataBaseManager sharedManager].database;
}

+ (NSArray<NLAlbum *> *)allLikedAlbums {
    WCTDatabase *database = [self safeDatabase];
    NSArray<NLAlbum *> *albums = database ? [database getObjectsOfClass:NLAlbum.class fromTable:kLikedAlbumsTableName] : nil;
    if (!albums) return @[];
    return [albums sortedArrayUsingComparator:^NSComparisonResult(NLAlbum *left, NLAlbum *right) {
        if (left.createTime > right.createTime) return NSOrderedAscending;
        if (left.createTime < right.createTime) return NSOrderedDescending;
        return [left.albumId compare:right.albumId];
    }];
}

+ (void)setAlbum:(NLAlbum *)album liked:(BOOL)liked completion:(void (^)(BOOL))completion {
    if (!album.albumId.length) {
        NLCompleteAlbumWrite(NO, completion);
        return;
    }
    NSString *albumID = [album.albumId copy];
    if (!liked) {
        [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
            return [database deleteFromTable:kLikedAlbumsTableName where:NLAlbum.albumId == albumID];
        } completionQueue:dispatch_get_main_queue() completion:completion];
        return;
    }

    NLAlbum *snapshot = [[NLAlbum alloc] initWithAlbumId:albumID
                                                    name:album.name ?: @""
                                                coverURL:album.coverURL
                                             artistName:album.artistName];
    snapshot.createTime = album.createTime > 0 ? album.createTime : [NSDate date].timeIntervalSince1970;
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:snapshot intoTable:kLikedAlbumsTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (BOOL)isAlbumLiked:(NSString *)albumId {
    if (albumId.length == 0) return NO;
    WCTDatabase *database = [self safeDatabase];
    if (!database) return NO;
    return [database getObjectOfClass:NLAlbum.class
                             fromTable:kLikedAlbumsTableName
                                 where:NLAlbum.albumId == albumId] != nil;
}

@end
