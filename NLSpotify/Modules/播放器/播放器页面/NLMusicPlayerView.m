//
//  NLMusicPlayerView.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/23.
//

#import "NLMusicPlayerView.h"
#import "NLSong.h"
#import <Masonry/Masonry.h>
#import <SDWebImage/SDWebImage.h>

@interface NLMusicPlayerView () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UIImageView *coverImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *totalTimeLabel;
@property (nonatomic, assign) BOOL hasShownVipToastForThisSong;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIView *progressContainerView;
@property (nonatomic, strong) UIProgressView *cacheProgressView;
@property (nonatomic, strong) NLExpandableTouchSlider *progressSlider;
@property (nonatomic, strong) NLExpandableTouchSlider *volumeSlider;
@property (nonatomic, strong) UIImageView *volumeLeftIcon;
@property (nonatomic, strong) UIImageView *volumeRightIcon;

// 歌曲信息右侧按钮
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *moreButton;

// 底部四个按钮
@property (nonatomic, strong) UIStackView *bottomButtonsStackView;
@property (nonatomic, strong) UIButton *commentButton;
@property (nonatomic, strong) UIButton *playModeButton;
@property (nonatomic, strong) UIButton *playlistButton;
@property (nonatomic, strong) UIButton *addToPlaylistButton;
@property (nonatomic, strong) UIView *playlistButtonCircleView;

// 播放控制与音量（StackView 分组）
@property (nonatomic, strong) UIStackView *timeLabelsStackView;
@property (nonatomic, strong) UIStackView *playControlsStackView;
@property (nonatomic, strong) UIStackView *volumeStackView;

// 下滑横栏指示器
@property (nonatomic, strong) UIView *dismissIndicator;

// 播放队列面板（在进度条上方）
@property (nonatomic, strong) UIView *queueContainerView;
@property (nonatomic, strong) UIStackView *queueContainerStackView;
@property (nonatomic, strong) UIStackView *queueModeStackView;
@property (nonatomic, strong) UIButton *queueShuffleButton;
@property (nonatomic, strong) UIButton *queueListLoopButton;
@property (nonatomic, strong) UIButton *queueSingleLoopButton;

@property (nonatomic, strong) UITableView *queueTableView;
@property (nonatomic, assign, readwrite) BOOL isQueuePanelVisible;

@property (nonatomic, assign) BOOL isLyricPanelVisible;

@property (nonatomic, assign) NLPlayMode playMode;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isTrackingVolume;

@end

@implementation NLMusicPlayerView

#pragma mark - Initializer

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.playMode = NLPlayModeListLoop;
        self.isPlaying = NO;
        [self setupUI];
        [self setupConstraints];
    }
    return self;
}

#pragma mark - UI Setup

