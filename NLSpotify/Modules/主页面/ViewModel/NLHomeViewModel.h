//
//  NLHomeViewModel.h
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/13.
//

#import <Foundation/Foundation.h>
#import "NLSectionViewModel.h"

NS_ASSUME_NONNULL_BEGIN

/// 首页多个推荐分区的视图数据装配器。
@interface NLHomeViewModel : NSObject

/// 已完成加载且可展示的分区数组。
/// - Discussion: `loadDataWithCompletion:` 会丢弃失败分区并在主线程整体替换该值。
@property (nonatomic, strong) NSArray *sections;

/// 并发请求首页推荐分区并在全部请求结束后回调。
/// - Parameter completion: 在主线程执行；此时 `sections` 仅包含成功构建的分区。
/// - Discussion: 每个请求无论成功或失败都会离开 dispatch group，避免单个接口失败阻塞首页。
- (void)loadDataWithCompletion:(void (^)(void))completion;

/// 返回当前可展示的分区数量。
/// - Returns: `sections.count`。
- (NSInteger)numberOfSections;

/// 返回指定位置的分区视图模型。
/// - Parameter index: 必须位于 `0 ..< numberOfSections`，调用方负责边界检查。
/// - Returns: 对应分区的视图模型。
- (NLSectionViewModel *)sectionAtIndex:(NSInteger)index;

@end



NS_ASSUME_NONNULL_END
