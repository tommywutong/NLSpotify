#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol NLKeychainCredentialStoring <NSObject>
- (nullable NSString *)stringForAccount:(NSString *)account error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setString:(NSString *)string forAccount:(NSString *)account error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeStringForAccount:(NSString *)account error:(NSError * _Nullable * _Nullable)error;
@end

@interface NLKeychainCredentialStore : NSObject <NLKeychainCredentialStoring>
@end

NS_ASSUME_NONNULL_END