- (void)setupUI {
    self.coverImageView = [[UIImageView alloc] init];
    self.coverImageView.layer.cornerRadius = 12;
    self.coverImageView.clipsToBounds = YES;
    self.coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.coverImageView.userInteractionEnabled = YES;
    UITapGestureRecognizer *coverTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(coverTapped)];
    [self.coverImageView addGestureRecognizer:coverTap];
    [self addSubview:self.coverImageView];

    // 下滑横栏指示器
    self.dismissIndicator = [[UIView alloc] init];
    self.dismissIndicator.backgroundColor = [UIColor tertiaryLabelColor];
    self.dismissIndicator.layer.cornerRadius = 2.5; // 圆角
    [self addSubview:self.dismissIndicator];

    // 歌曲信息
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    self.titleLabel.text = @"歌曲标题";
    [self addSubview:self.titleLabel];

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.textColor = [UIColor secondaryLabelColor];
    self.artistLabel.font = [UIFont systemFontOfSize:16];
    self.artistLabel.textAlignment = NSTextAlignmentLeft;
    self.artistLabel.text = @"歌手";
    [self addSubview:self.artistLabel];

    // 收藏和更多按钮
    self.favoriteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.favoriteButton setImage:[UIImage systemImageNamed:@"star"] forState:UIControlStateNormal];
    self.favoriteButton.tintColor = [UIColor labelColor];
    [self.favoriteButton addTarget:self action:@selector(favoriteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.favoriteButton];

    self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.moreButton setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    self.moreButton.tintColor = [UIColor labelColor];
    [self.moreButton addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.moreButton];

    self.progressContainerView = [[UIView alloc] init];
    self.progressContainerView.clipsToBounds = YES;
    [self addSubview:self.progressContainerView];

    self.cacheProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.cacheProgressView.progress = 0.f;
    self.cacheProgressView.progressTintColor = [UIColor colorWithWhite:0.55 alpha:1]; // 缓存条：灰度在未播与已播之间
    self.cacheProgressView.trackTintColor = [UIColor tertiarySystemFillColor];        // 未缓存部分与原先未播一致
    [self.progressContainerView addSubview:self.cacheProgressView];

    // 时间标签和进度条
    self.currentTimeLabel = [[UILabel alloc] init];
    self.currentTimeLabel.textColor = [UIColor secondaryLabelColor];
    self.currentTimeLabel.font = [UIFont systemFontOfSize:14];
    self.currentTimeLabel.textAlignment = NSTextAlignmentLeft;
    self.currentTimeLabel.text = @"0:00";
    [self addSubview:self.currentTimeLabel];

    self.totalTimeLabel = [[UILabel alloc] init];
    self.totalTimeLabel.textColor = [UIColor secondaryLabelColor];
    self.totalTimeLabel.font = [UIFont systemFontOfSize:14];
    self.totalTimeLabel.textAlignment = NSTextAlignmentRight;
    self.totalTimeLabel.text = @"0:00";
    [self addSubview:self.totalTimeLabel];

    self.progressSlider = [[NLExpandableTouchSlider alloc] init];
    self.progressSlider.sliderStyle = UISliderStyleThumbless;
    self.progressSlider.minimumTrackTintColor = [UIColor labelColor];
    self.progressSlider.maximumTrackTintColor = [UIColor clearColor];
    [self.progressSlider setThumbImage:[UIImage new] forState:UIControlStateHighlighted];
//    [self.progressSlider setThumbTintColor:UIColor.clearColor];
    [self.progressSlider addTarget:self action:@selector(progressChanged:) forControlEvents:UIControlEventValueChanged];
    [self.progressContainerView addSubview:self.progressSlider];

    UIView *timeSpacer = [[UIView alloc] init];
    self.timeLabelsStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.currentTimeLabel, timeSpacer, self.totalTimeLabel]];
    self.timeLabelsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.timeLabelsStackView.distribution = UIStackViewDistributionFill;
    self.timeLabelsStackView.alignment = UIStackViewAlignmentCenter;
    self.timeLabelsStackView.spacing = 8;
    [self addSubview:self.timeLabelsStackView];

    // 播放控制按钮
    self.previousButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *prevConfig = [UIImageSymbolConfiguration configurationWithPointSize:28];
    [self.previousButton setImage:[UIImage systemImageNamed:@"backward.end.fill" withConfiguration:prevConfig] forState:UIControlStateNormal];
    self.previousButton.tintColor = [UIColor labelColor];
    [self.previousButton addTarget:self action:@selector(previousTapped) forControlEvents:UIControlEventTouchUpInside];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *playConfig = [UIImageSymbolConfiguration configurationWithPointSize:36];
    [self.playPauseButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:playConfig] forState:UIControlStateNormal];
    self.playPauseButton.tintColor = [UIColor labelColor];
    [self.playPauseButton addTarget:self action:@selector(playPauseTapped) forControlEvents:UIControlEventTouchUpInside];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.end.fill" withConfiguration:prevConfig] forState:UIControlStateNormal];
    self.nextButton.tintColor = [UIColor labelColor];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];

    // 音量控制
    self.volumeLeftIcon = [[UIImageView alloc] init];
    self.volumeLeftIcon.image = [UIImage systemImageNamed:@"speaker.fill"];
    self.volumeLeftIcon.tintColor = [UIColor secondaryLabelColor];
    self.volumeLeftIcon.contentMode = UIViewContentModeScaleAspectFit;

    self.volumeRightIcon = [[UIImageView alloc] init];
    self.volumeRightIcon.image = [UIImage systemImageNamed:@"speaker.wave.3.fill"];
    self.volumeRightIcon.tintColor = [UIColor secondaryLabelColor];
    self.volumeRightIcon.contentMode = UIViewContentModeScaleAspectFit;

    self.volumeSlider = [[NLExpandableTouchSlider alloc] init];
    self.volumeSlider.value = 0.7;
    [self.volumeSlider setThumbImage:[UIImage new] forState:UIControlStateNormal];
    self.volumeSlider.minimumTrackTintColor = [UIColor secondaryLabelColor];
    self.volumeSlider.maximumTrackTintColor = [UIColor tertiarySystemFillColor];

    // 添加多个触摸事件，确保能够响应滑动
    [self.volumeSlider addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged];
