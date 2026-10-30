//
//  NLAudioCacheInfo.m
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/26.
//

#import "NLAudioCacheInfo.h"
#import <WCDBObjc/WCDBObjc.h>

@implementation NLAudioCacheInfo

WCDB_IMPLEMENTATION(NLAudioCacheInfo)

WCDB_SYNTHESIZE(cacheIdentifier)
WCDB_SYNTHESIZE(songId)
WCDB_SYNTHESIZE(totalLength)
WCDB_SYNTHESIZE(cachedRangesString)
WCDB_SYNTHESIZE(lastAccessTime)
WCDB_SYNTHESIZE(isFinished)

// 将 cacheIdentifier 设置为主键
WCDB_PRIMARY(cacheIdentifier)

@end
