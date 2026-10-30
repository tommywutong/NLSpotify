//
//  NLAuthManager.m
//  NLSpotify
//

#import "NLAuthManager.h"
#import "NLKeychainCredentialStore.h"

NSNotificationName const NLForceLogoutNotification = @"NLForceLogoutNotification";
static NSString * const kCookieKey       = @"NLNeteaseCookie";
static NSString * const kIsLoggedInKey   = @"isLoggedIn";
static NSString * const kUserAccountKey  = @"userAccount";

@interface NLAuthManager ()
@property (nonatomic, strong) id<NLKeychainCredentialStoring> credentialStore;
@property (nonatomic, strong) NSUserDefaults *legacyPreferences;
- (instancetype)initWithCredentialStore:(id<NLKeychainCredentialStoring>)credentialStore
                     legacyPreferences:(NSUserDefaults *)legacyPreferences;
- (NSString *)currentCookie;
- (BOOL)setCookie:(NSString *)cookie error:(NSError **)error;
- (BOOL)migrateLegacyCookieIfNeeded:(NSError **)error;
- (BOOL)isLoggedIn;
- (void)logout;
@end

@implementation NLAuthManager

+ (instancetype)sharedManager {
    static NLAuthManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[NLAuthManager alloc] initWithCredentialStore:[NLKeychainCredentialStore new]
                                               legacyPreferences:[NSUserDefaults standardUserDefaults]];
    });
    return manager;
}

- (instancetype)initWithCredentialStore:(id<NLKeychainCredentialStoring>)credentialStore
                     legacyPreferences:(NSUserDefaults *)legacyPreferences {
    if ((self = [super init])) {
        _credentialStore = credentialStore;
        _legacyPreferences = legacyPreferences;
    }
    return self;
}

+ (NSString *)currentCookie {
    return [[self sharedManager] currentCookie];
}

- (NSString *)currentCookie {
    NSError *readError = nil;
    NSString *cookie = [self.credentialStore stringForAccount:kCookieKey error:&readError];
    if (cookie.length > 0) return cookie;

    NSString *legacyCookie = [self.legacyPreferences stringForKey:kCookieKey];
    if (legacyCookie.length == 0) return nil;
    if (readError) return legacyCookie;

    NSError *migrationError = nil;
    if (![self migrateLegacyCookieIfNeeded:&migrationError]) return legacyCookie;
    return [self.credentialStore stringForAccount:kCookieKey error:nil] ?: legacyCookie;
}

+ (BOOL)setCookie:(NSString *)cookie error:(NSError **)error {
    return [[self sharedManager] setCookie:cookie error:error];
}

- (BOOL)setCookie:(NSString *)cookie error:(NSError **)error {
    if (error) *error = nil;
    if (cookie.length == 0) {
        if (![self.credentialStore removeStringForAccount:kCookieKey error:error]) return NO;
        [self.legacyPreferences removeObjectForKey:kCookieKey];
        [self.legacyPreferences removeObjectForKey:kIsLoggedInKey];
        [self.legacyPreferences removeObjectForKey:kUserAccountKey];
        return YES;
    }

    if (![self.credentialStore setString:cookie forAccount:kCookieKey error:error]) return NO;
    [self.legacyPreferences removeObjectForKey:kCookieKey];
    [self.legacyPreferences removeObjectForKey:kIsLoggedInKey];
    return YES;
}

+ (BOOL)migrateLegacyCookieIfNeeded:(NSError **)error {
    return [[self sharedManager] migrateLegacyCookieIfNeeded:error];
}

- (BOOL)migrateLegacyCookieIfNeeded:(NSError **)error {
    if (error) *error = nil;
    NSError *keychainReadError = nil;
    NSString *cookie = [self.credentialStore stringForAccount:kCookieKey error:&keychainReadError];
    if (cookie.length > 0) {
        [self.legacyPreferences removeObjectForKey:kCookieKey];
        [self.legacyPreferences removeObjectForKey:kIsLoggedInKey];
        return YES;
    }
    if (keychainReadError) {
        if (error) *error = keychainReadError;
        return NO;
    }
    NSString *legacyCookie = [self.legacyPreferences stringForKey:kCookieKey];
    if (legacyCookie.length == 0) {
        [self.legacyPreferences removeObjectForKey:kIsLoggedInKey];
        return YES;
    }

    if (![self.credentialStore setString:legacyCookie forAccount:kCookieKey error:error]) return NO;
    [self.legacyPreferences removeObjectForKey:kCookieKey];
    [self.legacyPreferences removeObjectForKey:kIsLoggedInKey];
    return YES;
}

+ (void)setLoginStateWithAccount:(id)account {
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    if (![self isLoggedIn] || !account) {
        [preferences removeObjectForKey:kUserAccountKey];
        return;
    }
    [preferences setObject:account forKey:kUserAccountKey];
}

+ (BOOL)isLoggedIn {
    return [self currentCookie].length > 0;
}
- (BOOL)isLoggedIn {
    return [self currentCookie].length > 0;
}

+ (void)logout {
    [[self sharedManager] logout];
}

- (void)logout {
    [self setCookie:nil error:nil];
}

@end
