#import "NLCommentListViewController.h"
#import "NLCommentService.h"
#import "NLCommentModel.h"
#import "NLCommentCell.h"
#import "NLCommentLayoutCoordinator.h"
#import <Masonry/Masonry.h>

static const NSInteger kPageSize = 20;

@interface NLCommentReadingAnchor : NSObject
@property (nonatomic, strong) NLCommentModel *comment;
@property (nonatomic) CGFloat topDistance;
@end
@implementation NLCommentReadingAnchor
@end

@interface NLCommentListViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic) NSInteger resourceId;
@property (nonatomic) NLCommentResourceType resourceType;
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NLCommentModel *> *comments;
@property (nonatomic) NSInteger total;
@property (nonatomic) NSInteger currentOffset;
@property (nonatomic) BOOL isLoading;
@property (nonatomic) BOOL hasLoadedOnce;
@property (nonatomic, strong) NLCommentLayoutCoordinator *layoutCoordinator;
@property (nonatomic, strong) NSMapTable<NLCommentModel *, NLCommentTextLayout *> *layouts;
@property (nonatomic, copy) NSArray<NLCommentModel *> *pendingComments;
@property (nonatomic) BOOL pendingReplacesComments;
@property (nonatomic, copy) NSString *environmentKey;
@property (nonatomic, strong) UIFont *layoutFont;
@property (nonatomic) CGFloat layoutWidth;
@property (nonatomic) CGFloat displayScale;
@property (nonatomic) NSUInteger layoutGeneration;
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic) BOOL preparingLayouts;
@property (nonatomic) BOOL reflowing;
@property (nonatomic) BOOL suspended;
@property (nonatomic, strong) NLCommentReadingAnchor *reflowAnchor;
@end

@implementation NLCommentListViewController

- (instancetype)initWithResourceId:(NSInteger)resourceId resourceType:(NLCommentListResourceType)type title:(NSString *)title {
    if ((self = [super init])) {
        _resourceId = resourceId;
        _resourceType = (NLCommentResourceType)type;
        _pageTitle = title ?: @"评论";
        _comments = [NSMutableArray array];
        _layouts = [NSMapTable strongToStrongObjectsMapTable];
        _layoutCoordinator = [NLCommentLayoutCoordinator new];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.pageTitle;
    [self.view addSubview:self.tableView];
    [self.tableView mas_makeConstraints:^(MASConstraintMaker *make) { make.edges.equalTo(self.view); }];
    [self registerForTraitChanges:@[UITraitPreferredContentSizeCategory.class, UITraitDisplayScale.class]
                     withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
        [(NLCommentListViewController *)environment updateLayoutEnvironment];
    }];
    [self loadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.suspended = NO;
    [self updateLayoutEnvironment];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.suspended = YES;
    self.layoutGeneration += 1;
    self.preparingLayouts = NO;
    [self.layoutCoordinator invalidate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateLayoutEnvironment];
}

- (void)updateLayoutEnvironment {
    if (!self.isViewLoaded || self.suspended) return;
    CGFloat width = [NLCommentCell textWidthForCellWidth:CGRectGetWidth(self.tableView.bounds)];
    if (width <= 0) return; // Never cache a guessed screen width before constraints are resolved.
    UIFont *font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
                    scaledFontForFont:[UIFont systemFontOfSize:15] compatibleWithTraitCollection:self.traitCollection];
    CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 1;
    NSString *key = [NLCommentTextLayout cacheKeyForText:self.traitCollection.preferredContentSizeCategory
                                                 width:width font:font displayScale:scale];
    if (![self.environmentKey isEqualToString:key]) {
        if (!self.reflowing) self.reflowAnchor = [self captureReadingAnchor];
        self.environmentKey = key;
        self.layoutWidth = width;
        self.layoutFont = font;
        self.displayScale = scale;
        self.layoutGeneration += 1;
        [self.layoutCoordinator invalidate];
        [self.layouts removeAllObjects];
        self.preparingLayouts = NO;
        self.reflowing = YES;
        // Old geometry must not be used by height delegates while the new environment is preparing.
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.tableView.backgroundView = indicator;
        [self.tableView reloadData];
    }
    [self prepareMissingLayouts];
}

- (NLCommentTextLayout *)layoutForComment:(NLCommentModel *)comment {
    NLCommentTextLayout *layout = [self.layouts objectForKey:comment];
    if (layout.width != self.layoutWidth || layout.displayScale != self.displayScale ||
        ![layout.font isEqual:self.layoutFont] || ![layout.sourceText isEqualToString:comment.content ?: @""]) return nil;
    return layout;
}

