//
//  NLCommentTextFolder.m
//  NLSpotify
//

#import "NLCommentTextFolder.h"

@implementation NLCommentTextFolder

+ (NSDictionary<NSAttributedStringKey, id> *)attributesForFont:(UIFont *)font {
    if (!font) font = [UIFont systemFontOfSize:15];
    return @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor labelColor]
    };
}

+ (NSAttributedString *)attributedStringForText:(NSString *)text font:(UIFont *)font {
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                            attributes:[self attributesForFont:font]];
}

+ (NSUInteger)lineCountForAttributedString:(NSAttributedString *)attributedString width:(CGFloat)width {
    if (attributedString.length == 0) return 0;
    if (width <= 0) return NSUIntegerMax;
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:attributedString];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [storage addLayoutManager:layoutManager];
    [layoutManager addTextContainer:container];
    NSRange glyphRange = [layoutManager glyphRangeForTextContainer:container];
    __block NSUInteger count = 0;
    [layoutManager enumerateLineFragmentsForGlyphRange:glyphRange
                                            usingBlock:^(CGRect rect, CGRect usedRect, NSTextContainer *textContainer, NSRange fragmentRange, BOOL *stop) {
        count += 1;
    }];
    return count;
}

+ (BOOL)textNeedExpand:(NSString *)text width:(CGFloat)width font:(UIFont *)font {
    if (text.length == 0 || width <= 0) return NO;
    return [self lineCountForAttributedString:[self attributedStringForText:text font:font] width:width] > 3;
}

+ (NSArray<NSNumber *> *)composedCharacterBoundariesForText:(NSString *)text {
    NSMutableArray<NSNumber *> *boundaries = [NSMutableArray arrayWithObject:@0];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        [boundaries addObject:@(NSMaxRange(substringRange))];
    }];
    return boundaries;
}

+ (NSAttributedString *)collapsedText:(NSString *)text font:(UIFont *)font width:(CGFloat)width {
    if (text.length == 0) return [self attributedStringForText:@"" font:font];
    if (width <= 0) return [self attributedStringForText:@"" font:font];
    if (![self textNeedExpand:text width:width font:font]) {
        return [self attributedStringForText:text font:font];
    }

    NSString *suffix = @"...展开";
    NSDictionary *attributes = [self attributesForFont:font];
    NSAttributedString *(^candidate)(NSUInteger) = ^NSAttributedString *(NSUInteger end) {
        NSString *prefix = [text substringToIndex:end];
        NSString *value = [prefix stringByAppendingString:suffix];
        NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:value attributes:attributes];
        [result addAttribute:NSForegroundColorAttributeName
                       value:[UIColor systemBlueColor]
                       range:NSMakeRange(result.length - suffix.length, suffix.length)];
        return result;
    };

    NSAttributedString *suffixOnly = candidate(0);
    if ([self lineCountForAttributedString:suffixOnly width:width] > 3) {
        NSAttributedString *fallback = [[NSAttributedString alloc] initWithString:@"…" attributes:attributes];
        return [self lineCountForAttributedString:fallback width:width] <= 3 ? fallback : [self attributedStringForText:@"" font:font];
    }

    NSArray<NSNumber *> *boundaries = [self composedCharacterBoundariesForText:text];
    NSInteger low = 0;
    NSInteger high = (NSInteger)boundaries.count - 1;
    NSInteger best = 0;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        NSUInteger end = boundaries[middle].unsignedIntegerValue;
        if ([self lineCountForAttributedString:candidate(end) width:width] <= 3) {
            best = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }

    return candidate(boundaries[best].unsignedIntegerValue);
}

+ (NSAttributedString *)expandedText:(NSString *)text font:(UIFont *)font {
    NSString *suffix = @" 收起";
    NSString *value = [NSString stringWithFormat:@"%@%@", text ?: @"", suffix];
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:value
                                                                                 attributes:[self attributesForFont:font]];
    [result addAttribute:NSForegroundColorAttributeName
                   value:[UIColor systemBlueColor]
                   range:NSMakeRange(result.length - suffix.length, suffix.length)];
    return result;
}

@end
