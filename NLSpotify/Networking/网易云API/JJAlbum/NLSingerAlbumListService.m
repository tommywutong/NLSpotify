//
//  NLSingerListService.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/16.
//

#import "NLSingerAlbumListService.h"
#import "NetWorkManager.h"
#import "NLSingerAlbumListModel.h"

@implementation NLSingerAlbumListService

+ (instancetype)sharedService {
    static NLSingerAlbumListService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[NLSingerAlbumListService alloc] init];
    });
    return service;
}

- (void)fetchSingerListWithSuccess:(void (^)(NSArray<NLSingerAlbumListModel *> *))success
                            failure:(void (^)(NSError *))failure {

    NSString *path = @"/artist/album?id=3684&limit=5";
    [[NetWorkManager sharedManager] GET:path
                             parameters:@{}
                                success:^(id  _Nullable responseObject) {

      //NLSingerAlbumListModel *model = [[NLSingerAlbumListModel alloc] init];
        NSArray *hotAlbums = responseObject[@"hotAlbums"];
      // NSLog(@"%@", hotAlbums); // 专注播放器时先注释
        NSMutableArray *resultArray = [NSMutableArray array];

        for (NSDictionary *albumDict in hotAlbums) {
          NLSingerAlbumListModel *model = [[NLSingerAlbumListModel alloc] init];
          NSDictionary *artistDict = albumDict[@"artist"];
          model.singer  = artistDict[@"name"];
          model.singerUrl = artistDict[@"picUrl"];

          //NLBigListModel *model = [[NLBigListModel alloc] init];
          model.coverUrl = albumDict[@"picUrl"];
          model.title    = albumDict[@"name"];
          NSString *id = albumDict[@"id"];
          model.cardId = [id intValue];
          NSString *company = albumDict[@"company"];
          model.subtitle = company.length > 0 ? company : @"推荐歌单";

          [resultArray addObject:model];
          // NSLog(@"zuihou:::%@", model); // 专注播放器时先注释
        }

        if (success) {
            success(resultArray);
        }

    } failure:^(NSError * _Nonnull error) {
        if (failure) {
            failure(error);
        }
    }];
}

@end
