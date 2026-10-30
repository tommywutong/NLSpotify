//
//  NLMusicPlayerView.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/23.
//

#import <UIKit/UIKit.h>
#import "NLPlayerManager.h"
#import "NLExpandableTouchSlider.h"

@class NLMusicPlayerView, NLSong;

NS_ASSUME_NONNULL_BEGIN

@protocol NLMusicPlayerViewDelegate <NSObject>

@optional
- (void)musicPlayerViewDidTapClose:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapPlayPause:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapPrevious:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapNext:(NLMusicPlayerView *)view;
- (void)musicPlayerView:(NLMusicPlayerView *)view didChangeProgress:(float)progress;
- (void)musicPlayerView:(NLMusicPlayerView *)view didChangeVolume:(float)volume;
- (void)musicPlayerViewDidTapComment:(NLMusicPlayerView *)view;
- (void)musicPlayerView:(NLMusicPlayerView *)view didChangePlayMode:(NLPlayMode)playMode;
- (void)musicPlayerViewDidTapPlaylist:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapFavorite:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapAddToPlaylist:(NLMusicPlayerView *)view;
- (void)musicPlayerViewDidTapMore:(NLMusicPlayerView *)view;

// 点击封面，展示歌词
- (void)musicPlayerViewDidTapCover:(NLMusicPlayerView *)view;

// 播放队列数据
- (NSArray<NLSong *> *)musicPlayerViewPlaylist:(NLMusicPlayerView *)view;
- (NSInteger)musicPlayerViewCurrentIndex:(NLMusicPlayerView *)view;
- (void)musicPlayerView:(NLMusicPlayerView *)view didSelectSongAtIndex:(NSInteger)index;

@end

@interface NLMusicPlayerView : UIView

@property (nonatomic, weak) id<NLMusicPlayerViewDelegate> delegate;
@property (nonatomic, readonly) BOOL isTrackingProgress;

@property (nonatomic, assign) CGFloat coverScaleProgress;
@property (nonatomic, assign) CGFloat dismissProgress;

@property (nonatomic, strong, readonly) UISlider *progressSlider;
@property (nonatomic, strong, readonly) UISlider *volumeSlider;

// 供歌词视图等使用的中部容器（原播放队列区域）
@property (nonatomic, strong, readonly) UIView *queueContainerView;



- (void)updateTitle:(NSString *)title artist:(NSString *)artist;
- (void)updateCoverURL:(nullable NSURL *)url;
- (void)updateProgress:(float)progress;
- (void)refreshProgress;
- (void)updateCacheProgress:(float)cacheProgress;
- (void)updateCurrentTime:(NSTimeInterval)currentTime totalTime:(NSTimeInterval)totalTime;
- (void)updateVolume:(float)volume;
- (void)updatePlayState:(BOOL)isPlaying;
- (void)updatePlayMode:(NLPlayMode)playMode;
- (void)updateFavoriteState:(BOOL)liked;

// 播放队列面板（在进度条上方，可独立上下滑动）
- (void)setQueuePanelVisible:(BOOL)visible animated:(BOOL)animated;
@property (nonatomic, assign, readonly) BOOL isQueuePanelVisible;
- (void)reloadQueue;

// 歌词模式：只调整封面/队列区域布局，不影响队列按钮和列表的显示状态
- (void)setLyricPanelVisible:(BOOL)visible animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
