//
//  NLAuthService.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Cookie 续期服务。
@interface NLAuthService : NSObject

/// 请求服务端刷新当前 Cookie。
/// - Parameters:
///   - success: 新 Cookie 成功保存后调用。
///   - failure: 刷新请求或响应解析失败时调用。
/// - Discussion: 此方法通常只由 `NetWorkManager` 的单飞刷新队列发起；不要由每个业务请求并发调用。
+ (void)refreshLoginWithSuccess:(void(^)(void))success
                        failure:(void(^)(NSError *error))failure;

@end

NS_ASSUME_NONNULL_END
