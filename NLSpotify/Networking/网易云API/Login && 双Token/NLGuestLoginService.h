//
//  NLGuestLoginService.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/17.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLGuestLoginService : NSObject

/// 提取并验证游客登录响应中的非空 Cookie。
/// - Returns: 响应有效时返回 Cookie；无效响应返回 nil 并填写错误。
+ (nullable NSString *)cookieFromResponse:(id)response error:(NSError * _Nullable * _Nullable)error;

+ (void)anonymousLoginWithSuccess:(void(^)(NSDictionary *response))success
                          failure:(void(^)(NSError *error))failure;

@end

NS_ASSUME_NONNULL_END
