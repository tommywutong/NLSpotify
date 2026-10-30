//
//  NLCreatePlayListSheetViewController.m
//  NLSpotify
//

#import "NLCreatePlayListSheetViewController.h"
#import <Masonry/Masonry.h>

@interface NLCreatePlayListSheetViewController ()
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *confirmButton;
@property (nonatomic, strong) MASConstraint *containerBottomConstraint;
@end

@implementation NLCreatePlayListSheetViewController

- (instancetype)init {
    if (self = [super init]) {
        _titleText = @"新建歌单";
        _placeholder = @"输入新建歌单标题";
        _confirmButtonTitle = @"完成";
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    self.dimmingView = [[UIView alloc] init];
    self.dimmingView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
    self.dimmingView.alpha = 0.0;
    [self.view addSubview:self.dimmingView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    [self.dimmingView addGestureRecognizer:tap];

    self.containerView = [[UIView alloc] init];
    if (@available(iOS 13.0, *)) {
        self.containerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    } else {
        self.containerView.backgroundColor = [UIColor whiteColor];
    }
    self.containerView.layer.cornerRadius = 16.0;
    self.containerView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.containerView.clipsToBounds = YES;
    [self.view addSubview:self.containerView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.titleLabel.text = self.titleText;

    self.textField = [[UITextField alloc] init];
    self.textField.borderStyle = UITextBorderStyleRoundedRect;
    self.textField.placeholder = self.placeholder;

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];

    self.confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.confirmButton setTitle:self.confirmButtonTitle forState:UIControlStateNormal];
    self.confirmButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.confirmButton addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.view setNeedsUpdateConstraints];

    [self.dimmingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.view);
    }];

    CGFloat height = (self.view.bounds.size.height > 0 ? self.view.bounds.size.height : self.view.window.windowScene.screen.bounds.size.height) * 0.25;
    height = MAX(220.0, height);

    [self.containerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.right.equalTo(self.view);
        make.height.mas_equalTo(height);
        self.containerBottomConstraint = make.bottom.equalTo(self.view.mas_bottom).offset(height);
    }];

    [self.containerView addSubview:self.titleLabel];
    [self.containerView addSubview:self.textField];
    [self.containerView addSubview:self.cancelButton];
    [self.containerView addSubview:self.confirmButton];

    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.containerView).offset(16);
        make.centerX.equalTo(self.containerView);
    }];

    [self.textField mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.titleLabel.mas_bottom).offset(16);
        make.left.equalTo(self.containerView).offset(20);
        make.right.equalTo(self.containerView).offset(-20);
        make.height.mas_equalTo(40);
    }];

    [self.cancelButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.containerView).offset(24);
        make.bottom.equalTo(self.containerView.mas_bottom).offset(-20);
    }];

    [self.confirmButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self.containerView).offset(-24);
        make.centerY.equalTo(self.cancelButton);
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    [self.view layoutIfNeeded];
    [self.containerBottomConstraint setOffset:0];
    [UIView animateWithDuration:0.25
                     animations:^{
        self.dimmingView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self.textField becomeFirstResponder];
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIKeyboardWillChangeFrameNotification
                                                  object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    CGRect endFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

    CGRect kbFrameInView = [self.view convertRect:endFrame fromView:nil];
    CGFloat viewHeight = self.view.bounds.size.height;
    CGFloat overlap = MAX(0, viewHeight - kbFrameInView.origin.y);

    // offset = 0 时贴在屏幕底部，键盘出现时整体向上移动 overlap
    CGFloat offset = overlap > 0 ? -overlap : 0;
    [self.containerBottomConstraint setOffset:offset];

    [UIView animateWithDuration:duration
                          delay:0
                        options:(UIViewAnimationOptions)(curve << 16)
                     animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dismissSelf {
    [self.textField resignFirstResponder];
    CGFloat height = self.containerView.bounds.size.height;
    [self.containerBottomConstraint setOffset:height];
    [UIView animateWithDuration:0.2
                     animations:^{
        self.dimmingView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)confirmTapped {
    NSString *name = self.textField.text ?: @"";
    if (self.completion) {
        self.completion(name);
    }
    [self dismissSelf];
}

@end

