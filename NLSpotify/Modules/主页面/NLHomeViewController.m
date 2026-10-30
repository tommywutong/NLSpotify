//
//  NLHomeViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/13.
//

#import "NLHomeViewController.h"
#import "NLHomeViewModel.h"
#import "NLSectionViewModel.h"
#import "NLPlaylistCell.h"
#import "NLSingerAlbumCell.h"
#import "NLHomeSectionHeaderView.h"

#import "Masonry/Masonry.h"
#import "NLSongListViewController.h"
#import "NLDrawerViewController.h"
#import "NLRecentPlayViewController.h"
#import "NLLoginViewController.h"
#import "NLAuthManager.h"
#import "NLCacheManager.h"
#import "NLPlayerManager.h"
#import "NLDownloadManager.h"
#import "NLDownloadRepository.h"
#import "NLSongRepository.h"

@interface NLHomeViewController () <NLDrawerViewControllerDelegate>
@property (nonatomic, strong) NLDrawerViewController *drawerVC;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *collapsedSections;
@end

@implementation NLHomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.collapsedSections = [NSMutableSet set];

    [self.view addSubview:self.tableView];
    [self setupConstraints];
    [self setupNavigation];
    [self loadData];
}

- (void)pressBtn:(id)sender {
    NSLog(@"Bar button tapped");
}

#pragma mark - Layout & Data

- (void)setupNavigation {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:25.0 weight:UIImageSymbolWeightMedium];
    UIButton *myImagePhotoBtn = [[UIButton alloc] init];
    [myImagePhotoBtn setImage:[UIImage systemImageNamed:@"person"] forState:UIControlStateNormal];
    myImagePhotoBtn.tintColor = [UIColor systemGreenColor];
    [myImagePhotoBtn setPreferredSymbolConfiguration:symbolConfig forImageInState:UIControlStateNormal];
    [myImagePhotoBtn addTarget:self action:@selector(openDrawer) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *myImagePhotoButtonItem = [[UIBarButtonItem alloc] initWithCustomView:myImagePhotoBtn];

    NSArray *titleArr = @[@"All", @"Music", @"Podcast", @"Audiobooks"];
    NSMutableArray *btnArr = [NSMutableArray arrayWithObject:myImagePhotoButtonItem];
    for (NSInteger index = 0; index < titleArr.count - 1; index++) {
        NSString *title = titleArr[index];
        UIBarButtonItem *btnItem = [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:self action:@selector(pressBtn:)];
        if (index == 0) btnItem.tintColor = [UIColor systemGreenColor];
        btnItem.tag = index + 100;
        [btnArr addObject:btnItem];
    }
    self.navigationItem.leftBarButtonItems = btnArr;
}

- (void)setupConstraints {
    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];
}

- (void)loadData {
    if (!self.collapsedSections) self.collapsedSections = [NSMutableSet set];
    self.homeVM = [[NLHomeViewModel alloc] init];
    // self -> homeVM -. block -> self
    __weak typeof(self) weakself = self;
    [self.homeVM loadDataWithCompletion:^{
        __strong typeof(weakself) self = weakself;
        if (!self) return;
        [self.tableView reloadData];
    }];
}

