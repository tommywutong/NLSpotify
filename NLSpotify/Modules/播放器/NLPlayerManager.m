//  NLPlayerManager.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/18.
//

#import "NLPlayerManager.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import "NLSongService.h"
#import "NLSongRepository.h"
#import "SDWebImage/SDWebImage.h"
#import "NLResourceLoader.h"
#import "NLCacheManager.h"
#import "NLOfflineAudioStore.h"

@interface NLResourceLoader (CacheManagerInjection)
@property (nonatomic, strong) NLCacheManager *cacheManager;
@end

//NSString * const NLPlayerSongDidChangeNotification = @"NLPlayerSongDidChangeNotification";//  歌曲换了，用于通知刷新UI
//NSString * const NLPlayerPlaybackStateDidChangeNotification = @"NLPlayerPlaybackStateDidChangeNotification";//  播放/暂停/加载中 时候发送通知，用于更新播放的按钮
//NSString * const NLPlayerProgressDidChangeNotification = @"NLPlayerProgressDidChangeNotification";//  用于通知进度的变化

static void *kPlayerCurrentItemStatusContext = &kPlayerCurrentItemStatusContext;
static void *kPlayerTimeControlStatusContext = &kPlayerTimeControlStatusContext;

static dispatch_queue_t NLAudioSessionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.nlspotify.audio-session", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface NLPlayerManager ()
@property (nonatomic, strong, readwrite) NLSong *currentSong;
@property (nonatomic, assign, readwrite) NLPlaybackState playbackState;
@property (nonatomic, strong, readwrite) NSArray<NLSong *> *playlist;
@property (nonatomic, assign, readwrite) NSInteger currentIndex;
@property (nonatomic, assign, readwrite) NLPlayMode playMode;
@property (nonatomic, strong) AVPlayer *player;   //音乐播放器
@property (nonatomic, strong) AVPlayerItem *currentPlayerItem;
@property (nonatomic, strong) RACSubject<NSNumber *> *playbackStateSubject;
@property (nonatomic, strong) RACSubject<NLSong *> *songSubject;
@property (nonatomic, strong) RACSubject<NSNumber *> *progressSubject;
@property (nonatomic, strong) RACSubject<NSNumber *> *cacheProgressSubject;
@property (nonatomic, strong) RACDisposable *cacheProgressDisposable;
@property (nonatomic, strong) RACBehaviorSubject<NSNumber *> *hasPlaylistSubject;
@property (nonatomic, strong) NLResourceLoader *resourceLoader;
@property (nonatomic, strong) NLCacheManager *cacheManager;

@property (nonatomic, strong) id timeObserver;  //周期性时间监听
@property (nonatomic, strong) AVPlayer *timeObserverOwner;
@property (nonatomic, strong) AVPlayer *observedPlayer;
@property (nonatomic, strong) AVPlayerItem *observedItem; // 当前被 KVO 的 item（强持有，避免快速切歌时 item 先释放导致 KVO 崩溃）
@property (nonatomic, strong) id endTimeObserver;       // 播放结束观察

@property (nonatomic, assign) NSUInteger playSwitchToken; // 丢弃过期异步回调（连续快速切歌）
@property (nonatomic, assign) NSUInteger lastRecordedPlaybackToken;
@property (nonatomic, assign) BOOL hasRecordedPlaybackToken;
@property (nonatomic, assign, readwrite) BOOL wantsToPlay;
@property (nonatomic, assign) BOOL audioSessionInterrupted;
@property (nonatomic, assign) BOOL resumeAfterInterruption;
@property (nonatomic, assign) BOOL audioSessionActivated;
@property (nonatomic, assign) BOOL audioSessionActivationPending;
@property (nonatomic, assign) NSUInteger audioSessionGeneration;
@property (nonatomic, strong) NSURL *currentSourceURL;
@property (nonatomic, strong) NSURL *pendingSourceURL;
@property (nonatomic, assign) BOOL requiresPlaybackReload;
@property (nonatomic, assign) BOOL hasPendingRestore;
@property (nonatomic, assign) BOOL restoringPosition;
@property (nonatomic, assign) NSTimeInterval pendingRestoreTime;
@property (nonatomic, strong) NSMutableArray<MPRemoteCommand *> *remoteCommands;
@property (nonatomic, strong) NSMutableArray<id> *remoteCommandTargets;

@property (nonatomic, assign) float lastLoggedCacheProgress; // 用于缓存跟踪日志，仅变化时打印
@property (nonatomic, copy) NSString *lastLoggedCacheURL;    // 上一首打印时的 URL，切歌后重新打印
- (void)startPlaybackWithURL:(NSURL *)url cacheKey:(NSString *)cacheKey token:(NSUInteger)token;
- (void)startSongAfterCacheReady:(NLSong *)song token:(NSUInteger)token;
- (void)tearDownCurrentPlaybackReleasingPlayer:(BOOL)releasePlayer;
- (void)installPlayerItem:(AVPlayerItem *)item sourceURL:(NSURL *)url;
- (void)synchronizePlaybackState;
- (void)applyPlaybackIntent;
- (void)requestAudioSessionActivation;
- (void)invalidateAudioSessionDeactivating:(BOOL)deactivate;
- (void)configureAudioSessionAfterReset;
@end

