//
//  NLGuestLoginService.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/1/17.
//

#import "NLGuestLoginService.h"
#import "NetWorkManager.h"

static NSError *NLGuestLoginError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NLGuestLoginService"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation NLGuestLoginService

+ (NSString *)cookieFromResponse:(id)response error:(NSError **)error {
    if (error) *error = nil;
    if (![response isKindOfClass:NSDictionary.class]) {
        if (error) *error = NLGuestLoginError(-1, @"游客登录响应格式错误");
        return nil;
    }

    NSDictionary *dictionary = response;
    NSInteger code = [dictionary[@"code"] integerValue];
    if (code != 200) {
        NSString *message = [dictionary[@"message"] isKindOfClass:NSString.class] ? dictionary[@"message"] : @"游客登录失败";
        if (error) *error = NLGuestLoginError(code, message);
        return nil;
    }

    id value = dictionary[@"cookie"];
    if (![value isKindOfClass:NSString.class] || [value length] == 0) {
        if (error) *error = NLGuestLoginError(-2, @"游客登录响应缺少 Cookie");
        return nil;
    }
    return value;
}

+ (void)anonymousLoginWithSuccess:(void(^)(NSDictionary *))success
                          failure:(void(^)(NSError *))failure {
    [[NetWorkManager sharedManager] GET:@"/register/anonimous"
                             parameters:@{}
                                success:^(id responseObject) {
        NSError *error = nil;
        if (![self cookieFromResponse:responseObject error:&error]) {
            if (failure) failure(error);
            return;
        }
        if (success) success(responseObject);
    } failure:^(NSError *error) {
        if (failure) failure(error);
    }];
}

@end
