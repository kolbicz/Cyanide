//
//  nsbar.m
//  NSBar: Network Speed Bar
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import "nsbar.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <math.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <time.h>

// Constants
// Only test my iPhone 14 in iOS 18.0
static const uint64_t kNSBarOverlayTag = 99422;
static const double kNSBarWinH = 18.0;
static const double kNSBarFontPt = 11.5;
// Was 999999.0/1001.0; keep it below the system status bar so scroll-to-top taps pass through.
static const double kNSBarWinLevel = 999.0;
static const double kNSBarMargin = 20.0;
static const double kNSBarTopY = 0.0;      // 顶部留 1px 间距
static const double kNSBarBottomY = 38.0;
static const double kNSBarDynamicIslandExtraY = 4.0;
static const double kNSBarTextHPad = 7.0;
static const double kNSBarMinWidth = 54.0;
static const double kNSBarNetworkWidth = 104.0;
static const double kNSBarPillBorderAlpha = 0.42;

// Manually flip to true when collecting detailed NSBar timing logs.
static const bool kNSBarDebugLogging = false;

#define NSBAR_DEBUG_LOG(fmt, ...) do { \
    if (kNSBarDebugLogging) log_user(fmt, ##__VA_ARGS__); \
} while (0)

// Global state
static uint64_t gNSBarApplyTick = 0;
static uint64_t gNSBarOverlayWindow = 0;
static uint64_t gNSBarOverlayLabel = 0;
static NSBarPosition gNSBarLastPosition = NSBarPositionTopLeft;

// Cached selectors
static uint64_t gNSBarSetTextSel = 0;
static uint64_t gNSBarPerformMainSel = 0;
static uint64_t gNSBarNSStringClass = 0;
static uint64_t gNSBarAllocSel = 0;
static uint64_t gNSBarInitUTF8Sel = 0;
static uint64_t gNSBarUIColorClass = 0;
static uint64_t gNSBarBorderColor = 0;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} NSBarRect;

typedef struct {
    double screenWidth;
    double screenHeight;
    double topAreaHeight;
} NSBarLayout;

typedef struct {
    double top;
    double left;
    double bottom;
    double right;
} NSBarEdgeInsets;

static bool nsbar_should_log_tick(void)
{
    return gNSBarApplyTick == 1;
}

static bool read_net_totals(uint64_t *ibytes, uint64_t *obytes)
{
    if (!ibytes || !obytes) return false;
    *ibytes = 0;
    *obytes = 0;

    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) return false;

    for (struct ifaddrs *ifa = head; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_data || !ifa->ifa_name) continue;
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        if ((ifa->ifa_flags & IFF_LOOPBACK) != 0) continue;
        if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;

        const struct if_data *data = (const struct if_data *)ifa->ifa_data;
        *ibytes += (uint64_t)data->ifi_ibytes;
        *obytes += (uint64_t)data->ifi_obytes;
    }

    freeifaddrs(head);
    return true;
}

static double nsbar_now_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static unsigned long long nsbar_elapsed_ms_since(double start)
{
    double now = nsbar_now_seconds();
    if (start <= 0.0 || now <= start) return 0;
    return (unsigned long long)((now - start) * 1000.0 + 0.5);
}

static void read_net_speed_kbps(double *downKB, double *upKB)
{
    static bool havePrev = false;
    static uint64_t prevIn = 0;
    static uint64_t prevOut = 0;
    static double prevTime = 0.0;

    if (downKB) *downKB = 0.0;
    if (upKB) *upKB = 0.0;

    uint64_t totalIn = 0;
    uint64_t totalOut = 0;
    double now = nsbar_now_seconds();
    if (now <= 0.0 || !read_net_totals(&totalIn, &totalOut)) return;

    if (havePrev && now > prevTime) {
        uint64_t din = (totalIn >= prevIn) ? (totalIn - prevIn) : 0;
        uint64_t dout = (totalOut >= prevOut) ? (totalOut - prevOut) : 0;
        double dt = now - prevTime;
        if (downKB) *downKB = ((double)din / dt) / 1024.0;
        if (upKB) *upKB = ((double)dout / dt) / 1024.0;
    }

    prevIn = totalIn;
    prevOut = totalOut;
    prevTime = now;
    havePrev = true;
}

