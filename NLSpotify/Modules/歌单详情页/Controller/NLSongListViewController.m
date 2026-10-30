//
//  NLSongListViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/15.
//

#import "NLSongListViewController.h"
#import "NLListCellModel.h"
#import "NLSongListCell.h"
#import "NLSongListHeaderView.h"
#import "NLAlbumService.h"
#import "NLSongListService.h"
#import "NLPlayerManager.h"
#import "NLMusicPlayerViewController.h"
#import "NLDownloadManager.h"
#import "NLSong.h"
#import "NLCommentListViewController.h"
#import "NLPlayListRepository.h"

#import "NLPlayList.h"
#import "NLAlbumRepository.h"
#import "NLAlbum.h"
#import <Masonry/Masonry.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import "NLLikedSongsPickerViewController.h"

@interface NLSongListViewController () <UITableViewDelegate, UITableViewDataSource, NLSongListHeaderViewDelegate>

@property (nonatomic, assign) NSInteger listId;
@property (nonatomic, assign) NLSongListType type;
@property (nonatomic, assign) BOOL isLocalPlayList;
@property (nonatomic, strong) NLPlayList *localPlayList;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NLListCellModel *> *songs;
@property (nonatomic, strong) NLSongListHeaderView *headerView;
@property (nonatomic, strong) NLHeaderModel *header;

@property (nonatomic, strong) UIBarButtonItem *favoriteItem;
@property (nonatomic, assign) BOOL isLikedPlayList;
@property (nonatomic, assign) BOOL isLikedAlbum;
@property (nonatomic, assign) NSUInteger localPlaylistLoadToken;
@property (nonatomic, assign) NSUInteger favoriteStateRequestToken;
@property (nonatomic, assign) BOOL favoriteWriteInProgress;

@end

@implementation NLSongListViewController

- (instancetype)initWithId:(NSInteger)listId type:(NLSongListType)type name:(NSString *)name {
    self = [super init];
    if (self) {
        _listId = listId;
        _type = type;
        self.title = name;
        self.songs = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithLocalPlayList:(NLPlayList *)playlist {
    self = [super init];
    if (self) {
        _isLocalPlayList = YES;
        _localPlayList = playlist;
        _listId = 0;
        _type = NLSongListTypePlaylist;
        self.title = playlist.name;
        self.songs = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupNavigationBar];
    [self.view addSubview:self.tableView];

    [self setupConstraints];
    [self setupNavigation];
    if (self.isLocalPlayList) {
        [self loadLocalPlayListData];
    } else {
        [self requestData];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从「从我喜欢的歌曲添加」返回时，重新加载本地歌单内容
    if (self.isLocalPlayList) {
        [self loadLocalPlayListData];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 底部留一半空间，避免被 tabBar 完全挡住
    CGFloat tabBarHeight = self.tabBarController.tabBar.frame.size.height;
    if (tabBarHeight == 0) {
        tabBarHeight = 49.0 + (self.view.safeAreaInsets.bottom > 0 ? self.view.safeAreaInsets.bottom : 0);
    }
    CGFloat bottomInset = (CGFloat)((NSInteger)(tabBarHeight * 0.5));
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, bottomInset, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;
}

- (void)setupNavigationBar {
    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.translucent = YES;
    bar.barTintColor = nil;
    bar.backgroundColor = [UIColor clearColor];
    [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = [UIImage new];
    bar.tintColor = [UIColor labelColor];
    bar.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor labelColor] };
}

- (void)setupNavigation {
    if (self.isLocalPlayList) {
        // 本地歌单：右上角显示「从我喜欢的歌曲添加」的加号
        UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                  target:self
                                                                                  action:@selector(addFromLikedTapped)];
        self.navigationItem.rightBarButtonItems = @[addItem];
    } else {
        UIBarButtonItem *commentItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"text.bubble"] style:UIBarButtonItemStylePlain target:self action:@selector(openCommentTapped)];
        UIBarButtonItem *batchDownloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(batchDownloadTapped)];
        batchDownloadItem.accessibilityLabel = @"批量下载";
        self.favoriteItem = [[UIBarButtonItem alloc] initWithImage:nil style:UIBarButtonItemStylePlain target:self action:@selector(favoriteTapped)];
        self.navigationItem.rightBarButtonItems = @[ commentItem, batchDownloadItem, self.favoriteItem ];
        [self refreshFavoriteButtonUI];
    }
}

//- (void)addTapped { NSLog(@"This 'Plus' Button is scrapped"); }

