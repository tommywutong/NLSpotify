//  NLMusicPlayerViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/19.
//

#import "NLMusicPlayerViewController.h"
#import "NLMusicPlayerView.h"
#import "NLPlayerManager.h"
#import "NLCacheManager.h"
#import "NLSong.h"
#import "NLSongRepository.h"
#import "NLPlayListRepository.h"
#import "NLAddToPlaylistSheetViewController.h"
#import "NLCommentListViewController.h"
#import "NLDownloadManager.h"
#import "NLSongService.h"
#import "NLLyricLine.h"
#import <Masonry/Masonry.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>


@interface NLMusicPlayerViewController () <NLMusicPlayerViewDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIView *backgroundOverlay;
@property (nonatomic, strong) NLMusicPlayerView *playerView;
@property (nonatomic, strong) MPVolumeView *systemVolumeView;
@property (nonatomic, copy) NSString *lastFullyCachedToastKey;
@property (nonatomic, assign) NSUInteger favoriteStateRequestToken;
@property (nonatomic, assign) BOOL favoriteWriteInProgress;

// 歌词
@property (nonatomic, strong) UITableView *lyricTableView;
@property (nonatomic, strong) NSArray<NLLyricLine *> *lyricLines;
@property (nonatomic, assign) NSInteger currentLyricIndex;
@property (nonatomic, assign) BOOL lyricVisible;
@property (nonatomic, copy) NSString *currentLyricSongId;
@property (nonatomic, assign) NSUInteger lyricRequestToken;
@property (nonatomic, assign) BOOL lyricPageVisible;
@end

@implementation NLMusicPlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self.view addSubview:self.backgroundOverlay];
    [self.view addSubview:self.playerView];
    [self.playerView addSubview:self.lyricTableView];
    [self setupConstraints];

    [self bindPlayer];
    [self refreshUI];

    // 隐藏的系统音量视图，用于驱动系统音量（硬件按键 / 控制中心）与自定义音量条同步
    self.systemVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    self.systemVolumeView.hidden = YES;
    [self.view addSubview:self.systemVolumeView];

    // 监听系统音量变化，将其同步到自定义音量条
    [[AVAudioSession sharedInstance] addObserver:self
                                      forKeyPath:@"outputVolume"
                                         options:NSKeyValueObservingOptionNew
                                         context:NULL];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.minimumNumberOfTouches = 0;
    pan.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:pan];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lyricPageVisible = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.lyricPageVisible = NO;
    [self invalidatePendingLyricRequests];
}

- (void)setupConstraints {
    [self.backgroundOverlay mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
    [self.playerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
    [self.lyricTableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.playerView.queueContainerView);
    }];
}

#pragma mark - Player Binding

