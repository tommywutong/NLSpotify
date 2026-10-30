#import "NLCommentTextLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// Page-owned. Requests/invalidation are main-thread-only; completions are asynchronous on main.
@interface NLCommentLayoutCoordinator : NSObject
- (void)requestLayoutForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale completion:(void (^)(NLCommentTextLayout *layout))completion;
/// Cancels outstanding work/waiters and clears this page's cache. Old work cannot publish results.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
