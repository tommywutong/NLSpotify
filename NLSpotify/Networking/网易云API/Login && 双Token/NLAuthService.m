//
//  NLAuthService.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/25.
//

#import "NLAuthService.h"
#import "NLAuthManager.h"
#import "NetWorkManager.h"

static NSError *NLAuthRefreshError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NLAuthService"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation NLAuthService

+ (void)refreshLoginWithSuccess:(void(^)(void))success
                        failure:(void(^)(NSError *error))failure {
    NSString *path = @"/login/refresh";
    [[NetWorkManager sharedManager] GET:path parameters:@{} success:^(id responseObject) {
        if (![responseObject isKindOfClass:NSDictionary.class]) {
            if (failure) failure(NLAuthRefreshError(-1, @"Cookie 刷新响应格式错误"));
            return;
        }

        NSDictionary *response = responseObject;
        NSInteger code = [response[@"code"] integerValue];
        if (code != 200) {
            NSString *message = [response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : @"Cookie 刷新失败";
            if (failure) failure(NLAuthRefreshError(code, message));
            return;
        }

        id value = response[@"cookie"];
        if (![value isKindOfClass:NSString.class] || [value length] == 0) {
            if (failure) failure(NLAuthRefreshError(-2, @"Cookie 刷新响应缺少新凭据"));
            return;
        }

        NSError *credentialError = nil;
        if (![NLAuthManager setCookie:value error:&credentialError]) {
            if (failure) failure(credentialError ?: NLAuthRefreshError(-3, @"无法保存刷新后的 Cookie"));
            return;
        }
        if (success) success();
    } failure:^(NSError *error) {
        if (failure) failure(error);
    }];
}

@end
