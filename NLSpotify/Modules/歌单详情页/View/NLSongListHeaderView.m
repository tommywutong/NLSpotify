//
//  NLSongListHeaderView.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/8.
//

#import "NLSongListHeaderView.h"
#import <Masonry/Masonry.h>
#import <SDWebImage/SDWebImage.h>
#import "NLHeaderModel.h"

@interface NLSongListHeaderView ()

@property (nonatomic, strong) UIImageView *coverImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *playAllButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIButton *expandDescButton;
@property (nonatomic, strong) MASConstraint *descAreaTopConstraint;
@property (nonatomic, strong) MASConstraint *descLabelHeightConstraint;
@property (nonatomic, strong) MASConstraint *expandButtonHeightConstraint;

@property (nonatomic, copy) NSString *fullDescText;
@property (nonatomic, assign, readwrite) BOOL descExpanded;


@end

@implementation NLSongListHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = NO; // 允许内容超出 bounds，避免标题被裁剪
        self.backgroundColor = [UIColor systemBackgroundColor];

        [self setupSubviews];
        [self setupConstrains];
    }
    return self;
}

- (void)setupSubviews {
    // 封面
    _coverImageView = [[UIImageView alloc] init];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = 8;
    [self addSubview:_coverImageView];

    // 歌单/专辑名称
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:22];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    // 设置内容压缩阻力 防止内容变形。
    // 如果我没有设置，那么在展开收起时可能会随机触发其他区域变形
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];  //垂直方向的抗压缩阻力为最高优先级
    [_titleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];    //同理，该行为抗拉伸
    [self addSubview:_titleLabel];

    // 副标题
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:18];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [_subtitleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_subtitleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self addSubview:_subtitleLabel];

    // 简介
    _descLabel = [[UILabel alloc] init];
    _descLabel.font = [UIFont systemFontOfSize:14];
    _descLabel.textColor = [UIColor secondaryLabelColor];
    _descLabel.textAlignment = NSTextAlignmentLeft;
    _descLabel.numberOfLines = 3;

    [_descLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self addSubview:_descLabel];

    // 展开/收起按钮
    _expandDescButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_expandDescButton setTitle:@"更多" forState:UIControlStateNormal];
    _expandDescButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [_expandDescButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    [_expandDescButton addTarget:self action:@selector(expandDescTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_expandDescButton];
}

- (void)setupConstrains {
    CGFloat coverSide = (self.bounds.size.width > 0 ? self.bounds.size.width : self.window.windowScene.screen.bounds.size.width) - 120;
    if (coverSide > 240) coverSide = 240;
    // TableView 已用 contentInsetAdjustmentBehavior = Automatic，系统已预留导航栏下方空间，这里只保留封面距 header 顶部的间距
    CGFloat topInset = 24.0;
    
    [_coverImageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self).offset(topInset);
        make.centerX.equalTo(self);
        make.width.height.mas_equalTo(coverSide);
    }];

    [_titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_coverImageView.mas_bottom).offset(12);
        make.left.right.equalTo(self).inset(24);
    }];
    
    [_subtitleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_titleLabel.mas_bottom).offset(4);
        make.centerX.equalTo(self);
    }];

    _playAllButton = [self createPlayAllButton];
    _shuffleButton = [self createShuffleButton];
    [self addSubview:_playAllButton];
    [self addSubview:_shuffleButton];

    [_playAllButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_subtitleLabel.mas_bottom).offset(16);
        make.left.equalTo(self).offset(24);
        make.right.equalTo(_shuffleButton.mas_left).offset(-12);
        make.height.mas_equalTo(40);
        make.width.equalTo(_shuffleButton);
    }];
    
    [_shuffleButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerY.equalTo(_playAllButton);
        make.right.equalTo(self).offset(-24);
        make.height.mas_equalTo(40);
    }];

    [_descLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        _descAreaTopConstraint = make.top.equalTo(_playAllButton.mas_bottom).offset(16);
        make.left.equalTo(self).offset(24);
        make.right.equalTo(self).offset(-24);
        _descLabelHeightConstraint = make.height.mas_equalTo(0).priority(UILayoutPriorityDefaultLow);
    }];
    
    [_expandDescButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_descLabel.mas_bottom).offset(4);
        make.left.equalTo(_descLabel);
        make.bottom.equalTo(self).offset(-24).priority(UILayoutPriorityDefaultHigh);
        _expandButtonHeightConstraint = make.height.mas_equalTo(28);
    }];
}

#pragma mark - Buttons