- (void)bindPlayer {
    NSLog(@"[PlayTrace] [PlayerVC] bindPlayer");
        NLPlayerManager *manager = NLPlayerManager.sharedManager;
        @weakify(self);
    // 等价于__weak typeof(self) weakSelf = self;
    // 单例 Subject 不会 completed。weakify 不断开订阅，页面销毁时用 takeUntil 移除 subscriber。
    //  歌曲信息变化
        [[manager.songSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NLSong *song) {
            @strongify(self);
            if (!song) return;
            NSLog(@"[PlayTrace] [PlayerVC] songSignal 收到歌曲: %@ (%@)", song.title, song.songId);
            [self.playerView refreshProgress];
            [self.playerView updateTitle:song.title artist:song.artist];
            [self.playerView updateCoverURL:song.coverURL];
            [self.playerView updateCurrentTime:0 totalTime:manager.totalTime];
            [self updateFavoriteStateForSong:song];
            if (self.playerView.isQueuePanelVisible) {
                [self.playerView reloadQueue];
            }
            NSString *cacheKey = [[NLCacheManager sharedManager] cacheIdentityForURL:song.playURL cacheKey:song.songId];
            __weak typeof(self) weakSelf = self;
            [[NLCacheManager sharedManager] whenReadyOnQueue:dispatch_get_main_queue() perform:^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || NLPlayerManager.sharedManager.currentSong != song) return;
                float cacheProgress = [[NLCacheManager sharedManager] cacheProgressForURL:song.playURL cacheKey:cacheKey];
                [strongSelf.playerView updateCacheProgress:cacheProgress];
            }];

            // 歌切换时，同步处理歌词：
            // 1）使旧歌词请求失效；2）清空旧歌词；3）记录当前歌曲 ID；4）若当前在歌词模式，则自动加载新歌歌词
            [self invalidatePendingLyricRequests];
            self.currentLyricSongId = song.songId.length ? song.songId : nil;
            self.lyricLines = nil;
            self.currentLyricIndex = -1;
            [self.lyricTableView reloadData];
            if (self.lyricVisible && song.songId.length) {
                NSString *targetSongId = song.songId;
                NSUInteger requestToken = [self beginLyricRequestForSongID:targetSongId];
                [[NLSongService sharedService] fetchLyricWithSongId:targetSongId success:^(NSString *lyric) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // 切歌、关闭歌词面板或离开播放页后的旧回调一律丢弃
                        if (![self isLyricResponseCurrentForToken:requestToken songID:targetSongId]) return;
                        [self buildLyricLinesFromRawText:lyric];
                        [self updateLyricForCurrentTime:NLPlayerManager.sharedManager.currentTime];
                    });
                } failure:^(NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (![self isLyricResponseCurrentForToken:requestToken songID:targetSongId]) return;
                        [self showToast:@"歌词加载失败"];
                    });
                }];
            }
        }];
    // 播放状态变化
        [[manager.playbackStateSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNumber *stateNum) {
            @strongify(self);
            dispatch_async(dispatch_get_main_queue(), ^{ // ✨ 加这层
                NSLog(@"[PlayTrace] [PlayerVC] playbackStateSignal state=%@", stateNum);
                [self.playerView updatePlayState:manager.wantsToPlay];
                if (stateNum.integerValue == NLPlaybackStatePlaying) {
                    [self maybeShowFullyCachedToastIfNeeded];
                }
            });
        }];

        // 进度变化
        [[manager.progressSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNumber *progressNum) {
            @strongify(self);
            dispatch_async(dispatch_get_main_queue(), ^{ // 加这层
                NSLog(@"[PlayTrace] [PlayerVC] progressSignal progress=%.3f", progressNum.floatValue);
                if (self.playerView.isTrackingProgress) return;
                float progress = progressNum.floatValue;
                [self.playerView updateProgress:progress];
                [self.playerView updateCurrentTime:manager.currentTime
                                         totalTime:manager.totalTime];
                [self updateLyricForCurrentTime:manager.currentTime];
            });
        }];
    // 缓存进度（ResourceLoader 在 NSURLSession 回调线程 sendNext，必须回主线程更新 UI）
        [[manager.cacheProgressSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNumber *progressNum) {
            @strongify(self);
            if (![progressNum isKindOfClass:[NSNumber class]]) return;
            float value = progressNum.floatValue;
            NSLog(@"[PlayTrace] [PlayerVC] cacheProgressSignal progress=%.3f", value);
            if ([NSThread isMainThread]) {
               [self.playerView updateCacheProgress:value];
           } else {
               dispatch_async(dispatch_get_main_queue(), ^{
                   [self.playerView updateCacheProgress:value];
               });
           }
        }];
}