@implementation NLPlayerManager

+ (instancetype)sharedManager {
    static NLPlayerManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[NLPlayerManager alloc] init];

    });
    return manager;
}

- (instancetype)init {
    if (self = [super init]) {
        _cacheManager = [NLCacheManager sharedManager];
        _volume = 0.8f;
        _playMode = NLPlayModeListLoop;
        _playbackStateSubject = [RACSubject subject];
        _songSubject = [RACSubject subject];
        _progressSubject = [RACSubject subject];
        _cacheProgressSubject = [RACSubject subject];
        _hasPlaylistSubject = [RACBehaviorSubject behaviorSubjectWithDefaultValue:@NO];

        _playbackStateSignal = _playbackStateSubject;
        _songSignal = _songSubject;
        _progressSignal = _progressSubject;
        _cacheProgressSignal = _cacheProgressSubject;
        _hasPlaylistSignal = _hasPlaylistSubject;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        [center addObserver:self selector:@selector(handleAudioInterruption:) name:AVAudioSessionInterruptionNotification object:session];
        [center addObserver:self selector:@selector(handleAudioRouteChange:) name:AVAudioSessionRouteChangeNotification object:session];
        [center addObserver:self selector:@selector(handleMediaServicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:session];
        [center addObserver:self selector:@selector(handleApplicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self setupRemoteCommands];
        [self updateNowPlayingInfo];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self tearDownCurrentPlaybackReleasingPlayer:YES];
    [self invalidateAudioSessionDeactivating:self.audioSessionActivated || self.audioSessionActivationPending];
    for (NSUInteger index = 0; index < self.remoteCommands.count; index++) {
        [self.remoteCommands[index] removeTarget:self.remoteCommandTargets[index]];
    }
}


- (NSString *)cacheKeyForSong:(NLSong *)song URL:(NSURL *)url {
    return [self.cacheManager cacheIdentityForURL:url cacheKey:song.songId];
}

- (dispatch_queue_t)resourceLoaderDelegateQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.nlspotify.resource-loader.delegate", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

- (void)invalidateCurrentStreamingPlayback {
    [self.cacheProgressDisposable dispose];
    self.cacheProgressDisposable = nil;
    [self.resourceLoader invalidateAndCancelAll];
    self.resourceLoader = nil;
}

- (void)tearDownCurrentPlaybackReleasingPlayer:(BOOL)releasePlayer {
    // Deregister from the original owners before changing player/item references.
    [self removePeriodicTimeObserver];
    [self uninstallCurrentItemObserver];
    if (self.observedPlayer) {
        [self.observedPlayer removeObserver:self forKeyPath:NSStringFromSelector(@selector(timeControlStatus))
                                   context:kPlayerTimeControlStatusContext];
        self.observedPlayer = nil;
    }
    [self invalidateCurrentStreamingPlayback];
    [self.player pause];
    if (self.player.currentItem) [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentPlayerItem = nil;
    self.currentSourceURL = nil;
    self.restoringPosition = NO;
    if (releasePlayer) self.player = nil;
}

- (void)installPlayerItem:(AVPlayerItem *)item sourceURL:(NSURL *)url {
    self.currentPlayerItem = item;
    self.currentSourceURL = url;
    if (!self.player) self.player = [[AVPlayer alloc] initWithPlayerItem:item];
    else [self.player replaceCurrentItemWithPlayerItem:item];
    self.player.volume = self.volume;
    self.observedPlayer = self.player;
    [self.observedPlayer addObserver:self forKeyPath:NSStringFromSelector(@selector(timeControlStatus))
                            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                            context:kPlayerTimeControlStatusContext];
    [self addPeriodicTimeObserver];
    [self observeCurrentItemForReady:item];
    [self observeCurrentItemForEnd:item];
    [self applyPlaybackIntent];
}

- (void)synchronizePlaybackState {
    AVPlayerItem *item = self.currentPlayerItem;
    if (!self.currentSong && !item) {
        [self setPlaybackState:NLPlaybackStateIdle];
    } else if (item.status == AVPlayerItemStatusFailed ||
               (self.playbackState == NLPlaybackStateError && !self.wantsToPlay)) {
        [self setPlaybackState:NLPlaybackStateError];
    } else if (!self.wantsToPlay || self.audioSessionInterrupted) {
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [self.player pause];
        [self setPlaybackState:NLPlaybackStatePaused];
    } else if (!item || item.status != AVPlayerItemStatusReadyToPlay ||
               self.restoringPosition || self.audioSessionActivationPending) {
        [self setPlaybackState:NLPlaybackStateLoading];
    } else {
        switch (self.player.timeControlStatus) {
            case AVPlayerTimeControlStatusPlaying:
                [self setPlaybackState:NLPlaybackStatePlaying];
                break;
            case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                [self setPlaybackState:NLPlaybackStateLoading];
                break;
            case AVPlayerTimeControlStatusPaused:
                [self setPlaybackState:NLPlaybackStatePaused];
                break;
        }
    }
}

- (void)applyPlaybackIntent {
    AVPlayerItem *item = self.currentPlayerItem;
    if (!self.wantsToPlay || self.audioSessionInterrupted) {
        [self.player pause];
        [self synchronizePlaybackState];
        return;
    }
    if (!item || item.status == AVPlayerItemStatusFailed || self.restoringPosition) {
        [self synchronizePlaybackState];
        return;
    }
    if (self.hasPendingRestore) {
        if (item.status != AVPlayerItemStatusReadyToPlay) {
            [self synchronizePlaybackState];
            return;
        }
        self.hasPendingRestore = NO;
        self.restoringPosition = YES;
        NSUInteger token = self.playSwitchToken;
        AVPlayer *player = self.player;
        CMTime position = CMTimeMakeWithSeconds(self.pendingRestoreTime, NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        [player seekToTime:position toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || token != self.playSwitchToken || self.player != player || self.currentPlayerItem != item) return;
                self.restoringPosition = NO;
                [self applyPlaybackIntent];
            });
        }];
        [self synchronizePlaybackState];
        return;
    }
    if (!self.audioSessionActivated) {
        [self requestAudioSessionActivation];
        [self synchronizePlaybackState];
        return;
    }
    [self.player play];
    [self synchronizePlaybackState];
}