//    [self.volumeSlider addTarget:self action:@selector(volumeTouchDown:) forControlEvents:UIControlEventTouchDown];
//    [self.volumeSlider addTarget:self action:@selector(volumeTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

    self.commentButton = [self createBottomButtonWithIcon:@"message" action:@selector(commentTapped)];
    self.playModeButton = [self createBottomButtonWithIcon:@"repeat" action:@selector(playModeTapped)];
    self.playlistButton = [self createBottomButtonWithIcon:@"list.bullet" action:@selector(playlistTapped)];
    self.addToPlaylistButton = [self createBottomButtonWithIcon:@"plus.circle" action:@selector(addToPlaylistTapped)];

    self.playlistButtonCircleView = [[UIView alloc] init];
    self.playlistButtonCircleView.backgroundColor = [UIColor systemGray4Color];
    self.playlistButtonCircleView.layer.cornerRadius = 20;
    self.playlistButtonCircleView.clipsToBounds = YES;
    self.playlistButtonCircleView.hidden = YES;
    [self addSubview:self.playlistButtonCircleView];
    [self sendSubviewToBack:self.playlistButtonCircleView];

    // 播放队列面板
    self.queueContainerView = [[UIView alloc] init];
    self.queueContainerView.backgroundColor = [UIColor clearColor];
    self.queueContainerView.clipsToBounds = YES;
    [self addSubview:self.queueContainerView];

    self.queueShuffleButton = [self createQueueModeButtonWithTitle:@"" icon:@"shuffle" tag:NLPlayModeRandom];
    self.queueListLoopButton = [self createQueueModeButtonWithTitle:@"" icon:@"repeat" tag:NLPlayModeListLoop];
    self.queueSingleLoopButton = [self createQueueModeButtonWithTitle:@"" icon:@"repeat.1" tag:NLPlayModeSingleLoop];

    self.queueModeStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.queueShuffleButton, self.queueListLoopButton, self.queueSingleLoopButton]];
    self.queueModeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.queueModeStackView.distribution = UIStackViewDistributionFillEqually;
    self.queueModeStackView.spacing = 16;
    self.queueModeStackView.alignment = UIStackViewAlignmentCenter;

    self.queueTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.queueTableView.delegate = self;
    self.queueTableView.dataSource = self;
    self.queueTableView.backgroundColor = [UIColor clearColor];
    self.queueTableView.separatorColor = [UIColor separatorColor];
    self.queueTableView.rowHeight = 52;
    self.queueTableView.scrollEnabled = YES;
    self.queueTableView.showsVerticalScrollIndicator = YES;
    [self.queueTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"QueueCell"];

    self.queueContainerStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.queueModeStackView, self.queueTableView]];
    self.queueContainerStackView.axis = UILayoutConstraintAxisVertical;
    self.queueContainerStackView.distribution = UIStackViewDistributionFill;
    self.queueContainerStackView.spacing = 8;
    self.queueContainerStackView.alignment = UIStackViewAlignmentFill;
    [self.queueContainerView addSubview:self.queueContainerStackView];

    self.playControlsStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.previousButton, self.playPauseButton, self.nextButton]];
    self.playControlsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.playControlsStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.playControlsStackView.spacing = 40;
    self.playControlsStackView.alignment = UIStackViewAlignmentCenter;
    [self addSubview:self.playControlsStackView];

    self.volumeStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.volumeLeftIcon, self.volumeSlider, self.volumeRightIcon]];
    self.volumeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.volumeStackView.distribution = UIStackViewDistributionFill;
    self.volumeStackView.spacing = 15;
    self.volumeStackView.alignment = UIStackViewAlignmentCenter;
    [self addSubview:self.volumeStackView];

    self.bottomButtonsStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.commentButton, self.playModeButton, self.playlistButton, self.addToPlaylistButton]];
    self.bottomButtonsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.bottomButtonsStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.bottomButtonsStackView.spacing = 56;
    self.bottomButtonsStackView.alignment = UIStackViewAlignmentCenter;
    [self addSubview:self.bottomButtonsStackView];
}


