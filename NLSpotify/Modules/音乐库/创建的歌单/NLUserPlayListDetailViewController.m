//
//  NLUserPlayListDetailViewController.m
//  NLSpotify
//

#import "NLUserPlayListDetailViewController.h"
#import "NLPlayList.h"
#import "NLPlayListRepository.h"
#import "NLSong.h"
#import "NLSongListCell.h"
#import "NLPlayerManager.h"
#import "NLLikedSongsPickerViewController.h"
#import <Masonry/Masonry.h>

static NSString * const kUserPlayListSongCellId = @"UserPlayListSongCell";

@interface NLUserPlayListDetailViewController () <UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate>
@property (nonatomic, strong) NLPlayList *playlist;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, copy) NSArray<NLSong *> *songs;
@property (nonatomic, assign) NSUInteger dataLoadToken;
@end

@implementation NLUserPlayListDetailViewController

- (instancetype)initWithPlayList:(NLPlayList *)playlist {
    if (self = [super init]) {
        _playlist = playlist;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.title = self.playlist.name ?: @"歌单";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(backTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addLikedSongsTapped)];

    self.navigationController.interactivePopGestureRecognizer.delegate = self;
    self.navigationController.interactivePopGestureRecognizer.enabled = YES;

    [self.view addSubview:self.tableView];
    [self.view addSubview:self.emptyStateView];

    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
    [self.emptyStateView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.view);
        make.left.greaterThanOrEqualTo(self.view.mas_left).offset(24);
        make.right.lessThanOrEqualTo(self.view.mas_right).offset(-24);
    }];

    [self loadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadData];
}

- (void)backTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)addLikedSongsTapped {
    // 打开「从我喜欢的歌曲选择」页面，勾选要加入当前歌单的歌曲
    NLLikedSongsPickerViewController *vc = [[NLLikedSongsPickerViewController alloc] initWithPlayList:self.playlist];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)loadData {
    NSUInteger token = ++self.dataLoadToken;
    NSString *playlistID = [self.playlist.playlistId copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLSong *> *songs = playlistID.length ? [NLPlayListRepository songsInPlayList:playlistID] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.dataLoadToken) return;
            self.songs = songs;
            [self.tableView reloadData];
            self.emptyStateView.hidden = self.songs.count > 0;
        });
    });
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.songs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSongListCell *cell = [tableView dequeueReusableCellWithIdentifier:kUserPlayListSongCellId forIndexPath:indexPath];
    [cell configWithNLSong:self.songs[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NLSong *song = self.songs[indexPath.row];
    if (!song.songId.length) return;
    NSMutableArray<NLSong *> *list = [self.songs mutableCopy];
    NSInteger startIndex = indexPath.row;
    [[NLPlayerManager sharedManager] playWithPlaylist:list startIndex:startIndex];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 72;
}

#pragma mark - Getters

- (UITableView *)tableView {
    if (!_tableView) {
        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.delegate = self;
        _tableView.dataSource = self;
        _tableView.backgroundColor = [UIColor systemBackgroundColor];
        _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        _tableView.separatorInset = UIEdgeInsetsMake(0, 76, 0, 0);
        _tableView.tableFooterView = [UIView new];
        [_tableView registerClass:[NLSongListCell class] forCellReuseIdentifier:kUserPlayListSongCellId];
    }
    return _tableView;
}

- (UIView *)emptyStateView {
    if (!_emptyStateView) {
        _emptyStateView = [[UIView alloc] init];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightLight];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"music.note.list" withConfiguration:config]];
        iconView.tintColor = [UIColor tertiaryLabelColor];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [_emptyStateView addSubview:iconView];

        UILabel *label = [[UILabel alloc] init];
        label.text = @"这个歌单里还没有歌曲。可以在播放器中点加号添加歌曲。";
        label.font = [UIFont systemFontOfSize:16];
        label.textColor = [UIColor tertiaryLabelColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [_emptyStateView addSubview:label];

        [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.centerX.equalTo(_emptyStateView);
            make.size.mas_equalTo(CGSizeMake(80, 80));
        }];
        [label mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.equalTo(iconView.mas_bottom).offset(16);
            make.left.right.bottom.equalTo(_emptyStateView);
        }];
    }
    return _emptyStateView;
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.navigationController.interactivePopGestureRecognizer) {
        if (self.navigationController.viewControllers.count <= 1) {
            return NO;
        }
    }
    return YES;
}

@end