- (void)updateFavoriteStateForSong:(NLSong *)song {
    if (song.songId.length == 0) {
        [self.playerView updateFavoriteState:NO];
        return;
    }
    NSString *songID = [song.songId copy];
    NSUInteger requestToken = ++self.favoriteStateRequestToken;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL liked = [NLSongRepository isSongLiked:songID];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || requestToken != self.favoriteStateRequestToken ||
                ![NLPlayerManager.sharedManager.currentSong.songId isEqualToString:songID]) return;
            [self.playerView updateFavoriteState:liked];
        });
    });
}
- (void)maybeShowFullyCachedToastIfNeeded {
    NLSong *song = NLPlayerManager.sharedManager.currentSong;
    if (!song) return;
    NSString *key = song.songId.length > 0 ? song.songId : (song.playURL.absoluteString ?: @"");
    if (key.length == 0) return;
    if ([self.lastFullyCachedToastKey isEqualToString:key]) return;
    NSString *cacheKey = [[NLCacheManager sharedManager] cacheIdentityForURL:song.playURL cacheKey:song.songId];
    __weak typeof(self) weakSelf = self;
    [[NLCacheManager sharedManager] whenReadyOnQueue:dispatch_get_main_queue() perform:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || NLPlayerManager.sharedManager.currentSong != song) return;
        if ([strongSelf.lastFullyCachedToastKey isEqualToString:key]) return;
        if (![[NLCacheManager sharedManager] isFullyCachedForURL:song.playURL cacheKey:cacheKey]) return;
        strongSelf.lastFullyCachedToastKey = key;
        [strongSelf showToast:@"该歌曲已完整缓存"];
    }];
}

- (void)refreshUI {
    NSLog(@"[PlayTrace] [PlayerVC] refreshUI");
    NLSong *song = NLPlayerManager.sharedManager.currentSong;
    if (!song) {
        NSLog(@"[PlayTrace] [PlayerVC] refreshUI: 当前没有歌曲");
        [self.playerView updateTitle:@"未在播放" artist:@""];
        [self.playerView updateCoverURL:nil];
    [self.playerView updateProgress:0];
    [self.playerView updateCacheProgress:0];
    [self.playerView updateCurrentTime:0 totalTime:0];
    [self.playerView updateFavoriteState:NO];
        return;
    }
    NSLog(@"[PlayTrace] [PlayerVC] refreshUI: 当前歌曲 %@ (%@)", song.title, song.songId);
    [self.playerView updateTitle:song.title artist:song.artist];
    [self.playerView updateCoverURL:song.coverURL];

    float progress = NLPlayerManager.sharedManager.currentProgress;
    NSLog(@"[PlayTrace] [PlayerVC] refreshUI: 设置播放进度=%.3f", progress);
    [self.playerView updateProgress:progress];

//    NSURL *url = song.playURL;
//    float cacheProgress = url ? [[NLCacheManager sharedManager] cacheProgressForURL:url] : 0.f;
//    NSLog(@"[缓存条] refreshUI 设置缓存条 progress=%.2f url=%@", cacheProgress, url.absoluteString ?: @"");
//    [self.playerView updateCacheProgress:cacheProgress];
    float cacheProgress = NLPlayerManager.sharedManager.latestCacheProgress;
    NSLog(@"[缓存条] refreshUI 设置缓存条 progress=%.2f", cacheProgress);
    NSLog(@"[PlayTrace] [PlayerVC] refreshUI: 设置缓存进度=%.3f", cacheProgress);
    [self.playerView updateCacheProgress:cacheProgress];

    NSTimeInterval currentTime = NLPlayerManager.sharedManager.currentTime;
    NSTimeInterval totalTime = NLPlayerManager.sharedManager.totalTime;
    [self.playerView updateCurrentTime:currentTime totalTime:totalTime];
    
    [self.playerView updateVolume:NLPlayerManager.sharedManager.volume];
    [self.playerView updatePlayState:NLPlayerManager.sharedManager.wantsToPlay];
    [self.playerView updatePlayMode:NLPlayerManager.sharedManager.playMode];
    [self updateFavoriteStateForSong:song];
    // 刷新歌词选中行
    [self updateLyricForCurrentTime:NLPlayerManager.sharedManager.currentTime];
}


#pragma mark -  Delegate

- (void)musicPlayerViewDidTapClose:(NLMusicPlayerView *)view {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)musicPlayerViewDidTapPlayPause:(NLMusicPlayerView *)view {
    NSLog(@"[PlayTrace] [PlayerVC] UI 点击播放/暂停");
    [NLPlayerManager.sharedManager togglePlayPause];
}

- (void)musicPlayerViewDidTapPrevious:(NLMusicPlayerView *)view {
    NSLog(@"[PlayTrace] [PlayerVC] UI 点击上一首");
    [NLPlayerManager.sharedManager playPrevious];
}

