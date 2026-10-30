#import <XCTest/XCTest.h>
#import "NLSongListCell.h"
#import "NLDownloadItem.h"

@interface NLSongListCellTests : XCTestCase
@end

@implementation NLSongListCellTests

- (void)testDownloadCellShowsProgressOnlyWhenExpectedBytesAreKnown {
    NLDownloadItem *item = [[NLDownloadItem alloc] init];
    item.songId = NSUUID.UUID.UUIDString;
    item.title = @"Progress";
    item.artist = @"Test";
    item.status = @"downloading";
    NLSongListCell *cell = [[NLSongListCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIProgressView *progressView = [cell valueForKey:@"downloadProgressView"];

    [cell configWithDownloadItem:item downloadProgress:-1.f];
    NSArray<UIActivityIndicatorView *> *indicators = [cell.contentView.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *view, NSDictionary *bindings) {
        return [view isKindOfClass:UIActivityIndicatorView.class];
    }]];
    XCTAssertEqual(indicators.count, 1u);
    XCTAssertTrue(progressView.hidden);
    if (indicators.count == 1) XCTAssertTrue(indicators.firstObject.isAnimating);

    [cell configWithDownloadItem:item downloadProgress:0.25f];
    XCTAssertFalse(progressView.hidden);
    XCTAssertEqualWithAccuracy(progressView.progress, 0.25f, 0.001f);
    if (indicators.count == 1) XCTAssertFalse(indicators.firstObject.isAnimating);
}

@end