#pragma mark - UITableViewDataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self.homeVM numberOfSections];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSectionViewModel *sectionVM =  [self.homeVM sectionAtIndex:indexPath.section];
    __weak typeof(self) weakSelf = self;

    if (sectionVM.style == NLHomeSectionStylePlaylist) {
        NLPlaylistCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"PlaylistCell" forIndexPath:indexPath];
        [cell configWithSectionVM:sectionVM];
        cell.sectionIndex = indexPath.section;
        cell.collapsed = [self.collapsedSections containsObject:@(indexPath.section)];
        cell.didSelectPlaylist = ^(NLRecommendAlbumListModel *model) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSLog(@"[Home] 点击小歌单: %@", model.name);
            NLSongListViewController *vc = [[NLSongListViewController alloc] initWithId:model.playlistId type:NLSongListTypePlaylist name:model.name];
            [self.navigationController pushViewController:vc animated:YES];
        };
        return cell;
    }
 if (sectionVM.style == NLHomeSectionStyleSingerAlbum) {
        NLSingerAlbumCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SingerAlbumCell"
                                        forIndexPath:indexPath];
     [cell configWithSectionVM:sectionVM];
     cell.sectionIndex = indexPath.section;
     cell.collapsed = [self.collapsedSections containsObject:@(indexPath.section)];
     cell.didSelectSingerAlbum = ^(NLSingerAlbumListModel *model) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSLog(@"[Home] 点击歌手专辑: %@", model.title);
            NLSongListViewController *vc = [[NLSongListViewController alloc] initWithId:model.cardId type:NLSongListTypeAlbum name:model.title];
            [self.navigationController pushViewController:vc animated:YES];
        };
        return cell;
    }
    // 兜底，防止炸掉
    return [UITableViewCell new];
}

//点击标题后的该行：折叠变展开，展开变折叠，然后重新刷新这一行
- (void)toggleSectionCollapsed:(NSInteger)section {
    if (section < 0) return;
    NSNumber *key = @(section);
    BOOL isCollapsing = ![self.collapsedSections containsObject:key];
    if (isCollapsing) {
        [self.collapsedSections addObject:key];
    } else {
        [self.collapsedSections removeObject:key];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationFade];

    // 折叠最后一个 section 时，contentSize 变小，系统会调整 contentOffset 导致列表整体上移；这里在布局完成后把列表顶在底部留 140pt 间距，避免“向上滑一段”
    if (isCollapsing && section == [self.homeVM numberOfSections] - 1) {
        __weak UITableView *weakTable = self.tableView;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakTable layoutIfNeeded];
            CGFloat contentH = weakTable.contentSize.height;
            CGFloat visibleH = weakTable.bounds.size.height - weakTable.contentInset.top - weakTable.contentInset.bottom;
            CGFloat targetY = contentH - visibleH + weakTable.contentInset.top + 140; // 底部留 140pt
            if (targetY < 0) targetY = 0;
            [weakTable setContentOffset:CGPointMake(0, targetY) animated:NO];
        });
    }
}


- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return NLHomeSectionHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 0.01; // 必须 >0，否则 grouped 会给默认高度
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self.collapsedSections containsObject:@(indexPath.section)]) {
        return 1; // 折叠后行高缩小，仅留 1pt
    }
    NLSectionViewModel *sectionVM = [self.homeVM sectionAtIndex:indexPath.section];
    if (sectionVM.style == NLHomeSectionStyleSingerAlbum) return 280;
    if (sectionVM.style == NLHomeSectionStylePlaylist) return 180;
    return 180;
}

- (UIView *)tableView:(UITableView *)tableView
viewForHeaderInSection:(NSInteger)section {
    NLHomeSectionHeaderView *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"NLHomeSectionHeader"];
    if (!header) return [UIView new];
    NLSectionViewModel *sectionVM = [self.homeVM sectionAtIndex:section];
    header.sectionIndex = section;
    header.collapsed = [self.collapsedSections containsObject:@(section)];
    [header configWithSectionVM:sectionVM collapsed:header.collapsed];
    __weak typeof(self) weakSelf = self;
    header.didTapHeader = ^(NSInteger sectionIndex) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self toggleSectionCollapsed:sectionIndex];
    };
    return header;
}

- (UIView *)tableView:(UITableView *)tableView
viewForFooterInSection:(NSInteger)section {
    return [UIView new];
}

#pragma mark - DrawerView相关

