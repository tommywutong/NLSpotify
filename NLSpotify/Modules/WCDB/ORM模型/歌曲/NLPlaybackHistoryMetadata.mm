#import "NLPlaybackHistoryMetadata.h"
#import "NLPlaybackHistoryMetadata+WCDB.h"

@implementation NLPlaybackHistoryMetadata

WCDB_IMPLEMENTATION(NLPlaybackHistoryMetadata)
WCDB_SYNTHESIZE(songId)
WCDB_SYNTHESIZE(lastPlayedAt)
WCDB_SYNTHESIZE(playCount)
WCDB_PRIMARY(songId)

@end
