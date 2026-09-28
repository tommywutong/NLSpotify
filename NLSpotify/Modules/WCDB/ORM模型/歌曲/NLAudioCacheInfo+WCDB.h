//
//  NLAudioCacheInfo+WCDB.h
//  NLSpotify
//
//  Created by 吴桐 on 2026/2/26.
//

#import "NLAudioCacheInfo.h"
#import <WCDBObjc/WCDBObjc.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLAudioCacheInfo (WCDB) <WCTTableCoding>

WCDB_PROPERTY(urlMD5)
WCDB_PROPERTY(songId)
WCDB_PROPERTY(totalLength)
WCDB_PROPERTY(cachedRangesString)
WCDB_PROPERTY(lastAccessTime)
WCDB_PROPERTY(isFinished)

@end

NS_ASSUME_NONNULL_END
