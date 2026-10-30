#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLPlaybackHistoryMetadata : NSObject

@property (nonatomic, copy) NSString *songId;
@property (nonatomic, assign) NSTimeInterval lastPlayedAt;
@property (nonatomic, assign) NSInteger playCount;

@end

NS_ASSUME_NONNULL_END
