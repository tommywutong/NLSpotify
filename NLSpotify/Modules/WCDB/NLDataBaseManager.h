//
//  NLDataBaseManager.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/23.
//

#import <Foundation/Foundation.h>

@class WCTDatabase, WCTHandle;

NS_ASSUME_NONNULL_BEGIN

/// 音频缓存账本表名（v3：主键为 SHA-256 缓存标识）。
extern NSString * const NLAudioCacheInfoTableName;

@interface NLDataBaseManager : NSObject

/// 全局数据库管理单例。
/// - Returns: 全局共享的 `NLDataBaseManager` 实例。
+ (instancetype)sharedManager;

/// 底层 WCDB 数据库实例。
/// - Discussion: 所有仓库类应通过此属性获取同一数据库连接。
@property (nonatomic, readonly) WCTDatabase *database;

/// 所有 Repository 单语句写入的串行执行入口；写 block 在 writer queue 运行。
- (void)performWrite:(BOOL (^)(WCTDatabase *database))write
     completionQueue:(dispatch_queue_t)completionQueue
          completion:(void (^)(BOOL success))completion;

/// 多表/多语句写入事务；block 返回 NO 时回滚。
- (void)performWriteTransaction:(BOOL (^)(WCTHandle *transactionHandle))transaction
                completionQueue:(dispatch_queue_t)completionQueue
                     completion:(void (^)(BOOL success))completion;

/// 在数据库后台队列生成读取快照，并在指定队列返回结果。
- (void)performRead:(id _Nullable (^)(WCTDatabase *database))read
    completionQueue:(dispatch_queue_t)completionQueue
         completion:(void (^)(id _Nullable result))completion;

/// 将旧缓存账本迁移到 v3（主键改为 `cacheIdentifier`），可重复执行。
/// - Discussion: 迁移在事务内复制旧 `urlMD5` 行到 v3 表并删除旧表；音频文件名不重算。
- (void)migrateCacheLedgerIfNeededWithCompletion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
