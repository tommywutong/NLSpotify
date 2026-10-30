//
//  AppDelegate.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/6.
//

#import "AppDelegate.h"
#import "NLHomeViewController.h"
#import "NLTabBarController.h"
#import "NLDataBaseManager.h"
#import "NLAuthManager.h"
#import "NLCacheManager.h"
#import "NLDownloadManager.h"
#import <IQKeyboardManager/IQKeyboardManager.h>
@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [NLDataBaseManager sharedManager];
    [NLDownloadManager sharedManager];
    [NLCacheManager sharedManager];
    [IQKeyboardManager sharedManager].enableAutoToolbar = NO;
    [IQKeyboardManager sharedManager].shouldResignOnTouchOutside = YES;
    NSString *cookie = [NLAuthManager currentCookie];
    if (cookie.length > 0) {
        NSLog(@"[App 启动] 已登录，当前 cookie 长度=%lu", (unsigned long)cookie.length);
    } else {
        NSLog(@"[App 启动] 未取到 cookie，当前为未登录状态");
    }
    return YES;
}

- (void)application:(UIApplication *)application
handleEventsForBackgroundURLSession:(NSString *)identifier
  completionHandler:(void (^)(void))completionHandler {
    [[NLDownloadManager sharedManager] handleBackgroundEventsForSessionIdentifier:identifier completionHandler:completionHandler];
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
  // Called when a new scene session is being created.
  // Use this method to select a configuration to create the new scene with.
  return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
  // Called when the user discards a scene session.
  // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
  // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
