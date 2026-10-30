//
//  NLSearchRepository.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/23.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class NLSearchRecord;

/// 搜索历史的 WCDB 访问层。
@interface NLSearchRepository : NSObject

/// 新增或覆盖一个关键词的搜索历史。
/// - Parameter keyword: 用户提交的搜索词；作为记录唯一键。
/// - Returns: completion 在主队列返回数据库写入结果。
+ (void)addSearchRecord:(NSString *)keyword completion:(void (^)(BOOL success))completion;

/// 查询最近的搜索历史。
/// - Returns: 按记录时间降序截取的历史数组。
+ (NSArray<NLSearchRecord *> *)allSearchRecords;

/// 清空全部搜索历史。
/// - Returns: completion 在主队列返回数据库删除结果。
+ (void)clearAllSearchRecordsWithCompletion:(void (^)(BOOL success))completion;

/// 删除一个指定关键词的历史记录。
/// - Parameter keyword: 要删除的关键词。
/// - Returns: 数据库删除是否成功。
+ (void)removeSearchRecord:(NSString *)keyword completion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
