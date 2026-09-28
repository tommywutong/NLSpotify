//  NLPlayerManager.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/18.
//

#import "NLPlayerManager.h"
#import <AVFoundation/AVFoundation.h>
#import "NLSongService.h"
#import "NLSongRepository.h"
#import "SDWebImage/SDWebImage.h"
#import "NLResourceLoader.h"
#import "NLCacheManager.h"

@interface NLResourceLoader (CacheManagerInjection)
@property (nonatomic, strong) NLCacheManager *cacheManager;
@end

//NSString * const NLPlayerSongDidChangeNotification = @"NLPlayerSongDidChangeNotification";//  歌曲换了，用于通知刷新UI
//NSString * const NLPlayerPlaybackStateDidChangeNotification = @"NLPlayerPlaybackStateDidChangeNotification";//  播放/暂停/加载中 时候发送通知，用于更新播放的按钮
//NSString * const NLPlayerProgressDidChangeNotification = @"NLPlayerProgressDidChangeNotification";//  用于通知进度的变化

static void *kPlayerCurrentItemStatusContext = &kPlayerCurrentItemStatusContext;

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
@property (nonatomic, strong) AVPlayerItem *observedItem; // 当前被 KVO 的 item（强持有，避免快速切歌时 item 先释放导致 KVO 崩溃）
@property (nonatomic, strong) id endTimeObserver;       // 播放结束观察

@property (nonatomic, assign) NSUInteger playSwitchToken; // 丢弃过期异步回调（连续快速切歌）
@property (nonatomic, assign) BOOL wantsToPlay;

@property (nonatomic, assign) float lastLoggedCacheProgress; // 用于缓存跟踪日志，仅变化时打印
@property (nonatomic, copy) NSString *lastLoggedCacheURL;    // 上一首打印时的 URL，切歌后重新打印
- (void)startPlaybackWithURL:(NSURL *)url cacheKey:(NSString *)cacheKey token:(NSUInteger)token;
- (void)startSongAfterCacheReady:(NLSong *)song token:(NSUInteger)token;
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
        [self setupRemoteCommands];
        [self updateNowPlayingInfo];
    }
    return self;
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
- (void)playWithPlaylist:(NSArray<NLSong *> *)playlist startIndex:(NSInteger)index {
    if (!playlist || playlist.count == 0 || index < 0 || index >= playlist.count) return;
    self.playlist = [playlist copy];
    self.currentIndex = index;
    [self.hasPlaylistSubject sendNext:@YES];
    [self playSongAtIndexIfNeeded:index];
}
- (void)playWithURL:(NSURL *)url {
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
    [self removePeriodicTimeObserver];
    [self invalidateCurrentStreamingPlayback];
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
    self.currentPlayerItem = item;
    [self uninstallCurrentItemObserver];
    if (!self.player) self.player = [[AVPlayer alloc] initWithPlayerItem:item];
    else [self.player replaceCurrentItemWithPlayerItem:item];
    [self addPeriodicTimeObserver];
    [self observeCurrentItemForReady:item];
    [self observeCurrentItemForEnd:item];
    self.player.volume = self.volume;
    [self setPlaybackState:self.wantsToPlay ? NLPlaybackStateLoading : NLPlaybackStatePaused];
    [self setupAudioSession];
    if (self.wantsToPlay) [self.player play];
}

#pragma mark - 播放入口


- (void)playFullyCachedSongAtPath:(NSString *)cachePath {
    if (cachePath.length == 0) {
        [self setPlaybackState:NLPlaybackStateError];
        return;
    }
    NSURL *localURL = [NSURL fileURLWithPath:cachePath];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:localURL];
    self.currentPlayerItem = item;
    [self uninstallCurrentItemObserver];
    if (!self.player) self.player = [[AVPlayer alloc] initWithPlayerItem:item];
    else [self.player replaceCurrentItemWithPlayerItem:item];
    [self addPeriodicTimeObserver];
    [self observeCurrentItemForReady:item];
    [self observeCurrentItemForEnd:item];
    self.player.volume = self.volume;
    [self setPlaybackState:self.wantsToPlay ? NLPlaybackStateLoading : NLPlaybackStatePaused];
    [self setupAudioSession];
    if (self.wantsToPlay) [self.player play];
}


#pragma mark - 播放控制

- (void)play {
    if (!self.currentSong) return;
    self.wantsToPlay = YES;
    if (!self.player.currentItem) {
        [self setPlaybackState:NLPlaybackStateLoading];
        return;
    }
    [self.player play];
    if (self.player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        [self setPlaybackState:NLPlaybackStatePlaying];
    } else if (self.playbackState != NLPlaybackStateLoading) {
        [self setPlaybackState:NLPlaybackStateLoading];
    }
    [self updateNowPlayingInfo];
}

- (void)pause {
    if (!self.currentSong) return;
    self.wantsToPlay = NO;
    [self.player pause];
    [self setPlaybackState:NLPlaybackStatePaused];
    [self updateNowPlayingInfo];
}

- (void)togglePlayPause {
    if (self.wantsToPlay) {
        [self pause];
    } else {
        [self play];
    }
}

//  pause为真正的暂停，stop为取消