- (void)prepareMissingLayouts {
    if (self.suspended || self.layoutWidth <= 0 || self.preparingLayouts) return;
    NSMutableArray<NLCommentModel *> *candidates = [NSMutableArray array];
    if (!self.pendingReplacesComments) [candidates addObjectsFromArray:self.comments];
    if (self.pendingComments) [candidates addObjectsFromArray:self.pendingComments];
    NSMutableArray<NLCommentModel *> *missing = [NSMutableArray array];
    for (NLCommentModel *comment in candidates) {
        if (![self layoutForComment:comment]) [missing addObject:comment];
    }
    if (missing.count == 0) {
        if (self.reflowing || self.pendingComments) [self commitPreparedComments];
        return;
    }
    self.preparingLayouts = YES;
    NSUInteger generation = self.layoutGeneration;
    __block NSUInteger remaining = missing.count;
    __weak typeof(self) weakSelf = self;
    for (NLCommentModel *comment in missing) {
        NSString *text = [comment.content copy] ?: @"";
        [self.layoutCoordinator requestLayoutForText:text width:self.layoutWidth font:self.layoutFont displayScale:self.displayScale completion:^(NLCommentTextLayout *layout) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.suspended || generation != self.layoutGeneration) return;
            BOOL belongsToPage = [self.comments indexOfObjectIdenticalTo:comment] != NSNotFound ||
                (self.pendingComments && [self.pendingComments indexOfObjectIdenticalTo:comment] != NSNotFound);
            if (belongsToPage && [layout.sourceText isEqualToString:comment.content ?: @""]) {
                [self.layouts setObject:layout forKey:comment];
            }
            remaining -= 1;
            if (remaining == 0) {
                self.preparingLayouts = NO;
                [self prepareMissingLayouts]; // Also handles a changed content snapshot or a newly received page.
            }
        }];
    }
}

- (void)commitPreparedComments {
    NLCommentReadingAnchor *anchor = self.reflowAnchor ?: [self captureReadingAnchor];
    BOOL reload = self.reflowing || self.pendingReplacesComments || self.comments.count == 0;
    NSUInteger oldCount = self.comments.count;
    BOOL hasPage = self.pendingComments != nil;
    if (self.pendingReplacesComments) {
        for (NLCommentModel *oldComment in self.comments) {
            if ([self.pendingComments indexOfObjectIdenticalTo:oldComment] == NSNotFound) {
                [self.layouts removeObjectForKey:oldComment];
            }
        }
        [self.comments removeAllObjects];
    }
    if (hasPage) [self.comments addObjectsFromArray:self.pendingComments];
    self.pendingComments = nil;
    self.pendingReplacesComments = NO;
    self.reflowing = NO;
    self.reflowAnchor = nil;
    self.tableView.backgroundView = nil;
    if (hasPage) self.isLoading = NO;
    [UIView performWithoutAnimation:^{
        if (reload) {
            [self.tableView reloadData];
        } else if (self.comments.count > oldCount) {
            NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
            for (NSUInteger index = oldCount; index < self.comments.count; index++) {
                [paths addObject:[NSIndexPath indexPathForRow:index inSection:0]];
            }
            [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        }
        [self updateLoadingFooter:self.isLoading];
        [self.tableView layoutIfNeeded];
        [self restoreReadingAnchor:anchor];
    }];
}

- (void)loadData {
    if (self.isLoading) return;
    self.isLoading = YES;
    [self updateLoadingFooter:YES];
    NSUInteger generation = ++self.requestGeneration;
    NSInteger offset = self.currentOffset;
    __weak typeof(self) weakSelf = self;
    [NLCommentService fetchCommentsWithResourceId:self.resourceId resourceType:self.resourceType limit:kPageSize offset:offset before:nil
                                        success:^(NSArray<NLCommentModel *> *comments, NSInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.requestGeneration != generation) return;
            [self acceptComments:comments total:total offset:offset];
        });
    } failure:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.requestGeneration != generation) return;
            self.isLoading = NO;
            [self updateLoadingFooter:NO];
        });
    }];
}

- (void)acceptComments:(NSArray<NLCommentModel *> *)comments total:(NSInteger)total offset:(NSInteger)offset {
    self.hasLoadedOnce = YES;
    self.total = MAX(0, total);
    self.pendingComments = [comments copy];
    self.pendingReplacesComments = offset == 0;
    [self updateLayoutEnvironment];
}

