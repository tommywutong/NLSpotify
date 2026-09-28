//
//  NLMusicLibraryListViewController.m
//  NLSpotify
//

#import "NLMusicLibraryListViewController.h"
#import "NLSongRepository.h"
#import "NLPlayListRepository.h"
#import "NLAlbumRepository.h"
#import "NLDownloadRepository.h"
#import "NLDownloadManager.h"
#import "NLSong.h"
#import "NLPlayList.h"
#import "NLAlbum.h"
#import "NLDownloadItem.h"
#import "NLSongListCell.h"
#import "NLSongListViewController.h"
#import "NLCreatePlayListSheetViewController.h"
#import "NLPlayerManager.h"
#import "NLSongService.h"
#import "NLCacheManager.h"
#import <Masonry/Masonry.h>

static NSString * const kCellId = @"MusicLibraryCell";

@interface NLMusicLibraryListViewController () <UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate>
@property (nonatomic, assign) NLMusicLibraryListMode mode;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, copy) NSArray<NLSong *> *songs;
@property (nonatomic, copy) NSArray<NLPlayList *> *playlists;
@property (nonatomic, copy) NSArray<NLAlbum *> *albums;
@property (nonatomic, copy) NSArray<NLDownloadItem *> *downloadItems;
@property (nonatomic, strong) NLCacheManager *cacheManager;
@property (nonatomic, assign) NSUInteger cachedReloadToken;
- (NSArray<NLSong *> *)cachedSongsSnapshot;
- (void)applyCachedSongs:(NSArray<NLSong *> *)songs forToken:(NSUInteger)token;
@end

@implementation NLMusicLibraryListViewController

- (instancetype)initWithMode:(NLMusicLibraryListMode)mode {
    if (self = [super init]) {
        _mode = mode;
        _cacheManager = [NLCacheManager sharedManager];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.title = [self titleForMode:self.mode];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(backTapped)];

    if (self.mode == NLMusicLibraryListModeMyPlaylists) {
        UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                  target:self
                                                                                  action:@selector(addTapped)];
        self.navigationItem.rightBarButtonItem = addItem;
    }

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

    if (self.mode == NLMusicLibraryListModeCachedSongs) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cacheDidFinish:) name:NLCacheManagerDidFinishCachingNotification object:nil];
    }
    if (self.mode == NLMusicLibraryListModeDownloadedSongs) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadDidUpdate:) name:NLDownloadManagerDidUpdateNotification object:nil];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.mode == NLMusicLibraryListModeCachedSongs) {
        self.cachedReloadToken += 1;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NLCacheManagerDidFinishCachingNotification object:nil];
    }
    if (self.mode == NLMusicLibraryListModeDownloadedSongs) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NLDownloadManagerDidUpdateNotification object:nil];
    }
}

- (void)cacheDidFinish:(NSNotification *)note {
    if (self.mode != NLMusicLibraryListModeCachedSongs) return;
    [self loadData];
}

- (void)downloadDidUpdate:(NSNotification *)note {
    if (self.mode != NLMusicLibraryListModeDownloadedSongs) return;
    [self loadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadData];
}

