//
//  NLAudioCacheInfo.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLAudioCacheInfo : NSObject
@property (nonatomic, copy) NSString *cacheIdentifier;
@property (nonatomic, copy, nullable) NSString *songId;
@property (nonatomic, assign) long long totalLength;

//已缓存的区间 (Range) 集合：这里存一个 JSON 字符串，例如："[{\"loc\":0, \"len\":10000}, {\"loc\":50000, \"len\":8000}]"
// 我们后续会在内存里把它转成 NSArray<NSValue *>，写入数据库时再转成 NSString
@property (nonatomic, copy) NSString *cachedRangesString;
@property (nonatomic, assign) NSTimeInterval lastAccessTime;
@property (nonatomic, assign) BOOL isFinished;

@end

NS_ASSUME_NONNULL_END
