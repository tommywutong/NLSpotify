#import <XCTest/XCTest.h>
#import "NLCommentListViewController.h"
#import "NLCommentModel.h"
#import "NLCommentCell.h"
#import "NLCommentLayoutCoordinator.h"
#import <QuartzCore/QuartzCore.h>

@interface NLCommentLayoutFrameWaiter : NSObject
@property (nonatomic, strong) XCTestExpectation *expectation;
@property (nonatomic) NSUInteger remaining;
@end
@implementation NLCommentLayoutFrameWaiter
- (void)tick:(CADisplayLink *)link {
    if (--self.remaining == 0) {
        [link invalidate];
        [self.expectation fulfill];
    }
}
@end

@interface NLCommentListViewController (ListLayoutTesting)
- (void)loadData;
- (void)acceptComments:(NSArray<NLCommentModel *> *)comments total:(NSInteger)total offset:(NSInteger)offset;
- (void)toggleComment:(NLCommentModel *)comment;
- (void)updateLayoutEnvironment;
- (NLCommentTextLayout *)layoutForComment:(NLCommentModel *)comment;
@end

// Replace only the external network boundary; table, lifecycle and async layout remain real.
@interface NLCommentFixtureController : NLCommentListViewController
@end
@implementation NLCommentFixtureController
- (void)loadData {}
@end

@interface NLCommentListLayoutTests : XCTestCase
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *previousWindow;
@property (nonatomic, strong) NLCommentFixtureController *controller;
@end

@implementation NLCommentListLayoutTests
- (void)setUp {
    [super setUp];
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
    self.previousWindow = scene.keyWindow;
    self.window = [[UIWindow alloc] initWithWindowScene:scene];
    UIViewController *container = [UIViewController new];
    self.window.rootViewController = container;
    [self.window makeKeyAndVisible];
    self.controller = [[NLCommentFixtureController alloc] initWithResourceId:1 resourceType:NLCommentListResourceTypeSong title:@"评论测试"];
    [container addChildViewController:self.controller];
    [container.view addSubview:self.controller.view];
    self.controller.view.frame = CGRectMake(0, 0, 390, 700);
    [self.controller didMoveToParentViewController:container];
    [self.controller.view layoutIfNeeded];
}

- (void)tearDown {
    self.window.hidden = YES;
    [self.previousWindow makeKeyAndVisible];
    self.controller = nil;
    self.window = nil;
    self.previousWindow = nil;
    [super tearDown];
}

- (void)waitFor:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(condition());
}

- (UITableView *)table { return [self.controller valueForKey:@"tableView"]; }

- (NSArray<NLCommentModel *> *)commentsFrom:(NSInteger)start count:(NSInteger)count {
    NSMutableArray *result = [NSMutableArray array];
    for (NSInteger index = start; index < start + count; index++) {
        NLCommentModel *comment = [NLCommentModel new];
        comment.commentId = index + 1;
        comment.content = [[NSString stringWithFormat:@"评论 %ld 中文 emoji 👩🏽‍🚀 ", (long)index] stringByPaddingToLength:700 withString:@"正文 mixed WWW iii 测试 " startingAtIndex:0];
        comment.user = [NLCommentUserModel new];
        comment.user.nickname = @"测试用户";
        [result addObject:comment];
    }
    return result;
}

- (void)testInitialPageIsNotExposedBeforeItsLayoutsArePrepared {
    NLCommentLayoutCoordinator *coordinator = [self.controller valueForKey:@"layoutCoordinator"];
    NSOperationQueue *queue = [coordinator valueForKey:@"queue"];
    queue.suspended = YES;
    NSArray *comments = [self commentsFrom:0 count:20];
    [self.controller acceptComments:comments total:20 offset:0];
    XCTAssertEqual([self.table numberOfRowsInSection:0], 0);
    queue.suspended = NO;
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 20; }];
    [self.table layoutIfNeeded];
    NLCommentCell *cell = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    XCTAssertEqualObjects(cell.textLayout.sourceText, ((NLCommentModel *)comments[0]).content);
    XCTAssertEqualWithAccuracy(cell.textLayout.width, 316, 0.01);
}

- (void)testAppendingAndRepeatedExpansionPreserveReadingAnchor {
    NSArray<NLCommentModel *> *comments = [self commentsFrom:0 count:30];
    [self.controller acceptComments:comments total:30 offset:0];
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 30; }];
    [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:8 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    [self.table layoutIfNeeded];
    NSIndexPath *anchor = [[self.table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)] firstObject];
    CGFloat distance = CGRectGetMinY([self.table rectForRowAtIndexPath:anchor]) - self.table.contentOffset.y;
    [self.controller acceptComments:[self commentsFrom:30 count:10] total:40 offset:30];
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 40; }];
    XCTAssertEqualWithAccuracy(CGRectGetMinY([self.table rectForRowAtIndexPath:anchor]) - self.table.contentOffset.y, distance, 1);
    CGFloat originalHeight = CGRectGetHeight([self.table rectForRowAtIndexPath:anchor]);
    for (NSUInteger index = 0; index < 6; index++) {
        [self.controller toggleComment:comments[anchor.row]];
        XCTAssertTrue(comments[anchor.row].isExpanded);
        XCTAssertGreaterThan(CGRectGetHeight([self.table rectForRowAtIndexPath:anchor]), originalHeight);
        [self.controller toggleComment:comments[anchor.row]];
        XCTAssertFalse(comments[anchor.row].isExpanded);
        XCTAssertEqualWithAccuracy(CGRectGetHeight([self.table rectForRowAtIndexPath:anchor]), originalHeight, 1);
        XCTAssertEqualWithAccuracy(CGRectGetMinY([self.table rectForRowAtIndexPath:anchor]) - self.table.contentOffset.y, distance, 1);
    }
}