- (void)playWithPlaylist:(NSArray<NLSong *> *)playlist startIndex:(NSInteger)index {
    if (!NSThread.isMainThread) {
        NSArray<NLSong *> *snapshot = [playlist copy];
        dispatch_async(dispatch_get_main_queue(), ^{ [self playWithPlaylist:snapshot startIndex:index]; });
        return;
    }
    if (!playlist || playlist.count == 0 || index < 0 || index >= playlist.count) return;
    self.playlist = [playlist copy];
    self.currentIndex = index;
    [self.hasPlaylistSubject sendNext:@YES];
    [self playSongAtIndexIfNeeded:index];
}
- (void)playWithURL:(NSURL *)url {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playWithURL:url]; });
        return;
    }
    if (!url) {
        [self setPlaybackState:NLPlaybackStateError];
        return;
    }
    self.playSwitchToken += 1;
    NSUInteger token = self.playSwitchToken;
    NSString *cacheKey = [self cacheKeyForSong:self.currentSong URL:url];
    __weak typeof(self) weakSelf = self;
    [self.cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.playSwitchToken) return;
        [strongSelf startPlaybackWithURL:url cacheKey:cacheKey token:token];
    }];
}

- (void)startPlaybackWithURL:(NSURL *)url cacheKey:(NSString *)cacheKey token:(NSUInteger)token {
    if (token != self.playSwitchToken) return;
    NLCacheManager *cacheManager = self.cacheManager;
    cacheManager.currentPlayingURL = url;
    cacheManager.currentPlayingCacheKey = cacheKey;
    [cacheManager touchAccessTimeForURL:url cacheKey:cacheKey];
    [self tearDownCurrentPlaybackReleasingPlayer:NO];
    [self updateCacheProgressForURL:url cacheKey:cacheKey];
    self.lastLoggedCacheURL = nil;
    self.lastLoggedCacheProgress = -1.f;

    if (self.latestCacheProgress >= 0.999f && [cacheManager isFullyCachedForURL:url cacheKey:cacheKey]) {
        [self playFullyCachedSongAtPath:[cacheManager cacheFilePathForURL:url cacheKey:cacheKey]];
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = @"streaming";
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:components.URL options:nil];
    self.resourceLoader = [[NLResourceLoader alloc] init];
    self.resourceLoader.originURL = url;
    self.resourceLoader.cacheManager = self.cacheManager;
    self.resourceLoader.cacheKey = cacheKey;
    [asset.resourceLoader setDelegate:self.resourceLoader queue:[self resourceLoaderDelegateQueue]];

    __weak typeof(self) weakSelf = self;
    self.cacheProgressDisposable = [self.resourceLoader.cacheProgressSubject subscribeNext:^(NSNumber *progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.playSwitchToken) return;
            strongSelf.latestCacheProgress = progress.floatValue;
            [strongSelf.cacheProgressSubject sendNext:progress];
        });
    }];

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    [self installPlayerItem:item sourceURL:url];
}

#pragma mark - 播放入口


