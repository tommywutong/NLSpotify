//
//  NLAlbumRepository.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/23.
//


#import <Foundation/Foundation.h>

@class NLAlbum;

NS_ASSUME_NONNULL_BEGIN

@interface NLAlbumRepository : NSObject

/// 查询所有已收藏的专辑。调用方须在后台读取。
+ (NSArray<NLAlbum *> *)allLikedAlbums;

/// 设置某个专辑的收藏状态。
+ (void)setAlbum:(NLAlbum *)album
           liked:(BOOL)liked
      completion:(void (^)(BOOL success))completion;

/// 判断专辑是否已被收藏。调用方须在后台读取。
+ (BOOL)isAlbumLiked:(NSString *)albumId;

@end

NS_ASSUME_NONNULL_END
