//
//  AppDelegate.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import "AppDelegate.h"
#import "SettingsViewController.h"
#import "TaskRop/Exception.h"   // round 21: excport lifecycle gate
#import "DSKeepAlive.h"
#import "LogTextView.h"
#import <signal.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <fcntl.h>
#import <time.h>
#import <unistd.h>

// Round 31: see AppDelegate.h. One self-contained line per call, appended
// with O_APPEND so it interleaves safely with LogTextView's FILE* writer.
// Deliberately shares NOTHING with the log machinery (no log_mutex, no
// live_log_file, no rotation): it must work from main() and from a process
// whose logging state is wedged.
void cyanide_launch_trace(const char *point)
{
    @autoreleasepool {
        NSURL *docs = [[[NSFileManager defaultManager]
                        URLsForDirectory:NSDocumentDirectory
                               inDomains:NSUserDomainMask] firstObject];
        if (!docs) return;
        const char *path = [docs URLByAppendingPathComponent:@"live.log"]
            .path.fileSystemRepresentation;
        if (!path) return;
        int bg = -1, term = -1;
        excport_gate_snapshot(&bg, &term);
        time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
        char line[512];
        int n = snprintf(line, sizeof(line),
            "[LAUNCH] %02d:%02d:%02d trace: %s pid=%d gate(bg=%d,term=%d) (round48)\n",
            tm.tm_hour, tm.tm_min, tm.tm_sec,
            point ?: "?", (int)getpid(), bg, term);
        if (n <= 0) return;
        if (n > (int)sizeof(line)) n = (int)sizeof(line);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd < 0) return;
        (void)write(fd, line, (size_t)n);
        fsync(fd);
        close(fd);
    }
}

@interface AppDelegate ()

@end

static dispatch_source_t g_sigterm_source;

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    cyanide_launch_trace("didFinishLaunching: entry");
    [self logBootIdentity];
    settings_register_defaults();
    log_set_verbose(YES);
    ds_keepalive_apply_enabled([[NSUserDefaults standardUserDefaults] boolForKey:kSettingsKeepAlive]);
    [self installTerminationHandlers];
    [self installBarAppearances];
    cyanide_launch_trace("didFinishLaunching: exit");
    return YES;
}

- (void)logBootIdentity {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build    = info[@"CFBundleVersion"] ?: @"?";

    struct utsname u = {0};
    const char *machine = "device";
    if (uname(&u) == 0 && u.machine[0])
        machine = u.machine;
    NSString *ios = UIDevice.currentDevice.systemVersion ?: @"?";

    fprintf(stdout,
        "\n"
        "     ╭───────────╮\n"
        "     │ ▄▄▄▄▄▄▄▄▄ │\n"
        "     ├───────────┤\n"
        "     │ ░░░░░░░░░ │   C Y A N I D E\n"
        "     │ ░░░ C ░░░ │   %s (%s)\n"
        "     │ ░░░░░░░░░ │   %s • iOS %s\n"
        "     │ ░░░░░░░░░ │\n"
        "     ╰───────────╯\n"
        "\n",
        shortVer.UTF8String, build.UTF8String,
        machine, ios.UTF8String);

    // Build stamp: every live log must self-identify the exact binary that
    // wrote it (a stale install once produced a "new build" panic report from
    // the previous binary). log_user bypasses the verbose gate — verbose is
    // only enabled after this — and mirrors straight into live.log.
    log_user("[BUILD] Cyanide %s (%s) built %s %s (round48)\n",
             shortVer.UTF8String, build.UTF8String, __DATE__, __TIME__);
}

- (void)installTerminationHandlers {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminateNotification:)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        signal(SIGTERM, SIG_IGN);
        g_sigterm_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                  SIGTERM,
                                                  0,
                                                  dispatch_get_main_queue());
        dispatch_source_set_event_handler(g_sigterm_source, ^{
            log_user("[CLEANUP] SIGTERM received; starting best-effort termination cleanup.\n");
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                settings_best_effort_termination_cleanup("SIGTERM");
                _Exit(0);
            });
        });
        dispatch_resume(g_sigterm_source);
    });
}

- (void)applicationWillTerminateNotification:(NSNotification *)note {
    settings_best_effort_termination_cleanup("UIApplicationWillTerminateNotification");
}

- (void)installBarAppearances {
    // Use the system's default glass material for ALL appearance states so the
    // bar never crossfades between transparent and blurred when content
    // scrolls past the edge. This is what UIKit's own apps do post-iOS 15.
    UINavigationBarAppearance *nav = [[UINavigationBarAppearance alloc] init];
    [nav configureWithDefaultBackground];
    UINavigationBar.appearance.standardAppearance = nav;
    UINavigationBar.appearance.scrollEdgeAppearance = nav;
    UINavigationBar.appearance.compactAppearance = nav;
    UINavigationBar.appearance.compactScrollEdgeAppearance = nav;

    UITabBarAppearance *tab = [[UITabBarAppearance alloc] init];
    [tab configureWithDefaultBackground];
    UITabBar.appearance.standardAppearance = tab;
    UITabBar.appearance.scrollEdgeAppearance = tab;
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    cyanide_launch_trace("applicationWillTerminate: entry");
    settings_best_effort_termination_cleanup("applicationWillTerminate");
    // Round 31: if this line is missing from the log while the entry line is
    // present, the cleanup hung AFTER its own last log line — the wedge that
    // leaves the process un-reaped and every relaunch foregrounding a corpse.
    cyanide_launch_trace("applicationWillTerminate: exit");
}

- (void)applicationWillResignActive:(UIApplication *)application {
    cyanide_launch_trace("applicationWillResignActive");
    // Round 30: non-UIScene pair of sceneWillResignActive: — close the
    // exception-port gate at the START of resignation so in-flight traps clear
    // before runningboardd policy-sets this task (184716). Re-opened by
    // didBecomeActive / willEnterForeground.
    excport_gate_set_backgrounded(true);
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    cyanide_launch_trace("applicationDidEnterBackground: entry");
    // Round 21: refuse new own-process exception-port traps immediately
    // (non-UIScene path; the scene path sets the same gate in
    // settings_application_did_enter_background).
    excport_gate_set_backgrounded(true);
    // iOS frequently kills a backgrounded app without ever calling
    // applicationWillTerminate, so secure the KRW primitive here too. Detach the
    // sockets to launchd's anchored fileports so the primitive survives device
    // sleep (a live session held by a suspended app dies across sleep); this
    // also parks the filter. Falls back to a plain filter park when detach isn't
    // available. Reversed by settings_reattach_krw_for_foreground() on return.
    settings_detach_krw_for_background();
}

@end
