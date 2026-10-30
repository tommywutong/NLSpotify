//
//  NLSongListViewController.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/15.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, NLSongListType) {
    NLSongListTypePlaylist,
    NLSongListTypeAlbum        
};

@class NLPlayList;

/// 歌单或专辑详情页，负责展示曲目列表并发起播放。
@interface NLSongListViewController : UIViewController

/// 使用远端歌单或专辑标识创建详情页。
/// - Parameters:
///   - listId: 服务端歌单或专辑标识。
///   - type: 标识 `listId` 属于歌单还是专辑。
///   - name: 用于初始导航标题的名称。
/// - Returns: 已配置远端数据源的详情控制器。
- (instancetype)initWithId:(NSInteger)listId
                      type:(NLSongListType)type
                      name:(NSString *)name;

/// 使用本地自建歌单创建详情页。
/// - Parameter playlist: WCDB 中已持久化的本地歌单。
/// - Returns: 已配置本地数据源的详情控制器。
- (instancetype)initWithLocalPlayList:(NLPlayList *)playlist;

@end

NS_ASSUME_NONNULL_END