- (NLCommentReadingAnchor *)captureReadingAnchor {
    NSIndexPath *path = [[self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)] firstObject];
    if (!path || path.row >= self.comments.count || self.reflowing) return nil;
    NLCommentReadingAnchor *anchor = [NLCommentReadingAnchor new];
    anchor.comment = self.comments[path.row];
    anchor.topDistance = CGRectGetMinY([self.tableView rectForRowAtIndexPath:path]) -
        (self.tableView.contentOffset.y + self.tableView.adjustedContentInset.top);
    return anchor;
}

- (void)restoreReadingAnchor:(NLCommentReadingAnchor *)anchor {
    if (!anchor) return;
    NSUInteger index = [self.comments indexOfObjectIdenticalTo:anchor.comment];
    if (index == NSNotFound) return;
    CGRect rect = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    CGFloat distance = MAX(anchor.topDistance, -MAX(0, CGRectGetHeight(rect) - 1));
    CGFloat minimum = -self.tableView.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, self.tableView.contentSize.height - CGRectGetHeight(self.tableView.bounds) + self.tableView.adjustedContentInset.bottom);
    CGFloat offset = CGRectGetMinY(rect) - distance - self.tableView.adjustedContentInset.top;
    [self.tableView setContentOffset:CGPointMake(self.tableView.contentOffset.x, MIN(maximum, MAX(minimum, offset))) animated:NO];
}

- (void)toggleComment:(NLCommentModel *)comment {
    if (self.reflowing) return;
    NSUInteger index = [self.comments indexOfObjectIdenticalTo:comment];
    NLCommentTextLayout *layout = [self layoutForComment:comment];
    if (index == NSNotFound || !layout.needsExpansion) return;
    comment.isExpanded = !comment.isExpanded;
    NLCommentCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    [cell configureWithComment:comment layout:layout];
    [UIView performWithoutAnimation:^{
        // Self-sizing estimates already coordinate contentOffset; do not compensate a local toggle twice.
        [self.tableView performBatchUpdates:nil completion:nil];
        [self.tableView layoutIfNeeded];
    }];
}

- (void)updateLoadingFooter:(BOOL)loading {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    if (loading) {
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 44)];
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [footer addSubview:indicator];
        [indicator mas_makeConstraints:^(MASConstraintMaker *make) { make.center.equalTo(footer); }];
        [indicator startAnimating];
        self.tableView.tableFooterView = footer;
    } else if (self.hasLoadedOnce && self.comments.count >= self.total) {
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 44)];
        UILabel *label = [UILabel new];
        label.text = @"没有更多评论";
        label.font = [UIFont systemFontOfSize:14];
        label.textColor = UIColor.tertiaryLabelColor;
        [footer addSubview:label];
        [label mas_makeConstraints:^(MASConstraintMaker *make) { make.center.equalTo(footer); }];
        self.tableView.tableFooterView = footer;
    } else {
        self.tableView.tableFooterView = [UIView new];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.reflowing ? 0 : self.comments.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLCommentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CommentCell" forIndexPath:indexPath];
    NLCommentModel *comment = self.comments[indexPath.row];
    NLCommentTextLayout *layout = [self layoutForComment:comment];
    NSAssert(layout != nil, @"Only prepared comments enter the list");
    [cell configureWithComment:comment layout:layout];
    __weak typeof(self) weakSelf = self;
    cell.expandBlock = ^(NLCommentModel *current) { [weakSelf toggleComment:current]; };
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= MAX(0, (NSInteger)self.comments.count - 3) && self.comments.count < self.total && !self.isLoading) {
        self.currentOffset = self.comments.count;
        [self loadData];
    }
}

- (UITableView *)tableView {
    if (!_tableView) {
        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.delegate = self;
        _tableView.dataSource = self;
        _tableView.rowHeight = UITableViewAutomaticDimension;
        _tableView.estimatedRowHeight = 110;
        _tableView.cellLayoutMarginsFollowReadableWidth = NO;
        _tableView.insetsContentViewsToSafeArea = NO;
        _tableView.separatorInset = UIEdgeInsetsMake(0, 62, 0, 12);
        _tableView.tableFooterView = [UIView new];
        [_tableView registerClass:NLCommentCell.class forCellReuseIdentifier:@"CommentCell"];
    }
    return _tableView;
}
@end
