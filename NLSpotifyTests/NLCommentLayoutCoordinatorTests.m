#import <XCTest/XCTest.h>
#import "NLCommentLayoutCoordinator.h"

@interface NLCommentLayoutCoordinatorTests : XCTestCase
@end
@implementation NLCommentLayoutCoordinatorTests

- (void)testLayoutGeometryIncludesFinalNewlineAndDoesNotClipLabel {
    UIFont *font = [UIFont systemFontOfSize:19];
    for (NSString *text in @[@"", @"一行", @"一行\n", @"👨‍👩‍👧‍👦 中英混排 é\n第二行\n", @"مرحبا بالعالم تعليق طويل"]) {
        NLCommentTextLayout *layout = [NLCommentTextLayout layoutForText:text width:145 font:font displayScale:3];
        UILabel *label = [UILabel new];
        label.numberOfLines = 0;
        label.font = font;
        label.attributedText = layout.collapsedText;
        CGFloat labelHeight = [label sizeThatFits:CGSizeMake(145, CGFLOAT_MAX)].height;
        XCTAssertGreaterThanOrEqual(layout.collapsedTextHeight + 0.5, labelHeight);
        XCTAssertEqualWithAccuracy(layout.collapsedTextHeight * 3, round(layout.collapsedTextHeight * 3), 0.001);
        if (!layout.needsExpansion) XCTAssertEqualObjects(layout.expandedText.string, text);
    }
}

- (void)testCacheSeparatesContentWidthAndFontWhileReusingMatchingResults {
    NLCommentLayoutCoordinator *coordinator = [NLCommentLayoutCoordinator new];
    UIFont *font = [UIFont systemFontOfSize:15];
    NSString *text = [@"评论 mixed 👩🏽‍🚀 " stringByPaddingToLength:500 withString:@"中文 WWW iii " startingAtIndex:0];
    XCTestExpectation *finished = [self expectationWithDescription:@"independent environments prepared"];
    finished.expectedFulfillmentCount = 4;
    __block NLCommentTextLayout *base;
    [coordinator requestLayoutForText:text width:130 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) {
        base = layout;
        XCTAssertTrue(NSThread.isMainThread);
        [coordinator requestLayoutForText:text width:130 font:font displayScale:2 completion:^(NLCommentTextLayout *cached) {
            XCTAssertEqual(cached, base);
            [finished fulfill];
        }];
    }];
    [coordinator requestLayoutForText:text width:300 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) {
        XCTAssertEqual(layout.width, 300);
        XCTAssertNotEqualObjects(layout.cacheKey, [NLCommentTextLayout cacheKeyForText:text width:130 font:font displayScale:2]);
        [finished fulfill];
    }];
    [coordinator requestLayoutForText:text width:130 font:[UIFont systemFontOfSize:30] displayScale:2 completion:^(NLCommentTextLayout *layout) {
        XCTAssertEqual(layout.font.pointSize, 30);
        XCTAssertGreaterThan(layout.collapsedTextHeight, font.lineHeight * 3);
        [finished fulfill];
    }];
    [coordinator requestLayoutForText:@"短评" width:130 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) {
        XCTAssertEqualObjects(layout.collapsedText.string, @"短评");
        XCTAssertFalse(layout.needsExpansion);
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5];
}

- (void)testDuplicateRequestsShareWorkAndMutableInputIsSnapshotted {
    NLCommentLayoutCoordinator *coordinator = [NLCommentLayoutCoordinator new];
    NSOperationQueue *queue = [coordinator valueForKey:@"queue"];
    queue.suspended = YES;
    NSMutableString *text = [NSMutableString stringWithString:@"原始内容"];
    UIFont *font = [UIFont systemFontOfSize:15];
    XCTestExpectation *finished = [self expectationWithDescription:@"shared snapshot delivered"];
    finished.expectedFulfillmentCount = 2;
    __block NLCommentTextLayout *first;
    for (NSUInteger index = 0; index < 2; index++) {
        [coordinator requestLayoutForText:text width:220 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) {
            XCTAssertTrue(NSThread.isMainThread);
            XCTAssertEqualObjects(layout.sourceText, @"原始内容");
            if (first) XCTAssertEqual(first, layout);
            first = layout;
            [finished fulfill];
        }];
    }
    XCTAssertEqual(queue.operationCount, 1u);
    [text setString:@"已经改变"];
    queue.suspended = NO;
    [self waitForExpectations:@[finished] timeout:5];
}

- (void)testInvalidationDropsOldWaitersWithoutLosingReplacementWithSameKey {
    NLCommentLayoutCoordinator *coordinator = [NLCommentLayoutCoordinator new];
    NSOperationQueue *queue = [coordinator valueForKey:@"queue"];
    queue.suspended = YES;
    UIFont *font = [UIFont systemFontOfSize:15];
    XCTestExpectation *obsolete = [self expectationWithDescription:@"obsolete callback suppressed"];
    obsolete.inverted = YES;
    [coordinator requestLayoutForText:@"相同内容" width:220 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) { [obsolete fulfill]; }];
    [coordinator invalidate];
    XCTestExpectation *current = [self expectationWithDescription:@"replacement delivered"];
    [coordinator requestLayoutForText:@"相同内容" width:220 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) {
        XCTAssertEqualObjects(layout.collapsedText.string, @"相同内容");
        [current fulfill];
    }];
    queue.suspended = NO;
    [self waitForExpectations:@[current] timeout:5];
    [self waitForExpectations:@[obsolete] timeout:0.1];
    // A queued cache-hit callback is subject to the same invalidation rule.
    XCTestExpectation *oldHit = [self expectationWithDescription:@"queued cache hit invalidated"];
    oldHit.inverted = YES;
    [coordinator requestLayoutForText:@"相同内容" width:220 font:font displayScale:2 completion:^(NLCommentTextLayout *layout) { [oldHit fulfill]; }];
    [coordinator invalidate];
    [self waitForExpectations:@[oldHit] timeout:0.1];
}
@end