- (void)playFullyCachedSongAtPath:(NSString *)cachePath {
    if (cachePath.length == 0) {
        [self setPlaybackState:NLPlaybackStateError];
        return;
    }
    NSURL *localURL = [NSURL fileURLWithPath:cachePath];
    [self tearDownCurrentPlaybackReleasingPlayer:NO];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:localURL];
    [self installPlayerItem:item sourceURL:localURL];
}


#pragma mark - 播放控制

- (void)play {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self play]; });
        return;
    }
    if (!self.currentSong) return;
    self.wantsToPlay = YES;
    if (self.audioSessionInterrupted) self.resumeAfterInterruption = YES;
    if (!self.player.currentItem && self.requiresPlaybackReload) {
        self.requiresPlaybackReload = NO;
        NSURL *source = self.pendingSourceURL;
        self.pendingSourceURL = nil;
        NLSong *song = self.currentSong;
        NSUInteger token = self.playSwitchToken;
        __weak typeof(self) weakSelf = self;
        [self.cacheManager whenReadyOnQueue:dispatch_get_main_queue() perform:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.playSwitchToken || self.currentSong != song) return;
            if (source.isFileURL) [self playFullyCachedSongAtPath:source.path];
            else if (source) [self playWithURL:source];
            else [self startSongAfterCacheReady:song token:token];
        }];
    }
    [self applyPlaybackIntent];
}

- (void)pause {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pause]; });
        return;
    }
    if (!self.currentSong) return;
    self.wantsToPlay = NO;
    self.resumeAfterInterruption = NO;
    [self applyPlaybackIntent];
}

- (void)togglePlayPause {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self togglePlayPause]; });
        return;
    }
    if (self.wantsToPlay) {
        [self pause];
    } else {
        [self play];
    }
}

//  pause为真正的暂停，stop为取消

- (void)stop {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
        return;
    }
    self.wantsToPlay = NO;
    self.playSwitchToken += 1;
    self.resumeAfterInterruption = NO;
    self.requiresPlaybackReload = NO;
    self.pendingSourceURL = nil;
    self.hasPendingRestore = NO;
    [self tearDownCurrentPlaybackReleasingPlayer:YES];
    [self invalidateAudioSessionDeactivating:self.audioSessionActivated || self.audioSessionActivationPending];
    self.cacheManager.currentPlayingURL = nil;
    self.cacheManager.currentPlayingCacheKey = nil;
    self.currentSong = nil;
    self.playlist = nil;
    [self.hasPlaylistSubject sendNext:@NO];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    self.currentIndex = 0;
    [self updateCacheProgressForURL:nil cacheKey:nil];
    [self setPlaybackState:NLPlaybackStateIdle];
}



#pragma mark - 播放列表调度
/// 根据播放模式计算下一首的索引
- (NSInteger)indexForNextInMode:(NLPlayMode)mode {
    if (!self.playlist || self.playlist.count == 0) return -1;
    switch (mode) {
        case NLPlayModeSingleLoop:
            return self.currentIndex; // 单曲循环：保持当前
        case NLPlayModeListLoop: {
            NSInteger next = self.currentIndex + 1;
            return next >= (NSInteger)self.playlist.count ? 0 : next;
        }
        case NLPlayModeRandom: {
            if (self.playlist.count <= 1) return self.currentIndex;
            NSInteger r;
            do {
                r = arc4random_uniform((uint32_t)self.playlist.count);
            } while (r == self.currentIndex);
            return r;
        }
    }
}

/// 根据播放模式计算上一首的索引
- (NSInteger)indexForPreviousInMode:(NLPlayMode)mode {
    if (!self.playlist || self.playlist.count == 0) return -1;
    switch (mode) {
        case NLPlayModeSingleLoop:
            return self.currentIndex; // 单曲循环：保持当前
        case NLPlayModeListLoop: {
            NSInteger prev = self.currentIndex - 1;
            return prev < 0 ? (NSInteger)self.playlist.count - 1 : prev;
        }
        case NLPlayModeRandom: {
            if (self.playlist.count <= 1) return self.currentIndex;
            NSInteger r;
            do {
                r = arc4random_uniform((uint32_t)self.playlist.count);
            } while (r == self.currentIndex);
            return r;
        }
    }
}

- (void)playNext {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playNext]; });
        return;
    }
    NSInteger idx = [self indexForNextInMode:self.playMode];
    if (idx < 0) return;
    [self playSongAtIndexIfNeeded:idx];
}

- (void)playPrevious {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playPrevious]; });
        return;
    }
    NSInteger idx = [self indexForPreviousInMode:self.playMode];
    if (idx < 0) return;
    [self playSongAtIndexIfNeeded:idx];
}

#pragma mark - 切歌调度核心

