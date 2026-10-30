//
//  NLSongListCell.m
//  NLSpotify
//

#import "NLSongListCell.h"
#import "NLListCellModel.h"
#import "NLSong.h"
#import "NLPlayList.h"
#import "NLAlbum.h"
#import "NLDownloadItem.h"
#import <Masonry/Masonry.h>
#import "SDWebImage/SDWebImage.h"

@interface NLSongListCell ()
@property (nonatomic, strong) UIImageView *thumbImageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *downloadStatusLabel; /// 下载项时显示「下载中...」或「已下载」
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) UIActivityIndicatorView *downloadActivityIndicator;
@end

@implementation NLSongListCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor systemBackgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleGray;

        _thumbImageView = [[UIImageView alloc] init];
        _thumbImageView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbImageView.clipsToBounds = YES;
        _thumbImageView.layer.cornerRadius = 4;
        _thumbImageView.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_thumbImageView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _nameLabel.numberOfLines = 1;
        [self.contentView addSubview:_nameLabel];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.textColor = [UIColor secondaryLabelColor];
        _artistLabel.font = [UIFont systemFontOfSize:14];
        _artistLabel.numberOfLines = 1;
        [self.contentView addSubview:_artistLabel];

        _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
        _moreButton.tintColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_moreButton];

        [_thumbImageView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self.contentView).offset(16);
            make.centerY.equalTo(self.contentView);
            make.size.mas_equalTo(CGSizeMake(48, 48));
        }];
        [_nameLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_thumbImageView.mas_right).offset(12);
            make.right.lessThanOrEqualTo(_moreButton.mas_left).offset(-8);
            make.top.equalTo(self.contentView).offset(12);
        }];
        [_artistLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_nameLabel);
            make.top.equalTo(_nameLabel.mas_bottom).offset(2);
        }];
        _downloadStatusLabel = [[UILabel alloc] init];
        _downloadStatusLabel.font = [UIFont systemFontOfSize:12];
        _downloadStatusLabel.textColor = [UIColor tertiaryLabelColor];
        _downloadStatusLabel.hidden = YES;
        [self.contentView addSubview:_downloadStatusLabel];
        _downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _downloadProgressView.hidden = YES;
        _downloadProgressView.progressTintColor = [UIColor systemBlueColor];
        [self.contentView addSubview:_downloadProgressView];
        _downloadActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _downloadActivityIndicator.hidesWhenStopped = YES;
        [_downloadActivityIndicator stopAnimating];
        [self.contentView addSubview:_downloadActivityIndicator];

        [_downloadActivityIndicator mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(_moreButton.mas_left).offset(-8);
            make.centerY.equalTo(_artistLabel);
            make.size.mas_equalTo(CGSizeMake(16, 16));
        }];
        [_downloadStatusLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(_downloadActivityIndicator.mas_left).offset(-6);
            make.centerY.equalTo(_artistLabel);
        }];
        [_moreButton mas_makeConstraints:^(MASConstraintMaker *make) {
            make.right.equalTo(self.contentView).offset(-12);
            make.centerY.equalTo(self.contentView);
            make.size.mas_equalTo(CGSizeMake(44, 44));
        }];
        [_downloadProgressView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_nameLabel);
            make.right.equalTo(_moreButton.mas_left).offset(-8);
            make.top.equalTo(_artistLabel.mas_bottom).offset(6);
            make.height.mas_equalTo(2);
        }];
    }
    return self;
}

- (void)configWithSong:(NLListCellModel *)song {
    _downloadStatusLabel.hidden = YES;
    _downloadProgressView.hidden = YES;
    [_downloadActivityIndicator stopAnimating];
    _nameLabel.text = song.name ?: @"";
    _artistLabel.text = song.artistName ?: @"";
    if (song.coverUrl.length > 0) {
        NSString *url = [song.coverUrl stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
        [_thumbImageView sd_setImageWithURL:[NSURL URLWithString:url] placeholderImage:nil];
    } else {
        _thumbImageView.image = nil;
    }
}

- (void)configWithNLSong:(NLSong *)song {
    _downloadStatusLabel.hidden = YES;
    _downloadProgressView.hidden = YES;
    [_downloadActivityIndicator stopAnimating];
    _nameLabel.text = song.title ?: @"";
    _artistLabel.text = song.artist ?: @"";
    if (song.coverURL) {
        [_thumbImageView sd_setImageWithURL:song.coverURL placeholderImage:nil];
    } else {
        _thumbImageView.image = nil;
    }
}

- (void)configWithPlayList:(NLPlayList *)playList {
    _downloadStatusLabel.hidden = YES;
    _downloadProgressView.hidden = YES;
    [_downloadActivityIndicator stopAnimating];
    _nameLabel.text = playList.name.length ? playList.name : @"歌单";
    _artistLabel.text = @"歌单";
    if (playList.coverURL.length > 0) {
        [_thumbImageView sd_setImageWithURL:[NSURL URLWithString:playList.coverURL] placeholderImage:nil];
    } else {
        _thumbImageView.image = nil;
        _thumbImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    }
}

- (void)configWithAlbum:(NLAlbum *)album {
    _downloadStatusLabel.hidden = YES;
    _downloadProgressView.hidden = YES;
    [_downloadActivityIndicator stopAnimating];
    _nameLabel.text = album.name.length ? album.name : @"专辑";
    _artistLabel.text = album.artistName.length ? album.artistName : @"专辑";
    if (album.coverURL.length > 0) {
        [_thumbImageView sd_setImageWithURL:[NSURL URLWithString:album.coverURL] placeholderImage:nil];
    } else {
        _thumbImageView.image = nil;
        _thumbImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    }
}

- (void)configWithDownloadItem:(NLDownloadItem *)item downloadProgress:(float)progress {
    _nameLabel.text = item.title ?: @"";
    _artistLabel.text = item.artist ?: @"";
    if (item.coverURLString.length > 0) {
        [_thumbImageView sd_setImageWithURL:[NSURL URLWithString:item.coverURLString] placeholderImage:nil];
    } else {
        _thumbImageView.image = nil;
        _thumbImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    }
    _downloadStatusLabel.hidden = NO;
    _downloadProgressView.hidden = YES;
    [_downloadActivityIndicator stopAnimating];
    if ([item.status isEqualToString:@"downloading"]) {
        _downloadStatusLabel.text = @"下载中...";
        if (progress >= 0.f) {
            _downloadProgressView.progress = MIN(MAX(progress, 0.f), 1.f);
            _downloadProgressView.hidden = NO;
        } else {
            [_downloadActivityIndicator startAnimating];
        }
    } else if ([item.status isEqualToString:@"completed"]) {
        _downloadStatusLabel.text = @"已下载";
    } else if ([item.status isEqualToString:@"paused"]) {
        _downloadStatusLabel.text = @"已暂停";
    } else if ([item.status isEqualToString:@"cancelled"]) {
        _downloadStatusLabel.text = @"已取消，可重试";
    } else {
        _downloadStatusLabel.text = @"下载失败";
    }
}

@end
