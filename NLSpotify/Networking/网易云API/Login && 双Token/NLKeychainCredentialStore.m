#import "NLKeychainCredentialStore.h"
#import <Security/Security.h>

static NSString * const NLKeychainCredentialStoreErrorDomain = @"NLKeychainCredentialStoreErrorDomain";
static NSString * const NLKeychainCredentialService = @"com.nlspotify.auth";

static NSDictionary *NLKeychainQuery(NSString *account) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NLKeychainCredentialService,
        (__bridge id)kSecAttrAccount: account
    };
}

static NSError *NLKeychainError(OSStatus status) {
    NSString *message = (__bridge_transfer NSString *)SecCopyErrorMessageString(status, NULL);
    return [NSError errorWithDomain:NLKeychainCredentialStoreErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Keychain 操作失败"}];
}

@implementation NLKeychainCredentialStore

- (NSString *)stringForAccount:(NSString *)account error:(NSError **)error {
    NSMutableDictionary *query = [NLKeychainQuery(account) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return nil;
    if (status != errSecSuccess) {
        if (error) *error = NLKeychainError(status);
        return nil;
    }

    NSData *data = CFBridgingRelease(result);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!value && error) {
        *error = [NSError errorWithDomain:NLKeychainCredentialStoreErrorDomain
                                     code:errSecDecode
                                 userInfo:@{NSLocalizedDescriptionKey: @"Keychain 凭据不是有效 UTF-8 文本"}];
    }
    return value;
}

- (BOOL)setString:(NSString *)string forAccount:(NSString *)account error:(NSError **)error {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:NLKeychainCredentialStoreErrorDomain
                                                code:errSecParam
                                            userInfo:@{NSLocalizedDescriptionKey: @"Keychain 凭据无法编码"}];
        return NO;
    }

    NSDictionary *query = NLKeychainQuery(account);
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *addition = [query mutableCopy];
        addition[(__bridge id)kSecValueData] = data;
        addition[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addition, NULL);
        if (status == errSecDuplicateItem) {
            status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
        }
    }

    if (status != errSecSuccess) {
        if (error) *error = NLKeychainError(status);
        return NO;
    }
    return YES;
}

- (BOOL)removeStringForAccount:(NSString *)account error:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)NLKeychainQuery(account));
    if (status == errSecSuccess || status == errSecItemNotFound) return YES;
    if (error) *error = NLKeychainError(status);
    return NO;
}

@end