- (void)musicPlayerViewDidTapNext:(NLMusicPlayerView *)view {
    NSLog(@"[PlayTrace] [PlayerVC] UI 点击下一首");
    [NLPlayerManager.sharedManager playNext];
}

- (void)musicPlayerView:(NLMusicPlayerView *)view didChangeProgress:(float)value {
    NSLog(@"[PlayTrace] [PlayerVC] UI 拖动进度到 %.3f", value);
    [[NLPlayerManager sharedManager] seekToProgress:value];
}

- (void)musicPlayerViewDidTapCover:(NLMusicPlayerView *)view {
    NLSong *song = NLPlayerManager.sharedManager.currentSong;
    if (!song || !song.songId.length) return;
    if (!self.lyricLines || self.lyricLines.count == 0) {
        // 第一次加载歌词
        NSString *targetSongId = song.songId;
        NSUInteger requestToken = [self beginLyricRequestForSongID:targetSongId];
        [[NLSongService sharedService] fetchLyricWithSongId:targetSongId success:^(NSString *lyric) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isLyricResponseCurrentForToken:requestToken songID:targetSongId]) return;
                [self buildLyricLinesFromRawText:lyric];
                [self showLyricView:YES];
            });
        } failure:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isLyricResponseCurrentForToken:requestToken songID:targetSongId]) return;
                [self showToast:@"歌词加载失败"];
            });
        }];
    } else {
        [self showLyricView:!self.lyricVisible];
    }
}

- (void)musicPlayerView:(NLMusicPlayerView *)view didChangeVolume:(float)value {
    // 将自定义音量条的变化同步到系统音量
    for (UIView *subview in self.systemVolumeView.subviews) {
        if ([subview isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)subview;
            [slider setValue:value animated:NO];
            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        }
    }
}

- (void)musicPlayerViewDidTapComment:(NLMusicPlayerView *)view {
    NLSong *song = NLPlayerManager.sharedManager.currentSong;
    if (!song || !song.songId.length) return;
    NSInteger songId = [song.songId integerValue];
    if (songId <= 0) return;
    NLCommentListViewController *commentVC = [[NLCommentListViewController alloc] initWithResourceId:songId resourceType:NLCommentListResourceTypeSong title:[NSString stringWithFormat:@"%@ 评论", song.title ?: @"歌曲"]];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:commentVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)musicPlayerViewDidTapPlaylist:(NLMusicPlayerView *)view {
    // 如果当前在歌词模式，先关闭歌词，避免歌词表和队列列表重叠
    if (self.lyricVisible) {
        [self showLyricView:NO];
    }
    BOOL wantShowQueue = !view.isQueuePanelVisible;
    [view setQueuePanelVisible:wantShowQueue animated:YES];
}

- (NSArray<NLSong *> *)musicPlayerViewPlaylist:(NLMusicPlayerView *)view {
    return NLPlayerManager.sharedManager.playlist ?: @[];
}

- (NSInteger)musicPlayerViewCurrentIndex:(NLMusicPlayerView *)view {
    return NLPlayerManager.sharedManager.currentIndex;
}

- (void)musicPlayerView:(NLMusicPlayerView *)view didSelectSongAtIndex:(NSInteger)index {
    [[NLPlayerManager sharedManager] playSongAtIndex:index];
    [view reloadQueue];
}

- (void)musicPlayerView:(NLMusicPlayerView *)view didChangePlayMode:(NLPlayMode)playMode {
    [view updatePlayMode:playMode];
    [NLPlayerManager.sharedManager setPlayMode:playMode];
}

- (void)musicPlayerViewDidTapAddToPlaylist:(NLMusicPlayerView *)view {
    NLSong *song = [NLPlayerManager sharedManager].currentSong;
    if (!song || !song.songId.length) return;

    NLAddToPlaylistSheetViewController *vc = [[NLAddToPlaylistSheetViewController alloc] init];
    vc.currentSong = song;
    [self presentViewController:vc animated:NO completion:nil];
}

