//
//  NLLoginViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/17.
//

#import "NLLoginViewController.h"
#import "NLTabBarController.h"

#import "NLAuthManager.h"
#import <Masonry/Masonry.h>
#import "NLGuestLoginService.h"

@interface NLLoginViewController ()

@property (nonatomic, strong) UIImageView *logoImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *buttonsContainer;
@property (nonatomic, strong) UIButton *guestLoginButton;

@end

@implementation NLLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setNeedsStatusBarAppearanceUpdate];

    [self.view addSubview:self.logoImageView];
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.buttonsContainer];

    [self setupConstraints];
}

#pragma mark - Layout

- (void)setupConstraints {
    [self.logoImageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.view);
        make.top.equalTo(self.view).offset(120);
        make.width.height.mas_equalTo(80);
    }];
    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.logoImageView.mas_bottom).offset(20);
        make.centerX.equalTo(self.view);
    }];
    [self.buttonsContainer mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleLabel.mas_bottom).offset(40);
        make.left.right.equalTo(self.view).inset(20);
    }];

    [self.guestLoginButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.buttonsContainer);
        make.top.bottom.equalTo(self.buttonsContainer);
        make.height.mas_equalTo(50);
    }];
}

- (UIButton *)createLoginButtonWithTitle:(NSString *)title
                        backgroundColor:(UIColor *)backgroundColor
                              textColor:(UIColor *)textColor
                                    icon:(NSString *)iconName {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = backgroundColor;
    button.layer.cornerRadius = 25;
    button.clipsToBounds = YES;

    // 标题
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:textColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // 如果有图标
    if (iconName) {
        UIImage *icon = [UIImage systemImageNamed:iconName];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.tintColor = textColor;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [button addSubview:iconView];

        [iconView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(button).offset(20);
            make.centerY.equalTo(button);
            make.width.height.mas_equalTo(24);
        }];
        button.configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 0);
    } else {
        // 没有图标，居中显示标题
        button.configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    }

    return button;
}



#pragma mark - Button Actions

- (void)guestLoginTapped {
    __weak typeof(self) weakSelf = self;
    [NLGuestLoginService anonymousLoginWithSuccess:^(NSDictionary *response) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSError *error = nil;
        NSString *cookie = [NLGuestLoginService cookieFromResponse:response error:&error];
        if (!cookie || ![NLAuthManager setCookie:cookie error:&error]) {
            [self presentGuestLoginFailure:error];
            return;
        }
        [NLAuthManager setLoginStateWithAccount:response[@"account"]];
        [self loginSuccess];
    } failure:^(NSError *error) {
        [weakSelf presentGuestLoginFailure:error];
    }];
}

- (void)presentGuestLoginFailure:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"游客登录失败"
                                                                   message:error.localizedDescription ?: @"凭据保存失败"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loginSuccess {
    // 切换到主页面
    NLTabBarController *tabBarController = [[NLTabBarController alloc] init];
    // 动画切换
    CATransition *transition = [CATransition animation];
    transition.duration = 0.5;
    transition.type = kCATransitionFade;

    UIWindow *window = self.view.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
                window = ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    }
    if (!window) return;
    [window.layer addAnimation:transition forKey:kCATransition];
    window.rootViewController = tabBarController;
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

#pragma mark - Getters

- (UIImageView *)logoImageView {
    if (!_logoImageView) {
        _logoImageView = [[UIImageView alloc] init];
        _logoImageView.image = [UIImage imageNamed:@"spotify"];
        _logoImageView.contentMode = UIViewContentModeScaleAspectFit;
    }
    return _logoImageView;
}

- (UILabel *)titleLabel {
    if (!_titleLabel) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = @"登录到 Spotify";
        _titleLabel.font = [UIFont boldSystemFontOfSize:24];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
    }
    return _titleLabel;
}

- (UIView *)buttonsContainer {
    if (!_buttonsContainer) {
        _buttonsContainer = [[UIView alloc] init];
        [_buttonsContainer addSubview:self.guestLoginButton];
    }
    return _buttonsContainer;
}


- (UIButton *)guestLoginButton {
    if (!_guestLoginButton) {
        _guestLoginButton = [self createLoginButtonWithTitle:@"游客登录" backgroundColor:[UIColor secondarySystemBackgroundColor] textColor:[UIColor labelColor] icon:nil];
        [_guestLoginButton addTarget:self action:@selector(guestLoginTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return _guestLoginButton;
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
