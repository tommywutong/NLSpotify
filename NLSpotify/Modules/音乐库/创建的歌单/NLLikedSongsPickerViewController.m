//
//  NLLikedSongsPickerViewController.m
//  NLSpotify
//

#import "NLLikedSongsPickerViewController.h"
#import "NLPlayList.h"
#import "NLSong.h"
#import "NLSongRepository.h"
#import "NLPlayListRepository.h"
#import "NLSongListCell.h"
#import <Masonry/Masonry.h>

static NSString * const kLikedSongCellId = @"LikedSongCell";

@interface NLLikedSongsPickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NLPlayList *playlist;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NLSong *> *likedSongs;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedSongIds;
@property (nonatomic, assign) NSUInteger dataLoadToken;
@property (nonatomic, assign) BOOL savingSelection;
@end

@implementation NLLikedSongsPickerViewController

- (instancetype)initWithPlayList:(NLPlayList *)playlist {
    if (self = [super init]) {
        _playlist = playlist;
        _selectedSongIds = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.title = @"从我喜欢的歌曲添加";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(backTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(doneTapped)];

    [self.view addSubview:self.tableView];
    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];

    [self loadData];
}

- (void)loadData {
    NSUInteger token = ++self.dataLoadToken;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLSong *> *songs = [NLSongRepository allLikedSongs] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || token != self.dataLoadToken) return;
            self.likedSongs = songs;
            [self.tableView reloadData];
        });
    });
}

- (void)backTapped {
    if (self.savingSelection) return;
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)doneTapped {
    if (self.savingSelection) return;
    if (self.selectedSongIds.count == 0) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    NSString *playlistID = self.playlist.playlistId;
    if (!playlistID.length) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    NSMutableArray<NLSong *> *selectedSongs = [NSMutableArray array];
    for (NLSong *song in self.likedSongs) {
        if (song.songId.length && [self.selectedSongIds containsObject:song.songId]) [selectedSongs addObject:song];
    }
    self.savingSelection = YES;
    [self addSongs:selectedSongs toPlayList:playlistID atIndex:0];
}

- (void)addSongs:(NSArray<NLSong *> *)songs toPlayList:(NSString *)playlistID atIndex:(NSUInteger)index {
    if (index >= songs.count) {
        self.savingSelection = NO;
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    NLSong *song = songs[index];
    [NLPlayListRepository addSong:song toPlayList:playlistID completion:^(BOOL success) {
        if (!success) {
            self.savingSelection = NO;
            UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"添加失败"
                                                                               message:@"歌曲未能保存到歌单，请重试。"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:failure animated:YES completion:nil];
            return;
        }
        [self addSongs:songs toPlayList:playlistID atIndex:index + 1];
    }];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.likedSongs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSongListCell *cell = [tableView dequeueReusableCellWithIdentifier:kLikedSongCellId forIndexPath:indexPath];
    NLSong *song = self.likedSongs[indexPath.row];
    [cell configWithNLSong:song];
    BOOL selected = (song.songId.length > 0 && [self.selectedSongIds containsObject:song.songId]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NLSong *song = self.likedSongs[indexPath.row];
    if (!song.songId.length) return;
    if ([self.selectedSongIds containsObject:song.songId]) {
        [self.selectedSongIds removeObject:song.songId];
    } else {
        [self.selectedSongIds addObject:song.songId];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 72.0;
}

#pragma mark - Getters

- (UITableView *)tableView {
    if (!_tableView) {
        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.dataSource = self;
        _tableView.delegate = self;
        _tableView.backgroundColor = [UIColor systemBackgroundColor];
        _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        _tableView.separatorInset = UIEdgeInsetsMake(0, 76, 0, 0);
        _tableView.tableFooterView = [UIView new];
        [_tableView registerClass:[NLSongListCell class] forCellReuseIdentifier:kLikedSongCellId];
    }
    return _tableView;
}

@end