- (void)musicPlayerViewDidTapFavorite:(NLMusicPlayerView *)view {
    NLSong *song = [NLPlayerManager sharedManager].currentSong;
    if (!song || !song.songId.length || self.favoriteWriteInProgress) return;
    self.favoriteWriteInProgress = YES;
    NSString *songID = [song.songId copy];
    NSUInteger requestToken = ++self.favoriteStateRequestToken;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL currentlyLiked = [NLSongRepository isSongLiked:songID];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (requestToken != self.favoriteStateRequestToken ||
                ![NLPlayerManager.sharedManager.currentSong.songId isEqualToString:songID]) {
                self.favoriteWriteInProgress = NO;
                return;
            }
            BOOL newLiked = !currentlyLiked;
            [NLSongRepository likeSong:song isLike:newLiked completion:^(BOOL success) {
                self.favoriteWriteInProgress = NO;
                if (requestToken != self.favoriteStateRequestToken ||
                    ![NLPlayerManager.sharedManager.currentSong.songId isEqualToString:songID]) return;
                if (success) [view updateFavoriteState:newLiked];
                else [self showToast:@"收藏失败，请重试"];
            }];
        });
    });
}

- (void)musicPlayerViewDidTapMore:(NLMusicPlayerView *)view {
    NLSong *song = [NLPlayerManager sharedManager].currentSong;
    if (!song || !song.songId.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NLDownloadManager sharedManager] addDownloadForSong:song];
        [self showToast:@"已加入下载"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = view;
        alert.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width - 60, 80, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showToast:(NSString *)text {
    UIView *toast = [[UIView alloc] init];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    toast.layer.cornerRadius = 10;
    toast.alpha = 0;
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = [UIColor whiteColor];
    [toast addSubview:label];
    [label mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(toast).insets(UIEdgeInsetsMake(12, 20, 12, 20));
    }];
    [self.view addSubview:toast];
    [toast mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.view);
    }];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

#pragma mark - System Volume KVO

- (void)dealloc {
    @try {
        [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
    } @catch (__unused NSException *e) {
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"outputVolume"]) {
        float v = [change[NSKeyValueChangeNewKey] floatValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.playerView updateVolume:v];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint location = [pan locationInView:self.playerView];
    CGPoint velocity = [pan velocityInView:self.playerView];
    if ([self isPointInSliderArea:location]) {
        return NO;
    }
    if (fabs(velocity.y) > fabs(velocity.x) && velocity.y > 0) {
        return YES;
    }
    return NO;
}

- (BOOL)isPointInSliderArea:(CGPoint)point {
    CGRect progressFrame = [self.playerView.progressSlider.superview convertRect:self.playerView.progressSlider.frame toView:self.playerView];
    CGRect volumeFrame = [self.playerView.volumeSlider.superview convertRect:self.playerView.volumeSlider.frame toView:self.playerView];

    return CGRectContainsPoint(progressFrame, point) || CGRectContainsPoint(volumeFrame, point);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    CGPoint velocity = [pan velocityInView:self.view];
    
    // 只处理向下滑动
    if (translation.y < 0) {
        // 如果向上滑动，重置状态
        if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
            [self resetDismissAnimation];
        }
        return;
    }
    // 计算下滑进度（使用更大的阈值，使交互更流畅）
    CGFloat dismissThreshold = 400.0;
    CGFloat progress = MIN(translation.y / dismissThreshold, 1.0);
    if (pan.state == UIGestureRecognizerStateBegan) {
        // 开始下滑时，可以添加触觉反馈
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        // 更新视图位置和进度
        self.view.transform = CGAffineTransformMakeTranslation(0, translation.y);
        self.playerView.dismissProgress = progress;
        // 在下拉过程中逐渐显示背景（让后面的页面可见）
        // 通过调整背景层的透明度，让后面的页面逐渐显示
        UIView *backgroundOverlay = self.backgroundOverlay;
        if (backgroundOverlay) {
            backgroundOverlay.alpha = 1.0 - progress; // 下拉时背景层逐渐透明
        }
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        // 判断是否应该关闭：进度超过阈值或向下速度足够快
        BOOL shouldDismiss = progress > 0.3 || velocity.y > 500;
        
        if (shouldDismiss) {
            // 关闭播放器
            [self dismissWithAnimation:progress];
        } else {
            // 恢复原状
            [self resetDismissAnimation];
        }
    }
}

