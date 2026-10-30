//
//  NLPlayerManager.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/18.
//

#import <Foundation/Foundation.h>
#import "ReactiveObjC/ReactiveObjC.h"
#import <MediaPlayer/MediaPlayer.h>
#import "NLSong.h"

typedef NS_ENUM(NSUInteger, NLPlaybackState) {
    NLPlaybackStateIdle,
    NLPlaybackStateLoading,
    NLPlaybackStatePlaying,
    NLPlaybackStatePaused,
    NLPlaybackStateEnded,
    NLPlaybackStateError
};

typedef NS_ENUM(NSInteger, NLPlayMode) {
    NLPlayModeListLoop,    // 列表循环
    NLPlayModeSingleLoop,  // 单曲循环
    NLPlayModeRandom       // 随机播放
};

NS_ASSUME_NONNULL_BEGIN

@interface NLPlayerManager : NSObject

/// 全局播放器单例。
/// - Returns: 全局共享的 `NLPlayerManager` 实例。
+ (instancetype)sharedManager;

/// 当前正在播放的歌曲。
/// - Discussion: 若当前没有播放任务，可能为 `nil`。
@property (nonatomic, strong, readonly) NLSong *currentSong;
/// 当前播放状态。
/// - SeeAlso: `NLPlaybackState`
@property (nonatomic, assign, readonly) NLPlaybackState playbackState;
/// 用户是否希望播放；等待数据或被系统中断时，可能为 YES 而引擎并未播放。
@property (nonatomic, assign, readonly) BOOL wantsToPlay;
/// 当前播放列表。
/// - Discussion: 顺序与 UI 中列表顺序一致。
@property (nonatomic, strong, readonly) NSArray<NLSong *> *playlist;
/// 播放音量，范围 0.0 ~ 1.0。
@property (nonatomic, assign) float volume;
/// 当前进度，范围 0.0 ~ 1.0。
@property (nonatomic, assign, readonly) float currentProgress;
/// 最近一次缓冲进度，范围 0.0 ~ 1.0。
@property (nonatomic, assign) float latestCacheProgress;
/// 当前播放时间（秒）。
@property (nonatomic, assign, readonly) NSTimeInterval currentTime;
/// 当前歌曲总时长（秒）。
@property (nonatomic, assign, readonly) NSTimeInterval totalTime;
/// 当前播放下标，对应 `playlist`。
@property (nonatomic, assign, readonly) NSInteger currentIndex;
/// 当前播放模式。
/// - SeeAlso: `NLPlayMode`
@property (nonatomic, assign, readonly) NLPlayMode playMode;

/// 播放状态（Playing / Paused / Loading 等）的信号。
/// - Discussion: 包装为 `NSNumber` 的 `NLPlaybackState`。
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *playbackStateSignal;
/// 当前歌曲变化的信号。
@property (nonatomic, strong, readonly) RACSignal<NLSong *> *songSignal;
/// 播放进度变化的信号。
/// - Discussion: 0.0 ~ 1.0 的进度值，包装为 `NSNumber`。
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *progressSignal;
/// 缓存进度变化的信号（0.0 ~ 1.0）。
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *cacheProgressSignal;
/// 是否有播放列表（列表非空时为 YES）的信号。
/// - Discussion: 常用于控制小播放器是否显示。
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *hasPlaylistSignal;


/// 使用播放列表开始播放。
/// - Parameters:
///   - playlist: 要播放的歌曲列表。
///   - index: 初始播放的下标。
- (void)playWithPlaylist:(NSArray<NLSong *> *)playlist startIndex:(NSInteger)index;
/// 继续播放当前歌曲。
- (void)play;
/// 暂停当前播放。
- (void)pause;
/// 播放/暂停切换。
- (void)togglePlayPause;
/// 停止播放并释放相关资源。
- (void)stop;
/// 播放下一首歌曲。
- (void)playNext;
/// 播放上一首歌曲。
- (void)playPrevious;
/// 播放指定下标的歌曲。
/// - Parameter index: 歌曲在 `playlist` 中的下标。
- (void)playSongAtIndex:(NSInteger)index;
/// 设置播放模式。
/// - Parameter playMode: 播放模式。
- (void)setPlayMode:(NLPlayMode)playMode;
/// 跳转到指定进度位置。
/// - Parameter progress: 0.0 ~ 1.0 的进度值。
- (void)seekToProgress:(float)progress;
/// 在串行后台队列配置并激活音频 Session；结果回主线程校验，避免阻塞 UI。
- (void)setupAudioSession;
/// 配置系统远程控制命令（耳机线控、锁屏控制中心等）。
- (void)setupRemoteCommands;
/// 更新系统「正在播放」信息（锁屏/控制中心显示）。
- (void)updateNowPlayingInfo;

@end

NS_ASSUME_NONNULL_END