- (UIButton *)createPlayAllButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.layer.cornerRadius = 20;
    btn.clipsToBounds = YES;
    btn.backgroundColor = [UIColor tertiarySystemFillColor];
    [btn setTitle:@" 播放" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    UIImage *icon = [[UIImage systemImageNamed:@"play.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [btn setImage:icon forState:UIControlStateNormal];
    btn.tintColor = [UIColor systemRedColor];
    [btn addTarget:self action:@selector(playAllTapped) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)createShuffleButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.layer.cornerRadius = 20;
    btn.clipsToBounds = YES;
    btn.backgroundColor = [UIColor tertiarySystemFillColor];

    [btn setTitle:@" 随机播放" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    UIImage *icon = [[UIImage systemImageNamed:@"shuffle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [btn setImage:icon forState:UIControlStateNormal];
    btn.tintColor = [UIColor systemRedColor];
    [btn addTarget:self action:@selector(shuffleTapped) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Actions

- (void)playAllTapped {
    if ([self.delegate respondsToSelector:@selector(headerViewDidTapPlayAll:)]) {
        [self.delegate headerViewDidTapPlayAll:self];
    }
}

- (void)shuffleTapped {
    if ([self.delegate respondsToSelector:@selector(headerViewDidTapShuffle:)]) {
        [self.delegate headerViewDidTapShuffle:self];
    }
}

#pragma mark - 简介展开/收起
/**
 * 用户点击"更多/收起"按钮
 * 简介自适应展开的核心逻辑：
 * 1. 切换展开状态（_descExpanded）
 * 2. 修改 label 的 numberOfLines（展开：0，收起：3）
 * 3. 更新按钮文字
 * 4. 通知 VC 重新计算 headerView 高度
 */
- (void)expandDescTapped {
    _descExpanded = !_descExpanded;
    _descLabel.numberOfLines = _descExpanded ? 0 : 3;
    //收起为0不代表显示0行，而是代表着行数无限制，系统会根据文字数量自动
    [_expandDescButton setTitle:_descExpanded ? @"收起" : @"更多" forState:UIControlStateNormal];
    if ([self.delegate respondsToSelector:@selector(headerViewDidRequestRelayout:)]) {
        [self.delegate headerViewDidRequestRelayout:self];
    }
}

- (BOOL)isDescExpanded {
    return _descExpanded;
}

#pragma mark - Config

- (void)configWithPlayList:(NLHeaderModel *)playlist {
    if (!playlist) return;

    NSString *cover = [playlist.coverUrl stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
    NSURL *coverURL = [NSURL URLWithString:cover];
    [_coverImageView sd_setImageWithURL:coverURL];

    _titleLabel.text = playlist.name;
    _subtitleLabel.text = playlist.creatorName.length ? playlist.creatorName : @"歌单";

    if (playlist.hideDescription) {
        _descLabel.hidden = YES;
        _descLabel.text = @"";
        _expandDescButton.hidden = YES;
        [_descAreaTopConstraint setOffset:0];
        [_descLabelHeightConstraint uninstall];
        [_descLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            _descLabelHeightConstraint = make.height.mas_equalTo(0).priority(UILayoutPriorityRequired);
        }];
        [_expandDescButton mas_updateConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(0);
        }];
        return;
    }

    _descLabel.hidden = NO;
    [_descAreaTopConstraint setOffset:16];
    [_descLabelHeightConstraint uninstall];
    [_descLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        _descLabelHeightConstraint = make.height.mas_equalTo(0).priority(UILayoutPriorityDefaultLow);
    }];
    _fullDescText = playlist.desc.length ? playlist.desc : @"暂无介绍";
    _descLabel.text = _fullDescText;
    _descExpanded = NO;
    _descLabel.numberOfLines = 3;
    [self updateExpandButtonVisibility];
}

/**
 * 更新展开按钮的显示状态
 * 
 * 简介自适应展开的初始判断逻辑：
 * 1. 如果没有简介文本，隐藏按钮
 * 2. 使用 boundingRectWithSize 测量文本实际高度
 * 3. 如果实际高度 > 3行高度，显示展开按钮
 * 4. 根据是否需要展开，设置按钮高度（0 或 28pt）
 */

- (void)updateExpandButtonVisibility {
    if (_fullDescText.length == 0) {
        _expandDescButton.hidden = YES;
        [_expandDescButton mas_updateConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(0);
        }];
        return;
    }
    
    CGFloat width = (self.bounds.size.width > 0 ? self.bounds.size.width : self.window.windowScene.screen.bounds.size.width) - 48;
    CGFloat lineHeight = _descLabel.font.lineHeight;
    CGFloat threeLineHeight = lineHeight * 3 + 4;
    CGSize maxSize = CGSizeMake(width, CGFLOAT_MAX);
    CGRect fitRect = [_fullDescText boundingRectWithSize:maxSize
                                                options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:@{ NSFontAttributeName: _descLabel.font }
                                                context:nil];
    
    BOOL needsExpand = fitRect.size.height > threeLineHeight;
    _expandDescButton.hidden = !needsExpand;
    
    [_expandDescButton mas_updateConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(needsExpand ? 28 : 0);
    }];
    if (needsExpand) {
        [_expandDescButton setTitle:_descExpanded ? @"收起" : @"更多" forState:UIControlStateNormal];
    }
}

@end
