//
//  NLAddToPlaylistSheetViewController.m
//  NLSpotify
//

#import "NLAddToPlaylistSheetViewController.h"
#import "NLSong.h"
#import "NLPlayList.h"
#import "NLPlayListRepository.h"
#import "NLCreatePlayListSheetViewController.h"
#import <Masonry/Masonry.h>
#import <SDWebImage/SDWebImage.h>

static NSString * const kNewPlaylistCellId = @"NewPlaylist";
static NSString * const kPlaylistCellId = @"Playlist";
static const CGFloat kPlaylistCoverSize = 40.0;

@interface NLAddToPlaylistSheetPlaylistCell : UITableViewCell
@property (nonatomic, strong) UIImageView *coverImageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *countLabel;
@end

@implementation NLAddToPlaylistSheetPlaylistCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        _coverImageView = [[UIImageView alloc] init];
        _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
        _coverImageView.clipsToBounds = YES;
        _coverImageView.layer.cornerRadius = 4;
        _coverImageView.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_coverImageView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];

        _countLabel = [[UILabel alloc] init];
        _countLabel.font = [UIFont systemFontOfSize:14];
        _countLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_countLabel];

        [_coverImageView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self.contentView).offset(16);
            make.centerY.equalTo(self.contentView);
            make.size.mas_equalTo(CGSizeMake(kPlaylistCoverSize, kPlaylistCoverSize));
        }];
        [_nameLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_coverImageView.mas_right).offset(12);
            make.right.lessThanOrEqualTo(self.contentView).offset(-16);
            make.top.equalTo(self.contentView).offset(12);
        }];
        [_countLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(_nameLabel);
            make.top.equalTo(_nameLabel.mas_bottom).offset(2);
        }];
    }
    return self;
}

@end

@interface NLAddToPlaylistSheetViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NLPlayList *> *playlists;
@property (nonatomic, strong) MASConstraint *containerBottomConstraint;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *songCountsByPlaylistID;
@property (nonatomic, assign) NSUInteger playlistLoadToken;
@end

@implementation NLAddToPlaylistSheetViewController

- (instancetype)init {
    if (self = [super init]) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _dimmingView = [[UIView alloc] init];
    _dimmingView.backgroundColor = [[UIColor colorWithWhite:0.25 alpha:1.0] colorWithAlphaComponent:0.45];
    _dimmingView.alpha = 0;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    [_dimmingView addGestureRecognizer:tap];
    [self.view addSubview:_dimmingView];

    _containerView = [[UIView alloc] init];
    _containerView.backgroundColor = [UIColor systemBackgroundColor];
    _containerView.layer.cornerRadius = 16;
    _containerView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _containerView.clipsToBounds = YES;
    [self.view addSubview:_containerView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"收藏到歌单";
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textColor = [UIColor labelColor];
    [_containerView addSubview:_titleLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundColor = [UIColor systemBackgroundColor];
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16 + kPlaylistCoverSize + 12, 0, 0);
    _tableView.tableFooterView = [UIView new];
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kNewPlaylistCellId];
    [_tableView registerClass:[NLAddToPlaylistSheetPlaylistCell class] forCellReuseIdentifier:kPlaylistCellId];
    [_containerView addSubview:_tableView];

    [_dimmingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];

    CGFloat sheetHeight = self.view.bounds.size.height * 0.5;
    [_containerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.view);
        make.height.mas_equalTo(sheetHeight);
        _containerBottomConstraint = make.bottom.equalTo(self.view.mas_bottom).offset(sheetHeight);
    }];
    [_titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_containerView).offset(20);
        make.left.equalTo(_containerView).offset(20);
    }];
    [_tableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_titleLabel.mas_bottom).offset(12);
        make.left.right.bottom.equalTo(_containerView);
    }];

    [self loadPlaylists];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view layoutIfNeeded];
    [_containerBottomConstraint setOffset:0];
    [UIView animateWithDuration:0.25 animations:^{
        self.dimmingView.alpha = 1;
        [self.view layoutIfNeeded];
    }];
}

