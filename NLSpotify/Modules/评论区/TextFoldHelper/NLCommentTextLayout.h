#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable text and geometry for one content/width/font environment; safe to cache across cells.
@interface NLCommentTextLayout : NSObject
@property (nonatomic, copy, readonly) NSString *cacheKey;
@property (nonatomic, copy, readonly) NSString *sourceText;
@property (nonatomic, readonly) CGFloat width;
@property (nonatomic, strong, readonly) UIFont *font;
@property (nonatomic, readonly) CGFloat displayScale;
@property (nonatomic, readonly) BOOL needsExpansion;
@property (nonatomic, copy, readonly) NSAttributedString *collapsedText;
@property (nonatomic, copy, readonly) NSAttributedString *expandedText;
@property (nonatomic, readonly) CGFloat collapsedTextHeight;
@property (nonatomic, readonly) CGFloat expandedTextHeight;
+ (NSString *)cacheKeyForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale;
/// Uses task-local text layout and string measurement without views. Call off-main for list preparation.
+ (instancetype)layoutForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale;
@end

NS_ASSUME_NONNULL_END