static NSString *format_net_speed(double kbValue)
{
    if (!isfinite(kbValue) || kbValue < 0.0) kbValue = 0.0;
    if (kbValue < 999.5) return [NSString stringWithFormat:@"%lldK", (long long)llround(kbValue)];
    double mbValue = kbValue / 1024.0;
    if (mbValue < 10.0) return [NSString stringWithFormat:@"%.1fM", mbValue];
    return [NSString stringWithFormat:@"%.0fM", mbValue];
}

static NSString *build_nsbar_text(void)
{
    double downKB = 0.0;
    double upKB = 0.0;
    read_net_speed_kbps(&downKB, &upKB);
    return [NSString stringWithFormat:@"↓%@ ↑%@",
            format_net_speed(downKB), format_net_speed(upKB)];
}

static uint64_t nsbar_nsstring_utf8_fast(const char *cstr)
{
    if (!cstr) cstr = "n/a";
    uint64_t buf = r_alloc_str(cstr);
    if (!buf) return 0;
    if (!gNSBarNSStringClass) gNSBarNSStringClass = r_class("NSString");
    if (!gNSBarAllocSel) gNSBarAllocSel = r_sel("alloc");
    if (!gNSBarInitUTF8Sel) gNSBarInitUTF8Sel = r_sel("initWithUTF8String:");
    if (!r_is_objc_ptr(gNSBarNSStringClass) || !gNSBarAllocSel || !gNSBarInitUTF8Sel) {
        r_free(buf);
        return 0;
    }
    uint64_t allocated = r_msg(gNSBarNSStringClass, gNSBarAllocSel, 0, 0, 0, 0);
    uint64_t ns = r_is_objc_ptr(allocated) ? r_msg(allocated, gNSBarInitUTF8Sel, buf, 0, 0, 0) : 0;
    r_free(buf);
    return ns;
}

static bool nsbar_set_text_fast(uint64_t label, uint64_t textObj)
{
    if (!r_is_objc_ptr(label) || !r_is_objc_ptr(textObj)) return false;
    if (!gNSBarSetTextSel) gNSBarSetTextSel = r_sel("setText:");
    if (!gNSBarSetTextSel) return false;
    r_msg2_main(label, "setText:", textObj, 0, 0, 0);
    return true;
}

static void nsbar_release_remote_obj(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return;
    r_dlsym_call(R_TIMEOUT, "CFRelease", obj, 0, 0, 0, 0, 0, 0, 0);
}

static bool r_send_double_main(uint64_t obj, const char *selName, double value)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, selName,
                    &value, sizeof(value),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    return true;
}

static bool r_send_rect_main(uint64_t obj, const char *selName,
                             double x, double y, double width, double height)
{
    if (!r_is_objc_ptr(obj)) return false;
    NSBarRect rect = { x, y, width, height };
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    return true;
}

static uint64_t nsbar_pill_border_color(void)
{
    if (!r_is_objc_ptr(gNSBarUIColorClass)) gNSBarUIColorClass = r_class("UIColor");
    if (!r_is_objc_ptr(gNSBarUIColorClass)) return 0;
    if (!r_is_objc_ptr(gNSBarBorderColor)) {
        double white = 0.72;
        double alpha = kNSBarPillBorderAlpha;
        gNSBarBorderColor = r_msg2_main_raw(gNSBarUIColorClass, "colorWithWhite:alpha:",
                                            &white, sizeof(white),
                                            &alpha, sizeof(alpha),
                                            NULL, 0,
                                            NULL, 0);
    }
    return gNSBarBorderColor;
}

