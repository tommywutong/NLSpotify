//
//  NLMusicPlayerAccessoryViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/19.
//

#import "NLMusicPlayerAccessoryViewController.h"
#import "NLMusicPlayerAccessoryView.h"
#import "NLSongService.h"
#import "NLPlayerManager.h"
#import "NLMusicPlayerViewController.h"
#import "Masonry/Masonry.h"

@interface NLMusicPlayerAccessoryViewController () <NLMusicPlayerAccessoryViewDelegate>
@property (nonatomic, strong) NLMusicPlayerAccessoryView *playerView;
@end

@implementation NLMusicPlayerAccessoryViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self.view addSubview:self.playerView];
    [self setupConstraints];
    [self.playerView bindPlayer];
}

- (void)setupConstraints {
    [self.playerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.bottom.equalTo(self.view);
        make.height.mas_equalTo(60);
    }];
}

#pragma mark - NLMusicPlayerAccessoryViewDelegate
// present只能在当前

- (void)accessoryViewDidTap:(NLMusicPlayerAccessoryView *)view {
    NLMusicPlayerViewController *fullPlayer = [[NLMusicPlayerViewController alloc] init];
    // 使用 OverFullScreen 让背景透明，可以看到后面的页面（类似Apple Music）
    fullPlayer.modalPresentationStyle = UIModalPresentationOverFullScreen;
    fullPlayer.modalTransitionStyle = UIModalTransitionStyleCoverVertical;

    // 直接使用当前视图控制器
    [self presentViewController:fullPlayer animated:YES completion:nil];
}

//- (void)accessoryViewDidTap:(NLMusicPlayerAccessoryView *)view {
//    NLMusicPlayerViewController *fullPlayer = [[NLMusicPlayerViewController alloc] init];
//    fullPlayer.modalPresentationStyle = UIModalPresentationFullScreen;
//    
//    // 找到当前最顶层的视图控制器来present
//    UIViewController *topVC = [self topViewController];
//    [topVC presentViewController:fullPlayer animated:YES completion:nil];
//}
//
//- (UIViewController *)topViewController {
//    UIViewController *rootVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
//    return [self topViewControllerWithRootViewController:rootVC];
//}
//
//- (UIViewController *)topViewControllerWithRootViewController:(UIViewController *)rootVC {
//    if ([rootVC isKindOfClass:[UITabBarController class]]) {
//        UITabBarController *tabBarController = (UITabBarController *)rootVC;
//        return [self topViewControllerWithRootViewController:tabBarController.selectedViewController];
//    } else if ([rootVC isKindOfClass:[UINavigationController class]]) {
//        UINavigationController *navigationController = (UINavigationController *)rootVC;
//        return [self topViewControllerWithRootViewController:navigationController.visibleViewController];
//    } else if (rootVC.presentedViewController) {
//        return [self topViewControllerWithRootViewController:rootVC.presentedViewController];
//    } else {
//        return rootVC;
//    }
//}

#pragma mark - Getters

- (NLMusicPlayerAccessoryView *)playerView {
    if (!_playerView) {
        _playerView = [[NLMusicPlayerAccessoryView alloc] initWithFrame:CGRectZero];
        _playerView.delegate = self;
    }
    return _playerView;
}

@end
/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/