- (void)setupConstraints {
    [self.coverImageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.mas_safeAreaLayoutGuideTop).offset(60);
        make.centerX.equalTo(self);
        make.width.height.mas_equalTo(320);
    }];

    [self.dismissIndicator mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.coverImageView.mas_top).offset(-42);
        make.centerX.equalTo(self);
        make.width.mas_equalTo(80);
        make.height.mas_equalTo(5);
    }];

    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.coverImageView.mas_bottom).offset(24);
        make.left.equalTo(self).offset(20);
        make.right.lessThanOrEqualTo(self.favoriteButton.mas_left).offset(-16);
    }];

    [self.artistLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleLabel.mas_bottom).offset(4);
        make.left.equalTo(self.titleLabel);
        make.right.lessThanOrEqualTo(self.favoriteButton.mas_left).offset(-16);
    }];

    [self.favoriteButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.titleLabel);
        make.right.equalTo(self.moreButton.mas_left).offset(-20);
        make.size.mas_equalTo(32);
    }];

    [self.moreButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(self.titleLabel);
        make.right.equalTo(self).offset(-20);
        make.size.mas_equalTo(32);
    }];

    [self.queueContainerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.artistLabel.mas_bottom).offset(32);
        make.centerX.equalTo(self);
        make.width.mas_equalTo(342);
        make.height.mas_equalTo(0);
    }];
    [self.queueContainerStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.queueContainerView);
    }];
    [self.queueModeStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(35);
    }];
    [self.queueShuffleButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(35);
    }];
    [self.queueListLoopButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(35);
    }];
    [self.queueSingleLoopButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(35);
    }];
    [self.queueTableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(312);
    }];
    // 初始为折叠状态，隐藏队列内容避免 height==0 与 stack 内 35+8+312 冲突
    self.queueModeStackView.hidden = YES;
    self.queueTableView.hidden = YES;

    [self.progressContainerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(30);
        make.right.equalTo(self).offset(-30);
        make.height.mas_equalTo(6);
        make.bottom.equalTo(self.timeLabelsStackView.mas_top).offset(-17);
    }];
    [self.cacheProgressView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(30);
        make.right.equalTo(self).offset(-30);
        make.height.mas_equalTo(6);
        make.bottom.equalTo(self.timeLabelsStackView.mas_top).offset(-17);
    }];
    [self.progressSlider mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(30);
        make.right.equalTo(self).offset(-30);
        make.height.mas_equalTo(6);
        make.bottom.equalTo(self.timeLabelsStackView.mas_top).offset(-17);
    }];

    [self.currentTimeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.mas_equalTo(50);
    }];
    [self.totalTimeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.mas_equalTo(50);
    }];
    [self.timeLabelsStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.progressSlider);
        make.bottom.equalTo(self.playControlsStackView.mas_top).offset(-32);
    }];

    [self.playControlsStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self);
        make.bottom.equalTo(self.volumeStackView.mas_top).offset(-32);
    }];
    [self.previousButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(44);
    }];
    [self.playPauseButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(60);
    }];
    [self.nextButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(44);
    }];

    [self.volumeStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self).offset(40);
        make.right.equalTo(self).offset(-40);
        make.bottom.equalTo(self.bottomButtonsStackView.mas_top).offset(-32);
    }];
    [self.volumeLeftIcon mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(18);
    }];
    [self.volumeRightIcon mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(18);
    }];
    [self.volumeSlider mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(10);
    }];

    [self.bottomButtonsStackView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self);
        make.bottom.equalTo(self.mas_safeAreaLayoutGuideBottom).offset(-48);
    }];
    [self.commentButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(30);
    }];
    [self.playModeButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(30);
    }];
    [self.playlistButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(30);
    }];
    [self.addToPlaylistButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(30);
    }];
    [self.playlistButtonCircleView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.playlistButton);
        make.size.mas_equalTo(40);
    }];
}

