//
//  NetWorkManager.h
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/15.
//

#import <Foundation/Foundation.h>
//#import "AFNetworking/AFNetworking.h"

@class NetWorkManager;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NLRequestMethod) {
  NLRequestMethodGET,
  NLRequestMethodPOST
};

typedef void(^SuccessBlock)(id _Nullable responseObject);
typedef void(^FailureBlock)(NSError *error);

/// 网易云 API 请求门面。
///
/// 统一注入当前 Cookie；业务码 301 或 HTTP 401 会进入单飞刷新队列，刷新成功后至多重试一次。
@interface NetWorkManager : NSObject

/// 返回全局共享的网络管理器。
/// - Returns: 唯一的 `NetWorkManager` 实例。
+ (instancetype)sharedManager;

/// 发起 GET 请求。
/// - Parameters:
///   - url: 相对 API 路径，而非完整 URL。
///   - params: 查询参数；可为空。
///   - success: 收到非认证失败响应后的回调。
///   - failure: 网络失败、认证刷新失败或重试后仍失效时的回调。
/// - Discussion: 回调线程由 AFNetworking 决定；调用方更新 UIKit 前应切回主线程。
- (void)GET:(NSString *)url
 parameters:(NSDictionary *)params
    success:(SuccessBlock)success
    failure:(FailureBlock)failure;

/// 发起 POST 请求。
/// - Parameters:
///   - url: 相对 API 路径，而非完整 URL。
///   - params: 请求参数；可为空。
///   - success: 收到非认证失败响应后的回调。
///   - failure: 网络失败、认证刷新失败或重试后仍失效时的回调。
/// - Discussion: POST 重放是否业务安全取决于服务端幂等性；本方法仅保证认证恢复后最多尝试一次重发。
- (void)POST:(NSString *)url
  parameters:(NSDictionary *)params
     success:(SuccessBlock)success
     failure:(FailureBlock)failure;

@end

NS_ASSUME_NONNULL_END
