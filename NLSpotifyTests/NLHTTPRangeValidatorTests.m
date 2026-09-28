#import <XCTest/XCTest.h>
#import "NLHTTPRangeValidator.h"

@interface NLHTTPRangeValidatorTests : XCTestCase
@end

@implementation NLHTTPRangeValidatorTests

- (NSHTTPURLResponse *)responseWithStatus:(NSInteger)status
                                  headers:(NSDictionary<NSString *, NSString *> *)headers
                             expectedSize:(long long)expectedSize {
    NSMutableDictionary *responseHeaders = [headers mutableCopy] ?: [NSMutableDictionary dictionary];
    if (expectedSize > 0) responseHeaders[@"Content-Length"] = [NSString stringWithFormat:@"%lld", expectedSize];
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com/audio.mp3"]
                                       statusCode:status
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:responseHeaders];
}

- (void)testAccepts206WhoseContentRangeMatchesRequestedOffset {
    NSHTTPURLResponse *response = [self responseWithStatus:206
                                                    headers:@{@"Content-Range": @"bytes 100-199/1000"}
                                               expectedSize:100];
    long long responseStart = -1;
    long long totalLength = -1;

    XCTAssertTrue([NLHTTPRangeValidator validateResponse:response
                                         requestedOffset:100
                                         requestedLength:100
                                           responseStart:&responseStart
                                            totalLength:&totalLength]);
    XCTAssertEqual(responseStart, 100);
    XCTAssertEqual(totalLength, 1000);
}

- (void)testRejects206ExtendingBeyondRequestedLength {
    NSHTTPURLResponse *response = [self responseWithStatus:206
                                                    headers:@{@"Content-Range": @"bytes 100-299/1000"}
                                               expectedSize:200];
    XCTAssertFalse([NLHTTPRangeValidator validateResponse:response
                                          requestedOffset:100
                                          requestedLength:100
                                            responseStart:NULL
                                             totalLength:NULL]);
}

- (void)testRejects206WhoseContentRangeStartsAtAnotherOffset {
    NSHTTPURLResponse *response = [self responseWithStatus:206
                                                    headers:@{@"Content-Range": @"bytes 0-99/1000"}
                                               expectedSize:100];

    XCTAssertFalse([NLHTTPRangeValidator validateResponse:response
                                          requestedOffset:100
                                          requestedLength:100
                                            responseStart:NULL
                                             totalLength:NULL]);
}

- (void)testRejectsNonSuccessResponses {
    NSHTTPURLResponse *response = [self responseWithStatus:403
                                                    headers:@{}
                                               expectedSize:128];

    XCTAssertFalse([NLHTTPRangeValidator validateResponse:response
                                          requestedOffset:0
                                          requestedLength:128
                                            responseStart:NULL
                                             totalLength:NULL]);
}

- (void)testAllows200OnlyForARequestStartingAtZero {
    NSHTTPURLResponse *response = [self responseWithStatus:200
                                                    headers:@{}
                                               expectedSize:1000];

    XCTAssertTrue([NLHTTPRangeValidator validateResponse:response
                                         requestedOffset:0
                                         requestedLength:1000
                                           responseStart:NULL
                                            totalLength:NULL]);
    XCTAssertFalse([NLHTTPRangeValidator validateResponse:response
                                          requestedOffset:100
                                          requestedLength:100
                                            responseStart:NULL
                                             totalLength:NULL]);
}

@end
