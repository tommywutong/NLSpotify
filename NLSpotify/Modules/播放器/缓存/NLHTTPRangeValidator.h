#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLHTTPRangeValidator : NSObject

+ (BOOL)validateResponse:(NSHTTPURLResponse *)response
         requestedOffset:(long long)requestedOffset
         requestedLength:(NSInteger)requestedLength
           responseStart:(nullable long long *)responseStart
            totalLength:(nullable long long *)totalLength;

@end

NS_ASSUME_NONNULL_END