- (void)stop {
    self.wantsToPlay = NO;
    self.playSwitchToken += 1;
    [self invalidateCurrentStreamingPlayback];
    self.cacheManager.currentPlayingURL = nil;
    self.cacheManager.currentPlayingCacheKey = nil;
    [self uninstallCurrentItemObserver];
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentPlayerItem = nil;
    self.player = nil;
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
    NSInteger idx = [self indexForNextInMode:self.playMode];
    if (idx < 0) return;
    [self playSongAtIndexIfNeeded:idx];
}

- (void)playPrevious {
    NSInteger idx = [self indexForPreviousInMode:self.playMode];
    if (idx < 0) return;
    [self playSongAtIndexIfNeeded:idx];
}

#pragma mark - 切歌调度核心

/// 同一个入口处理列表切换、直接选曲和网络 URL 的过期回调。
- (void)playSongAtIndexIfNeeded:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.playlist.count) return;
    self.playSwitchToken += 1;
    NSUInteger token = self.playSwitchToken;
    self.wantsToPlay = YES;
    self.currentIndex = index;
    NLSong *song = self.playlist[index];
    self.currentSong = song;
    [self.progressSubject sendNext:@(0.f)];
    [NLSongRepository addPlayHistory:song];
    [self postSongChangedNotification];

    [self removePeriodicTimeObserver];
    [self invalidateCurrentStreamingPlayback];
    [self uninstallCurrentItemObserver];
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentPlayerItem = nil;
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

    [self.player seekToTime:target
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero];
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
    dispatch_queue_t timeQueue = dispatch_queue_create("com.nlspotify.timeobserver", DISPATCH_QUEUE_SERIAL);
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                                    queue:timeQueue
                                                               usingBlock:^(CMTime ignoredTime) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.playSwitchToken ||
                strongSelf.currentPlayerItem != observedItem || strongSelf.player.currentItem != observedItem) return;

            [strongSelf.progressSubject sendNext:@(strongSelf.currentProgress)];
            NSURL *url = strongSelf.currentSong.playURL;
            NSString *urlString = url.absoluteString ?: @"";
            if (![urlString isEqualToString:strongSelf.lastLoggedCacheURL]) {
                strongSelf.lastLoggedCacheURL = urlString;
            }
        });
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
        @try {
            [self.observedItem removeObserver:self
                                    forKeyPath:NSStringFromSelector(@selector(status))
                                       context:kPlayerCurrentItemStatusContext];
        } @catch (NSException *exception) {
        }
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
            if (self.wantsToPlay) [self.player play];
            break;
        case NLPlayModeListLoop:
        case NLPlayModeRandom:
            [self playNext];
            break;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != kPlayerCurrentItemStatusContext || object != self.player.currentItem ||
        ![keyPath isEqualToString:NSStringFromSelector(@selector(status))]) return;

    AVPlayerItemStatus status = [change[NSKeyValueChangeNewKey] integerValue];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || object != strongSelf.currentPlayerItem || object != strongSelf.player.currentItem) return;
        if (status == AVPlayerItemStatusReadyToPlay) {
            if (strongSelf.wantsToPlay) {
                [strongSelf.player play];
                [strongSelf setPlaybackState:NLPlaybackStatePlaying];
            } else {
                [strongSelf.player pause];
                [strongSelf setPlaybackState:NLPlaybackStatePaused];
            }
            [strongSelf updateNowPlayingInfo];
        } else if (status == AVPlayerItemStatusFailed) {
            [strongSelf setPlaybackState:NLPlaybackStateError];
        }
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
    _playbackState = state;
    [self.playbackStateSubject sendNext:@(state)];
    [self updateNowPlayingInfo];
}
- (void)postSongChangedNotification {
    // 发送 RAC 信号
    if (self.currentSong) {
        [self.songSubject sendNext:self.currentSong];
    }
}

- (void)setPlayMode:(NLPlayMode)playMode {
    _playMode = playMode;
}


#pragma mark - 用于兼容灵动岛、锁屏播放等

- (void)setupAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error) {
        NSLog(@"[Player] AudioSession Category Error: %@", error);
        error = nil;
    }
    [session setActive:YES error:&error];
    if (error) {
        NSLog(@"[Player] AudioSession Active Error: %@", error);
    }
}

- (void)setupRemoteCommands {
    MPRemoteCommandCenter *commandCenter =
        [MPRemoteCommandCenter sharedCommandCenter];

    __weak typeof(self) weakSelf = self;
    [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf play]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    // ⏸ Pause
    [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf pause]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    //Seek
    [commandCenter.changePlaybackPositionCommand
     addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {

        MPChangePlaybackPositionCommandEvent *e =
            (MPChangePlaybackPositionCommandEvent *)event;

        NSTimeInterval position = e.positionTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.totalTime > 0) [weakSelf seekToProgress:position / weakSelf.totalTime];
        });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf playNext]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
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
    if (!self.timeObserver) return;
    if (self.player) {
        @try {
            [self.player removeTimeObserver:self.timeObserver];
        } @catch (NSException *exception) {
            NSLog(@"[Player] 移除时间监听异常: %@", exception);
        }
    }
    self.timeObserver = nil;
}
@end