- (NSString *)currentPlayListIdString {
    if (self.type != NLSongListTypePlaylist) return nil;
    return [NSString stringWithFormat:@"%ld", (long)self.listId];
}

- (void)refreshFavoriteButtonUI {
    if (!self.favoriteItem) return;
    BOOL liked = (self.type == NLSongListTypePlaylist) ? self.isLikedPlayList : self.isLikedAlbum;
    NSString *iconName = liked ? @"star.fill" : @"star";
    UIImage *img = [UIImage systemImageNamed:iconName];
    self.favoriteItem.image = img;
}

- (void)refreshFavoriteStateForHeader:(NLHeaderModel *)header {
    NSUInteger token = ++self.favoriteStateRequestToken;
    NLSongListType type = self.type;
    NSString *identifier = type == NLSongListTypePlaylist
        ? [NSString stringWithFormat:@"%ld", (long)header.playlistId]
        : [NSString stringWithFormat:@"%ld", (long)self.listId];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL liked = type == NLSongListTypePlaylist
            ? [NLPlayListRepository isPlayListLiked:identifier]
            : [NLAlbumRepository isAlbumLiked:identifier];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.favoriteStateRequestToken || self.header != header) return;
            if (type == NLSongListTypePlaylist) self.isLikedPlayList = liked;
            else self.isLikedAlbum = liked;
            [self refreshFavoriteButtonUI];
        });
    });
}

- (void)favoriteTapped {
    if (self.favoriteWriteInProgress) return;
    if (self.type == NLSongListTypePlaylist) {
        NSString *playlistId = [self currentPlayListIdString];
        if (playlistId.length == 0) return;
        NLPlayList *playList = [[NLPlayList alloc] initWithId:playlistId
                                                         name:self.header.name.length ? self.header.name : (self.title ?: @"歌单")
                                                  isUserCreated:NO];
        playList.coverURL = self.header.coverUrl ?: @"";
        playList.createTime = [[NSDate date] timeIntervalSince1970];
        BOOL newLiked = !self.isLikedPlayList;
        self.favoriteWriteInProgress = YES;
        NSUInteger token = ++self.favoriteStateRequestToken;
        [NLPlayListRepository setPlayList:playList liked:newLiked completion:^(BOOL success) {
            self.favoriteWriteInProgress = NO;
            if (token != self.favoriteStateRequestToken) return;
            if (success) {
                self.isLikedPlayList = newLiked;
                [self refreshFavoriteButtonUI];
            } else {
                [self showToast:@"收藏失败，请重试"];
            }
        }];
        return;
    }
    if (self.type == NLSongListTypeAlbum) {
        NSString *albumId = [NSString stringWithFormat:@"%ld", (long)self.listId];
        NLAlbum *album = [[NLAlbum alloc] initWithAlbumId:albumId
                                                    name:self.header.name.length ? self.header.name : (self.title ?: @"专辑")
                                                coverURL:self.header.coverUrl ?: @""
                                             artistName:self.header.creatorName ?: @""];
        BOOL newLiked = !self.isLikedAlbum;
        self.favoriteWriteInProgress = YES;
        NSUInteger token = ++self.favoriteStateRequestToken;
        [NLAlbumRepository setAlbum:album liked:newLiked completion:^(BOOL success) {
            self.favoriteWriteInProgress = NO;
            if (token != self.favoriteStateRequestToken) return;
            if (success) {
                self.isLikedAlbum = newLiked;
                [self refreshFavoriteButtonUI];
            } else {
                [self showToast:@"收藏失败，请重试"];
            }
        }];
    }
}

