//
//  NLDownloadItem.h
//  NLSpotify
//
//  下载队列项：用户点击「下载」后加入，status 为 downloading / completed
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLDownloadItem : NSObject

@property (nonatomic, copy) NSString *songId;
@property (nonatomic, copy) NSString *playURLString;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *coverURLString;
@property (nonatomic, assign) NSTimeInterval addedTime;

@property (nonatomic, copy) NSString *status;
/// 瞬时进度快照，仅由下载管理器填充，不映射到 WCDB。
@property (nonatomic, assign) long long receivedBytes;
@property (nonatomic, assign) long long expectedBytes;

- (NSURL * _Nullable)playURL;

@end

NS_ASSUME_NONNULL_END