- (void)openDrawer {
    if (self.drawerVC) return;
    NLDrawerViewController *drawer = [[NLDrawerViewController alloc] init];
    drawer.delegate = self;
    __weak typeof(self) w = self;
    drawer.drawrDidDismiss = ^{
        w.drawerVC = nil;
    };
    self.drawerVC = drawer;
    // 从主视图推出
    [drawer presentFromHostViewController:self.navigationController ?: self];
}

- (void)drawerController:(NLDrawerViewController *)controller didSelectMenuAtIndex:(NSInteger)index {
    // 菜单顺序：0 添加帐号 1 新增内容 2 收听统计 3 最近播放 4 设置 5 一键清空 6 退出登录
    if (index == 3) {
        __weak typeof(self) w = self;
        [controller dismissWithAnimation:YES completion:^{
            __strong typeof(w) s = w;
            if (!s) return;
            NLRecentPlayViewController *vc = [[NLRecentPlayViewController alloc] init];
            [s.navigationController pushViewController:vc animated:YES];
        }];
        return;
    }
    if (index == 5) {
        [controller dismissWithAnimation:YES completion:^{
            [self showClearAllConfirmation];
        }];
        return;
    }
    if (index == 6) {
        __weak typeof(self) w = self;
        [controller dismissWithAnimation:YES completion:^{
            __strong typeof(w) s = w;
            if (!s) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出登录" message:@"确定要退出登录吗？"preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                NSLog(@"[测试] 退出登录（用户确认）");
                [NLAuthManager logout];
                NLLoginViewController *loginVC = [[NLLoginViewController alloc] init];
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loginVC];
                nav.navigationBarHidden = YES;

                UIWindow *window = s.view.window;
                if (!window) {
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
                            window = ((UIWindowScene *)scene).windows.firstObject;
                            break;
                        }
                    }
                }
                if (!window) return;
                window.rootViewController = nav;
            }]];
            [s presentViewController:alert animated:YES completion:nil];
        }];
        return;
    }
    NSLog(@"[Drawer] 菜单项 %ld", (long)index);
}

- (void)showClearAllConfirmation {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"一键清空"
                                                                   message:@"将清除所有缓存与已下载音乐，且无法恢复。确定继续吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) w = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[NLPlayerManager sharedManager] stop];
        [[NLDownloadManager sharedManager] removeAllOfflineDownloads];
        [[NLCacheManager sharedManager] clearAllCache];
        [NLDownloadRepository clearAllDownloadItemsWithCompletion:^(BOOL queueCleared) {
            __strong typeof(w) self = w;
            if (!self || queueCleared) {
                if (!self) return;
                [NLSongRepository clearAllDownloadedSongsWithCompletion:^(BOOL songsCleared) {
                    if (songsCleared) return;
                    UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"清空失败"
                                                                                       message:@"已下载歌曲记录未能全部清除，请重试。"
                                                                                preferredStyle:UIAlertControllerStyleAlert];
                    [failure addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:failure animated:YES completion:nil];
                }];
                return;
            }
            UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"清空失败"
                                                                               message:@"下载队列未能清除，请重试。"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:failure animated:YES completion:nil];
        }];
    }]];
    [w presentViewController:alert animated:YES completion:nil];
}


#pragma mark - Getters

- (UITableView *)tableView {
    if (!_tableView) {
        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
        _tableView.backgroundColor = [UIColor clearColor];
        _tableView.delegate = self;
        _tableView.dataSource = self;
        _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _tableView.rowHeight = UITableViewAutomaticDimension;
        _tableView.estimatedRowHeight = 220;    //预估高度
        [_tableView registerClass:NLHomeSectionHeaderView.class forHeaderFooterViewReuseIdentifier:@"NLHomeSectionHeader"];
        [_tableView registerClass:NLPlaylistCell.class forCellReuseIdentifier:@"PlaylistCell"];
        [_tableView registerClass:NLSingerAlbumCell.class forCellReuseIdentifier:@"SingerAlbumCell"];
    }
    return _tableView;
}


@end