/// 同一个入口处理列表切换、直接选曲和网络 URL 的过期回调。
- (void)playSongAtIndexIfNeeded:(NSInteger)index {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playSongAtIndexIfNeeded:index]; });
        return;
    }
    if (index < 0 || index >= (NSInteger)self.playlist.count) return;
    self.playSwitchToken += 1;
    NSUInteger token = self.playSwitchToken;
    self.wantsToPlay = YES;
    self.resumeAfterInterruption = self.audioSessionInterrupted;
    self.requiresPlaybackReload = NO;
    self.pendingSourceURL = nil;
    self.hasPendingRestore = NO;
    self.currentIndex = index;
    NLSong *song = self.playlist[index];
    self.currentSong = song;
    [self.progressSubject sendNext:@(0.f)];
    [self postSongChangedNotification];

    [self tearDownCurrentPlaybackReleasingPlayer:NO];
    NLCacheManager *cache = self.cacheManager;
    cache.currentPlayingURL = nil;
    cache.currentPlayingCacheKey = nil;
    self.latestCacheProgress = 0.f;
    [self.cacheProgressSubject sendNext:@(0.f)];
    [self setPlaybackState:NLPlaybackStateLoading];
    __weak typeof(self) weakSelf = self;
    [cache whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.playSwitchToken) return;
        [strongSelf startSongAfterCacheReady:song token:token];
    }];
}

- (void)startSongAfterCacheReady:(NLSong *)song token:(NSUInteger)token {
    if (token != self.playSwitchToken || self.currentSong != song) return;
    NLCacheManager *cache = self.cacheManager;
    NSURL *offlineURL = [[NLOfflineAudioStore sharedStore] localFileURLForSongID:song.songId];
    if (offlineURL) {
        self.latestCacheProgress = 1.f;
        [self.cacheProgressSubject sendNext:@(1.f)];
        [self playFullyCachedSongAtPath:offlineURL.path];
        return;
    }
    NSString *cacheKey = [cache cacheIdentityForURL:song.playURL cacheKey:song.songId];
    if (song.songId.length && [cache isFullyCachedForURL:song.playURL cacheKey:cacheKey]) {
        cache.currentPlayingURL = song.playURL;
        cache.currentPlayingCacheKey = cacheKey;
        [cache touchAccessTimeForURL:song.playURL cacheKey:cacheKey];
        self.latestCacheProgress = 1.f;
        [self.cacheProgressSubject sendNext:@(1.f)];
        [self playFullyCachedSongAtPath:[cache cacheFilePathForURL:song.playURL cacheKey:cacheKey]];
        return;
    }

    if (song.playURL) {
        [self playWithURL:song.playURL];
        return;
    }

    self.cacheManager.currentPlayingURL = nil;
    self.cacheManager.currentPlayingCacheKey = nil;
    [self updateCacheProgressForURL:nil cacheKey:nil];
    __weak typeof(self) weakSelf = self;
    [[NLSongService sharedService] fetchPlayableURLWithSongId:song.songId
        success:^(NSURL *playURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || token != strongSelf.playSwitchToken || strongSelf.currentSong != song) return;
                song.playURL = playURL;
                [strongSelf playWithURL:playURL];
            });
        } failure:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || token != strongSelf.playSwitchToken || strongSelf.currentSong != song) return;
                NSLog(@"获取播放URL失败: %@", error.localizedDescription);
                [strongSelf setPlaybackState:NLPlaybackStateError];
            });
        }];
}

- (void)playSongAtIndex:(NSInteger)index {
    [self playSongAtIndexIfNeeded:index];
}

#pragma mark - 进度和音量
- (float)currentProgress {
    AVPlayerItem *item = self.player.currentItem;
    if (!item) return 0.0f;
    CMTime duration = item.duration;
    CMTime currentTime = self.player.currentTime;
    if (!CMTIME_IS_NUMERIC(duration) || CMTIME_IS_INDEFINITE(duration) ||
        !CMTIME_IS_NUMERIC(currentTime) || CMTIME_IS_INDEFINITE(currentTime)) {
        return 0.0f;
    }
    double durationSeconds = CMTimeGetSeconds(duration);
    double currentSeconds = CMTimeGetSeconds(currentTime);
    if (!isfinite(durationSeconds) || durationSeconds <= 0 || !isfinite(currentSeconds)) return 0.0f;
    return fminf(fmaxf((float)(currentSeconds / durationSeconds), 0.f), 1.f);
}

- (NSTimeInterval)currentTime {
    if (!self.player.currentItem) return 0.0;
    CMTime time = self.player.currentTime;
    if (!CMTIME_IS_NUMERIC(time) || CMTIME_IS_INDEFINITE(time)) return 0.0;
    double seconds = CMTimeGetSeconds(time);
    return isfinite(seconds) && seconds >= 0 ? seconds : 0.0;
}

- (NSTimeInterval)totalTime {
    if (!self.player.currentItem) return 0.0;
    CMTime duration = self.player.currentItem.duration;
    if (!CMTIME_IS_NUMERIC(duration) || CMTIME_IS_INDEFINITE(duration)) return 0.0;
    double seconds = CMTimeGetSeconds(duration);
    return isfinite(seconds) && seconds > 0 ? seconds : 0.0;
}

