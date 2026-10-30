//
//  NLSearchViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/14
//

#import "NLSearchViewController.h"
#import "NLCategoryModel.h"
#import "NLCategoryCell.h"
#import "NLSearchAdBannerView.h"
#import <Masonry/Masonry.h>
#import "NLPlayListsViewController.h"
#import "NLSearchResultViewController.h"
#import "NLPlaylistService.h"

@interface NLSearchViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

/// 顶部广告条（独立 View）
@property (nonatomic, strong) NLSearchAdBannerView *adBannerView;
@property (nonatomic, strong) MASConstraint *adBannerHeightConstraint;
@property (nonatomic, assign) BOOL adBannerDismissed;

// 搜索（Category 格子）
@property (nonatomic, strong) UILabel *sectionTitleLabel;
@property (nonatomic, strong) UICollectionView *categoryCollectionView;
@property (nonatomic, strong) NSArray<NLCategoryModel *> *categories;
@property (nonatomic, strong) UISearchController *searchController;

@property (nonatomic, assign) BOOL presentingResult;

@end

@implementation NLSearchViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"搜索";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.definesPresentationContext = YES;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (@available(iOS 18.0, *)) {
        self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }
    if (self.searchController.active) {
        [self.searchController setActive:NO];
    }

    [self.view addSubview:self.scrollView];
    [self.scrollView addSubview:self.contentView];
    [self.contentView addSubview:self.adBannerView];
    [self.contentView addSubview:self.sectionTitleLabel];
    [self.contentView addSubview:self.categoryCollectionView];

    [self setupData];   // 先设置 categories，setupConstraints 里会用到 calculateCategoryCollectionHeight
    [self setupConstraints];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 重置presentingResult状态，允许再次进入result页面
    self.presentingResult = NO;
}

#pragma mark - UISearchBarDelegate

- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar {
    // 拦截点击：跳转到结果页，而不是在当前页搜索
    NLSearchResultViewController *resultVC = [[NLSearchResultViewController alloc] init];
    [self.navigationController pushViewController:resultVC animated:YES];
    return NO;
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    // 在 SearchVC 中不需要处理取消按钮，因为不会显示
    [searchBar resignFirstResponder];
}

#pragma mark - Data

- (void)setupData {
    self.categories = [NLCategoryModel defaultCategories];
    [self fetchCategoryPreviews];
}

- (void)fetchCategoryPreviews {
    __weak typeof(self) weakSelf = self;
    [self.categories enumerateObjectsUsingBlock:^(NLCategoryModel *model, NSUInteger idx, BOOL *stop) {
        [NLPlaylistService fetchPlaylistsWithCategory:model.name
                                              success:^(NSArray<NLPlaylistModel *> *playlists) {
            if (playlists.count > 0) {
                NLPlaylistModel *first = playlists.firstObject;
                model.previewCoverUrl = first.coverImgUrl;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:idx inSection:0];
                    [weakSelf.categoryCollectionView reloadItemsAtIndexPaths:@[indexPath]];
                });
            }
        } failure:^(NSError *error) { (void)error; }];
    }];
}

#pragma mark - Layout

- (void)adExperienceTapped {
    // 跳转另一页，暂不实现
}

- (void)adCloseTapped {
    if (self.adBannerDismissed) return;
    self.adBannerDismissed = YES;

    [_adBannerHeightConstraint uninstall];
    [self.adBannerView mas_updateConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(0);
    }];

    [self.sectionTitleLabel mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.contentView).offset(0);
        make.left.equalTo(self.contentView).offset(20);
    }];

    [UIView animateWithDuration:0.3 animations:^{
        self.adBannerView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        self.adBannerView.hidden = YES;
    }];
}

- (void)setupConstraints {
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.scrollView);
        make.width.equalTo(self.scrollView);
    }];
    [self.adBannerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.contentView).offset(16);
        make.left.equalTo(self.contentView).offset(16);
        make.right.equalTo(self.contentView).offset(-16);
        _adBannerHeightConstraint = make.height.mas_equalTo(320);
    }];
    [self.sectionTitleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.adBannerView.mas_bottom).offset(20);
        make.left.equalTo(self.contentView).offset(20);
    }];
    [self.categoryCollectionView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.sectionTitleLabel.mas_bottom).offset(12);
        make.left.equalTo(self.contentView).offset(20);
        make.right.equalTo(self.contentView).offset(-20);
        make.height.mas_equalTo([self calculateCategoryCollectionHeight]);
        make.bottom.equalTo(self.contentView).offset(-30);
    }];
}

- (CGFloat)calculateCategoryCollectionHeight {
    if (!self.categories.count) return 0;
    NSInteger rows = (self.categories.count + 1) / 2;
    return rows * 105 + (rows - 1) * 12;
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.categories.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NLCategoryCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"CategoryCell" forIndexPath:indexPath];
    cell.model = self.categories[indexPath.item];
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NLCategoryModel *model = self.categories[indexPath.item];
    NLPlayListsViewController *vc = [[NLPlayListsViewController alloc] initWithCategoryModel:model];
    [self.navigationController pushViewController:vc animated:YES];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = (collectionView.bounds.size.width - 12) / 2;
    return CGSizeMake(width, 105);
}

#pragma mark - Getters

- (UIScrollView *)scrollView {
    if (!_scrollView) {
        _scrollView = [[UIScrollView alloc] init];
        _scrollView.showsVerticalScrollIndicator = NO;
    }
    return _scrollView;
}

- (UIView *)contentView {
    if (!_contentView) {
        _contentView = [[UIView alloc] init];
    }
    return _contentView;
}

- (NLSearchAdBannerView *)adBannerView {
    if (!_adBannerView) {
        _adBannerView = [[NLSearchAdBannerView alloc] init];
        __weak typeof(self) weakSelf = self;
        _adBannerView.onCloseTapped = ^{
            [weakSelf adCloseTapped];
        };
        _adBannerView.onExperienceTapped = ^{
            [weakSelf adExperienceTapped];
        };
    }
    return _adBannerView;
}

- (UILabel *)sectionTitleLabel {
    if (!_sectionTitleLabel) {
        _sectionTitleLabel = [[UILabel alloc] init];
        _sectionTitleLabel.text = @"搜索";
        _sectionTitleLabel.font = [UIFont boldSystemFontOfSize:25];
        _sectionTitleLabel.textColor = [UIColor labelColor];
    }
    return _sectionTitleLabel;
}

- (UICollectionView *)categoryCollectionView {
    if (!_categoryCollectionView) {
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.minimumLineSpacing = 12;
        layout.minimumInteritemSpacing = 12;
        layout.itemSize = CGSizeMake(140, 105);
        _categoryCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
        _categoryCollectionView.backgroundColor = UIColor.clearColor;
        _categoryCollectionView.scrollEnabled = NO;
        _categoryCollectionView.dataSource = self;
        _categoryCollectionView.delegate = self;
        [_categoryCollectionView registerClass:[NLCategoryCell class] forCellWithReuseIdentifier:@"CategoryCell"];
    }
    return _categoryCollectionView;
}

- (UISearchController *)searchController {
    if (!_searchController) {
        UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
        sc.searchBar.delegate = self;
        sc.searchBar.placeholder = @"艺人、歌曲、歌词以及更多内容";
        sc.searchBar.searchBarStyle = UISearchBarStyleMinimal;
        sc.hidesNavigationBarDuringPresentation = NO;
        sc.automaticallyShowsCancelButton = NO;
        _searchController = sc;
    }
    return _searchController;
}

@end
