#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "NLCommentTextFolder.h"
#import "NLCommentCell.h"
#import "NLCommentModel.h"
#import "NLCommentTextLayout.h"
#import <objc/message.h>


@interface NLCommentCell (LayoutTesting)
- (void)textTap;
@end
@interface NLCommentLayoutTests : XCTestCase @end
@implementation NLCommentLayoutTests
- (NSUInteger)lines:(NSAttributedString *)text width:(CGFloat)width {
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:text];
    NSLayoutManager *layout = [NSLayoutManager new];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0; [storage addLayoutManager:layout]; [layout addTextContainer:container];
    NSRange glyphs = [layout glyphRangeForTextContainer:container]; __block NSUInteger lines = 0;
    [layout enumerateLineFragmentsForGlyphRange:glyphs usingBlock:^(CGRect rect, CGRect used, NSTextContainer *c, NSRange range, BOOL *stop) { lines++; }];
    return lines;
}
- (void)testCollapsedSuffixFitsAndPrefixEndsAtComposedBoundary {
    NSArray *samples = @[@"中文评论👨‍👩‍👧‍👦👩🏽‍🚀é测试文字", @"WWWWWWiiii WWW 这是中英混排", @"مرحبا بالعالم تعليق طويل 👩‍💻", @"longwordwithoutspacesabcdefghijklmnop", @"第一行\n第二行\n第三行\n第四行"];
    for (NSString *sample in samples) {
        NSString *text = [[NSArray arrayWithObjects:sample, sample, sample, sample, sample, nil] componentsJoinedByString:@" "];
        for (NSNumber *w in @[@65, @131, @223]) {
            CGFloat width = w.doubleValue; UIFont *font = [UIFont systemFontOfSize:19];
            NSAttributedString *folded = [NLCommentTextFolder collapsedText:text font:font width:width];
            XCTAssertLessThanOrEqual([self lines:folded width:width], 3u, @"%@ width=%@", sample, w);
            XCTAssertTrue([folded.string hasSuffix:@"...展开"]);
            NSUInteger end = folded.length - @"...展开".length;
            XCTAssertEqualObjects([text substringToIndex:end], [folded.string substringToIndex:end]);
            if (end > 0) XCTAssertEqual(NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:end - 1]), end);
        }
    }
}
- (void)testShortTextDoesNotGainExpandSuffix {
    NSString *text = @"短评👩‍🚀";
    XCTAssertFalse([NLCommentTextFolder textNeedExpand:text width:260 font:[UIFont systemFontOfSize:15]]);
    XCTAssertEqualObjects([NLCommentTextFolder collapsedText:text font:[UIFont systemFontOfSize:15] width:260].string, text);
}
- (void)testNarrowAndZeroWidthDoNotSplitCharactersOrExceedThreeLines {
    NSString *text = @"👨‍👩‍👧‍👦🇨🇳é重复重复重复重复重复重复重复重复";
    for (NSNumber *w in @[@0, @1, @20]) {
        NSAttributedString *folded = [NLCommentTextFolder collapsedText:text font:[UIFont systemFontOfSize:40] width:w.doubleValue];
        if (w.doubleValue > 0) XCTAssertLessThanOrEqual([self lines:folded width:w.doubleValue], 3u);
        else XCTAssertEqual(folded.length, 0u);
    }
}
- (NLCommentCell *)cellForModel:(NLCommentModel *)model width:(CGFloat)width font:(UIFont *)font {
    NLCommentCell *cell = [[NLCommentCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.frame = CGRectMake(0, 0, width, 100);
    NLCommentTextLayout *layout = [NLCommentTextLayout layoutForText:model.content width:[NLCommentCell textWidthForCellWidth:width] font:font displayScale:2];
    [cell configureWithComment:model layout:layout];
    __weak NLCommentCell *weakCell = cell;
    cell.expandBlock = ^(NLCommentModel *current) {
        current.isExpanded = !current.isExpanded;
        [weakCell configureWithComment:current layout:weakCell.textLayout];
    };
    return cell;
}

- (void)testPreparedLayoutMatchesCellGeometryAcrossWidthsAndLargeFonts {
    NLCommentModel *model = [NLCommentModel new];
    model.content = [@"长评论 mixed text 👩🏽‍🚀 " stringByPaddingToLength:900 withString:@"中文 WWW iii 👩‍🚀 " startingAtIndex:0];
    for (NSNumber *width in @[@220, @390, @520]) {
        for (NSNumber *size in @[@15, @36]) {
            NLCommentCell *cell = [self cellForModel:model width:width.doubleValue font:[UIFont systemFontOfSize:size.doubleValue]];
            for (NSNumber *expanded in @[@NO, @YES, @NO]) {
                model.isExpanded = expanded.boolValue;
                [cell configureWithComment:model layout:cell.textLayout];
                CGSize fitting = [cell systemLayoutSizeFittingSize:CGSizeMake(width.doubleValue, UILayoutFittingCompressedSize.height)
                                    withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
                cell.frame = CGRectMake(0, 0, width.doubleValue, fitting.height);
                [cell layoutIfNeeded];
                UILabel *label = [cell valueForKey:@"contentLabel"];
                CGFloat expected = model.isExpanded ? cell.textLayout.expandedTextHeight : cell.textLayout.collapsedTextHeight;
                XCTAssertEqualWithAccuracy(CGRectGetWidth(label.bounds), width.doubleValue - 74, 0.5);
                XCTAssertEqualWithAccuracy(CGRectGetHeight(label.bounds), expected, 0.5);
                CGFloat rendered = [label sizeThatFits:CGSizeMake(CGRectGetWidth(label.bounds), CGFLOAT_MAX)].height;
                XCTAssertGreaterThanOrEqual(CGRectGetHeight(label.bounds) + 0.5, rendered);
                if (!model.isExpanded) XCTAssertLessThanOrEqual([self lines:label.attributedText width:label.bounds.size.width], 3u);
            }
        }
    }
}

- (void)testReuseClearsOldExpansionActionAndRendersNewContent {
    NLCommentModel *longModel = [NLCommentModel new];
    longModel.content = [@"long " stringByPaddingToLength:700 withString:@"评论 " startingAtIndex:0];
    NLCommentCell *cell = [self cellForModel:longModel width:390 font:[UIFont systemFontOfSize:15]];
    ((UIImageView *)[cell valueForKey:@"avatarView"]).image = [UIImage systemImageNamed:@"person.fill"];
    [cell prepareForReuse];
    [cell textTap];
    XCTAssertFalse(longModel.isExpanded);
    XCTAssertNil(cell.comment);
    XCTAssertNil(cell.textLayout);
    NLCommentModel *shortModel = [NLCommentModel new];
    shortModel.content = @"替换后的短评";
    NLCommentTextLayout *layout = [NLCommentTextLayout layoutForText:shortModel.content width:316 font:[UIFont systemFontOfSize:15] displayScale:2];
    [cell configureWithComment:shortModel layout:layout];
    UILabel *label = [cell valueForKey:@"contentLabel"];
    XCTAssertEqualObjects(label.attributedText.string, shortModel.content);
    XCTAssertNil(label.accessibilityCustomActions);
    XCTAssertNil(((UIImageView *)[cell valueForKey:@"avatarView"]).image);
}

- (void)testShortCommentTapDoesNotChangeExpansionState {
    NLCommentModel *model = [NLCommentModel new];
    model.content = @"短评";
    NLCommentCell *cell = [self cellForModel:model width:390 font:[UIFont systemFontOfSize:15]];
    [cell textTap];
    XCTAssertFalse(model.isExpanded);
}

- (void)testLongCommentOffersVoiceOverExpansionAction {
    NLCommentModel *model = [NLCommentModel new];
    model.content = [@"评论正文 👩🏽‍🚀 " stringByPaddingToLength:700 withString:@"中文评论 mixed text " startingAtIndex:0];
    NLCommentCell *cell = [self cellForModel:model width:390 font:[UIFont systemFontOfSize:15]];
    UILabel *label = [cell valueForKey:@"contentLabel"];
    XCTAssertEqual(label.accessibilityCustomActions.count, 1u);
    UIAccessibilityCustomAction *action = label.accessibilityCustomActions.firstObject;
    if (!action) return;
    BOOL activated = ((BOOL (*)(id, SEL, id))objc_msgSend)(action.target, action.selector, action);
    XCTAssertTrue(activated);
    XCTAssertTrue(model.isExpanded);
    XCTAssertEqualObjects(label.attributedText.string, cell.textLayout.expandedText.string);
    action = label.accessibilityCustomActions.firstObject;
    XCTAssertTrue(((BOOL (*)(id, SEL, id))objc_msgSend)(action.target, action.selector, action));
    XCTAssertFalse(model.isExpanded);
    XCTAssertEqualObjects(label.attributedText.string, cell.textLayout.collapsedText.string);
}
@end