- (void)seekToProgress:(float)progress {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self seekToProgress:progress]; });
        return;
    }
    AVPlayerItem *item = self.player.currentItem;
    if (!item) return;

    CMTime duration = item.duration;

    if (!CMTIME_IS_NUMERIC(duration) ||
        CMTIME_IS_INDEFINITE(duration) ||
        CMTimeGetSeconds(duration) <= 0) {
        return;
    }

    float clamped = fminf(fmaxf(progress, 0.f), 1.f);
    CMTime target = CMTimeMultiplyByFloat64(duration, clamped);

    NSUInteger token = self.playSwitchToken;
    AVPlayer *player = self.player;
    __weak typeof(self) weakSelf = self;
    [player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        if (!finished) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.playSwitchToken || self.player != player || self.currentPlayerItem != item) return;
            [self.progressSubject sendNext:@(self.currentProgress)];
            [self synchronizePlaybackState]; // Also publish the actual seek time to Now Playing while paused.
        });
    }];
}

- (void)setVolume:(float)volume {
    _volume = volume;
    self.player.volume = volume;
}


//  播放进度和缓存进度
- (void)addPeriodicTimeObserver {
    if (self.timeObserver || !self.player || !self.currentPlayerItem) return;
    __weak typeof(self) weakSelf = self;
    AVPlayerItem *observedItem = self.currentPlayerItem;
    NSUInteger token = self.playSwitchToken;
    self.timeObserverOwner = self.player;
    self.timeObserver = [self.timeObserverOwner addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                                          queue:dispatch_get_main_queue()
                                                                     usingBlock:^(CMTime ignoredTime) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.playSwitchToken ||
            self.currentPlayerItem != observedItem || self.player.currentItem != observedItem) return;
        [self.progressSubject sendNext:@(self.currentProgress)];
    }];
}

- (void)updateCacheProgressForURL:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (!url) {
        [self.cacheProgressSubject sendNext:@(0.f)];
        self.latestCacheProgress = 0.f;
        return;
    }
    float progress = [self.cacheManager cacheProgressForURL:url cacheKey:cacheKey];
    self.latestCacheProgress = progress;
    [self.cacheProgressSubject sendNext:@(progress)];
    NSString *urlStr = url.absoluteString ?: @"";
    if (![urlStr isEqualToString:self.lastLoggedCacheURL]) {
        self.lastLoggedCacheURL = urlStr;
        if (progress >= 0.999f) NSLog(@"[缓存] 歌曲已完整缓存: %@", self.currentSong.title ?: @"(未知)");
        else if (progress > 0) NSLog(@"[缓存] 歌曲部分缓存: %.1f%%", progress * 100);
        else NSLog(@"[缓存] 歌曲无缓存");
    }
}

- (void)updateCacheProgressForURL:(NSURL *)url {
    [self updateCacheProgressForURL:url cacheKey:[self cacheKeyForSong:self.currentSong URL:url]];
}

#pragma mark - 监听

- (void)observeCurrentItemForReady:(AVPlayerItem *)item {
    if (!item) return;
    self.observedItem = item;
    [item addObserver:self forKeyPath:NSStringFromSelector(@selector(status))
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:kPlayerCurrentItemStatusContext];
}
- (void)uninstallCurrentItemObserver {
    if (self.observedItem) {
        [self.observedItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(status))
                                 context:kPlayerCurrentItemStatusContext];
        self.observedItem = nil;
    }
    if (self.endTimeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endTimeObserver];
        self.endTimeObserver = nil;
    }
}

// 当前歌曲什么时候完成
- (void)observeCurrentItemForEnd:(AVPlayerItem *)item {
    if (!item) return;
    if (self.endTimeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endTimeObserver];
        self.endTimeObserver = nil;
    }
    __weak typeof(self) weakSelf = self;
    self.endTimeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.currentPlayerItem != item || strongSelf.player.currentItem != item) return;
        [strongSelf handleCurrentItemDidPlayToEnd];
    }];
}

//收到播放结束的通知后怎么做
- (void)handleCurrentItemDidPlayToEnd {
    switch (self.playMode) {
        case NLPlayModeSingleLoop:
            [self.player seekToTime:kCMTimeZero];
            [self applyPlaybackIntent];
            break;
        case NLPlayModeListLoop:
        case NLPlayModeRandom:
            [self playNext];
            break;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != kPlayerCurrentItemStatusContext && context != kPlayerTimeControlStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    BOOL itemEvent = context == kPlayerCurrentItemStatusContext;
    if (itemEvent ? object != self.observedItem : object != self.observedPlayer) return;
    AVPlayerItem *item = self.currentPlayerItem;
    AVPlayer *player = self.player;
    NSUInteger token = self.playSwitchToken;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.playSwitchToken || self.player != player ||
            self.currentPlayerItem != item || player.currentItem != item) return;
        if (itemEvent && item.status == AVPlayerItemStatusReadyToPlay) [self applyPlaybackIntent];
        else [self synchronizePlaybackState];
    });
}


