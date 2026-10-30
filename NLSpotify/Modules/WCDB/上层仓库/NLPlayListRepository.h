//
//  NLPlayListRepository.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/23.
//

#import <Foundation/Foundation.h>

@class NLPlayList;
@class NLSong;

NS_ASSUME_NONNULL_BEGIN

@interface NLPlayListRepository : NSObject

/// 创建或更新一个歌单。
+ (void)savePlayList:(NLPlayList *)playList completion:(void (^)(BOOL success))completion;

/// 删除指定歌单及其关系；未被其他歌单引用的本地歌曲一并清理。
+ (void)deletePlayList:(NSString *)playListId completion:(void (^)(BOOL success))completion;

/// 查询所有用户自建歌单。调用方须在后台读取。
+ (NSArray<NLPlayList *> *)allUserCreatedPlayLists;

/// 查询所有已收藏歌单。调用方须在后台读取。
+ (NSArray<NLPlayList *> *)allLikedPlayLists;

/// 将歌单标记为「自建」或取消该标记。
+ (void)markPlayList:(NLPlayList *)playList
         userCreated:(BOOL)isUserCreated
          completion:(void (^)(BOOL success))completion;

/// 设置歌单的收藏状态。
+ (void)setPlayList:(NLPlayList *)playList
              liked:(BOOL)liked
         completion:(void (^)(BOOL success))completion;

/// 判断歌单是否已被收藏。调用方须在后台读取。
+ (BOOL)isPlayListLiked:(NSString *)playListId;

/// 原子地向歌单添加歌曲。
+ (void)addSong:(NLSong *)song
      toPlayList:(NSString *)playListId
      completion:(void (^)(BOOL success))completion;

/// 从歌单移除歌曲关系，并清理无其他关系引用的本地歌曲。
+ (void)removeSong:(NSString *)songId
      fromPlayList:(NSString *)playListId
        completion:(void (^)(BOOL success))completion;

/// 查询歌单中的所有歌曲。调用方须在后台读取。
+ (NSArray<NLSong *> *)songsInPlayList:(NSString *)playListId;

/// 创建一个用户自建歌单。
+ (void)createUserPlayListWithName:(NSString *)name
                        completion:(void (^)(NLPlayList * _Nullable playList))completion;

@end

NS_ASSUME_NONNULL_END