- (void)backTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)addTapped {
    NLCreatePlayListSheetViewController *vc = [[NLCreatePlayListSheetViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    vc.completion = ^(NSString *name) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NLPlayList *playList = [NLPlayListRepository createUserPlayListWithName:name];
        if (playList) {
            [self loadData];
        }
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (NSString *)titleForMode:(NLMusicLibraryListMode)mode {
    switch (mode) {
        case NLMusicLibraryListModeRecentPlay:       return @"播放历史";
        case NLMusicLibraryListModeLikedPlaylists:   return @"收藏的歌单";
        case NLMusicLibraryListModeMyPlaylists:       return @"创建的歌单";
        case NLMusicLibraryListModeCachedSongs:       return @"缓存";
        case NLMusicLibraryListModeDownloadedSongs:   return @"我下载的音乐";
        case NLMusicLibraryListModeLikedAlbums:       return @"我收藏的专辑";
        case NLMusicLibraryListModeLikedSongs:        return @"我喜欢的歌曲";
    }
}

- (void)loadData {
    switch (self.mode) {
        case NLMusicLibraryListModeRecentPlay: {
            NSArray<NLSong *> *history = [NLSongRepository allPlayHistory];
            self.songs = [[[history reverseObjectEnumerator] allObjects] copy];
            self.playlists = nil;
            self.albums = nil;
            self.downloadItems = nil;
            break;
        }
        case NLMusicLibraryListModeLikedSongs: {
            self.songs = [NLSongRepository allLikedSongs];
            self.playlists = nil;
            self.albums = nil;
            self.downloadItems = nil;
            break;
        }
        case NLMusicLibraryListModeLikedPlaylists: {
            self.songs = nil;
            self.playlists = [NLPlayListRepository allLikedPlayLists];
            self.albums = nil;
            self.downloadItems = nil;
            break;
        }
        case NLMusicLibraryListModeMyPlaylists: {
            self.songs = nil;
            self.playlists = [NLPlayListRepository allUserCreatedPlayLists];
            self.albums = nil;
            self.downloadItems = nil;
            break;
        }
        case NLMusicLibraryListModeCachedSongs: {
            NSUInteger token = ++self.cachedReloadToken;
            __weak typeof(self) weakSelf = self;
            [self.cacheManager whenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) perform:^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                [strongSelf loadCachedSongsForToken:token];
            }];
            return;
        }
        case NLMusicLibraryListModeDownloadedSongs: {
            self.songs = nil;
            self.playlists = nil;
            self.albums = nil;
            self.downloadItems = [NLDownloadRepository allDownloadItems];
            break;
        }
        case NLMusicLibraryListModeLikedAlbums: {
            self.songs = nil;
            self.playlists = nil;
            self.albums = [NLAlbumRepository allLikedAlbums];
            self.downloadItems = nil;
            break;
        }
    }
    [self.tableView reloadData];
    BOOL hasItems = [self rowCount] > 0;
    self.emptyStateView.hidden = hasItems;
}

- (void)loadCachedSongsForToken:(NSUInteger)token {
    NSArray<NLSong *> *cachedSongs = [self cachedSongsSnapshot];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf applyCachedSongs:cachedSongs forToken:token];
    });
}

