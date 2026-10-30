//
//  NLPlayListsViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/17.
//
#import "NLPlayListsViewController.h"
#import "NLPlaylistService.h"
#import "NLPlaylistCollectionCell.h"
#import <Masonry/Masonry.h>
#import "NLCategoryModel.h"
#import "NLSongListViewController.h"

@interface NLPlayListsViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableArray<NLPlaylistModel *> *playlists;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation NLPlayListsViewController

- (instancetype)initWithCategoryModel:(NLCategoryModel *)model {
    self = [super init];
    if (self) {
        _categoryModel = model;
        _categoryName = model.name;
        _playlists = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    [self.view addSubview:self.scrollView];
    [self.scrollView addSubview:self.contentView];
    [self.contentView addSubview:self.titleLabel];
    [self.contentView addSubview:self.collectionView];
    [self.view addSubview:self.loadingIndicator];

    [self setupConstraints];

    [self setupNavigation];
    [self loadData];
}

- (void)setupConstraints {
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];

    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.scrollView);
        make.width.equalTo(self.scrollView);
    }];

    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.contentView).offset(20);
        make.left.equalTo(self.contentView).offset(16);
        make.right.equalTo(self.contentView).offset(-16);
    }];

    [self.collectionView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleLabel.mas_bottom).offset(20);
        make.left.equalTo(self.contentView).offset(16);
        make.right.equalTo(self.contentView).offset(-16);
        make.bottom.equalTo(self.contentView).offset(-24);
        make.height.mas_equalTo(0);
    }];

    [self.loadingIndicator mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.equalTo(self.view);
    }];
}

- (void)updateCollectionViewHeight {
    CGFloat h = 0;
    if (self.playlists.count > 0) {
        CGFloat itemWidth = (self.view.bounds.size.width - 48) / 2;
        CGFloat itemHeight = itemWidth + 60;
        NSInteger rows = (self.playlists.count + 1) / 2;
        h = rows * itemHeight + (rows - 1) * 16;
    }
    [_collectionView mas_updateConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(h);
    }];
}

- (void)setupNavigation {
    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [backButton setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    backButton.tintColor = [UIColor labelColor];
    [backButton addTarget:self action:@selector(backButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIBarButtonItem *backItem = [[UIBarButtonItem alloc] initWithCustomView:backButton];
    self.navigationItem.leftBarButtonItem = backItem;
    self.navigationController.navigationBar.tintColor = [UIColor labelColor];
}

- (void)loadData {
    [_loadingIndicator startAnimating];

    __weak typeof(self) weakSelf = self;
    [NLPlaylistService fetchPlaylistsWithCategory:self.categoryName success:^(NSArray<NLPlaylistModel *> *playlists) {
        [weakSelf.loadingIndicator stopAnimating];
        weakSelf.playlists = [playlists mutableCopy];
        [weakSelf.collectionView reloadData];
        [weakSelf updateCollectionViewHeight];
      if (playlists.count > 0) {
          NLPlaylistModel *first = playlists.firstObject;
          self.categoryModel.previewCoverUrl = first.coverImgUrl;
      }
        if (playlists.count == 0) {
            [weakSelf showEmptyView];
        }
    } failure:^(NSError *error) {
        [weakSelf.loadingIndicator stopAnimating];
        [weakSelf showError:error.localizedDescription];
    }];
}

- (void)showError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                   message:errorMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *retry = [UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self loadData];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:retry];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showEmptyView {
    UILabel *emptyLabel = [[UILabel alloc] init];
    emptyLabel.text = @"暂无歌单数据";
    emptyLabel.textColor = [UIColor tertiaryLabelColor];
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.font = [UIFont systemFontOfSize:16];
    self.collectionView.backgroundView = emptyLabel;
}

- (void)backButtonTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.playlists.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NLPlaylistCollectionCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"PlaylistCollectionCell" forIndexPath:indexPath];
    cell.playlist = self.playlists[indexPath.item];
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NLPlaylistModel *playlist = self.playlists[indexPath.item];
    NLSongListViewController *vc = [[NLSongListViewController alloc] initWithId:playlist.playlistId type:NLSongListTypePlaylist name:playlist.name];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Getters

- (UIScrollView *)scrollView {
    if (!_scrollView) {
        _scrollView = [[UIScrollView alloc] init];
        _scrollView.showsVerticalScrollIndicator = YES;
        _scrollView.alwaysBounceVertical = YES;
    }
    return _scrollView;
}

- (UIView *)contentView {
    if (!_contentView) {
        _contentView = [[UIView alloc] init];
        _contentView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    return _contentView;
}

- (UILabel *)titleLabel {
    if (!_titleLabel) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = self.categoryName;
        _titleLabel.font = [UIFont boldSystemFontOfSize:24];
        _titleLabel.textColor = [UIColor labelColor];
    }
    return _titleLabel;
}

- (UICollectionView *)collectionView {
    if (!_collectionView) {
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;
        layout.minimumLineSpacing = 16;
        layout.minimumInteritemSpacing = 16;
        CGFloat itemWidth = (self.view.bounds.size.width - 48) / 2.0;
        layout.itemSize = CGSizeMake(itemWidth, itemWidth + 60);
        _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
        _collectionView.dataSource = self;
        _collectionView.delegate = self;
        _collectionView.scrollEnabled = NO;
        _collectionView.backgroundColor = [UIColor clearColor];
        [_collectionView registerClass:[NLPlaylistCollectionCell class] forCellWithReuseIdentifier:@"PlaylistCollectionCell"];
    }
    return _collectionView;
}

- (UIActivityIndicatorView *)loadingIndicator {
    if (!_loadingIndicator) {
        _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _loadingIndicator.hidesWhenStopped = YES;
    }
    return _loadingIndicator;
}

@end