#pragma mark - 通知发送

// 状态变化
- (void)setPlaybackState:(NLPlaybackState)state {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setPlaybackState:state];
        });
        return;
    }
    if (state == NLPlaybackStateError) {
        self.wantsToPlay = NO;
        self.resumeAfterInterruption = NO;
        [self.player pause];
    }
    _playbackState = state;
    [self.playbackStateSubject sendNext:@(state)];
    if (state == NLPlaybackStatePlaying && self.currentSong.songId.length > 0) {
        NSUInteger token = self.playSwitchToken;
        if (!self.hasRecordedPlaybackToken || self.lastRecordedPlaybackToken != token) {
            self.hasRecordedPlaybackToken = YES;
            self.lastRecordedPlaybackToken = token;
            NLSong *song = self.currentSong;
            [NLSongRepository recordPlaybackStart:song completion:^(BOOL success) { (void)success; }];
        }
    }
    [self updateNowPlayingInfo];
}
- (void)postSongChangedNotification {
    // 发送 RAC 信号
    if (self.currentSong) {
        [self.songSubject sendNext:self.currentSong];
    }
}

- (void)setPlayMode:(NLPlayMode)playMode {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setPlayMode:playMode]; });
        return;
    }
    _playMode = playMode;
}


#pragma mark - 用于兼容灵动岛、锁屏播放等

- (void)setupAudioSession {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setupAudioSession]; });
        return;
    }
    if (!self.audioSessionInterrupted) [self requestAudioSessionActivation];
}

- (void)requestAudioSessionActivation {
    if (self.audioSessionActivated || self.audioSessionActivationPending) return;
    self.audioSessionActivationPending = YES;
    NSUInteger generation = self.audioSessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(NLAudioSessionQueue(), ^{
        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        BOOL activated = [session setCategory:AVAudioSessionCategoryPlayback error:&error] &&
            [session setActive:YES error:&error];
        if (!activated) NSLog(@"[Player] AudioSession activation failed: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.audioSessionGeneration) return;
            self.audioSessionActivationPending = NO;
            self.audioSessionActivated = activated;
            if (activated) [self applyPlaybackIntent];
            else [self setPlaybackState:NLPlaybackStateError];
        });
    });
}

- (void)invalidateAudioSessionDeactivating:(BOOL)deactivate {
    self.audioSessionGeneration += 1;
    self.audioSessionActivationPending = NO;
    self.audioSessionActivated = NO;
    if (deactivate) {
        // This follows any older activation on the same queue, even if its main callback is stale.
        dispatch_async(NLAudioSessionQueue(), ^{
            [AVAudioSession.sharedInstance setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                              error:nil];
        });
    }
}

- (void)configureAudioSessionAfterReset {
    NSUInteger generation = self.audioSessionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(NLAudioSessionQueue(), ^{
        NSError *error = nil;
        BOOL configured = [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error];
        if (!configured) NSLog(@"[Player] AudioSession category failed: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.audioSessionGeneration || configured) return;
            if (self.currentSong) [self setPlaybackState:NLPlaybackStateError];
        });
    });
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleAudioInterruption:notification]; });
        return;
    }
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (![type isKindOfClass:NSNumber.class]) return;
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        if (self.audioSessionInterrupted) return;
        self.audioSessionInterrupted = YES;
        [self invalidateAudioSessionDeactivating:self.audioSessionActivationPending];
        self.resumeAfterInterruption = self.wantsToPlay;
        [self applyPlaybackIntent];
    } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded && self.audioSessionInterrupted) {
        self.audioSessionInterrupted = NO;
        AVAudioSessionInterruptionOptions options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        BOOL resume = self.resumeAfterInterruption && self.wantsToPlay &&
            (options & AVAudioSessionInterruptionOptionShouldResume) && self.currentSong;
        self.resumeAfterInterruption = NO;
        self.wantsToPlay = resume;
        [self applyPlaybackIntent];
    }
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleApplicationDidBecomeActive:notification]; });
        return;
    }
    // Reconcile snapshots only; foregrounding is not a request to resume playback.
    [self synchronizePlaybackState];
    if (self.currentPlayerItem) [self.progressSubject sendNext:@(self.currentProgress)];
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleAudioRouteChange:notification]; });
        return;
    }
    if ([notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        AVAudioSessionRouteDescription *previousRoute = notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
        NSArray<AVAudioSessionPortDescription *> *outputs = previousRoute.outputs;
        // Missing route data: retain the privacy-safe pause policy.
        BOOL lostExternalOutput = outputs.count == 0;
        for (AVAudioSessionPortDescription *port in outputs) {
            if (![port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker] &&
                ![port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
                lostExternalOutput = YES;
                break;
            }
        }
        if (lostExternalOutput) [self pause];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleMediaServicesReset:notification]; });
        return;
    }
    NSURL *source = self.currentSourceURL ?: self.pendingSourceURL;
    NSTimeInterval position = self.hasPendingRestore ? self.pendingRestoreTime : self.currentTime;
    self.playSwitchToken += 1;
    self.wantsToPlay = NO;
    self.resumeAfterInterruption = NO;
    self.audioSessionInterrupted = NO;
    [self invalidateAudioSessionDeactivating:YES];
    [self tearDownCurrentPlaybackReleasingPlayer:YES];
    self.cacheManager.currentPlayingURL = nil;
    self.cacheManager.currentPlayingCacheKey = nil;
    self.pendingSourceURL = source;
    self.pendingRestoreTime = position;
    self.hasPendingRestore = position > 0;
    self.requiresPlaybackReload = self.currentSong != nil;
    // Apple requires explicit user action before restarting after a media-services reset.
    [self configureAudioSessionAfterReset];
    [self synchronizePlaybackState];
}

