//
//  NLTabBarController.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/14.
//

#import "NLTabBarController.h"
#import "NLAdvertiseViewController.h"
#import "NLCreateViewController.h"
#import "NLMusicViewController.h"
#import "NLSearchViewController.h"
#import "NLMusicPlayerAccessoryViewController.h"
#import "NLMusicPlayerAccessoryView.h"
#import "NLHomeViewController.h"
#import "NLPlayerManager.h"
#import "Masonry/Masonry.h"
#import <ReactiveObjC/ReactiveObjC.h>

@interface NLTabBarController ()
@property (nonatomic, strong) UIView *legacyAccessoryView;
@property (nonatomic, strong) NLMusicPlayerAccessoryViewController *playerVC;
@property (nonatomic, strong) UITabAccessory *playerAccessory;
@end

@implementation NLTabBarController

- (void)viewDidLoad {
    [super viewDidLoad];

    UITab *homeTab = [[UITab alloc] initWithTitle:@"首页"
                                            image:[UIImage systemImageNamed:@"house"]
                                       identifier:@"Home"
                           viewControllerProvider:^UIViewController * _Nonnull(UITab * _Nonnull tab) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NLHomeViewController new]];
        nav.interactivePopGestureRecognizer.enabled = YES;
        return nav;
    }];

    UITab *musicTab = [[UITab alloc] initWithTitle:@"音乐库"
                                             image:[UIImage systemImageNamed:@"music.pages"]
                                        identifier:@"MusicLibrary"
                            viewControllerProvider:^UIViewController * _Nonnull(UITab * _Nonnull tab) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NLMusicViewController new]];
        nav.interactivePopGestureRecognizer.enabled = YES;
        return nav;
    }];

    UITab *broadcastTab = [[UITab alloc] initWithTitle:@"广播"
                                               image:[UIImage systemImageNamed:@"waveform.mid"]
                                          identifier:@"broadcast"
                              viewControllerProvider:^UIViewController * _Nonnull(UITab * _Nonnull tab) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NLAdvertiseViewController new]];
        nav.interactivePopGestureRecognizer.enabled = YES;
        return nav;
    }];

//    UITab *createTab = [[UITab alloc] initWithTitle:@"创建"
//                                              image:[UIImage systemImageNamed:@"plus"]
//                                         identifier:@"Create"
//                             viewControllerProvider:^UIViewController * _Nonnull(UITab * _Nonnull tab) {
//        return [[UINavigationController alloc] initWithRootViewController:[NLCreateViewController new]];
//    }];


    UISearchTab *searchTab =
    [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController * _Nonnull(UITab * _Nonnull tab) {
        NLSearchViewController *searchVC = [[NLSearchViewController alloc] init];
        UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:searchVC];
        navVC.interactivePopGestureRecognizer.enabled = YES;
        return navVC;
    }];

    searchTab.title = @"搜索";
    searchTab.image = [UIImage systemImageNamed:@"magnifyingglass"];
    // 非常重要！！切换到 SearchTab 时是否自动激活底部搜索框！！
    searchTab.automaticallyActivatesSearch = NO;

    self.tabs = @[homeTab, musicTab, broadcastTab, searchTab];
    self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorOnScrollDown;
    self.playerVC = [[NLMusicPlayerAccessoryViewController alloc] init];
    [self addChildViewController:self.playerVC];

    self.playerAccessory = [[UITabAccessory alloc] initWithContentView:self.playerVC.view];
    [self.playerVC didMoveToParentViewController:self];

    // 无歌单时不显示小播放器，有歌单时显示。登出重建 TabBar 时也要取消旧订阅。
    @weakify(self);
    [[[NLPlayerManager sharedManager].hasPlaylistSignal takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNumber *hasPlaylist) {
        @strongify(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.bottomAccessory = hasPlaylist.boolValue ? self.playerAccessory : nil;
        });
    }];
}

@end
