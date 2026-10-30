//
//  NLMusicPlayerAccessoryView.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/19.
//
#import <ReactiveObjC/ReactiveObjC.h>
#import "NLMusicPlayerAccessoryView.h"
#import "NLPlayerManager.h"
#import "Masonry/Masonry.h"
#import <SDWebImage/SDWebImage.h>

@interface NLMusicPlayerAccessoryView ()

@property (nonatomic, strong) UIImageView *coverImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
//@property (nonatomic, weak) id<NLMusicPlayerAccessoryViewDelegate> delegate;

@end

@implementation NLMusicPlayerAccessoryView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor systemBackgroundColor];
        [self setupUI];
    }
    return self;
}


//最重要的一集： 状态变了通知manager，更新UI
- (void)bindPlayer {
//    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
//    [center addObserver:self selector:@selector(onSongChanged)
//                   name:NLPlayerSongDidChangeNotification object:nil];
//    [center addObserver:self selector:@selector(onPlaybackStateChanged)
//                   name:NLPlayerPlaybackStateDidChangeNotification object:nil];
    NLPlayerManager *manager = NLPlayerManager.sharedManager;
    @weakify(self);
    // 单例 Subject 不会 completed。weakify 不断开订阅，视图销毁时用 takeUntil 移除 subscriber。

    // 歌曲变化
    [[manager.songSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NLSong *song) {
        @strongify(self);
        if (!song) {
            self.titleLabel.text = @"未播放";
            self.artistLabel.text = @"";
            self.coverImageView.image = [UIImage imageNamed:@"placeholder"];
            return;
        }

        self.titleLabel.text = song.title ?: @"";
        self.artistLabel.text = song.artist ?: @"";

        if (song.coverURL) {
            [self.coverImageView sd_setImageWithURL:song.coverURL
                                   placeholderImage:[UIImage imageNamed:@"placeholder"]];
        } else {
            self.coverImageView.image = [UIImage imageNamed:@"placeholder"];
        }
    }];

    // 播放状态
    [[manager.playbackStateSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNumber *stateNum) {
        @strongify(self);
        BOOL playing = manager.wantsToPlay;
        NSString *icon = playing ? @"pause.fill" : @"play.fill";
        [self.playPauseButton setImage:[UIImage systemImageNamed:icon]
                              forState:UIControlStateNormal];
    }];
}

#pragma mark - UI

- (void)setupUI {
    self.coverImageView = [[UIImageView alloc] init];
    self.coverImageView.layer.cornerRadius = 6;
    self.coverImageView.clipsToBounds = YES;
    self.coverImageView.backgroundColor = [UIColor systemGray5Color];
    self.coverImageView.contentMode = UIViewContentModeScaleAspectFill;

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.font = [UIFont systemFontOfSize:13];
    self.artistLabel.textColor = [UIColor secondaryLabelColor];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playPauseButton addTarget:self
                             action:@selector(onPlayPauseTapped)
                   forControlEvents:UIControlEventTouchUpInside];
    [self.playPauseButton setImage:[UIImage systemImageNamed:@"play.fill"]
                          forState:UIControlStateNormal];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.fill"]
                     forState:UIControlStateNormal];
    [self.nextButton addTarget:self
                        action:@selector(onNextTapped)
              forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:self.coverImageView];
    [self addSubview:self.titleLabel];
    [self addSubview:self.artistLabel];
    [self addSubview:self.playPauseButton];
    [self addSubview:self.nextButton];

    [self makeConstraints];
    
    // 添加点击手势打开大播放器
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(viewTapped:)];
    [self addGestureRecognizer:tapGesture];
    
    // 确保按钮点击不会触发视图点击
    tapGesture.cancelsTouchesInView = NO;
}

- (void)makeConstraints {
    [self.coverImageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(16);
        make.centerY.equalTo(self).offset(7);
        make.width.height.mas_equalTo(40);
    }];

    [self.playPauseButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self).offset(-56);
        make.centerY.equalTo(self).offset(7);
        make.width.height.mas_equalTo(32);
    }];

    [self.nextButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self).offset(-16);
        make.centerY.equalTo(self).offset(7);
        make.width.height.mas_equalTo(32);
    }];

    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.coverImageView.mas_right).offset(12);
        make.right.lessThanOrEqualTo(self.playPauseButton.mas_left).offset(-8);
        make.top.equalTo(self.coverImageView);
    }];

    [self.artistLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.titleLabel);
        make.bottom.equalTo(self.coverImageView);
    }];
}

#pragma mark - Actions

- (void)onPlayPauseTapped {
    [[NLPlayerManager sharedManager] togglePlayPause];
}

- (void)onNextTapped {
    [[NLPlayerManager sharedManager] playNext];
}

- (void)viewTapped:(UITapGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    // 如果点击的是按钮区域，不处理
    if (CGRectContainsPoint(self.playPauseButton.frame, location) ||
        CGRectContainsPoint(self.nextButton.frame, location)) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(accessoryViewDidTap:)]) {
        [self.delegate accessoryViewDidTap:self];
    }
}

#pragma mark - Notifications

//- (void)onSongChanged {
//    [self refreshUI];
//}
//
//- (void)onPlaybackStateChanged {
//    [self refreshPlayButton];
//}

#pragma mark - UI Update

- (void)refreshUI {
    NLPlayerManager *manager = [NLPlayerManager sharedManager];
    NLSong *song = manager.currentSong;

    if (song) {
        self.titleLabel.text = song.title ?: @"";
        self.artistLabel.text = song.artist ?: @"";

        if (song.coverURL) {
            [self.coverImageView sd_setImageWithURL:song.coverURL
                                   placeholderImage:[UIImage imageNamed:@"placeholder"]];
        } else {
            self.coverImageView.image = [UIImage imageNamed:@"placeholder"];
        }
    } else {
        self.titleLabel.text = @"未播放";
        self.artistLabel.text = @"";
        self.coverImageView.image = [UIImage imageNamed:@"placeholder"];
    }

    [self refreshPlayButton];
}

- (void)refreshPlayButton {
    NSString *iconName = NLPlayerManager.sharedManager.wantsToPlay ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:iconName]
                          forState:UIControlStateNormal];
}

- (void)dealloc {
//    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