- (NSArray<NLSong *> *)cachedSongsSnapshot {
    NSArray<NLSong *> *history = [NLSongRepository allPlayHistory];
    NSArray<NLSong *> *liked = [NLSongRepository allLikedSongs];
    NSMutableDictionary<NSString *, NLSong *> *bySongId = [NSMutableDictionary dictionary];
    for (NLSong *song in history) { if (song.songId.length) bySongId[song.songId] = song; }
    for (NLSong *song in liked) { if (song.songId.length) bySongId[song.songId] = song; }

    NLCacheManager *cacheManager = self.cacheManager;
    NSMutableArray<NLSong *> *cachedSongs = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *lastAccessBySongId = [NSMutableDictionary dictionary];
    for (NLSong *song in bySongId.allValues) {
        NSString *cacheKey = [cacheManager cacheIdentityForURL:song.playURL cacheKey:song.songId];
        if (![cacheManager isFullyCachedForURL:song.playURL cacheKey:cacheKey]) continue;
        [cachedSongs addObject:song];
        lastAccessBySongId[song.songId] = @([cacheManager lastAccessTimeForFullyCachedURL:song.playURL cacheKey:cacheKey]);
    }
    [cachedSongs sortUsingComparator:^NSComparisonResult(NLSong *left, NLSong *right) {
        NSTimeInterval leftTime = lastAccessBySongId[left.songId].doubleValue;
        NSTimeInterval rightTime = lastAccessBySongId[right.songId].doubleValue;
        if (leftTime > rightTime) return NSOrderedAscending;
        if (leftTime < rightTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return [cachedSongs copy];
}

- (void)applyCachedSongs:(NSArray<NLSong *> *)songs forToken:(NSUInteger)token {
    if (token != self.cachedReloadToken || self.mode != NLMusicLibraryListModeCachedSongs || !self.viewIfLoaded.window) return;
    self.songs = songs;
    self.playlists = nil;
    self.albums = nil;
    self.downloadItems = nil;
    [self.tableView reloadData];
    self.emptyStateView.hidden = self.songs.count > 0;
}

- (BOOL)isSongMode {
    return self.mode == NLMusicLibraryListModeRecentPlay || self.mode == NLMusicLibraryListModeLikedSongs || self.mode == NLMusicLibraryListModeCachedSongs;
}

- (BOOL)isDownloadMode {
    return self.mode == NLMusicLibraryListModeDownloadedSongs;
}

- (BOOL)isAlbumMode {
    return self.mode == NLMusicLibraryListModeLikedAlbums;
}

- (NSInteger)rowCount {
    if ([self isSongMode]) return (NSInteger)self.songs.count;
    if ([self isDownloadMode]) return (NSInteger)self.downloadItems.count;
    if ([self isAlbumMode]) return (NSInteger)self.albums.count;
    return (NSInteger)self.playlists.count;
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rowCount];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSongListCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId forIndexPath:indexPath];
    if ([self isSongMode]) {
        [cell configWithNLSong:self.songs[indexPath.row]];
    } else if ([self isDownloadMode]) {
        NLDownloadItem *item = self.downloadItems[indexPath.row];
        [cell configWithDownloadItem:item downloadProgress:-1.f];
    } else if ([self isAlbumMode]) {
        [cell configWithAlbum:self.albums[indexPath.row]];
    } else {
        [cell configWithPlayList:self.playlists[indexPath.row]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isDownloadMode]) {
        NLDownloadItem *selectedItem = self.downloadItems[indexPath.row];
        if (![selectedItem.status isEqualToString:@"completed"]) return;
        NSString *selectedSongID = [selectedItem.songId copy];
        __weak typeof(self) weakSelf = self;
        [[NLCacheManager sharedManager] whenReadyOnQueue:dispatch_get_main_queue() perform:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded || strongSelf.mode != NLMusicLibraryListModeDownloadedSongs) return;
            NLDownloadItem *currentItem = nil;
            for (NLDownloadItem *item in strongSelf.downloadItems) {
                if ([item.songId isEqualToString:selectedSongID] && [item.status isEqualToString:@"completed"]) {
                    currentItem = item;
                    break;
                }
            }
            if (!currentItem) return;
            NSArray<NLSong *> *allDownloaded = [NLSongRepository allDownloadedSongs];
            NSMutableDictionary<NSString *, NLSong *> *byId = [NSMutableDictionary dictionary];
            for (NLSong *song in allDownloaded) { if (song.songId.length) byId[song.songId] = song; }
            NSMutableArray<NLSong *> *list = [NSMutableArray array];
            for (NLDownloadItem *item in strongSelf.downloadItems) {
                if (![item.status isEqualToString:@"completed"]) continue;
                NLSong *song = byId[item.songId];
                NSString *cacheKey = [NLCacheManager.sharedManager cacheIdentityForURL:song.playURL cacheKey:song.songId];
                if (song && [NLCacheManager.sharedManager isFullyCachedForURL:song.playURL cacheKey:cacheKey]) [list addObject:song];
            }
            NLSong *song = byId[selectedSongID];
            NSInteger index = [list indexOfObject:song];
            if (index != NSNotFound) [[NLPlayerManager sharedManager] playWithPlaylist:[list copy] startIndex:index];
        }];
        return;
    }
    if ([self isSongMode]) {
        NLSong *song = self.songs[indexPath.row];
        if (!song.songId.length) return;
        NSMutableArray<NLSong *> *list = [self.songs mutableCopy];
        NSInteger startIndex = indexPath.row;
        [[NLPlayerManager sharedManager] playWithPlaylist:list startIndex:startIndex];
        return;
    }
    if ([self isAlbumMode]) {
        NLAlbum *album = self.albums[indexPath.row];
        if (!album.albumId.length) return;
        NSInteger albumId = [album.albumId integerValue];
        if (albumId <= 0) return;
        NLSongListViewController *vc = [[NLSongListViewController alloc] initWithId:albumId
                                                                               type:NLSongListTypeAlbum
                                                                               name:album.name ?: @""];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    NLPlayList *list = self.playlists[indexPath.row];
    if (!list.playlistId.length) return;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    BOOL isNumeric = ([list.playlistId rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
    NLSongListViewController *vc;
    if (isNumeric && [list.playlistId integerValue] > 0) {
        vc = [[NLSongListViewController alloc] initWithId:[list.playlistId integerValue]
                                                    type:NLSongListTypePlaylist
                                                    name:list.name ?: @""];
    } else {
        vc = [[NLSongListViewController alloc] initWithLocalPlayList:list];
    }
    [self.navigationController pushViewController:vc animated:YES];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 72;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if ([self isSongMode]) {
        NLSong *song = self.songs[indexPath.row];
        if (self.mode == NLMusicLibraryListModeRecentPlay) {
            [NLSongRepository removePlayHistoryWithSongId:song.songId];
        } else if (self.mode == NLMusicLibraryListModeLikedSongs) {
            [NLSongRepository likeSong:song isLike:NO];
        }
        // NLMusicLibraryListModeCachedSongs：仅从列表移除，不删历史/收藏
        NSMutableArray *mutable = [self.songs mutableCopy];
        [mutable removeObjectAtIndex:indexPath.row];
        self.songs = [mutable copy];
    } else if ([self isDownloadMode]) {
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除已下载"
                                                                       message:@"确定删除该首已下载的音乐吗？"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || indexPath.row >= (NSInteger)strongSelf.downloadItems.count) return;
            NLDownloadItem *item = strongSelf.downloadItems[indexPath.row];
            [NLDownloadRepository removeDownloadItemWithSongId:item.songId];
            [NLSongRepository removeDownloadedSong:item.songId];
            NSMutableArray *mutable = [strongSelf.downloadItems mutableCopy];
            [mutable removeObjectAtIndex:indexPath.row];
            strongSelf.downloadItems = [mutable copy];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            strongSelf.emptyStateView.hidden = [strongSelf rowCount] > 0;
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    } else if ([self isAlbumMode]) {
        NLAlbum *album = self.albums[indexPath.row];
        [NLAlbumRepository setAlbum:album liked:NO];
        NSMutableArray *mutable = [self.albums mutableCopy];
        [mutable removeObjectAtIndex:indexPath.row];
        self.albums = [mutable copy];
    } else {
        NLPlayList *list = self.playlists[indexPath.row];
        if (self.mode == NLMusicLibraryListModeLikedPlaylists) {
            [NLPlayListRepository setPlayList:list liked:NO];
        } else {
            [NLPlayListRepository deletePlayList:list.playlistId];
        }
        NSMutableArray *mutable = [self.playlists mutableCopy];
        [mutable removeObjectAtIndex:indexPath.row];
        self.playlists = [mutable copy];
    }
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"删除";
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
        [_tableView registerClass:[NLSongListCell class] forCellReuseIdentifier:kCellId];
    }
    return _tableView;
}