- (void)addFromLikedTapped {
    if (!self.isLocalPlayList || !self.localPlayList.playlistId.length) return;
    NLLikedSongsPickerViewController *vc = [[NLLikedSongsPickerViewController alloc] initWithPlayList:self.localPlayList];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 评论区

- (void)openCommentTapped {
    NLCommentListResourceType type = (self.type == NLSongListTypePlaylist) 
        ? NLCommentListResourceTypePlaylist 
        : NLCommentListResourceTypeAlbum;
    
    NLCommentListViewController *vc = [[NLCommentListViewController alloc] 
        initWithResourceId:self.listId 
              resourceType:type 
                     title:[NSString stringWithFormat:@"%@ 评论", self.title ?: @"评论"]];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 批量下载

- (void)batchDownloadTapped {
    if (self.songs.count == 0) {
        [self showToast:@"当前没有歌曲"];
        return;
    }
    NSInteger count = self.songs.count;
    NSString *message = [NSString stringWithFormat:@"将本%@全部 %ld 首加入下载队列？已下载或已在队列中的会跳过。", self.type == NLSongListTypePlaylist ? @"歌单" : @"专辑", (long)count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"批量下载" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"下载全部" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf performBatchDownload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performBatchDownload {
    NSMutableArray<NLSong *> *songList = [self buildSongListShuffled:NO];
    if (songList.count == 0) {
        [self showToast:@"没有歌曲"];
        return;
    }
    NLDownloadManager *mgr = [NLDownloadManager sharedManager];
    for (NLSong *song in songList) {
        [mgr addDownloadForSong:song];
    }
    [self showToast:[NSString stringWithFormat:@"已将 %lu 首加入下载队列", (unsigned long)songList.count]];
}

// 窗口弹出方法
- (void)showToast:(NSString *)text {
    UIView *toast = [[UIView alloc] init];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    toast.layer.cornerRadius = 10;
    toast.alpha = 0;
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 0;
    [toast addSubview:label];
    [label mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(toast).insets(UIEdgeInsetsMake(12, 20, 12, 20));
    }];
    [self.view addSubview:toast];
    [toast mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.view);
    }];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

#pragma mark - Layout

- (void)setupConstraints {
    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
}

#pragma mark - 简介高度自适应，方案一。

- (void)setupTableHeader {
    if (!self.headerView) {
        self.headerView = [[NLSongListHeaderView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 0)];
        self.headerView.delegate = self;
    }
    [self.headerView configWithPlayList:self.header];
    [self updateHeaderViewHeight];
}

- (void)updateHeaderViewHeight {
    CGFloat w = self.tableView.bounds.size.width;
    CGFloat screenH = self.view.window.windowScene.screen.bounds.size.height;
    if (screenH <= 0) screenH = self.view.bounds.size.height;
    CGFloat maxH = screenH * 0.75f; // 收起时最大高度限制
    CGFloat largeHeight = 10000.0f; // 布局计算用足够大的高度，确保能正确测量所有内容
    
    // 设置足够大的 bounds，让 Auto Layout 能正确测量
    self.headerView.bounds = CGRectMake(0, 0, w, largeHeight);
    [self.headerView setNeedsLayout];// 强制布局
    [self.headerView layoutIfNeeded];
    
    // 测量实际需要的高度,使用 systemLayoutSizeFittingSize，iOS自适应高度标准方案
    CGSize fitSize = [self.headerView systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)];
    CGFloat headerHeight = fitSize.height > 0 ? fitSize.height : maxH;
    
    // 根据展开状态决定是否限制高度
    if (![self.headerView isDescExpanded]) {
        // 收起状态：限制在 3/4 屏高
        headerHeight = (CGFloat)fmin(headerHeight, maxH);
    }
    self.headerView.frame = CGRectMake(0, 0, w, headerHeight);
    self.tableView.tableHeaderView = nil;
    self.tableView.tableHeaderView = self.headerView;
    [self.tableView layoutIfNeeded];
}

- (void)requestData {
    __weak typeof(self) weakSelf = self;
    if (self.type == NLSongListTypeAlbum) {
        [NLAlbumService fetchAlbumDetailWithId:self.listId
                                   completion:^(NLHeaderModel *header,
           NSArray<NLListCellModel *> *songs) {
            [weakSelf handleResponse:header songs:songs];
        }];
    } else {
        [NLSongListService fetchPlayListDetailWithId:self.listId
                                      completion:^(NLHeaderModel *header,
           NSArray<NLListCellModel *> *songs) {
            [weakSelf handleResponse:header songs:songs];
        }];
    }
}

#pragma mark - Local PlayList

- (void)loadLocalPlayListData {
    NSString *playlistID = [self.localPlayList.playlistId copy];
    if (playlistID.length == 0) {
        [self.songs removeAllObjects];
        [self.tableView reloadData];
        return;
    }
    NSUInteger token = ++self.localPlaylistLoadToken;
    NLHeaderModel *header = [[NLHeaderModel alloc] init];
    header.playlistId = 0;
    header.name = self.localPlayList.name ?: @"歌单";
    header.coverUrl = self.localPlayList.coverURL ?: @"";
    header.desc = @"";
    header.hideDescription = YES;
    header.creatorName = @"";
    header.creatorAvatar = @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLSong *> *localSongs = [NLPlayListRepository songsInPlayList:playlistID];
        NSMutableArray<NLListCellModel *> *models = [NSMutableArray arrayWithCapacity:localSongs.count];
        for (NLSong *song in localSongs) {
            NLListCellModel *model = [[NLListCellModel alloc] init];
            model.songId = song.songId.integerValue;
            model.name = song.title ?: @"";
            model.artistName = song.artist ?: @"";
            model.albumName = @"";
            model.coverUrl = song.coverURL.absoluteString ?: @"";
            model.duration = 0;
            [models addObject:model];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.localPlaylistLoadToken || !self.isLocalPlayList) return;
            self.header = header;
            [self.songs removeAllObjects];
            [self.songs addObjectsFromArray:models];
            [self setupTableHeader];
            [self.tableView reloadData];
        });
    });
}

