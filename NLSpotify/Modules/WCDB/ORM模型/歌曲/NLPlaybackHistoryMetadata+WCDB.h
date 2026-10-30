#import "NLPlaybackHistoryMetadata.h"
#import <WCDBObjc/WCDBObjc.h>

NS_ASSUME_NONNULL_BEGIN

@interface NLPlaybackHistoryMetadata (WCDB) <WCTTableCoding>
WCDB_PROPERTY(songId)
WCDB_PROPERTY(lastPlayedAt)
WCDB_PROPERTY(playCount)
@end

NS_ASSUME_NONNULL_END
