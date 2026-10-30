//
//  NLSearchRepository.mm
//  NLSpotify
//

#import "NLSearchRepository.h"
#import "NLDataBaseManager.h"
#import "NLSearchRecord+WCDB.h"

static NSString * const kSearchHistoryTableName = @"SearchHistoryTable";

static void NLCompleteSearchWrite(BOOL success, void (^completion)(BOOL)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
}

@implementation NLSearchRepository

+ (WCTDatabase *)safeDatabase {
    return [NLDataBaseManager sharedManager].database;
}

+ (void)addSearchRecord:(NSString *)keyword completion:(void (^)(BOOL))completion {
    if (keyword.length == 0) {
        NLCompleteSearchWrite(NO, completion);
        return;
    }
    NLSearchRecord *record = [[NLSearchRecord alloc] initWithKeyword:keyword];
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database insertOrReplaceObject:record intoTable:kSearchHistoryTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (NSArray<NLSearchRecord *> *)allSearchRecords {
    WCTDatabase *database = [self safeDatabase];
    NSArray<NLSearchRecord *> *records = database ? [database getObjectsOfClass:NLSearchRecord.class
                                                                        fromTable:kSearchHistoryTableName] : nil;
    if (!records || records.count == 0) return @[];
    NSArray<NLSearchRecord *> *sortedRecords = [records sortedArrayUsingComparator:^NSComparisonResult(NLSearchRecord *left, NLSearchRecord *right) {
        if (left.timestamp > right.timestamp) return NSOrderedAscending;
        if (left.timestamp < right.timestamp) return NSOrderedDescending;
        return [left.keyword compare:right.keyword];
    }];
    return sortedRecords.count > 20 ? [sortedRecords subarrayWithRange:NSMakeRange(0, 20)] : sortedRecords;
}

+ (void)clearAllSearchRecordsWithCompletion:(void (^)(BOOL))completion {
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kSearchHistoryTableName];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

+ (void)removeSearchRecord:(NSString *)keyword completion:(void (^)(BOOL))completion {
    if (keyword.length == 0) {
        NLCompleteSearchWrite(NO, completion);
        return;
    }
    [[NLDataBaseManager sharedManager] performWrite:^BOOL(WCTDatabase *database) {
        return [database deleteFromTable:kSearchHistoryTableName where:NLSearchRecord.keyword == keyword];
    } completionQueue:dispatch_get_main_queue() completion:completion];
}

@end