- (void)dismissWithAnimation:(CGFloat)progress {
    // 计算剩余距离
    CGFloat remainingDistance = self.view.bounds.size.height - self.view.transform.ty;
    
    // 根据剩余距离和速度计算动画时长
    CGFloat duration = MIN(remainingDistance / 800.0, 0.4);
    
    UIView *backgroundOverlay = self.backgroundOverlay;
    [UIView animateWithDuration:duration
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.view.transform = CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
        self.playerView.dismissProgress = 1.0;
        if (backgroundOverlay) {
            backgroundOverlay.alpha = 0.0; // 完全透明，显示后面的页面
        }
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)resetDismissAnimation {
    UIView *backgroundOverlay = self.backgroundOverlay;
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.view.transform = CGAffineTransformIdentity;
        self.playerView.dismissProgress = 0.0;
        if (backgroundOverlay) {
            backgroundOverlay.alpha = 1.0; // 恢复不透明
        }
    } completion:nil];
}

#pragma mark - Getters

- (UIView *)backgroundOverlay {
    if (!_backgroundOverlay) {
        _backgroundOverlay = [[UIView alloc] init];
        // 使用稍微深一点的背景色，避免纯白
        if (@available(iOS 13.0, *)) {
            _backgroundOverlay.backgroundColor = [UIColor secondarySystemBackgroundColor];
        } else {
            _backgroundOverlay.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
        }
        _backgroundOverlay.tag = 999;
    }
    return _backgroundOverlay;
}

- (NLMusicPlayerView *)playerView {
    if (!_playerView) {
        _playerView = [[NLMusicPlayerView alloc] initWithFrame:CGRectZero];
        _playerView.delegate = self;
    }
    return _playerView;
}

- (UITableView *)lyricTableView {
    if (!_lyricTableView) {
        _lyricTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _lyricTableView.backgroundColor = [UIColor clearColor];
        _lyricTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _lyricTableView.showsVerticalScrollIndicator = NO;
        _lyricTableView.hidden = YES;
        _lyricTableView.alpha = 0.0;
        _lyricTableView.dataSource = (id<UITableViewDataSource>)self;
        _lyricTableView.delegate = (id<UITableViewDelegate>)self;
        _lyricTableView.rowHeight = 32.0;
        _lyricTableView.contentInset = UIEdgeInsetsMake(120, 0, 120, 0);
        [_lyricTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"LyricCell"];
    }
    return _lyricTableView;
}
#pragma mark - 歌词解析 & 表格

- (void)buildLyricLinesFromRawText:(NSString *)rawLyric {
    NSMutableArray<NLLyricLine *> *result = [NSMutableArray array];
    NSArray<NSString *> *lines = [rawLyric componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})\\]" options:0 error:NULL];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:trimSet];
        if (trimmed.length == 0) continue;

        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (matches.count == 0) continue;

        // 文本部分在最后一个 time tag 之后
        NSTextCheckingResult *lastMatch = matches.lastObject;
        NSUInteger textStart = NSMaxRange(lastMatch.range);
        if (textStart >= trimmed.length) continue;
        NSString *text = [[trimmed substringFromIndex:textStart] stringByTrimmingCharactersInSet:trimSet];
        if (text.length == 0) continue;

        for (NSTextCheckingResult *m in matches) {
            if (m.numberOfRanges < 4) continue;
            NSString *mmStr = [trimmed substringWithRange:[m rangeAtIndex:1]];
            NSString *ssStr = [trimmed substringWithRange:[m rangeAtIndex:2]];
            NSString *ffStr = [trimmed substringWithRange:[m rangeAtIndex:3]];
            NSInteger mm = mmStr.integerValue;
            NSInteger ss = ssStr.integerValue;
            NSInteger ff = ffStr.integerValue;
            NSTimeInterval time = mm * 60 + ss + (ff >= 100 ? ff / 1000.0 : ff / 100.0);

            NLLyricLine *lineObj = [[NLLyricLine alloc] init];
            lineObj.time = time;
            lineObj.text = text;
            [result addObject:lineObj];
        }
    }

    [result sortUsingComparator:^NSComparisonResult(NLLyricLine *a, NLLyricLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    self.lyricLines = result;
    self.currentLyricIndex = -1;
    [self.lyricTableView reloadData];
}

- (void)showLyricView:(BOOL)show {
    self.lyricVisible = show;
    if (!show) [self invalidatePendingLyricRequests];
    if (show) {
        // 展开中部区域为歌词模式（不影响队列按钮和列表）
        [self.playerView setLyricPanelVisible:YES animated:YES];
        self.lyricTableView.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.lyricTableView.alpha = 1.0;
        }];
    } else {
        // 收起歌词区域，恢复大封面样式
        [UIView animateWithDuration:0.25 animations:^{
            self.lyricTableView.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.lyricTableView.hidden = YES;
        }];
        [self.playerView setLyricPanelVisible:NO animated:YES];
    }
}

