//
//  InstallProgressViewController.m
//  Cyanide
//

#import "InstallProgressViewController.h"
#import "PackageQueue.h"
#import "QueueReviewViewController.h"
#import "../SettingsViewController.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import <sys/utsname.h>

@interface InstallProgressViewController ()
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, strong) LogTextView *logView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIBarButtonItem *hideOrDoneButton;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) NSLayoutConstraint *retryButtonWidth;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, assign) BOOL didPromptForHideHomeBarRespring;
@end

@implementation InstallProgressViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIColor *bg = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0];
    self.view.backgroundColor = bg;
    self.title = @"Activity";
    self.modalInPresentation = NO;

    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerLabel.numberOfLines = 0;
    self.bannerLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    self.bannerLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    self.bannerLabel.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
    self.bannerLabel.textAlignment = NSTextAlignmentLeft;
    self.bannerLabel.attributedText = [self buildBannerText];
    self.bannerLabel.layer.cornerRadius = 10;
    self.bannerLabel.clipsToBounds = YES;
    [self.view addSubview:self.bannerLabel];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [self.view addSubview:separator];

    self.logView = [[LogTextView alloc] initWithFrame:CGRectZero];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    // Blurred footer
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *footer = [[UIVisualEffectView alloc] initWithEffect:blur];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:footer];

    UIView *footerDivider = [[UIView alloc] init];
    footerDivider.translatesAutoresizingMaskIntoConstraints = NO;
    footerDivider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [footer.contentView addSubview:footerDivider];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.spinner startAnimating];
    [footer.contentView addSubview:self.spinner];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Running — stay here until complete.";
    self.statusLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.statusLabel.numberOfLines = 1;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.minimumScaleFactor = 0.8;
    [footer.contentView addSubview:self.statusLabel];

    // Run Again button: zero-width and hidden while running, expanded only
    // when the chain run fails to acquire KRW (a clean, same-boot-retryable
    // miss). The width constraint keeps the status label's layout stable in
    // both states without activating/deactivating constraints.
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.retryButton setTitle:@"Run Again" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    [self.retryButton setTitleColor:[UIColor colorWithRed:0.40 green:0.78 blue:1.0 alpha:1.0]
                           forState:UIControlStateNormal];
    self.retryButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    self.retryButton.hidden = YES;
    self.retryButton.clipsToBounds = YES;
    [self.retryButton addTarget:self
                         action:@selector(didTapRetry)
               forControlEvents:UIControlEventTouchUpInside];
    [footer.contentView addSubview:self.retryButton];
    self.retryButtonWidth = [self.retryButton.widthAnchor constraintEqualToConstant:0.0];
    self.retryButtonWidth.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.bannerLabel.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.bannerLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.bannerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [separator.topAnchor      constraintEqualToAnchor:self.bannerLabel.bottomAnchor constant:12],
        [separator.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [separator.heightAnchor   constraintEqualToConstant:0.5],

        [self.logView.topAnchor      constraintEqualToAnchor:separator.bottomAnchor],
        [self.logView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.logView.bottomAnchor   constraintEqualToAnchor:footer.topAnchor],

        [footer.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
        [footer.heightAnchor   constraintEqualToConstant:64.0],

        [footerDivider.topAnchor      constraintEqualToAnchor:footer.topAnchor],
        [footerDivider.leadingAnchor  constraintEqualToAnchor:footer.leadingAnchor],
        [footerDivider.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [footerDivider.heightAnchor   constraintEqualToConstant:0.5],

        [self.spinner.leadingAnchor      constraintEqualToAnchor:footer.leadingAnchor constant:20.0],
        [self.spinner.centerYAnchor      constraintEqualToAnchor:footer.safeAreaLayoutGuide.topAnchor constant:22.0],
        [self.statusLabel.leadingAnchor  constraintEqualToAnchor:self.spinner.trailingAnchor constant:12.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.retryButton.leadingAnchor constant:-8.0],
        [self.statusLabel.centerYAnchor  constraintEqualToAnchor:self.spinner.centerYAnchor],

        [self.retryButton.trailingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [self.retryButton.centerYAnchor  constraintEqualToAnchor:self.spinner.centerYAnchor],
    ]];

    self.hideOrDoneButton = [[UIBarButtonItem alloc] initWithTitle:@"Hide"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(didTapDone)];
    self.navigationItem.rightBarButtonItem = self.hideOrDoneButton;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveCompleteNotification:)
                                                 name:kSettingsActionsDidCompleteNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveStatusNotification:)
                                                 name:kSettingsApplyStatusDidChangeNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)didReceiveStatusNotification:(NSNotification *)note
{
    if (self.completed) return;
    NSString *text = note.userInfo[kSettingsApplyStatusTextKey];
    self.statusLabel.text = text.length ? text : @"Running — stay here until complete.";
}

