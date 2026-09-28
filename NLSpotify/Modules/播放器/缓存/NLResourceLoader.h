//
//  NLResourceLoader.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/26.
//

#import "AVFoundation/AVFoundation.h"
#import <Foundation/Foundation.h>
#import "RACSubject.h"

NS_ASSUME_NONNULL_BEGIN

@interface NLResourceLoader : NSObject<AVAssetResourceLoaderDelegate>

/// 原始音频资源的稳定缓存身份，由歌曲 ID 与 URL 路径版本组成；为空时退回 URL 哈希。
@property (nonatomic, copy, nullable) NSString *cacheKey;

/// 原始音频资源的网络地址。
/// - Discussion: 对应未带自定义 Scheme 的真实播放 URL。
@property (nonatomic, strong) NSURL *originURL;

/// 缓存进度主题，发送 0.0 ~ 1.0 的进度值。
/// - Discussion: 由内部在收到数据并写入缓存后推送，供外部 UI 监听。
@property (nonatomic, strong, readonly) RACSubject<NSNumber *> *cacheProgressSubject;

/// 指定初始化方法。
/// - Returns: 一个新的 `NLResourceLoader` 实例。
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// 取消所有未完成的加载请求并释放内部资源。
- (void)invalidateAndCancelAll;

@end

NS_ASSUME_NONNULL_END