static void nsbar_make_label_click_through(uint64_t label)
{
    if (!r_is_objc_ptr(label)) return;
    r_msg2_main(label, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(label, "setMultipleTouchEnabled:", 0, 0, 0, 0);
    r_msg2_main(label, "setExclusiveTouch:", 0, 0, 0, 0);
}

static void nsbar_make_window_click_through(uint64_t win)
{
    if (!r_is_objc_ptr(win)) return;
    r_msg2_main(win, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(win, "setMultipleTouchEnabled:", 0, 0, 0, 0);
    r_msg2_main(win, "setExclusiveTouch:", 0, 0, 0, 0);

    const char *selectors[] = {
        "_setWindowIgnoresHitTest:",
        "setWindowIgnoresHitTest:",
        "_setIgnoresHitTesting:",
        "setIgnoresHitTesting:",
        "setIgnoresHitTest:",
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (r_responds_main(win, selectors[i])) {
            r_msg2_main(win, selectors[i], 1, 0, 0, 0);
        }
    }
}

static uint64_t nsbar_overlay_font(void)
{
    uint64_t UIFont = r_class("UIFont");
    if (!r_is_objc_ptr(UIFont)) return 0;

    double size = kNSBarFontPt;
    double weight = 0.0;
    uint64_t font = r_msg2_main_raw(UIFont, "monospacedDigitSystemFontOfSize:weight:",
                                    &size, sizeof(size),
                                    &weight, sizeof(weight),
                                    NULL, 0,
                                    NULL, 0);
    if (r_is_objc_ptr(font)) return font;

    return r_msg2_main_raw(UIFont, "systemFontOfSize:",
                           &size, sizeof(size),
                           NULL, 0,
                           NULL, 0,
                           NULL, 0);
}

static void nsbar_apply_overlay_style(uint64_t label)
{
    if (!r_is_objc_ptr(label)) return;
    nsbar_make_label_click_through(label);

    uint64_t font = nsbar_overlay_font();
    if (r_is_objc_ptr(font)) {
        r_msg2_main(label, "setFont:", font, 0, 0, 0);
    }
    r_msg2_main(label, "setAdjustsFontSizeToFitWidth:", 0, 0, 0, 0);
    r_msg2_main(label, "setLineBreakMode:", 2, 0, 0, 0); // NSLineBreakByClipping

    uint64_t layer = r_msg2_main(label, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        double radius = kNSBarWinH / 2.0;
        double borderWidth = 0.5;
        r_send_double_main(layer, "setCornerRadius:", radius);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
        r_send_double_main(layer, "setBorderWidth:", borderWidth);
        uint64_t borderColor = nsbar_pill_border_color();
        if (r_is_objc_ptr(borderColor)) {
            uint64_t cgColor = r_msg2_main(borderColor, "CGColor", 0, 0, 0, 0);
            if (cgColor) r_msg2_main(layer, "setBorderColor:", cgColor, 0, 0, 0);
        }
    }
}

static bool nsbar_valid_screen_length(double v)
{
    return isfinite(v) && v >= 100.0 && v <= 2000.0;
}

static bool nsbar_valid_top_area(double v)
{
    return isfinite(v) && v >= 8.0 && v <= 140.0;
}

static double nsbar_fallback_top_area(double screenWidth, double screenHeight)
{
    double shortSide = fmin(screenWidth, screenHeight);
    double longSide = fmax(screenWidth, screenHeight);
    if (!nsbar_valid_screen_length(shortSide) || !nsbar_valid_screen_length(longSide)) return 20.0;
    if (longSide >= 852.0 && shortSide >= 390.0) return 59.0;
    if (longSide >= 844.0 && shortSide >= 390.0) return 47.0;
    if (longSide >= 812.0 && shortSide >= 375.0) return 44.0;
    return 20.0;
}

static uint64_t nsbar_remote_key_window(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (r_is_objc_ptr(keyWin)) return keyWin;

    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t count = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
    if (count > 0 && count < 64) return r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
    return 0;
}

static double nsbar_remote_safe_area_top(void)
{
    uint64_t keyWin = nsbar_remote_key_window();
    if (!r_is_objc_ptr(keyWin)) return 0.0;

    NSBarEdgeInsets insets = {0};
    bool ok = r_msg2_main_struct_ret(keyWin, "safeAreaInsets",
                                     &insets, sizeof(insets),
                                     NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    if (!ok || !nsbar_valid_top_area(insets.top)) return 0.0;
    return insets.top;
}

static NSBarLayout nsbar_read_layout(void)
{
    NSBarLayout layout = { 390.0, 844.0, 47.0 };
    CGRect bounds = UIScreen.mainScreen.bounds;
    if (nsbar_valid_screen_length(bounds.size.width)) layout.screenWidth = bounds.size.width;
    if (nsbar_valid_screen_length(bounds.size.height)) layout.screenHeight = bounds.size.height;

    layout.topAreaHeight = nsbar_remote_safe_area_top();
    if (!nsbar_valid_top_area(layout.topAreaHeight)) {
        layout.topAreaHeight = nsbar_fallback_top_area(layout.screenWidth, layout.screenHeight);
    }
    return layout;
}

static double nsbar_bottom_row_y(double topAreaHeight)
{
    if (!nsbar_valid_top_area(topAreaHeight)) return kNSBarBottomY;
    double y = topAreaHeight - (kNSBarWinH / 2.0);
    if (topAreaHeight >= 55.0) y += kNSBarDynamicIslandExtraY;
    return fmax(kNSBarBottomY, floor(y));
}

static double nsbar_width_for_text(NSString *text, NSBarPosition position, NSBarLayout layout)
{
    double screenWidth = layout.screenWidth;
    if (!nsbar_valid_screen_length(screenWidth)) screenWidth = 390.0;
    double maxWidth = (position == NSBarPositionCenter)
        ? screenWidth * 0.40
        : (screenWidth * 0.5) - kNSBarMargin - 4.0;
    if (maxWidth < kNSBarMinWidth) maxWidth = kNSBarMinWidth;

    double width = kNSBarNetworkWidth;
    if (width < kNSBarMinWidth) width = kNSBarMinWidth;
    if (width > maxWidth) width = maxWidth;
    return width;
}

static void nsbar_calculate_position(NSBarPosition position,
                                     NSBarLayout layout,
                                     double *outX,
                                     double *outY,
                                     double width)
{
    double screenWidth = layout.screenWidth;
    if (!nsbar_valid_screen_length(screenWidth)) screenWidth = 390.0;
    
    double x = 0.0;
    double y = 0.0;
    
    switch (position) {
        case NSBarPositionTopLeft:
            x = kNSBarMargin;
            y = kNSBarTopY;
            break;
        case NSBarPositionBottomLeft:
            x = kNSBarMargin;
            y = nsbar_bottom_row_y(layout.topAreaHeight);
            break;
        case NSBarPositionTopRight:
            x = screenWidth - width - kNSBarMargin;
            y = kNSBarTopY;
            break;
        case NSBarPositionBottomRight:
            x = screenWidth - width - kNSBarMargin;
            y = nsbar_bottom_row_y(layout.topAreaHeight);
            break;
        case NSBarPositionCenter:
            // With StatBar same position
            x = (screenWidth - width) / 2.0;
            y = nsbar_bottom_row_y(layout.topAreaHeight);
            printf("[NSBAR] Center position: screenWidth=%.1f width=%.1f x=%.1f y=%.1f\n",
                   screenWidth, width, x, y);
            break;
        default:
            printf("[NSBAR] Unknown position: %d, using top left\n", position);
            x = kNSBarMargin;
            y = kNSBarTopY;
            break;
    }
    
    *outX = x;
    *outY = y;
}

static bool nsbar_apply_overlay_layout(uint64_t win, uint64_t label, NSBarPosition position, NSString *text)
{
    if (!r_is_objc_ptr(win)) return false;

    NSBarLayout layout = nsbar_read_layout();
    double width = nsbar_width_for_text(text, position, layout);
    double x = 0.0;
    double y = 0.0;
    
    nsbar_calculate_position(position, layout, &x, &y, width);

    if (nsbar_should_log_tick()) {
        printf("[NSBAR] overlay: layout position=%d screen=%.1fx%.1f top=%.1f frame={%.1f,%.1f,%.1f,%.1f}\n",
               position, layout.screenWidth, layout.screenHeight, layout.topAreaHeight, x, y, width, kNSBarWinH);
    }

    bool ok = true;
    ok &= r_send_rect_main(win, "setFrame:", x, y, width, kNSBarWinH);
    ok &= r_send_double_main(win, "setWindowLevel:", kNSBarWinLevel);
    r_msg2_main(win, "setUserInteractionEnabled:", 0, 0, 0, 0);

    if (r_is_objc_ptr(label)) {
        ok &= r_send_rect_main(label, "setFrame:", 0.0, 0.0, width, kNSBarWinH);
    }
    
    return ok;
}

static bool nsbar_install_overlay(NSString *text, NSBarPosition position)
{
    double start = nsbar_now_seconds();
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] start position=%d cachedWindow=0x%llx cachedLabel=0x%llx\n",
                    position, gNSBarOverlayWindow, gNSBarOverlayLabel);
    if (nsbar_should_log_tick())
        printf("[NSBAR] overlay: entry (dedicated UIWindow)\n");

    const char *utf8 = text.UTF8String;
    if (!utf8) utf8 = "n/a";
    double stringStart = nsbar_now_seconds();
    uint64_t textObj = nsbar_nsstring_utf8_fast(utf8);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] textObj=0x%llx elapsed=%llums\n",
                    textObj, nsbar_elapsed_ms_since(stringStart));
    if (!r_is_objc_ptr(textObj)) { 
        printf("[NSBAR] overlay: NSString alloc failed\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=textObj total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    // Fast path: update existing overlay
    if (r_is_objc_ptr(gNSBarOverlayWindow) && r_is_objc_ptr(gNSBarOverlayLabel)) {
        double fastStart = nsbar_now_seconds();
        if (nsbar_should_log_tick())
            printf("[NSBAR] fast path: current position=%d last position=%d\n", position, gNSBarLastPosition);
        bool ok = nsbar_set_text_fast(gNSBarOverlayLabel, textObj);
        nsbar_release_remote_obj(textObj);
        if (ok) {
            double layoutStart = nsbar_now_seconds();
            nsbar_apply_overlay_layout(gNSBarOverlayWindow, gNSBarOverlayLabel, position, text);
            gNSBarLastPosition = position;
            if (nsbar_should_log_tick())
                printf("[NSBAR] overlay: fast cached text updated\n");
            NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] fast-path ok=1 setTextAndRelease=%llums layout=%llums total=%llums\n",
                            nsbar_elapsed_ms_since(fastStart),
                            nsbar_elapsed_ms_since(layoutStart),
                            nsbar_elapsed_ms_since(start));
            return true;
        }
        gNSBarOverlayWindow = 0;
        gNSBarOverlayLabel = 0;
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] fast-path ok=0 elapsed=%llums total=%llums\n",
                        nsbar_elapsed_ms_since(fastStart),
                        nsbar_elapsed_ms_since(start));
        return false;
    }

    // Create new overlay
    double appStart = nsbar_now_seconds();
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) {
        nsbar_release_remote_obj(textObj);
        printf("[NSBAR] overlay: UIApplication missing\n");
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=uiapplication total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false;
    }

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] app=0x%llx elapsed=%llums\n",
                    app, nsbar_elapsed_ms_since(appStart));
    if (!r_is_objc_ptr(app)) {
        nsbar_release_remote_obj(textObj);
        printf("[NSBAR] overlay: sharedApplication nil\n");
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=sharedApplication total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false;
    }

    double assocStart = nsbar_now_seconds();
    uint64_t assocKey = r_sel("darkswordNSBarOverlayWindow");
    if (!assocKey) {
        nsbar_release_remote_obj(textObj);
        printf("[NSBAR] overlay: assoc key failed\n");
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=assoc-key total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false;
    }

    // Check for cached window
    uint64_t cachedWin = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      app, assocKey, 0, 0, 0, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] assoc key=%llu cachedWin=0x%llx elapsed=%llums\n",
                    assocKey, cachedWin, nsbar_elapsed_ms_since(assocStart));
    if (r_is_objc_ptr(cachedWin)) {
        double cachedStart = nsbar_now_seconds();
        uint64_t cachedLabel = r_msg2_main(cachedWin, "viewWithTag:", kNSBarOverlayTag, 0, 0, 0);
        if (nsbar_should_log_tick())
            printf("[NSBAR] overlay: cached window=0x%llx label=0x%llx\n", cachedWin, cachedLabel);
        if (r_is_objc_ptr(cachedLabel)) {
            gNSBarOverlayWindow = cachedWin;
            gNSBarOverlayLabel = cachedLabel;
            gNSBarLastPosition = position;
            nsbar_set_text_fast(cachedLabel, textObj);
            nsbar_make_window_click_through(cachedWin);
            nsbar_apply_overlay_style(cachedLabel);
            nsbar_apply_overlay_layout(cachedWin, cachedLabel, position, text);
            r_msg2_main(cachedWin, "setHidden:", 0, 0, 0, 0);
            nsbar_release_remote_obj(textObj);
            if (nsbar_should_log_tick())
                printf("[NSBAR] overlay: cached text updated\n");
            NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] associated-cache ok=1 label=0x%llx elapsed=%llums total=%llums\n",
                            cachedLabel, nsbar_elapsed_ms_since(cachedStart),
                            nsbar_elapsed_ms_since(start));
            return true;
        }
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, assocKey, 0, 1, 0, 0, 0, 0);
        gNSBarOverlayWindow = 0;
        gNSBarOverlayLabel = 0;
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] associated-cache invalid label=0x%llx elapsed=%llums\n",
                        cachedLabel, nsbar_elapsed_ms_since(cachedStart));
    }

    // Get window scene
    double sceneStart = nsbar_now_seconds();
    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        uint64_t count = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
        if (count > 0 && count < 64) keyWin = r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] keyWindow fallback windows=0x%llx count=%llu keyWin=0x%llx\n",
                        windows, count, keyWin);
    }
    if (!r_is_objc_ptr(keyWin)) { 
        printf("[NSBAR] overlay: keyWindow nil\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=keyWindow total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] keyWin=0x%llx scene=0x%llx elapsed=%llums\n",
                    keyWin, scene, nsbar_elapsed_ms_since(sceneStart));
    if (!r_is_objc_ptr(scene)) { 
        printf("[NSBAR] overlay: windowScene nil\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=windowScene total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    // Create window
    double windowStart = nsbar_now_seconds();
    uint64_t UIWindow = r_class("UIWindow");
    if (!r_is_objc_ptr(UIWindow)) { 
        printf("[NSBAR] overlay: UIWindow missing\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=uiwindow total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    uint64_t winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(winAlloc)) { 
        printf("[NSBAR] overlay: UIWindow alloc failed\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=window-alloc total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    uint64_t win = r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] window alloc=0x%llx win=0x%llx elapsed=%llums\n",
                    winAlloc, win, nsbar_elapsed_ms_since(windowStart));
    if (!r_is_objc_ptr(win)) { 
        printf("[NSBAR] overlay: initWithWindowScene failed\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=window-init total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }
    if (nsbar_should_log_tick())
        printf("[NSBAR] overlay: window=0x%llx\n", win);

    uint64_t UIColor = r_class("UIColor");
    if (r_is_objc_ptr(UIColor)) {
        double colorStart = nsbar_now_seconds();
        uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0, 0, 0);
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] window color clear=0x%llx elapsed=%llums\n",
                        clear, nsbar_elapsed_ms_since(colorStart));
    }

    // Create label
    double labelStart = nsbar_now_seconds();
    uint64_t UILabel = r_class("UILabel");
    if (!r_is_objc_ptr(UILabel)) { 
        printf("[NSBAR] overlay: UILabel missing\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=uilabel total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    uint64_t labelAlloc = r_msg2_main(UILabel, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(labelAlloc)) { 
        printf("[NSBAR] overlay: UILabel alloc failed\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=label-alloc total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }

    uint64_t label = r_msg2_main(labelAlloc, "init", 0, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] label alloc=0x%llx label=0x%llx elapsed=%llums\n",
                    labelAlloc, label, nsbar_elapsed_ms_since(labelStart));
    if (!r_is_objc_ptr(label)) { 
        printf("[NSBAR] overlay: UILabel init failed\n"); 
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=0 reason=label-init total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        return false; 
    }
    if (nsbar_should_log_tick())
        printf("[NSBAR] overlay: label=0x%llx\n", label);

    r_msg2_main(label, "setText:", textObj, 0, 0, 0);
    r_msg2_main(label, "setTag:", kNSBarOverlayTag, 0, 0, 0);
    r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);
    r_msg2_main(label, "setNumberOfLines:", 1, 0, 0, 0);
    r_msg2_main(label, "setAdjustsFontSizeToFitWidth:", 0, 0, 0, 0);
    r_msg2_main(label, "setLineBreakMode:", 2, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] label base-config elapsed=%llums\n",
                    nsbar_elapsed_ms_since(labelStart));

    if (r_is_objc_ptr(UIColor)) {
        double labelColorStart = nsbar_now_seconds();
        uint64_t black = r_msg2_main(UIColor, "blackColor", 0, 0, 0, 0);
        uint64_t white = r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(black)) r_msg2_main(label, "setBackgroundColor:", black, 0, 0, 0);
        if (r_is_objc_ptr(white)) r_msg2_main(label, "setTextColor:", white, 0, 0, 0);
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] label colors black=0x%llx white=0x%llx elapsed=%llums\n",
                        black, white, nsbar_elapsed_ms_since(labelColorStart));
    }

    double styleStart = nsbar_now_seconds();
    nsbar_apply_overlay_style(label);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] style elapsed=%llums\n",
                    nsbar_elapsed_ms_since(styleStart));
    double clickStart = nsbar_now_seconds();
    nsbar_make_window_click_through(win);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] click-through elapsed=%llums\n",
                    nsbar_elapsed_ms_since(clickStart));
    double layoutStart = nsbar_now_seconds();
    nsbar_apply_overlay_layout(win, label, position, text);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] layout elapsed=%llums\n",
                    nsbar_elapsed_ms_since(layoutStart));
    double attachStart = nsbar_now_seconds();
    r_msg2_main(win, "addSubview:", label, 0, 0, 0);
    r_msg2_main(win, "setHidden:", 0, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, assocKey, win, 1, 0, 0, 0, 0);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] attach/show/assoc elapsed=%llums\n",
                    nsbar_elapsed_ms_since(attachStart));
    
    gNSBarOverlayWindow = win;
    gNSBarOverlayLabel = label;
    gNSBarLastPosition = position;
    nsbar_release_remote_obj(textObj);

    if (nsbar_should_log_tick())
        printf("[NSBAR] overlay: installed dedicated window\n");
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][install] end ok=1 total=%llums window=0x%llx label=0x%llx\n",
                    nsbar_elapsed_ms_since(start), win, label);
    return true;
}