#pragma mark - Updata Data

- (void)updateTitle:(NSString *)title artist:(NSString *)artist {
    self.titleLabel.text = title ?: @"";
    self.artistLabel.text = artist ?: @"";
}

- (void)updateCoverURL:(NSURL *)url {
    if (url) {
        [self.coverImageView sd_setImageWithURL:url placeholderImage:[UIImage imageNamed:@"placeholder"]];
    } else {
        self.coverImageView.image = [UIImage imageNamed:@"placeholder"];
    }
}

- (void)updatePlayState:(BOOL)isPlaying {
    self.isPlaying = isPlaying;

    NSString *iconName = isPlaying ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:36];
    [self.playPauseButton setImage:[UIImage systemImageNamed:iconName withConfiguration:config] forState:UIControlStateNormal];
}

- (void)updateProgress:(float)progress {
    if (!self.progressSlider.isTracking) {
        self.progressSlider.value = progress;
    }
}

- (void)refreshProgress {
    self.progressSlider.value = 0;
}

- (BOOL)isTrackingProgress {
    return self.progressSlider.isTracking;
}

- (void)updateCacheProgress:(float)progress {
    [self.cacheProgressView setProgress:progress animated:YES];
}

- (void)updateCurrentTime:(NSTimeInterval)currentTime totalTime:(NSTimeInterval)totalTime {
    self.currentTimeLabel.text = [self formattedTime:currentTime];
    self.totalTimeLabel.text = [self formattedTime:totalTime];
    BOOL isVipTrial = (totalTime > 0 && totalTime <= 60);
    if (isVipTrial && !self.hasShownVipToastForThisSong) {
        self.hasShownVipToastForThisSong = YES;
    } else if (!isVipTrial) {
        self.hasShownVipToastForThisSong = NO;
    }
}


- (void)updateVolume:(float)volume {
    self.volumeSlider.value = volume;
}

- (void)setDismissProgress:(CGFloat)dismissProgress {
    _dismissProgress = dismissProgress;
    // 更新封面缩放（下滑时缩小，考虑播放状态）
    CGFloat baseScale = self.isPlaying ? 0.92 : 1.0;
    CGFloat dismissScale = 1.0 - dismissProgress * 0.1;
    self.coverImageView.transform = CGAffineTransformMakeScale(baseScale * dismissScale, baseScale * dismissScale);
    self.alpha = 1.0 - dismissProgress * 0.2;
}

- (void)updateFavoriteState:(BOOL)liked {
    NSString *iconName = liked ? @"star.fill" : @"star";
    [self.favoriteButton setImage:[UIImage systemImageNamed:iconName] forState:UIControlStateNormal];
    self.favoriteButton.tintColor = liked ? [UIColor systemYellowColor] : [UIColor labelColor];
}