- (UIView *)emptyStateView {
    if (!_emptyStateView) {
        _emptyStateView = [[UIView alloc] init];
        NSString *iconName = @"music.note.list";
        NSString *text = @"暂无内容";
        switch (self.mode) {
            case NLMusicLibraryListModeRecentPlay:
                iconName = @"clock.arrow.circlepath";
                text = @"最近播放的歌曲将在这里显示。";
                break;
            case NLMusicLibraryListModeLikedSongs:
                iconName = @"heart";
                text = @"收藏的歌曲将在这里显示。在播放器中点击星星即可收藏。";
                break;
            case NLMusicLibraryListModeLikedPlaylists:
                iconName = @"star.circle";
                text = @"收藏的歌单会显示在这里。在歌单页面点右上角星星即可收藏。";
                break;
            case NLMusicLibraryListModeMyPlaylists:
                iconName = @"folder.badge.plus";
                text = @"还没有自建歌单。点击右上角加号创建歌单。";
                break;
            case NLMusicLibraryListModeCachedSongs:
                iconName = @"arrow.down.circle";
                text = @"已完全缓存并转为 mp3 的歌曲会显示在这里。播放过的歌曲在缓存完成后会自动出现。";
                break;
            case NLMusicLibraryListModeDownloadedSongs:
                iconName = @"arrow.down.circle.fill";
                text = @"在播放器点击三点菜单选择「下载」后，已下载与下载中的歌曲会显示在这里。";
                break;
            case NLMusicLibraryListModeLikedAlbums:
                iconName = @"square.stack";
                text = @"收藏的专辑会显示在这里。在专辑详情页点右上角星星即可收藏。";
                break;
        }
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightLight];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName withConfiguration:config]];
        iconView.tintColor = [UIColor tertiaryLabelColor];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [_emptyStateView addSubview:iconView];

        UILabel *label = [[UILabel alloc] init];
        label.text = text;
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

@end
