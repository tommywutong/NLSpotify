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
#import "NLOfflineAudioStore.h"
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
@property (nonatomic, assign) NSUInteger listReloadToken;
- (NSArray<NLSong *> *)cachedSongsSnapshot;
- (void)applyCachedSongs:(NSArray<NLSong *> *)songs forToken:(NSUInteger)token;
- (void)showRepositoryFailure:(NSString *)message;
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
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.listReloadToken += 1;
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
    NSDictionary *userInfo = note.userInfo;
    NSString *songID = [userInfo[@"songId"] isKindOfClass:NSString.class] ? userInfo[@"songId"] : nil;
    NSString *status = [userInfo[@"status"] isKindOfClass:NSString.class] ? userInfo[@"status"] : nil;
    if (songID.length == 0 || status.length == 0) {
        [self loadData];
        return;
    }
    NSUInteger row = [self.downloadItems indexOfObjectPassingTest:^BOOL(NLDownloadItem *item, NSUInteger idx, BOOL *stop) {
        return [item.songId isEqualToString:songID];
    }];
    if (row == NSNotFound) {
        [self loadData];
        return;
    }
    NLDownloadItem *item = self.downloadItems[row];
    item.status = status;
    item.receivedBytes = [userInfo[@"receivedBytes"] longLongValue];
    item.expectedBytes = [userInfo[@"expectedBytes"] longLongValue];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
    NLSongListCell *cell = (id)[self.tableView cellForRowAtIndexPath:indexPath];
    if (cell) {
        float progress = item.expectedBytes > 0 ? (float)item.receivedBytes / (float)item.expectedBytes : -1.f;
        [cell configWithDownloadItem:item downloadProgress:progress];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.mode == NLMusicLibraryListModeDownloadedSongs) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadDidUpdate:) name:NLDownloadManagerDidUpdateNotification object:nil];
    }
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
        [NLPlayListRepository createUserPlayListWithName:name completion:^(NLPlayList * _Nullable playlist) {
            if (!playlist) {
                [self showRepositoryFailure:@"歌单创建失败，请重试。"];
                return;
            }
            [self loadData];
        }];
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