bool nsbar_apply_in_session(NSBarPosition position)
{
    uint32_t oldSettleUS = r_settle_us(0);
    double start = nsbar_now_seconds();
    gNSBarApplyTick++;
    double textStart = nsbar_now_seconds();
    NSString *text = build_nsbar_text();
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][apply] text='%s' position=%d tick=%llu settleUS=%u->0 buildText=%llums\n",
                    text.UTF8String, position, gNSBarApplyTick, oldSettleUS,
                    nsbar_elapsed_ms_since(textStart));
    if (nsbar_should_log_tick()) {
        printf("[NSBAR] === entry === text='%s' position=%d tick=%llu\n",
               text.UTF8String, position, gNSBarApplyTick);
    }

    double installStart = nsbar_now_seconds();
    bool ok = nsbar_install_overlay(text, position);
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][apply] install ok=%d elapsed=%llums total=%llums\n",
                    ok ? 1 : 0, nsbar_elapsed_ms_since(installStart),
                    nsbar_elapsed_ms_since(start));
    r_settle_us(oldSettleUS);
    return ok;
}

bool nsbar_stop_in_session(void)
{
    uint32_t oldSettleUS = r_settle_us(0);
    double start = nsbar_now_seconds();
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][stop] start window=0x%llx label=0x%llx settleUS=%u->0\n",
                    gNSBarOverlayWindow, gNSBarOverlayLabel, oldSettleUS);
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) {
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][stop] end ok=0 reason=uiapplication total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        r_settle_us(oldSettleUS);
        return false;
    }

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) {
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][stop] end ok=0 reason=sharedApplication total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        r_settle_us(oldSettleUS);
        return false;
    }

    uint64_t assocKey = r_sel("darkswordNSBarOverlayWindow");
    if (!assocKey) {
        NSBAR_DEBUG_LOG("[NSBAR][DEBUG][stop] end ok=0 reason=assoc-key total=%llums\n",
                        nsbar_elapsed_ms_since(start));
        r_settle_us(oldSettleUS);
        return false;
    }

    uint64_t win = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                app, assocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(win)) {
        r_msg2_main(win, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, assocKey, 0, 1, 0, 0, 0, 0);
    }

    gNSBarOverlayWindow = 0;
    gNSBarOverlayLabel = 0;
    printf("[NSBAR] overlay: stopped\n");
    NSBAR_DEBUG_LOG("[NSBAR][DEBUG][stop] end ok=1 total=%llums\n",
                    nsbar_elapsed_ms_since(start));
    r_settle_us(oldSettleUS);
    return true;
}

void nsbar_forget_remote_state(void)
{
    gNSBarOverlayWindow = 0;
    gNSBarOverlayLabel = 0;
    gNSBarSetTextSel = 0;
    gNSBarPerformMainSel = 0;
    gNSBarNSStringClass = 0;
    gNSBarAllocSel = 0;
    gNSBarInitUTF8Sel = 0;
    gNSBarUIColorClass = 0;
    gNSBarBorderColor = 0;
    printf("[NSBAR] forgot remote overlay state\n");
}