- (void)handleResponse:(NLHeaderModel *)header
                songs:(NSArray<NLListCellModel *> *)songs {
    self.header = header;
    if (self.type == NLSongListTypePlaylist || self.type == NLSongListTypeAlbum) {
        [self refreshFavoriteStateForHeader:header];
    }
    [self.songs removeAllObjects];
    [self.songs addObjectsFromArray:songs];
    [self setupTableHeader];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.songs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSongListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NLSongCell" forIndexPath:indexPath];
    [cell configWithSong:self.songs[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self playSongAtIndex:indexPath.row];
}

#pragma mark - Playback

// 将 self.songs 转为 NLSong 数组，可选是否打乱顺序
- (NSMutableArray<NLSong *> *)buildSongListShuffled:(BOOL)shuffle {
    NSMutableArray<NLSong *> *list = [NSMutableArray array];
    for (NLListCellModel *model in self.songs) {
        NLSong *song = [NLSong songWithListCellModel:model];
        if (song) [list addObject:song];
    }
    //  洗牌，用于随机播放
    if (shuffle && list.count > 1) {
        for (NSInteger i = list.count - 1; i >= 1; i--) {
            NSInteger j = arc4random_uniform((uint32_t)(i + 1));
            [list exchangeObjectAtIndex:i withObjectAtIndex:j];
        }
    }
    return list;
}

// 拉取指定位置的歌曲播放 URL，然后以该首为起点播放列表
- (void)playSongList:(NSMutableArray<NLSong *> *)songList startIndex:(NSInteger)index {
    NSLog(@"[PlayTrace] [SongList] -> playSongList:startIndex: songs=%lu index=%ld", (unsigned long)songList.count, (long)index);
    if (songList.count == 0 || index < 0 || index >= songList.count) return;
    
    NLSong *startSong = songList[index];
    if (!startSong.songId.length) return;

    [[NLPlayerManager sharedManager] playWithPlaylist:songList startIndex:index];
    NLMusicPlayerViewController *fullPlayer = [[NLMusicPlayerViewController alloc] init];
    fullPlayer.modalPresentationStyle = UIModalPresentationOverFullScreen;
    fullPlayer.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self presentViewController:fullPlayer animated:YES completion:nil];
}

- (void)playSongAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.songs.count) return;
    NSMutableArray<NLSong *> *songList = [self buildSongListShuffled:NO];
    if (songList.count == 0) return;
    [self playSongList:songList startIndex:index];
}

#pragma mark - NLSongListHeaderViewDelegate

- (void)headerViewDidTapPlayAll:(NLSongListHeaderView *)headerView {
    NSMutableArray<NLSong *> *songList = [self buildSongListShuffled:NO];
    if (songList.count == 0) return;
    [self playSongList:songList startIndex:0];
}

- (void)headerViewDidTapShuffle:(NLSongListHeaderView *)headerView {
    NSMutableArray<NLSong *> *songList = [self buildSongListShuffled:YES];
    if (songList.count == 0) return;
    [self playSongList:songList startIndex:0];
}


- (void)headerViewDidRequestRelayout:(NLSongListHeaderView *)headerView {
    [self updateHeaderViewHeight];
}

#pragma mark - Getters

- (UITableView *)tableView {
    if (!_tableView) {
        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.delegate = self;
        _tableView.dataSource = self;
        _tableView.rowHeight = 64;
        _tableView.backgroundColor = [UIColor systemBackgroundColor];
        _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        _tableView.separatorColor = [UIColor separatorColor];
        _tableView.separatorInset = UIEdgeInsetsMake(0, 72, 0, 0);
        _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;

        _tableView.contentInset = UIEdgeInsetsMake(0, 0, 42, 0); // 约为 tabBar 高度的一半，避免挡住内容
        _tableView.scrollIndicatorInsets = _tableView.contentInset;
        [_tableView registerClass:[NLSongListCell class] forCellReuseIdentifier:@"NLSongCell"];
    }
    return _tableView;
}

@end
