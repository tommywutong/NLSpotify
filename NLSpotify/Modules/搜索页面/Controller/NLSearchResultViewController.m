//
//  NLSearchResultViewController.m
//  NLSpotify
//

#import "NLSearchResultViewController.h"
#import "NLSearchSuggestService.h"
#import "NLSong.h"
#import "NLSongListViewController.h"
#import "NLPlayerManager.h"
#import "NetWorkManager.h"
#import <Masonry/Masonry.h>

@interface NLArtistDetailController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, assign) NSInteger artistId;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *songs;
- (instancetype)initWithArtistId:(NSInteger)artistId name:(NSString *)name;
@end

@implementation NLArtistDetailController
- (instancetype)initWithArtistId:(NSInteger)artistId name:(NSString *)name { if ((self = [super init])) { _artistId = artistId; _artistName = [name copy]; _songs = @[]; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.artistName;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [[NetWorkManager sharedManager] GET:@"/artists" parameters:@{@"id": @(self.artistId)} success:^(NSDictionary *response) {
        self.songs = [response[@"hotSongs"] isKindOfClass:NSArray.class] ? response[@"hotSongs"] : @[];
        [self.tableView reloadData];
    } failure:^(NSError *error) { self.title = [NSString stringWithFormat:@"%@（加载失败）", self.artistName]; }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.songs.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath { UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ArtistSong"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ArtistSong"]; NSDictionary *song = self.songs[indexPath.row]; cell.textLabel.text = song[@"name"]; cell.detailTextLabel.text = self.artistName; return cell; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { NSDictionary *raw = self.songs[indexPath.row]; NSString *songId = [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""]; if (songId.length == 0) return; NLSong *song = [[NLSong alloc] initWithId:songId title:raw[@"name"] ?: @"歌曲" artist:self.artistName coverURL:[[NSURL alloc] initWithString:@"about:blank"]]; [[NLPlayerManager sharedManager] playWithPlaylist:@[song] startIndex:0]; }
@end

@interface NLSearchResultViewController () <UISearchBarDelegate, UISearchResultsUpdating, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *typeControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingView;
@property (nonatomic, copy) NSString *keyword;
@property (nonatomic, assign) NLSearchType searchType;
@property (nonatomic, assign) NSUInteger requestToken;
@property (nonatomic, assign) NSUInteger offset;
@property (nonatomic, assign) BOOL hasMore;
@property (nonatomic, assign) BOOL loadingPage;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@implementation NLSearchResultViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.definesPresentationContext = YES;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchType = NLSearchTypeSong;
    self.hasMore = YES;
    self.items = @[];
    self.typeControl = [[UISegmentedControl alloc] initWithItems:@[@"歌曲", @"歌单", @"艺人", @"歌词"]];
    self.typeControl.selectedSegmentIndex = 0;
    [self.typeControl addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.typeControl];
    [self.typeControl mas_makeConstraints:^(MASConstraintMaker *make) { make.top.equalTo(self.view.safeAreaLayoutGuide).offset(12); make.left.right.equalTo(self.view).inset(16); }];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) { make.top.equalTo(self.typeControl.mas_bottom).offset(8); make.left.right.bottom.equalTo(self.view); }];
    self.loadingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.view addSubview:self.loadingView];
    [self.loadingView mas_makeConstraints:^(MASConstraintMaker *make) { make.center.equalTo(self.view); }];
    self.stateLabel = [[UILabel alloc] init];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.textColor = UIColor.secondaryLabelColor;
    self.stateLabel.numberOfLines = 0;
    self.tableView.backgroundView = self.stateLabel;
}

- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; dispatch_async(dispatch_get_main_queue(), ^{ [self.searchController.searchBar becomeFirstResponder]; }); }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.requestToken += 1; }
- (void)typeChanged:(UISegmentedControl *)sender { NSNumber *type = @[@(NLSearchTypeSong), @(NLSearchTypePlaylist), @(NLSearchTypeArtist), @(NLSearchTypeLyric)][sender.selectedSegmentIndex]; self.searchType = (NLSearchType)type.integerValue; [self startSearchForKeyword:self.keyword ?: self.searchController.searchBar.text ?: @""]; }
- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar { self.requestToken += 1; [self.navigationController popViewControllerAnimated:YES]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; [self startSearchForKeyword:searchBar.text ?: @""]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self startSearchForKeyword:searchController.searchBar.text ?: @""]; }