- (void)didReceiveCompleteNotification:(NSNotification *)note
{
    if (self.completed) return;
    self.completed = YES;
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    NSNumber *successValue = note.userInfo[kSettingsActionsDidCompleteSuccessKey];
    BOOL success = successValue ? successValue.boolValue : YES;
    NSString *message = note.userInfo[kSettingsActionsDidCompleteMessageKey];
    self.statusLabel.text = message.length
        ? message
        : (success ? @"All tweaks applied in-session." : @"Failed — check the log above.");
    self.statusLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = success
        ? [UIColor colorWithRed:0.38 green:0.90 blue:0.55 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.38 blue:0.32 alpha:1.0];
    self.title = success ? @"Complete" : @"Failed";
    self.hideOrDoneButton.title = @"Done";
    // Offer a one-tap retry only for the main chain run's KRW-acquire
    // failure — a clean miss that is fully re-entrant in the same boot
    // (the actions lock is already released by the time this notification
    // fires). Never when the injection wedged: re-running there hangs again,
    // and the Restart Cyanide alert owns that case.
    BOOL canRetry = !success &&
        [message isEqualToString:kSettingsRunKRWFailedMessage] &&
        !remote_call_init_wedged();
    self.retryButton.hidden = !canRetry;
    self.retryButtonWidth.constant = canRetry ? 90.0 : 0.0;
    if (success &&
        self.promptsForHideHomeBarRespring &&
        settings_hide_home_bar_respring_pending()) {
        [self scheduleHideHomeBarRespringPrompt];
    }
}

- (void)didTapRetry
{
    // Re-arm the progress UI and re-run the chain in the same mode as the
    // last invocation. The next completion notification lands back in
    // didReceiveCompleteNotification: and updates this screen again.
    self.retryButton.hidden = YES;
    self.retryButtonWidth.constant = 0.0;
    self.completed = NO;
    self.title = @"Activity";
    self.hideOrDoneButton.title = @"Hide";
    self.statusLabel.text = @"Running — stay here until complete.";
    self.statusLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.spinner.hidden = NO;
    [self.spinner startAnimating];
    settings_rerun_last_actions();
}

- (void)scheduleHideHomeBarRespringPrompt
{
    if (self.didPromptForHideHomeBarRespring) return;
    self.didPromptForHideHomeBarRespring = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.view.window) return;
        settings_present_hide_home_bar_respring_prompt(self);
    });
}

- (NSAttributedString *)buildBannerText {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";

    struct utsname u = {0};
    const char *machine = "device";
    if (uname(&u) == 0 && u.machine[0])
        machine = u.machine;
    NSString *ios = UIDevice.currentDevice.systemVersion ?: @"?";

    NSString *banner = [NSString stringWithFormat:
        @"     ╭───────────╮\n"
        @"     │ ▄▄▄▄▄▄▄▄▄ │\n"
        @"     ├───────────┤\n"
        @"     │ ░░░░░░░░░ │   C Y A N I D E\n"
        @"     │ ░░░ C ░░░ │   %@ (%@)\n"
        @"     │ ░░░░░░░░░ │   %s • iOS %@\n"
        @"     │ ░░░░░░░░░ │\n"
        @"     ╰───────────╯",
        shortVer, build, machine, ios];

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.lineSpacing = 2.0;

    return [[NSAttributedString alloc] initWithString:banner attributes:@{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.86 alpha:1.0],
        NSParagraphStyleAttributeName: para,
    }];
}

- (void)didTapDone
{
    UIViewController *presenter = self.presentingViewController;
    UINavigationController *nav = [presenter isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)presenter
        : presenter.navigationController;
    [self dismissViewControllerAnimated:YES completion:^{
        if (!nav) return;
        NSMutableArray<__kindof UIViewController *> *stack = [nav.viewControllers mutableCopy];
        NSInteger removed = 0;
        for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
            if ([stack[i] isKindOfClass:QueueReviewViewController.class]) {
                [stack removeObjectAtIndex:i];
                removed++;
            }
        }
        if (removed > 0) {
            [nav setViewControllers:stack animated:YES];
        }
    }];
}

@end