- (void)registerRemoteCommand:(MPRemoteCommand *)command handler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler {
    id target = [command addTargetWithHandler:handler];
    [self.remoteCommands addObject:command];
    [self.remoteCommandTargets addObject:target];
}

- (void)setupRemoteCommands {
    if (self.remoteCommandTargets.count > 0) return;
    self.remoteCommands = [NSMutableArray arrayWithCapacity:5];
    self.remoteCommandTargets = [NSMutableArray arrayWithCapacity:5];
    MPRemoteCommandCenter *commandCenter =
        [MPRemoteCommandCenter sharedCommandCenter];

    __weak typeof(self) weakSelf = self;
    [self registerRemoteCommand:commandCenter.playCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf play]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    // ⏸ Pause
    [self registerRemoteCommand:commandCenter.pauseCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf pause]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    //Seek
    [self registerRemoteCommand:commandCenter.changePlaybackPositionCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {

        MPChangePlaybackPositionCommandEvent *e =
            (MPChangePlaybackPositionCommandEvent *)event;

        NSTimeInterval position = e.positionTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.totalTime > 0) [weakSelf seekToProgress:position / weakSelf.totalTime];
        });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [self registerRemoteCommand:commandCenter.nextTrackCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf playNext]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [self registerRemoteCommand:commandCenter.previousTrackCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf playPrevious]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateNowPlayingInfo {
    [self updateNowPlayingInfoWithArtwork:nil];
}

- (void)updateNowPlayingInfoWithArtwork:(UIImage *)artworkImage {
    if (!self.currentSong) return;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle]  = self.currentSong.title ?: @"";
    info[MPMediaItemPropertyArtist] = self.currentSong.artist ?: @"";

    // 封面：若调用方未传入则用缓存或占位图；若仍未命中缓存则异步加载后再刷一次
    UIImage *img = artworkImage;
    if (!img) {
        img = [UIImage imageNamed:@"placeholder_cover"];
        NSURL *coverURL = self.currentSong.coverURL;
        if (coverURL) {
            NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:coverURL];
            UIImage *cached = [[SDImageCache sharedImageCache] imageFromDiskCacheForKey:key];
            if (cached) img = cached;
            else {
                __weak typeof(self) w = self;
                [[SDWebImageManager sharedManager] loadImageWithURL:coverURL
                                                             options:SDWebImageRetryFailed
                                                            progress:nil
                                                           completed:^(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, SDImageCacheType cacheType, BOOL finished, NSURL * _Nullable imageURL) {
                    if (!finished || !image || !imageURL) return;
                    NSURL *loadedURL = imageURL;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(w) s = w;
                        if (!s || !s.currentSong.coverURL || ![s.currentSong.coverURL isEqual:loadedURL]) return;
                        [s updateNowPlayingInfoWithArtwork:image];
                    });
                }];
            }
        }
    }
    if (img) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:img.size requestHandler:^UIImage * _Nonnull(CGSize size) {
            return img;
        }];
        info[MPMediaItemPropertyArtwork] = artwork;
    }
    // 进度与时长（等 AVPlayerItem 就绪后才有有效 duration，由 KVO 触发再次更新）
    if (self.player.currentItem) {
        CMTime duration = self.player.currentItem.duration;
        CMTime current  = self.player.currentTime;
        if (CMTIME_IS_NUMERIC(duration)) {
            info[MPMediaItemPropertyPlaybackDuration] = @(CMTimeGetSeconds(duration));
        }
        if (CMTIME_IS_NUMERIC(current)) {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(CMTimeGetSeconds(current));
        }
    }

    info[MPNowPlayingInfoPropertyPlaybackRate] =
        (self.playbackState == NLPlaybackStatePlaying) ? @(1.0) : @(0.0);

    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)removePeriodicTimeObserver {
    if (self.timeObserver) [self.timeObserverOwner removeTimeObserver:self.timeObserver];
    self.timeObserver = nil;
    self.timeObserverOwner = nil;
}
@end
