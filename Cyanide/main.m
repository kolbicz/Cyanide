//
//  main.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "Localization/CyanideLanguage.h"
#import "SettingsViewController.h"

#pragma mark - Unsupported device / iOS version

// On an unsupported iOS version or device nothing of Cyanide runs: not the
// app delegate (exploit auto-run, kernel setup), not the settings screen.
// Only this screen, with the reason. The app is built for iOS 16 and up so
// iOS 16 gets here at all (frameworks newer than that are linked weakly);
// installers that skip the minimum version check let it install there, and
// it used to crash at launch.

@interface CYUnsupportedViewController : UIViewController
@end

@implementation CYUnsupportedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"exclamationmark.triangle.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:44]]];
    icon.tintColor = UIColor.systemOrangeColor;

    UILabel *title = [UILabel new];
    title.text = @"Not Supported";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;

    UILabel *message = [UILabel new];
    message.text = [settings_unsupported_message() stringByAppendingString:
                    @"\n\nCyanide can't run here. Please uninstall it."];
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    message.adjustsFontForContentSizeCategory = YES;
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, message ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.readableContentGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end

@interface CYUnsupportedSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation CYUnsupportedSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [CYUnsupportedViewController new];
    [self.window makeKeyAndVisible];
}

@end

@interface CYUnsupportedAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation CYUnsupportedAppDelegate

// Replaces the Info.plist scene configuration (Cyanide's SceneDelegate).
- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:nil sessionRole:session.role];
    config.delegateClass = CYUnsupportedSceneDelegate.class;
    return config;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        CyanideLanguageInstall();
    }
    // Round 31: FIRST executable statement — before UIApplicationMain, before
    // any app code. If the black-screen-with-no-headers failure reproduces,
    // this line existing (with a NEW pid) proves a fresh process spawned and
    // the wedge is later; its absence proves SpringBoard never spawned one.
    cyanide_launch_trace("main: entry");
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = settings_device_supported()
            ? NSStringFromClass([AppDelegate class])
            : NSStringFromClass([CYUnsupportedAppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
