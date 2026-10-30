//
//  NLAuthManager.h
//  NLSpotify
//
//  统一管理登录凭证（cookie）、登录状态与登出，双 token 时 refresh 成功后也通过此处写回 cookie。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 强制登出（如 refresh 失败、重试仍 401 等），监听后应切到登录页
FOUNDATION_EXPORT NSNotificationName const NLForceLogoutNotification;

/// 当前项目 Cookie 凭证和登录态管理器。
///
/// 这不是 OAuth2 accessToken/refreshToken 模型；网络层刷新成功后通过本类替换 Cookie。
@interface NLAuthManager : NSObject

/// 返回当前持久化的 Cookie。
/// - Returns: 未登录或凭证缺失时为 `nil`。
+ (NSString * _Nullable)currentCookie;

/// 更新或清除当前 Cookie。
/// - Parameters:
///   - cookie: 新 Cookie；传入 `nil` 会清除当前凭据。
///   - error: Keychain 读写失败时返回错误；失败时不丢弃旧凭据。
+ (BOOL)setCookie:(NSString * _Nullable)cookie error:(NSError * _Nullable * _Nullable)error;

/// 将旧 `NSUserDefaults` Cookie 幂等迁移到 Keychain。
/// - Returns: 迁移或确认无需迁移成功时为 YES；失败时保留旧值。
+ (BOOL)migrateLegacyCookieIfNeeded:(NSError * _Nullable * _Nullable)error;

/// 保存游客登录返回的账户信息；只有本地 Cookie 存在时才保存。
/// - Parameter account: 游客登录响应中的账户对象；为空时移除本地账户对象。
+ (void)setLoginStateWithAccount:(id _Nullable)account;

/// 根据当前 Cookie 凭据推导本地登录态。
/// - Returns: 持有 Keychain 或待迁移 legacy Cookie 时为 YES；不验证服务端会话是否仍有效。
+ (BOOL)isLoggedIn;

/// 清除 Keychain Cookie、legacy Cookie 和账户信息。
/// - Discussion: 强制登出通知由调用方或网络层另行发送。
+ (void)logout;

@end

NS_ASSUME_NONNULL_END
