//
//  NLCommentCell.h
//  NLSpotify
//

#import <UIKit/UIKit.h>

@class NLCommentModel;
@class NLCommentTextLayout;

NS_ASSUME_NONNULL_BEGIN

@interface NLCommentCell : UITableViewCell
@property (nonatomic, strong, readonly, nullable) NLCommentModel *comment;
@property (nonatomic, strong, readonly, nullable) NLCommentTextLayout *textLayout;
@property (nonatomic, copy, nullable) void (^expandBlock)(NLCommentModel *comment);
+ (CGFloat)textWidthForCellWidth:(CGFloat)width;
- (void)configureWithComment:(NLCommentModel *)comment layout:(NLCommentTextLayout *)layout;
@end

NS_ASSUME_NONNULL_END
