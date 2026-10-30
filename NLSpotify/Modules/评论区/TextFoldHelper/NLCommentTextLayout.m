#import "NLCommentTextLayout.h"
#import "NLCommentTextFolder.h"
#import <math.h>

@implementation NLCommentTextLayout

+ (NSString *)cacheKeyForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale {
    // Exact geometry, not a rounded width that could make the last glyph overflow.
    return [NSString stringWithFormat:@"fold-v1|%a|%a|%@|%a|%@|%@", (double)width,
            (double)displayScale, font.fontName, (double)font.pointSize,
            font.fontDescriptor.fontAttributes, text ?: @""];
}

+ (CGFloat)heightForText:(NSAttributedString *)text width:(CGFloat)width scale:(CGFloat)scale {
    if (text.length == 0 || width <= 0) return 0;
    // Match UILabel's string-drawing metrics, including fallback fonts in mixed emoji text.
    // NSLayoutManager.usedRect can differ over many lines; using that height clips UILabel.
    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                    context:nil];
    CGFloat height = CGRectGetHeight(rect);
    return ceil(height * scale) / scale;
}

+ (instancetype)layoutForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font displayScale:(CGFloat)displayScale {
    NLCommentTextLayout *result = [self new];
    result->_sourceText = [text copy] ?: @"";
    result->_width = isfinite(width) ? MAX(0, width) : 0;
    result->_font = font;
    result->_displayScale = isfinite(displayScale) && displayScale > 0 ? displayScale : 1;
    result->_cacheKey = [self cacheKeyForText:result.sourceText width:result.width font:font displayScale:result.displayScale];
    result->_collapsedText = [NLCommentTextFolder collapsedText:result.sourceText font:font width:result.width];
    result->_needsExpansion = result.width > 0 && ![result.collapsedText.string isEqualToString:result.sourceText];
    result->_expandedText = result.needsExpansion ? [NLCommentTextFolder expandedText:result.sourceText font:font] : result.collapsedText;
    result->_collapsedTextHeight = [self heightForText:result.collapsedText width:result.width scale:result.displayScale];
    result->_expandedTextHeight = result.needsExpansion ? [self heightForText:result.expandedText width:result.width scale:result.displayScale] : result.collapsedTextHeight;
    return result;
}
@end
