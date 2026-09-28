#import "NLHTTPRangeValidator.h"

@implementation NLHTTPRangeValidator

+ (BOOL)validateResponse:(NSHTTPURLResponse *)response
         requestedOffset:(long long)requestedOffset
         requestedLength:(NSInteger)requestedLength
           responseStart:(long long *)responseStart
            totalLength:(long long *)totalLength {
    if (!response || requestedOffset < 0 || requestedLength <= 0) return NO;

    NSInteger statusCode = response.statusCode;
    if (statusCode == 200) {
        if (requestedOffset != 0) return NO;
        long long expectedLength = response.expectedContentLength;
        if (expectedLength <= 0) return NO;
        if (responseStart) *responseStart = 0;
        if (totalLength) *totalLength = expectedLength;
        return YES;
    }

    if (statusCode != 206) return NO;

    NSString *contentRange = nil;
    for (NSString *key in response.allHeaderFields) {
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            contentRange = response.allHeaderFields[key];
            break;
        }
    }
    if (contentRange.length == 0) return NO;

    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^bytes[ \\t]+([0-9]+)-([0-9]+)/([0-9]+)$"
                                                                                   options:0
                                                                                     error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:contentRange
                                                         options:0
                                                           range:NSMakeRange(0, contentRange.length)];
    if (!match || match.numberOfRanges != 4) return NO;

    long long start = [[contentRange substringWithRange:[match rangeAtIndex:1]] longLongValue];
    long long end = [[contentRange substringWithRange:[match rangeAtIndex:2]] longLongValue];
    long long total = [[contentRange substringWithRange:[match rangeAtIndex:3]] longLongValue];
    if (start < 0 || end < start || total <= end || start != requestedOffset) return NO;

    long long responseLength = end - start + 1;
    if (responseLength > requestedLength) return NO;
    long long expectedLength = response.expectedContentLength;
    if (expectedLength > 0 && expectedLength != responseLength) return NO;

    if (responseStart) *responseStart = start;
    if (totalLength) *totalLength = total;
    return YES;
}

@end