- (void)updatePlayMode:(NLPlayMode)playMode {
    self.playMode = playMode;
    [self updateQueueModeButtonsSelection];
    NSString *iconName = @"";
    /*
     switchCase不使用default，便于后续添加或删除
     */
    switch (playMode) {
        case NLPlayModeListLoop:
            iconName = @"repeat";
            break;
        case NLPlayModeSingleLoop:
            iconName = @"repeat.1";
            break;
        case NLPlayModeRandom:
            iconName = @"shuffle";
            break;
    }

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24];
    [self.playModeButton setImage:[UIImage systemImageNamed:iconName withConfiguration:config] forState:UIControlStateNormal];
}

- (void)coverTapped {
    if ([self.delegate respondsToSelector:@selector(musicPlayerViewDidTapCover:)]) {
        [self.delegate musicPlayerViewDidTapCover:self];
    }
}

#pragma mark - Tool Methods && Factory Methods

- (NSString *)formattedTime:(float)seconds {
    int totalSeconds = (int)seconds;
    int minutes = totalSeconds / 60;
    int remainingSeconds = totalSeconds % 60;
    return [NSString stringWithFormat:@"%d:%02d", minutes, remainingSeconds];
}


- (UIButton *)createBottomButtonWithIcon:(NSString *)iconName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightLight];
    [button setImage:[UIImage systemImageNamed:iconName withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.configurationUpdateHandler = ^(__kindof UIButton *updatedButton) {
        if (updatedButton.isHighlighted) {
            updatedButton.imageView.alpha = 0.5;
        } else {
            updatedButton.imageView.alpha = 1.0;
        }
    };
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)createQueueModeButtonWithTitle:(NSString *)title icon:(NSString *)iconName tag:(NLPlayMode)mode {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setImage:[UIImage systemImageNamed:iconName] forState:UIControlStateNormal];
    btn.tag = mode;
    btn.titleLabel.font = [UIFont systemFontOfSize:13];
    btn.tintColor = [UIColor secondaryLabelColor];
    btn.backgroundColor = [UIColor tertiarySystemFillColor];
    btn.layer.cornerRadius = 17.5;
    btn.clipsToBounds = YES;
    [btn addTarget:self action:@selector(queueModeTapped:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Actions && Delegate

- (void)favoriteTapped {
    if ([self.delegate respondsToSelector:@selector(musicPlayerViewDidTapFavorite:)]) {
        [self.delegate musicPlayerViewDidTapFavorite:self];
    }
}

- (void)moreTapped {
    if ([self.delegate respondsToSelector:@selector(musicPlayerViewDidTapMore:)]) {
        [self.delegate musicPlayerViewDidTapMore:self];
    }
}

- (void)playPauseTapped {
    [self.delegate musicPlayerViewDidTapPlayPause:self];
}

- (void)previousTapped {
    [self.delegate musicPlayerViewDidTapPrevious:self];
}

- (void)nextTapped {
    [self.delegate musicPlayerViewDidTapNext:self];
}

- (void)commentTapped {
    [self.delegate musicPlayerViewDidTapComment:self];
}

- (void)playlistTapped {
    [self.delegate musicPlayerViewDidTapPlaylist:self];
}

- (void)queueModeTapped:(UIButton *)sender {
    NLPlayMode mode = (NLPlayMode)sender.tag;
    self.playMode = mode;
    [self updateQueueModeButtonsSelection];
    [self.delegate musicPlayerView:self didChangePlayMode:mode];
}

- (void)updateQueueModeButtonsSelection {
    UIColor *selectedColor = [UIColor labelColor];
    UIColor *normalColor = [UIColor secondaryLabelColor];
    self.queueShuffleButton.tintColor = (self.playMode == NLPlayModeRandom) ? selectedColor : normalColor;
    self.queueListLoopButton.tintColor = (self.playMode == NLPlayModeListLoop) ? selectedColor : normalColor;
    self.queueSingleLoopButton.tintColor = (self.playMode == NLPlayModeSingleLoop) ? selectedColor : normalColor;
}

#pragma mark - Queue Panel

- (void)setQueuePanelVisible:(BOOL)visible animated:(BOOL)animated {
    if (_isQueuePanelVisible == visible) return;
    _isQueuePanelVisible = visible;
    CGFloat queueHeight = visible ? 355 : 0;
    [self applyLayoutCompact:visible queuePanelHeight:queueHeight];
    if (visible) {
        [self updateQueueModeButtonsSelection];
        [self reloadQueue];
        self.coverImageView.transform = CGAffineTransformIdentity;
        self.playlistButtonCircleView.hidden = NO;
    } else {
        CGFloat baseScale = self.isPlaying ? 0.92f : 1.0f;
        CGFloat dismissScale = 1.0f - (CGFloat)self.dismissProgress * 0.1f;
        self.coverImageView.transform = CGAffineTransformMakeScale(baseScale * dismissScale, baseScale * dismissScale);
        self.playlistButtonCircleView.hidden = YES;
    }
}

- (void)setLyricPanelVisible:(BOOL)visible animated:(BOOL)animated {
    if (_isLyricPanelVisible == visible) return;
    _isLyricPanelVisible = visible;
    CGFloat lyricHeight = visible ? 355 : 0;
    [self applyLayoutCompact:visible queuePanelHeight:lyricHeight];
    if (visible) {
        self.queueModeStackView.hidden = YES;
        self.queueTableView.hidden = YES;
    }
}

- (void)applyLayoutCompact:(BOOL)compact queuePanelHeight:(CGFloat)queuePanelHeight {
    if (compact) {
        [self.dismissIndicator mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.mas_safeAreaLayoutGuideTop).offset(6);
            make.centerX.equalTo(self);
            make.width.mas_equalTo(80);
            make.height.mas_equalTo(5);
        }];
        [self.coverImageView mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.mas_safeAreaLayoutGuideTop).offset(16);
            make.left.equalTo(self).offset(20);
            make.width.height.mas_equalTo(56);
        }];
        [self.titleLabel mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self.coverImageView.mas_right).offset(12);
            make.top.equalTo(self.coverImageView);
            make.right.lessThanOrEqualTo(self.moreButton.mas_left).offset(-8);
        }];
        [self.artistLabel mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self.titleLabel);
            make.top.equalTo(self.titleLabel.mas_bottom).offset(2);
        }];
        [self.favoriteButton mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.coverImageView);
            make.right.equalTo(self.moreButton.mas_left).offset(-20);
            make.size.mas_equalTo(32);
        }];
        [self.moreButton mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.coverImageView);
            make.right.equalTo(self).offset(-20);
            make.size.mas_equalTo(32);
        }];
        [self.queueContainerView mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.coverImageView.mas_bottom).offset(28);
            make.centerX.equalTo(self);
            make.width.mas_equalTo(342);
            make.height.mas_equalTo(queuePanelHeight);
        }];
        [self.queueTableView mas_updateConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(312);
        }];
        self.queueModeStackView.hidden = NO;
        self.queueTableView.hidden = NO;
    } else {
        [self.dismissIndicator mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.bottom.equalTo(self.coverImageView.mas_top).offset(-42);
            make.centerX.equalTo(self);
            make.width.mas_equalTo(80);
            make.height.mas_equalTo(5);
        }];
        [self.coverImageView mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.mas_safeAreaLayoutGuideTop).offset(60);
            make.centerX.equalTo(self);
            make.width.height.mas_equalTo(320);
        }];
        [self.titleLabel mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.coverImageView.mas_bottom).offset(24);
            make.left.equalTo(self).offset(20);
            make.right.lessThanOrEqualTo(self.favoriteButton.mas_left).offset(-16);
        }];
        [self.artistLabel mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.titleLabel.mas_bottom).offset(4);
            make.left.equalTo(self.titleLabel);
            make.right.lessThanOrEqualTo(self.favoriteButton.mas_left).offset(-16);
        }];
        [self.favoriteButton mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.titleLabel);
            make.right.equalTo(self.moreButton.mas_left).offset(-20);
            make.size.mas_equalTo(32);
        }];
        [self.moreButton mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.centerY.equalTo(self.titleLabel);
            make.right.equalTo(self).offset(-20);
            make.size.mas_equalTo(32);
        }];
        [self.queueContainerView mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(self.artistLabel.mas_bottom).offset(32);
            make.centerX.equalTo(self);
            make.width.mas_equalTo(342);
            make.height.mas_equalTo(0);
        }];
        [self.queueTableView mas_updateConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(160);
        }];
        self.queueModeStackView.hidden = YES;
        self.queueTableView.hidden = YES;
    }
    [self setNeedsLayout];
}