#pragma mark - 歌词请求代次

- (NSUInteger)beginLyricRequestForSongID:(NSString *)songID {
    self.currentLyricSongId = songID.length ? songID : nil;
    self.lyricRequestToken += 1;
    return self.lyricRequestToken;
}

- (void)invalidatePendingLyricRequests {
    self.lyricRequestToken += 1;
}

- (BOOL)isLyricResponseCurrentForToken:(NSUInteger)requestToken songID:(NSString *)songID {
    if (!self.lyricPageVisible) return NO;
    if (!songID.length || ![self.currentLyricSongId isEqualToString:songID]) return NO;
    return requestToken == self.lyricRequestToken;
}

- (void)updateLyricForCurrentTime:(NSTimeInterval)currentTime {
    if (!self.lyricLines || self.lyricLines.count == 0) return;
    // 找到当前时间所在的行：根据时间前进/后退决定起始搜索位置
    NSInteger start = 0;
    if (self.currentLyricIndex >= 0 && self.currentLyricIndex < (NSInteger)self.lyricLines.count) {
        NSTimeInterval lastTime = self.lyricLines[self.currentLyricIndex].time;
        if (currentTime >= lastTime) {
            // 时间向前（正常播放/快进）：从当前行往后找，加速
            start = self.currentLyricIndex;
        } else {
            // 时间往回跳：从头开始重新匹配（也可以改成从更前几行开始）
            start = 0;
        }
    }
    NSInteger targetIndex = -1;

    for (NSInteger i = start; i < self.lyricLines.count; i++) {
        NLLyricLine *line = self.lyricLines[i];
        NSTimeInterval nextTime = (i + 1 < self.lyricLines.count) ? self.lyricLines[i + 1].time : DBL_MAX;
        if (currentTime >= line.time && currentTime < nextTime) {
            targetIndex = i;
            break;
        }
    }
    if (targetIndex == -1 && currentTime < self.lyricLines.firstObject.time) {
        targetIndex = 0;
    }
    if (targetIndex == -1) return;
    if (targetIndex == self.currentLyricIndex) return;

    self.currentLyricIndex = targetIndex;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:targetIndex inSection:0];
    [self.lyricTableView reloadData];
    [self.lyricTableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyricLines.count > 0 ? self.lyricLines.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LyricCell" forIndexPath:indexPath];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.numberOfLines = 0;

    if (self.lyricLines.count == 0) {
        cell.textLabel.text = @"暂无歌词";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        return cell;
    }

    NLLyricLine *line = self.lyricLines[indexPath.row];
    cell.textLabel.text = line.text;
    BOOL isCurrent = (indexPath.row == self.currentLyricIndex);
    cell.textLabel.textColor = isCurrent ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    cell.textLabel.font = isCurrent ? [UIFont boldSystemFontOfSize:18] : [UIFont systemFontOfSize:16];
    return cell;
}

@end

