//
//  NLAdvertiseViewController.m
//  NLSpotify
//
//  Created by 吴桐 on 2025/12/14.
//  Created by 吴桐 on 2025/12/14.

@class NLRadioProgramController;

#import "NLAdvertiseViewController.h"
#import "NetWorkManager.h"
#import "NLSearchSuggestService.h"
#import "NLSong.h"
#import "NLPlayerManager.h"
@interface NLRadioProgramController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, assign) NSInteger radioId;
@property (nonatomic, copy) NSString *radioName;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *programs;
- (instancetype)initWithRadioId:(NSInteger)radioId name:(NSString *)name;
@end

@interface NLAdvertiseViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *radios;
@property (nonatomic, copy) NSArray<NSDictionary *> *categories;
@end

@implementation NLAdvertiseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"广播";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.radios = @[];
    self.categories = @[];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self loadRadios];
}

- (void)loadRadios {
    [[NetWorkManager sharedManager] GET:@"/dj/recommend" parameters:@{} success:^(NSDictionary *response) {
        NSArray *items = [response[@"djRadios"] isKindOfClass:NSArray.class] ? response[@"djRadios"] : response[@"data"];
        self.radios = [items isKindOfClass:NSArray.class] ? items : @[];
        [self.tableView reloadData];
    } failure:^(NSError *error) {
        [[NetWorkManager sharedManager] GET:@"/dj/hot" parameters:@{@"limit": @20} success:^(NSDictionary *response) {
            self.radios = [response[@"djRadios"] isKindOfClass:NSArray.class] ? response[@"djRadios"] : @[];
            [self.tableView reloadData];
        } failure:^(NSError *error) {}];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.radios.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @"推荐电台"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RadioCell"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RadioCell"];
    NSDictionary *radio = self.radios[indexPath.row];
    cell.textLabel.text = radio[@"name"] ?: @"电台";
    cell.detailTextLabel.text = radio[@"category"] ?: @"推荐内容";
    cell.imageView.image = [UIImage systemImageNamed:@"dot.radiowaves.left.and.right"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *radio = self.radios[indexPath.row];
    NLRadioProgramController *controller = [[NLRadioProgramController alloc] initWithRadioId:[radio[@"id"] integerValue] name:radio[@"name"] ?: @"电台"];
    [self.navigationController pushViewController:controller animated:YES];
}
@end


@implementation NLRadioProgramController
- (instancetype)initWithRadioId:(NSInteger)radioId name:(NSString *)name { if ((self = [super init])) { _radioId = radioId; _radioName = [name copy]; _programs = @[]; } return self; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = self.radioName; self.view.backgroundColor = UIColor.systemBackgroundColor; self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped]; self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; self.tableView.dataSource = self; self.tableView.delegate = self; [self.view addSubview:self.tableView]; [[NetWorkManager sharedManager] GET:@"/dj/program" parameters:@{@"rid": @(self.radioId), @"limit": @30} success:^(NSDictionary *response) { self.programs = [response[@"programs"] isKindOfClass:NSArray.class] ? response[@"programs"] : @[]; [self.tableView reloadData]; } failure:^(NSError *error) {}]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.programs.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath { UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ProgramCell"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ProgramCell"]; NSDictionary *program = self.programs[indexPath.row]; cell.textLabel.text = program[@"name"] ?: @"节目"; cell.detailTextLabel.text = program[@"description"] ?: self.radioName; cell.imageView.image = [UIImage systemImageNamed:@"mic"]; return cell; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { NSDictionary *program = self.programs[indexPath.row]; NSDictionary *song = program[@"mainSong"]; if (![song isKindOfClass:NSDictionary.class]) return; NSArray *artists = song[@"artists"]; NSString *artist = [artists.firstObject isKindOfClass:NSDictionary.class] ? artists.firstObject[@"name"] : @""; NLSong *model = [[NLSong alloc] initWithId:[NSString stringWithFormat:@"%@", song[@"id"] ?: @""] title:song[@"name"] ?: @"节目" artist:artist coverURL:[[NSURL alloc] initWithString:@"about:blank"]]; [[NLPlayerManager sharedManager] playWithPlaylist:@[model] startIndex:0]; }
@end
