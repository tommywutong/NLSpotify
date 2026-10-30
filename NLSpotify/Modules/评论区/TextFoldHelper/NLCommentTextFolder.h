//
//  NLCommentTextFolder.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/21.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 基于 TextKit 的评论折叠文本构造器。
@interface NLCommentTextFolder : NSObject

/// 判断文本在给定排版宽度和字体下是否超过三行。
/// - Parameters:
///   - text: 原始评论文本。
///   - width: 用于 `NSTextContainer` 的实际可用宽度。
///   - font: 评论正文使用的字体。
/// - Returns: 超过三行时为 YES。
/// - Discussion: 结果依赖宽度和字体；外层缓存应在 Dynamic Type、横竖屏或约束变化时失效。
+ (BOOL)textNeedExpand:(NSString *)text width:(CGFloat)width font:(UIFont *)font;

/// 生成附带“展开”后缀的折叠富文本。
/// - Parameters:
///   - text: 原始评论文本。
///   - font: 评论正文使用的字体。
///   - width: 用于确定第三行截断位置的可用宽度。
/// - Returns: 折叠态富文本；调用方应先以 `textNeedExpand:width:font:` 判断是否需要折叠。
+ (NSAttributedString *)collapsedText:(NSString *)text font:(UIFont *)font width:(CGFloat)width;

/// 生成附带“收起”后缀的完整富文本。
/// - Parameters:
///   - text: 原始评论文本。
///   - font: 评论正文使用的字体。
/// - Returns: 展开态富文本。
+ (NSAttributedString *)expandedText:(NSString *)text font:(UIFont *)font;
@end

NS_ASSUME_NONNULL_END
