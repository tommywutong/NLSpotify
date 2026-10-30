//
//  SceneDelegate.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/6.
//

#import "SceneDelegate.h"
#import "NLTabBarController.h"
#import "NLLoginViewController.h"
#import "NLAuthManager.h"

@interface SceneDelegate ()

@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleForceLogout) name:NLForceLogoutNotification object:nil];
    [self showRootViewController];
    [self.window makeKeyAndVisible];
}

- (void)showRootViewController {
    NSError *migrationError = nil;
    if (![NLAuthManager migrateLegacyCookieIfNeeded:&migrationError]) {
        NSLog(@"[Auth] Keychain credential migration failed: %@", migrationError.localizedDescription ?: @"unknown error");
    }
    if ([NLAuthManager isLoggedIn]) {
        self.window.rootViewController = [[NLTabBarController alloc] init];
    } else {
        NLLoginViewController *loginVC = [[NLLoginViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loginVC];
        nav.navigationBarHidden = YES;
        self.window.rootViewController = nav;
    }
}

- (void)handleForceLogout {
    NLLoginViewController *loginVC = [[NLLoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loginVC];
    nav.navigationBarHidden = YES;
    CATransition *transition = [CATransition animation];
    transition.duration = 0.5;
    transition.type = kCATransitionFade;
    [self.window.layer addAnimation:transition forKey:kCATransition];
    self.window.rootViewController = nav;
}

- (void)sceneDidDisconnect:(UIScene *)scene {
  // Called as the scene is being released by the system.
  // This occurs shortly after the scene enters the background, or when its session is discarded.
  // Release any resources associated with this scene that can be re-created the next time the scene connects.
  // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
  // Called when the scene has moved from an inactive state to an active state.
  // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
  // Called when the scene will move from an active state to an inactive state.
  // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
  // Called as the scene transitions from the background to the foreground.
  // Use this method to undo the changes made on entering the background.
}




@end