- (void)applyListSnapshotForMode:(NLMusicLibraryListMode)mode
                             token:(NSUInteger)token
                             songs:(NSArray<NLSong *> *)songs
                         playlists:(NSArray<NLPlayList *> *)playlists
                             albums:(NSArray<NLAlbum *> *)albums
                      downloadItems:(NSArray<NLDownloadItem *> *)downloadItems {
    if (token != self.listReloadToken || mode != self.mode) return;
    self.songs = songs;
    self.playlists = playlists;
    self.albums = albums;
    self.downloadItems = downloadItems;
    [self.tableView reloadData];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (void)loadData {
    NLMusicLibraryListMode mode = self.mode;
    NSUInteger token = ++self.listReloadToken;
    if (mode == NLMusicLibraryListModeCachedSongs) {
        NSUInteger cachedToken = ++self.cachedReloadToken;
        __weak typeof(self) weakSelf = self;
        [self.cacheManager whenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) perform:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf loadCachedSongsForToken:cachedToken];
        }];
        return;
    }

    if (mode == NLMusicLibraryListModeRecentPlay) {
        __weak typeof(self) weakSelf = self;
        [NLSongRepository allPlayHistoryWithCompletion:^(NSArray<NLSong *> *songs) {
            __strong typeof(weakSelf) self = weakSelf;
            [self applyListSnapshotForMode:mode token:token songs:songs playlists:nil albums:nil downloadItems:nil];
        }];
        return;
    }

    if (mode == NLMusicLibraryListModeDownloadedSongs) {
        __weak typeof(self) weakSelf = self;
        [[NLDownloadManager sharedManager] loadDownloadItemsWithCompletion:^(NSArray<NLDownloadItem *> *items) {
            __strong typeof(weakSelf) self = weakSelf;
            [self applyListSnapshotForMode:mode token:token songs:nil playlists:nil albums:nil downloadItems:items];
        }];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLSong *> *songs = nil;
        NSArray<NLPlayList *> *playlists = nil;
        NSArray<NLAlbum *> *albums = nil;
        NSArray<NLDownloadItem *> *downloadItems = nil;
        switch (mode) {
            case NLMusicLibraryListModeRecentPlay:
                break;
            case NLMusicLibraryListModeLikedSongs:
                songs = [NLSongRepository allLikedSongs];
                break;
            case NLMusicLibraryListModeLikedPlaylists:
                playlists = [NLPlayListRepository allLikedPlayLists];
                break;
            case NLMusicLibraryListModeMyPlaylists:
                playlists = [NLPlayListRepository allUserCreatedPlayLists];
                break;
            case NLMusicLibraryListModeCachedSongs:
                break;
            case NLMusicLibraryListModeDownloadedSongs:
                downloadItems = [NLDownloadRepository allDownloadItems];
                break;
            case NLMusicLibraryListModeLikedAlbums:
                albums = [NLAlbumRepository allLikedAlbums];
                break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self applyListSnapshotForMode:mode token:token songs:songs playlists:playlists albums:albums downloadItems:downloadItems];
        });
    });
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
        float progress = item.expectedBytes > 0 ? (float)item.receivedBytes / (float)item.expectedBytes : -1.f;
        [cell configWithDownloadItem:item downloadProgress:progress];
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
        if (indexPath.row >= self.downloadItems.count) return;
        NSString *selectedSongID = [self.downloadItems[indexPath.row].songId copy];
        if (!selectedSongID.length) return;
        NSArray<NLDownloadItem *> *downloadItems = [self.downloadItems copy];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NLSong *> *allDownloaded = [NLSongRepository allDownloadedSongs];
            NSMutableDictionary<NSString *, NLSong *> *songsByID = [NSMutableDictionary dictionaryWithCapacity:allDownloaded.count];
            for (NLSong *song in allDownloaded) {
                if (song.songId.length) songsByID[song.songId] = song;
            }
            NSMutableArray<NLSong *> *playlist = [NSMutableArray array];
            for (NLDownloadItem *item in downloadItems) {
                NLSong *song = songsByID[item.songId];
                BOOL isCompleted = [item.status isEqualToString:@"completed"];
                BOOL hasOfflineFile = isCompleted && [[NLOfflineAudioStore sharedStore] localFileURLForSongID:item.songId] != nil;
                if (song && hasOfflineFile) [playlist addObject:song];
            }
            NLSong *selectedSong = songsByID[selectedSongID];
            NSUInteger songIndex = [playlist indexOfObject:selectedSong];
            if (songIndex == NSNotFound) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self.mode != NLMusicLibraryListModeDownloadedSongs) return;
                BOOL stillQueued = [self.downloadItems indexOfObjectPassingTest:^BOOL(NLDownloadItem *item, NSUInteger idx, BOOL *stop) {
                    return [item.songId isEqualToString:selectedSongID] && [item.status isEqualToString:@"completed"];
                }] != NSNotFound;
                if (stillQueued) {
                    [[NLPlayerManager sharedManager] playWithPlaylist:playlist startIndex:(NSInteger)songIndex];
                }
            });
        });
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
        NLSongListViewController *vc = [[NLSongListViewController alloc] initWithId:albumId type:NLSongListTypeAlbum name:album.name ?: @""];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    NLPlayList *list = self.playlists[indexPath.row];
    if (!list.playlistId.length) return;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    BOOL isNumeric = ([list.playlistId rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
    NLSongListViewController *vc;
    if (isNumeric && [list.playlistId integerValue] > 0) {
        vc = [[NLSongListViewController alloc] initWithId:[list.playlistId integerValue] type:NLSongListTypePlaylist name:list.name ?: @""];
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

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isDownloadMode] || indexPath.row >= self.downloadItems.count) return nil;
    NLDownloadItem *item = self.downloadItems[indexPath.row];
    NSString *songID = [item.songId copy];
    if (songID.length == 0) return nil;

    __weak typeof(self) weakSelf = self;
    NLDownloadManager *manager = [NLDownloadManager sharedManager];
    UIContextualAction *(^makeCommandAction)(NSString *, void (^)(void (^)(BOOL))) = ^UIContextualAction *(NSString *title, void (^command)(void (^)(BOOL))) {
        return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:title handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            command(^(BOOL success) {
                __strong typeof(weakSelf) self = weakSelf;
                if (self && !success) [self showRepositoryFailure:@"下载操作未能完成，请重试。"];
                completionHandler(success);
            });
        }];
    };

    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];
    if ([item.status isEqualToString:@"downloading"]) {
        [actions addObject:makeCommandAction(@"暂停", ^(void (^done)(BOOL)) { [manager pauseDownloadForSongID:songID completion:done]; })];
        [actions addObject:makeCommandAction(@"取消", ^(void (^done)(BOOL)) { [manager cancelDownloadForSongID:songID completion:done]; })];
    } else if ([item.status isEqualToString:@"paused"]) {
        [actions addObject:makeCommandAction(@"继续", ^(void (^done)(BOOL)) { [manager resumeDownloadForSongID:songID completion:done]; })];
        [actions addObject:makeCommandAction(@"取消", ^(void (^done)(BOOL)) { [manager cancelDownloadForSongID:songID completion:done]; })];
    } else if ([item.status isEqualToString:@"failed"] || [item.status isEqualToString:@"cancelled"]) {
        [actions addObject:makeCommandAction(@"重试", ^(void (^done)(BOOL)) { [manager retryDownloadForSongID:songID completion:done]; })];
    }
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf tableView:tableView commitEditingStyle:UITableViewCellEditingStyleDelete forRowAtIndexPath:indexPath];
        completionHandler(YES);
    }];
    [actions addObject:deleteAction];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:actions];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)showRepositoryFailure:(NSString *)message {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作失败"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeSongRowWithID:(NSString *)songID {
    NSUInteger row = [self.songs indexOfObjectPassingTest:^BOOL(NLSong *song, NSUInteger idx, BOOL *stop) {
        return [song.songId isEqualToString:songID];
    }];
    if (row == NSNotFound) return;
    NSMutableArray<NLSong *> *songs = [self.songs mutableCopy];
    [songs removeObjectAtIndex:row];
    self.songs = songs;
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (void)removeDownloadRowWithID:(NSString *)songID {
    NSUInteger row = [self.downloadItems indexOfObjectPassingTest:^BOOL(NLDownloadItem *item, NSUInteger idx, BOOL *stop) {
        return [item.songId isEqualToString:songID];
    }];
    if (row == NSNotFound) return;
    NSMutableArray<NLDownloadItem *> *items = [self.downloadItems mutableCopy];
    [items removeObjectAtIndex:row];
    self.downloadItems = items;
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (void)removeAlbumRowWithID:(NSString *)albumID {
    NSUInteger row = [self.albums indexOfObjectPassingTest:^BOOL(NLAlbum *album, NSUInteger idx, BOOL *stop) {
        return [album.albumId isEqualToString:albumID];
    }];
    if (row == NSNotFound) return;
    NSMutableArray<NLAlbum *> *albums = [self.albums mutableCopy];
    [albums removeObjectAtIndex:row];
    self.albums = albums;
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (void)removePlaylistRowWithID:(NSString *)playlistID {
    NSUInteger row = [self.playlists indexOfObjectPassingTest:^BOOL(NLPlayList *playlist, NSUInteger idx, BOOL *stop) {
        return [playlist.playlistId isEqualToString:playlistID];
    }];
    if (row == NSNotFound) return;
    NSMutableArray<NLPlayList *> *playlists = [self.playlists mutableCopy];
    [playlists removeObjectAtIndex:row];
    self.playlists = playlists;
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.emptyStateView.hidden = [self rowCount] > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if ([self isSongMode]) {
        if (indexPath.row >= self.songs.count) return;
        NLSong *song = self.songs[indexPath.row];
        NSString *songID = [song.songId copy];
        if (!songID.length) return;
        if (self.mode == NLMusicLibraryListModeCachedSongs) {
            [self removeSongRowWithID:songID];
            return;
        }
        __weak typeof(self) weakSelf = self;
        void (^finishRemoval)(BOOL) = ^(BOOL success) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (success) {
                [self removeSongRowWithID:songID];
            } else {
                [self showRepositoryFailure:@"歌曲状态未能保存，列表未更改。"];
            }
        };
        if (self.mode == NLMusicLibraryListModeRecentPlay) {
            [NLSongRepository removePlayHistoryWithSongId:songID completion:finishRemoval];
        } else if (self.mode == NLMusicLibraryListModeLikedSongs) {
            [NLSongRepository likeSong:song isLike:NO completion:finishRemoval];
        }
        return;
    }
    if ([self isDownloadMode]) {
        if (indexPath.row >= self.downloadItems.count) return;
        NSString *songID = [self.downloadItems[indexPath.row].songId copy];
        if (!songID.length) return;
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除下载"
                                                                       message:@"确定删除该首下载的音乐吗？"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [[NLDownloadManager sharedManager] removeOfflineDownloadForSongID:songID];
                [NLDownloadRepository removeDownloadItemWithSongId:songID completion:^(BOOL queueRemoved) {
                    if (!queueRemoved) {
                        [self showRepositoryFailure:@"下载记录未能删除，列表未更改。"];
                        return;
                    }
                    [NLSongRepository removeDownloadedSong:songID completion:^(BOOL songRemoved) {
                        if (!songRemoved) {
                            [self showRepositoryFailure:@"歌曲记录未能删除，列表未更改。"];
                            return;
                        }
                        [self removeDownloadRowWithID:songID];
                    }];
                }];
            });
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if ([self isAlbumMode]) {
        if (indexPath.row >= self.albums.count) return;
        NLAlbum *album = self.albums[indexPath.row];
        NSString *albumID = [album.albumId copy];
        if (!albumID.length) return;
        __weak typeof(self) weakSelf = self;
        [NLAlbumRepository setAlbum:album liked:NO completion:^(BOOL success) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (success) [self removeAlbumRowWithID:albumID];
            else [self showRepositoryFailure:@"专辑收藏状态未能保存，列表未更改。"];
        }];
        return;
    }
    if (indexPath.row >= self.playlists.count) return;
    NLPlayList *playlist = self.playlists[indexPath.row];
    NSString *playlistID = [playlist.playlistId copy];
    if (!playlistID.length) return;
    __weak typeof(self) weakSelf = self;
    void (^finishRemoval)(BOOL) = ^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (success) [self removePlaylistRowWithID:playlistID];
        else [self showRepositoryFailure:@"歌单状态未能保存，列表未更改。"];
    };
    if (self.mode == NLMusicLibraryListModeLikedPlaylists) {
        [NLPlayListRepository setPlayList:playlist liked:NO completion:finishRemoval];
    } else {
        [NLPlayListRepository deletePlayList:playlistID completion:finishRemoval];
    }
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