- (void)reloadQueue {
    [self.queueTableView reloadData];
    NSInteger currentIndex = [self.delegate respondsToSelector:@selector(musicPlayerViewCurrentIndex:)] ? [self.delegate musicPlayerViewCurrentIndex:self] : -1;
    NSArray *list = [self.delegate respondsToSelector:@selector(musicPlayerViewPlaylist:)] ? [self.delegate musicPlayerViewPlaylist:self] : nil;
    if (currentIndex >= 0 && list.count > 0 && currentIndex < (NSInteger)list.count) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:currentIndex inSection:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.queueTableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        });
    }
}

#pragma mark - UITableViewDataSource / Delegate (Queue)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView != self.queueTableView) return 0;
    if (![self.delegate respondsToSelector:@selector(musicPlayerViewPlaylist:)]) return 0;
    NSArray *list = [self.delegate musicPlayerViewPlaylist:self];
    if (!list || list.count == 0) return 1; // 占位行「队列中无音乐。」
    return list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"QueueCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = [UIColor labelColor];
    NSArray *list = [self.delegate musicPlayerViewPlaylist:self];
    NSInteger currentIndex = [self.delegate musicPlayerViewCurrentIndex:self];
    if (!list || list.count == 0) {
        cell.textLabel.text = @"队列中无音乐";
        cell.textLabel.textColor = [UIColor tertiaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NLSong *song = list[indexPath.row];
    cell.textLabel.text = song.title ?: @"";
    cell.textLabel.textColor = (indexPath.row == currentIndex) ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *list = [self.delegate respondsToSelector:@selector(musicPlayerViewPlaylist:)] ? [self.delegate musicPlayerViewPlaylist:self] : nil;
    if (!list || list.count == 0) return;
    if ([self.delegate respondsToSelector:@selector(musicPlayerView:didSelectSongAtIndex:)]) {
        [self.delegate musicPlayerView:self didSelectSongAtIndex:indexPath.row];
    }
}

#pragma mark - 事件响应

- (void)addToPlaylistTapped {
    if ([self.delegate respondsToSelector:@selector(musicPlayerViewDidTapAddToPlaylist:)]) {
        [self.delegate musicPlayerViewDidTapAddToPlaylist:self];
    }
}

- (void)playModeTapped {
    // 循环切换播放模式
    NLPlayMode nextMode = (self.playMode + 1) % 3;
    [self updatePlayMode:nextMode];

    if ([self.delegate respondsToSelector:@selector(musicPlayerView:didChangePlayMode:)]) {
        [self.delegate musicPlayerView:self didChangePlayMode:nextMode];
    }
}

- (void)progressChanged:(UISlider *)slider {
    if ([self.delegate respondsToSelector:@selector(musicPlayerView:didChangeProgress:)]) {
        [self.delegate musicPlayerView:self didChangeProgress:slider.value];
    }
}

- (void)volumeChanged:(UISlider *)slider {
    if ([self.delegate respondsToSelector:@selector(musicPlayerView:didChangeVolume:)]) {
        [self.delegate musicPlayerView:self didChangeVolume:slider.value];
    }
}



@end
