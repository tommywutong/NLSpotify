#import <XCTest/XCTest.h>
#import "NLAuthManager.h"
#import "NLGuestLoginService.h"

@protocol NLTestCredentialStoring <NSObject>
- (nullable NSString *)stringForAccount:(NSString *)account error:(NSError **)error;
- (BOOL)setString:(NSString *)value forAccount:(NSString *)account error:(NSError **)error;
- (BOOL)removeStringForAccount:(NSString *)account error:(NSError **)error;
@end

@interface NLAuthManager (CredentialMigrationTesting)
- (instancetype)initWithCredentialStore:(id<NLTestCredentialStoring>)credentialStore
                     legacyPreferences:(NSUserDefaults *)legacyPreferences;
- (BOOL)migrateLegacyCookieIfNeeded:(NSError **)error;
- (nullable NSString *)currentCookie;
- (BOOL)isLoggedIn;
- (void)logout;
@end

@interface NLGuestLoginService (ResponseParsingTesting)
+ (nullable NSString *)cookieFromResponse:(id)response error:(NSError **)error;
@end

@interface NLMemoryCredentialStore : NSObject <NLTestCredentialStoring>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@property (nonatomic, assign) BOOL rejectsWrites;
@property (nonatomic, assign) BOOL rejectsReads;
@end

@implementation NLMemoryCredentialStore
- (instancetype)init {
    if ((self = [super init])) _values = [NSMutableDictionary dictionary];
    return self;
}
- (NSString *)stringForAccount:(NSString *)account error:(NSError **)error {
    if (self.rejectsReads) {
        if (error) *error = [NSError errorWithDomain:@"NLMemoryCredentialStore" code:2 userInfo:nil];
        return nil;
    }
    return self.values[account];
}
- (BOOL)setString:(NSString *)value forAccount:(NSString *)account error:(NSError **)error {
    if (self.rejectsWrites) {
        if (error) *error = [NSError errorWithDomain:@"NLMemoryCredentialStore" code:1 userInfo:nil];
        return NO;
    }
    self.values[account] = value;
    return YES;
}
- (BOOL)removeStringForAccount:(NSString *)account error:(NSError **)error {
    [self.values removeObjectForKey:account];
    return YES;
}
@end

@interface NLAuthManagerTests : XCTestCase
@property (nonatomic, strong) NSMutableArray<NSString *> *suiteNames;
@end

@implementation NLAuthManagerTests

- (void)setUp {
    [super setUp];
    self.suiteNames = [NSMutableArray array];
}

- (void)tearDown {
    for (NSString *suiteName in self.suiteNames) {
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suiteName];
    }
    [super tearDown];
}

- (NSUserDefaults *)newLegacyPreferences {
    NSString *suiteName = [NSString stringWithFormat:@"com.nlspotify.tests.%@", NSUUID.UUID.UUIDString];
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    [self.suiteNames addObject:suiteName];
    return preferences;
}

- (NLAuthManager *)managerWithStore:(NLMemoryCredentialStore *)store preferences:(NSUserDefaults *)preferences {
    SEL selector = @selector(initWithCredentialStore:legacyPreferences:);
    if (![NLAuthManager instancesRespondToSelector:selector]) {
        XCTFail(@"NLAuthManager must support injected credential storage and preferences");
        return nil;
    }
    return [[NLAuthManager alloc] initWithCredentialStore:store legacyPreferences:preferences];
}

- (void)testLegacyCredentialIsRemovedOnlyAfterKeychainWriteSucceeds {
    NSUserDefaults *preferences = [self newLegacyPreferences];
    NSString *cookie = [NSString stringWithFormat:@"test-cookie-%@", NSUUID.UUID.UUIDString];
    [preferences setObject:cookie forKey:@"NLNeteaseCookie"];
    NLMemoryCredentialStore *store = [NLMemoryCredentialStore new];
    NLAuthManager *manager = [self managerWithStore:store preferences:preferences];
    if (!manager) return;

    NSError *error = nil;
    XCTAssertTrue([manager migrateLegacyCookieIfNeeded:&error]);
    XCTAssertNil(error);
    XCTAssertNil([preferences objectForKey:@"NLNeteaseCookie"]);
    XCTAssertEqualObjects(store.values[@"NLNeteaseCookie"], cookie);
}