- (void)loadPlaylists {
    NSUInteger token = ++self.playlistLoadToken;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLPlayList *> *playlists = [NLPlayListRepository allUserCreatedPlayLists];
        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionaryWithCapacity:playlists.count];
        for (NLPlayList *playlist in playlists) {
            counts[playlist.playlistId] = @([NLPlayListRepository songsInPlayList:playlist.playlistId].count);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.playlistLoadToken) return;
            self.playlists = playlists;
            self.songCountsByPlaylistID = counts;
            [self.tableView reloadData];
        });
    });
}

- (void)dismissSelf {
    CGFloat h = self.containerView.bounds.size.height;
    [_containerBottomConstraint setOffset:h];
    [UIView animateWithDuration:0.2 animations:^{
        self.dimmingView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1 + (NSInteger)self.playlists.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kNewPlaylistCellId forIndexPath:indexPath];
        cell.backgroundColor = [UIColor systemBackgroundColor];
        cell.textLabel.text = @"新建歌单";
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.textLabel.textColor = [UIColor labelColor];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *plusImg = [UIImage systemImageNamed:@"plus" withConfiguration:config];
        cell.imageView.image = [plusImg imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.imageView.tintColor = [UIColor tertiaryLabelColor];
        cell.imageView.backgroundColor = [UIColor tertiarySystemFillColor];
        cell.imageView.layer.cornerRadius = 4;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.contentMode = UIViewContentModeCenter;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NLAddToPlaylistSheetPlaylistCell *cell = [tableView dequeueReusableCellWithIdentifier:kPlaylistCellId forIndexPath:indexPath];
    cell.backgroundColor = [UIColor systemBackgroundColor];
    NLPlayList *pl = self.playlists[indexPath.row - 1];
    cell.nameLabel.text = pl.name.length ? pl.name : @"歌单";
    NSInteger count = self.songCountsByPlaylistID[pl.playlistId].integerValue;
    cell.countLabel.text = count == 0 ? @"0首" : [NSString stringWithFormat:@"%ld首", (long)count];
    if (pl.coverURL.length > 0) {
        [cell.coverImageView sd_setImageWithURL:[NSURL URLWithString:pl.coverURL] placeholderImage:nil];
    } else {
        cell.coverImageView.image = nil;
        cell.coverImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.currentSong || !self.currentSong.songId.length) return;

    if (indexPath.row == 0) {
        NLCreatePlayListSheetViewController *vc = [[NLCreatePlayListSheetViewController alloc] init];
        vc.titleText = @"新建歌单";
        vc.placeholder = @"输入歌单名称";
        vc.confirmButtonTitle = @"创建并添加";
        __weak typeof(self) weakSelf = self;
        vc.completion = ^(NSString *name) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [NLPlayListRepository createUserPlayListWithName:name completion:^(NLPlayList * _Nullable playlist) {
                if (!playlist) {
                    [self showToast:@"创建失败，请重试"];
                    return;
                }
                [NLPlayListRepository addSong:self.currentSong toPlayList:playlist.playlistId completion:^(BOOL success) {
                    [self loadPlaylists];
                    [self showToast:success ? @"收藏成功" : @"添加失败，请重试"];
                }];
            }];
        };
        [self presentViewController:vc animated:YES completion:nil];
        return;
    }

    if (indexPath.row - 1 >= self.playlists.count) return;
    NLPlayList *playlist = self.playlists[indexPath.row - 1];
    [NLPlayListRepository addSong:self.currentSong toPlayList:playlist.playlistId completion:^(BOOL success) {
        if (!success) {
            [self showToast:@"添加失败，请重试"];
            return;
        }
        [self showToast:@"收藏成功"];
        [self dismissSelf];
    }];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 60;
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

@end