- (void)waitForDisplayLayouts {
    NLCommentLayoutFrameWaiter *waiter = [NLCommentLayoutFrameWaiter new];
    waiter.expectation = [self expectationWithDescription:@"table update rendered"];
    waiter.remaining = 3;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:waiter selector:@selector(tick:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self waitForExpectations:@[waiter.expectation] timeout:3];
    [link invalidate];
}

- (void)testTogglingLowerCommentKeepsUpperVisibleCellAtSameScreenPosition {
    // Include the real navigation-bar inset and mixed heights, not just equal-height rows at the top.
    [self.controller willMoveToParentViewController:nil];
    [self.controller.view removeFromSuperview];
    [self.controller removeFromParentViewController];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:self.controller];
    [self.window layoutIfNeeded];
    [self.controller.view layoutIfNeeded];
    NSArray<NLCommentModel *> *comments = [self commentsFrom:0 count:150];
    for (NSUInteger index = 0; index < comments.count; index += 4) comments[index].content = @"短评论";
    [self.controller acceptComments:comments total:150 offset:0];
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 150; }];
    [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:50 inSection:0]
                    atScrollPosition:UITableViewScrollPositionTop animated:NO];
    [self.table layoutIfNeeded];
    [self.table setContentOffset:CGPointMake(0, self.table.contentOffset.y + 23) animated:NO];
    [self waitForDisplayLayouts];

    CGFloat visibleTop = self.table.contentOffset.y + self.table.adjustedContentInset.top;
    NSIndexPath *upperPath = nil;
    for (NSIndexPath *path in [self.table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]) {
        UITableViewCell *cell = [self.table cellForRowAtIndexPath:path];
        if (CGRectGetMaxY(cell.frame) > visibleTop + 1) { upperPath = path; break; }
    }
    XCTAssertNotNil(upperPath);
    if (!upperPath) return;
    NSInteger target = upperPath.row + 2;
    if (target % 4 == 0) target += 1;
    UITableViewCell *upper = [self.table cellForRowAtIndexPath:upperPath];
    CGFloat screenY = [self.table convertRect:upper.frame toView:self.window].origin.y;
    CGFloat upperHeight = CGRectGetHeight(upper.frame);
    for (NSUInteger index = 0; index < 4; index++) {
        [self.controller toggleComment:comments[target]];
        XCTAssertEqual(comments[target].isExpanded, index % 2 == 0);
        upper = [self.table cellForRowAtIndexPath:upperPath];
        XCTAssertNotNil(upper);
        XCTAssertEqualWithAccuracy([self.table convertRect:upper.frame toView:self.window].origin.y, screenY, 0.5);
        [self waitForDisplayLayouts];
        upper = [self.table cellForRowAtIndexPath:upperPath];
        XCTAssertNotNil(upper);
        XCTAssertEqualWithAccuracy(CGRectGetHeight(upper.frame), upperHeight, 0.5);
        XCTAssertEqualWithAccuracy([self.table convertRect:upper.frame toView:self.window].origin.y, screenY, 0.5);
    }
}

- (void)testWidthContentAndDynamicTypeChangesRejectOldLayoutEnvironment {
    NLCommentLayoutCoordinator *coordinator = [self.controller valueForKey:@"layoutCoordinator"];
    NSOperationQueue *queue = [coordinator valueForKey:@"queue"];
    queue.suspended = YES;
    NLCommentModel *comment = [self commentsFrom:0 count:1].firstObject;
    [self.controller acceptComments:@[comment] total:1 offset:0];
    comment.content = @"新的短评论";
    self.controller.view.frame = CGRectMake(0, 0, 220, 700);
    [self.controller.view setNeedsLayout];
    [self.controller.view layoutIfNeeded];
    queue.suspended = NO;
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 1; }];
    NLCommentTextLayout *narrow = [self.controller layoutForComment:comment];
    XCTAssertEqualWithAccuracy(narrow.width, 146, 0.01);
    XCTAssertEqualObjects(narrow.sourceText, @"新的短评论");
    CGFloat oldFontSize = narrow.font.pointSize;
    self.controller.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryAccessibilityExtraExtraExtraLarge;
    [self.controller updateLayoutEnvironment];
    [self waitFor:^BOOL{ return [self.controller layoutForComment:comment].font.pointSize > oldFontSize; }];
    NLCommentTextLayout *large = [self.controller layoutForComment:comment];
    XCTAssertGreaterThan(large.expandedTextHeight, narrow.expandedTextHeight);
    [self.table layoutIfNeeded];
    NLCommentCell *cell = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    XCTAssertEqual(cell.textLayout, large);
}

- (void)testDisappearanceCancelsWorkAndReentryPreparesPendingPage {
    NLCommentLayoutCoordinator *coordinator = [self.controller valueForKey:@"layoutCoordinator"];
    NSOperationQueue *queue = [coordinator valueForKey:@"queue"];
    queue.suspended = YES;
    [self.controller acceptComments:[self commentsFrom:0 count:3] total:3 offset:0];
    [self.controller viewDidDisappear:NO];
    queue.suspended = NO;
    XCTAssertEqual([self.table numberOfRowsInSection:0], 0);
    [self.controller viewWillAppear:NO];
    [self waitFor:^BOOL{ return [self.table numberOfRowsInSection:0] == 3; }];
    [self.table layoutIfNeeded];
    NLCommentCell *cell = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    XCTAssertNotNil(cell.textLayout);
}
@end
