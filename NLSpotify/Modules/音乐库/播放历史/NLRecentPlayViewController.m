//
//  NLRecentPlayViewController.m
//  NLSpotify
//

#import "NLRecentPlayViewController.h"
#import "NLSongRepository.h"
#import "NLSong.h"
#import "NLSongListCell.h"
#import "NLPlayerManager.h"
#import <Masonry/Masonry.h>

static NSString * const kCellId = @"RecentPlayCell";

@interface NLRecentPlayViewController () <UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, copy) NSArray<NLSong *> *songs;
@property (nonatomic, assign) NSUInteger historyRequestToken;
@end

@implementation NLRecentPlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.title = @"最近播放";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(backTapped)];

    // 右滑返回
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

- (void)loadData {
    NSUInteger token = ++self.historyRequestToken;
    __weak typeof(self) weakSelf = self;
    [NLSongRepository allPlayHistoryWithCompletion:^(NSArray<NLSong *> *history) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.historyRequestToken) return;
        self.songs = history;
        [self.tableView reloadData];
        self.emptyStateView.hidden = history.count > 0;
    }];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.songs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSongListCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId forIndexPath:indexPath];
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
        [_tableView registerClass:[NLSongListCell class] forCellReuseIdentifier:kCellId];
    }
    return _tableView;
}

- (UIView *)emptyStateView {
    if (!_emptyStateView) {
        _emptyStateView = [[UIView alloc] init];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightLight];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath" withConfiguration:config]];
        iconView.tintColor = [UIColor tertiaryLabelColor];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [_emptyStateView addSubview:iconView];

        UILabel *label = [[UILabel alloc] init];
        label.text = @"最近播放的歌曲将在这里显示。";
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

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.navigationController.interactivePopGestureRecognizer) {
        if (self.navigationController.viewControllers.count <= 1) {
            return NO;
        }
    }
    return YES;
}
@end