- (void)testFailedMigrationKeepsLegacyCredentialUsable {
    NSUserDefaults *preferences = [self newLegacyPreferences];
    NSString *cookie = [NSString stringWithFormat:@"test-cookie-%@", NSUUID.UUID.UUIDString];
    [preferences setObject:cookie forKey:@"NLNeteaseCookie"];
    NLMemoryCredentialStore *store = [NLMemoryCredentialStore new];
    store.rejectsWrites = YES;
    NLAuthManager *manager = [self managerWithStore:store preferences:preferences];
    if (!manager) return;

    NSError *error = nil;
    XCTAssertFalse([manager migrateLegacyCookieIfNeeded:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([manager currentCookie], cookie);
    XCTAssertTrue([manager isLoggedIn]);
    XCTAssertEqualObjects([preferences objectForKey:@"NLNeteaseCookie"], cookie);
}
- (void)testMigrationFailsWhenKeychainReadFailsWithoutErrorOutput {
    NSUserDefaults *preferences = [self newLegacyPreferences];
    NLMemoryCredentialStore *store = [NLMemoryCredentialStore new];
    store.rejectsReads = YES;
    NLAuthManager *manager = [self managerWithStore:store preferences:preferences];
    if (!manager) return;

    XCTAssertFalse([manager migrateLegacyCookieIfNeeded:nil]);
}


- (void)testGuestLoginResponseWithoutCookieIsRejected {
    NSError *error = nil;
    SEL selector = @selector(cookieFromResponse:error:);
    if (![NLGuestLoginService respondsToSelector:selector]) {
        XCTFail(@"Guest response parsing must reject successful responses without a Cookie");
        return;
    }

    NSString *cookie = [NLGuestLoginService cookieFromResponse:@{@"code": @200, @"account": @{}} error:&error];
    XCTAssertNil(cookie);
    XCTAssertNotNil(error);
}

- (void)testLogoutRemovesKeychainAndLegacyCredential {
    NSUserDefaults *preferences = [self newLegacyPreferences];
    NLMemoryCredentialStore *store = [NLMemoryCredentialStore new];
    NSString *cookie = [NSString stringWithFormat:@"test-cookie-%@", NSUUID.UUID.UUIDString];
    store.values[@"NLNeteaseCookie"] = cookie;
    [preferences setObject:cookie forKey:@"NLNeteaseCookie"];
    NLAuthManager *manager = [self managerWithStore:store preferences:preferences];
    if (!manager) return;

    [manager logout];
    XCTAssertNil(store.values[@"NLNeteaseCookie"]);
    XCTAssertNil([preferences objectForKey:@"NLNeteaseCookie"]);
    XCTAssertFalse([manager isLoggedIn]);
}

- (void)testKeychainCredentialPersistsAcrossStoreInstances {
    Class storeClass = NSClassFromString(@"NLKeychainCredentialStore");
    XCTAssertNotNil(storeClass);
    if (!storeClass) return;

    id<NLTestCredentialStoring> writer = [[storeClass alloc] init];
    id<NLTestCredentialStoring> reader = [[storeClass alloc] init];
    NSString *account = [NSString stringWithFormat:@"test-account-%@", NSUUID.UUID.UUIDString];
    NSString *secret = [NSString stringWithFormat:@"test-cookie-%@", NSUUID.UUID.UUIDString];
    NSError *error = nil;

    XCTAssertTrue([writer setString:secret forAccount:account error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects([reader stringForAccount:account error:&error], secret);
    XCTAssertNil(error);
    XCTAssertTrue([reader removeStringForAccount:account error:&error]);
    XCTAssertNil(error);
}

@end