- (void)startSearchForKeyword:(NSString *)keyword {
    NSString *trimmed = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger token = ++self.requestToken;
    self.keyword = trimmed;
    self.offset = 0;
    self.hasMore = YES;
    self.loadingPage = NO;
    self.items = @[];
    [self.tableView reloadData];
    if (trimmed.length == 0) { self.stateLabel.text = @"输入关键词开始搜索"; return; }
    self.stateLabel.text = nil;
    [self.loadingView startAnimating];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (token == self.requestToken && [trimmed isEqualToString:self.keyword]) [self loadPageForToken:token keyword:trimmed reset:YES]; });
}

- (void)loadPageForToken:(NSUInteger)token keyword:(NSString *)keyword reset:(BOOL)reset {
    if (self.loadingPage || (!reset && !self.hasMore)) return;
    self.loadingPage = YES;
    NSUInteger pageOffset = reset ? 0 : self.offset;
    [NLSearchSuggestService searchWithKeywords:keyword type:self.searchType offset:pageOffset limit:20 success:^(NSArray<NSDictionary *> *items, BOOL hasMore) {
        if (token != self.requestToken || ![keyword isEqualToString:self.keyword]) return;
        self.loadingPage = NO;
        self.hasMore = hasMore;
        self.offset = pageOffset + items.count;
        self.items = reset ? items : [self.items arrayByAddingObjectsFromArray:items];
        [self.loadingView stopAnimating];
        self.stateLabel.text = self.items.count ? nil : @"没有找到相关内容";
        [self.tableView reloadData];
    } failure:^(NSError *error) {
        if (token != self.requestToken || ![keyword isEqualToString:self.keyword]) return;
        self.loadingPage = NO;
        [self.loadingView stopAnimating];
        self.stateLabel.text = [NSString stringWithFormat:@"搜索失败\n%@", error.localizedDescription ?: @"请稍后重试"];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SearchCell"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SearchCell"];
    NSDictionary *item = self.items[indexPath.row];
    if (self.searchType == NLSearchTypePlaylist) { cell.textLabel.text = item[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"歌曲 %ld 首", (long)[item[@"trackCount"] integerValue]]; }
    else if (self.searchType == NLSearchTypeArtist) { cell.textLabel.text = item[@"name"]; cell.detailTextLabel.text = [NSString stringWithFormat:@"歌曲 %ld · 专辑 %ld", (long)[item[@"musicSize"] integerValue], (long)[item[@"albumSize"] integerValue]]; }
    else { cell.textLabel.text = item[@"title"] ?: item[@"name"]; cell.detailTextLabel.text = item[@"artist"] ?: @"歌词匹配"; }
    cell.imageView.image = [UIImage systemImageNamed:@"music.note"];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[indexPath.row];
    if (self.searchType == NLSearchTypeArtist) { NLArtistDetailController *controller = [[NLArtistDetailController alloc] initWithArtistId:[item[@"artistId"] integerValue] name:item[@"name"] ?: @"艺人"]; [self.navigationController pushViewController:controller animated:YES]; return; }
    NSString *songId = item[@"songId"];
    if (songId.length == 0) return;
    NLSong *song = [[NLSong alloc] initWithId:songId title:item[@"title"] ?: item[@"name"] ?: @"歌曲" artist:item[@"artist"] ?: @"" coverURL:[[NSURL alloc] initWithString:@"about:blank"]];
    [[NLPlayerManager sharedManager] playWithPlaylist:@[song] startIndex:0];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { if (scrollView.contentOffset.y + scrollView.bounds.size.height > scrollView.contentSize.height - 80) [self loadPageForToken:self.requestToken keyword:self.keyword reset:NO]; }

- (UISearchController *)searchController {
    if (!_searchController) { UISearchController *controller = [[UISearchController alloc] initWithSearchResultsController:nil]; controller.searchResultsUpdater = self; controller.obscuresBackgroundDuringPresentation = NO; controller.hidesNavigationBarDuringPresentation = NO; controller.searchBar.delegate = self; controller.searchBar.placeholder = @"艺人、歌曲、歌词以及更多内容"; controller.searchBar.searchBarStyle = UISearchBarStyleMinimal; controller.searchBar.showsCancelButton = YES; _searchController = controller; }
    return _searchController;
}
@end
