//
//  NLCommentCell.m
//  NLSpotify
//

#import "NLCommentCell.h"
#import "NLCommentModel.h"
#import <Masonry/Masonry.h>
#import <SDWebImage/SDWebImage.h>
#import "NLCommentTextLayout.h"

@interface NLCommentCell ()
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *nicknameLabel;
@property (nonatomic, strong) UILabel *contentLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *likedLabel;
@property (nonatomic, strong, readwrite) NLCommentModel *comment;
@property (nonatomic, strong, readwrite) NLCommentTextLayout *textLayout;
@property (nonatomic, strong) MASConstraint *textHeightConstraint;
@end

@implementation NLCommentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _avatarView = [[UIImageView alloc] init];
        _avatarView.layer.cornerRadius = 20;
        _avatarView.clipsToBounds = YES;
        _avatarView.backgroundColor = [UIColor systemGray5Color];
        [self.contentView addSubview:_avatarView];

        _nicknameLabel = [[UILabel alloc] init];
        _nicknameLabel.font = [UIFont boldSystemFontOfSize:14];
        _nicknameLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_nicknameLabel];

        _contentLabel = [[UILabel alloc] init];
        _contentLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:15]];
        _contentLabel.textColor = [UIColor labelColor];
        _contentLabel.numberOfLines = 0;
        _contentLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _contentLabel.accessibilityIdentifier = @"comment.content";
        _contentLabel.isAccessibilityElement = YES;
        [self.contentView addSubview:_contentLabel];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:12];
        _timeLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:_timeLabel];

        _likedLabel = [[UILabel alloc] init];
        _likedLabel.font = [UIFont systemFontOfSize:12];
        _likedLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:_likedLabel];

        [_avatarView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self.contentView).offset(12);
            make.top.equalTo(self.contentView).offset(12);
            make.size.mas_equalTo(CGSizeMake(40, 40));
            make.bottom.lessThanOrEqualTo(self.contentView).offset(-12);
        }];
        [_nicknameLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_avatarView.mas_right).offset(10);
            make.top.equalTo(_avatarView);
            make.right.lessThanOrEqualTo(_likedLabel.mas_left).offset(-8);
        }];
        [_contentLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_nicknameLabel);
            make.right.equalTo(self.contentView).offset(-12);
            make.top.equalTo(_nicknameLabel.mas_bottom).offset(4);
            self.textHeightConstraint = make.height.mas_equalTo(0).priority(999);
        }];
        [_timeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_contentLabel);
            make.top.equalTo(_contentLabel.mas_bottom).offset(6);
            make.bottom.equalTo(self.contentView).offset(-12);
        }];
        [_likedLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(self.contentView).offset(-12);
            make.centerY.equalTo(_nicknameLabel);
        }];

        UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                 action:@selector(textTap)];
        [_contentLabel addGestureRecognizer:tap];
        _contentLabel.userInteractionEnabled = YES;
    }
    return self;
}

+ (CGFloat)textWidthForCellWidth:(CGFloat)width {
    return MAX(0, width - 74.0);
}

- (void)textTap {
    if (!self.comment || !self.textLayout.needsExpansion) return;
    if (self.expandBlock) self.expandBlock(self.comment);
}

- (BOOL)accessibilityToggle:(UIAccessibilityCustomAction *)action {
    if (!self.comment || !self.textLayout.needsExpansion || !self.expandBlock) return NO;
    [self textTap];
    return YES;
}

- (void)configureWithComment:(NLCommentModel *)comment layout:(NLCommentTextLayout *)layout {
    self.comment = comment;
    self.textLayout = layout;
    BOOL expanded = layout.needsExpansion && comment.isExpanded;
    NSAttributedString *text = expanded ? layout.expandedText : layout.collapsedText;
    if (_contentLabel.attributedText != text) _contentLabel.attributedText = text;
    _contentLabel.font = layout.font;
    [self.textHeightConstraint setOffset:expanded ? layout.expandedTextHeight : layout.collapsedTextHeight];
    _contentLabel.accessibilityLabel = comment.content;
    _contentLabel.accessibilityValue = layout.needsExpansion ? (expanded ? @"已展开" : @"已收起") : nil;
    _contentLabel.accessibilityHint = layout.needsExpansion ? @"可通过操作菜单展开或收起评论" : nil;
    _contentLabel.accessibilityCustomActions = layout.needsExpansion ? @[
        [[UIAccessibilityCustomAction alloc] initWithName:expanded ? @"收起评论" : @"展开评论"
                                                 target:self selector:@selector(accessibilityToggle:)]
    ] : nil;
    _nicknameLabel.text = comment.user.nickname ?: @"匿名";
    _timeLabel.text = [self timeStringFromTimestamp:comment.time];
    _likedLabel.text = comment.likedCount > 0 ? [NSString stringWithFormat:@"♥ %ld", (long)comment.likedCount] : @"";
    [_avatarView sd_cancelCurrentImageLoad];
    _avatarView.image = nil;
    if (comment.user.avatarUrl.length > 0) {
        NSString *avatarUrl = [self urlStringByReplacingHttpWithHttps:comment.user.avatarUrl];
        [_avatarView sd_setImageWithURL:[NSURL URLWithString:avatarUrl] placeholderImage:nil];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_avatarView sd_cancelCurrentImageLoad];
    _avatarView.image = nil;
    self.comment = nil;
    self.textLayout = nil;
    self.expandBlock = nil;
    _contentLabel.attributedText = nil;
    _contentLabel.accessibilityLabel = nil;
    _contentLabel.accessibilityValue = nil;
    _contentLabel.accessibilityHint = nil;
    _contentLabel.accessibilityCustomActions = nil;
    [self.textHeightConstraint setOffset:0];
}

- (NSString *)urlStringByReplacingHttpWithHttps:(NSString *)urlString {
    if (!urlString.length) return urlString;
    if ([urlString hasPrefix:@"http://"]) {
        return [@"https://" stringByAppendingString:[urlString substringFromIndex:7]];
    }
    return urlString;
}

- (NSString *)timeStringFromTimestamp:(NSTimeInterval)timestamp {
    if (timestamp <= 0) return @"";
    NSTimeInterval diff = [[NSDate date] timeIntervalSince1970] - timestamp;
    if (diff < 60) return @"刚刚";
    if (diff < 3600) return [NSString stringWithFormat:@"%.0f分钟前", diff / 60];
    if (diff < 86400) return [NSString stringWithFormat:@"%.0f小时前", diff / 3600];
    if (diff < 2592000) return [NSString stringWithFormat:@"%.0f天前", diff / 86400];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

@end
