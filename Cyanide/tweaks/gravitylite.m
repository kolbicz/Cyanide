//
//  gravitylite.m
//  RemoteCall-only core port of Julio Verne's Gravity tweak.
//

#import "gravitylite.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

typedef struct {
    double a;
    double b;
    double c;
    double d;
    double tx;
    double ty;
} GL_CGAffineTransform;

typedef struct {
    double x;
    double y;
    double w;
    double h;
} GL_CGRect;

typedef struct {
    double top;
    double left;
    double bottom;
    double right;
} GL_UIEdgeInsets;

static uint64_t s_gravity_ptrs[8];
static volatile int s_gravity_ptr_count = 0;
static const uint64_t kGravityLiteOverlayTag = 0x47524156ULL; // "GRAV"
static const double kGravityLiteSnapshotScale = 1.22;

static uint64_t gl_safe_msg(uint64_t obj, const char *selName,
                            uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!r_is_objc_ptr(obj) || !selName) return 0;
    if (!r_responds_main(obj, selName)) return 0;
    return r_msg2_main(obj, selName, a0, a1, a2, a3);
}

static uint64_t gl_icon_controller(void)
{
    uint64_t cls = r_class("SBIconController");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
}

static uint64_t gl_icon_manager(uint64_t ctrl)
{
    return gl_safe_msg(ctrl, "iconManager", 0, 0, 0, 0);
}

static uint64_t gl_root_folder_controller(uint64_t ctrl, uint64_t mgr);

static uint64_t gl_dock_list_view(uint64_t ctrl, uint64_t mgr)
{
    uint64_t dock = gl_safe_msg(mgr, "dockListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(dock)) dock = gl_safe_msg(ctrl, "dockListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(dock)) {
        uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
        dock = gl_safe_msg(rootFC, "dockListView", 0, 0, 0, 0);
    }
    return dock;
}

static uint64_t gl_dock_list_view_legacy(uint64_t ctrl, uint64_t mgr)
{
    uint64_t dock = gl_safe_msg(mgr, "dockListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(dock)) dock = gl_safe_msg(ctrl, "dockListView", 0, 0, 0, 0);
    return dock;
}

static uint64_t gl_dock_list_view_for_path(uint64_t ctrl, uint64_t mgr, bool useIOS26Path)
{
    return useIOS26Path ? gl_dock_list_view(ctrl, mgr) : gl_dock_list_view_legacy(ctrl, mgr);
}

static uint64_t gl_current_root_list_view(uint64_t ctrl, uint64_t mgr);

static uint64_t gl_state_key(void)
{
    return r_sel("cyanideGravityLiteState");
}

static uint64_t gl_get_state(uint64_t ctrl)
{
    uint64_t key = gl_state_key();
    if (!r_is_objc_ptr(ctrl) || !key) return 0;
    return r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                        ctrl, key, 0, 0, 0, 0, 0, 0);
}

static void gl_set_state(uint64_t ctrl, uint64_t state)
{
    uint64_t key = gl_state_key();
    if (!r_is_objc_ptr(ctrl) || !key) return;
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 ctrl, key, state, state ? 1 : 0, 0, 0, 0, 0);
}

static uint64_t gl_new_remote(const char *className)
{
    uint64_t cls = r_class(className);
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2(cls, "new", 0, 0, 0, 0);
}

static void gl_release(uint64_t obj)
{
    if (r_is_objc_ptr(obj)) r_msg2(obj, "release", 0, 0, 0, 0);
}

static uint64_t gl_key(const char *s)
{
    return r_nsstr_retained(s);
}

static int gl_remote_ios_major(void)
{
    uint64_t uid = r_class("UIDevice");
    uint64_t device = r_is_objc_ptr(uid) ? r_msg2(uid, "currentDevice", 0, 0, 0, 0) : 0;
    uint64_t version = r_is_objc_ptr(device) ? gl_safe_msg(device, "systemVersion", 0, 0, 0, 0) : 0;
    char buf[32] = {0};
    if (!r_read_nsstring(version, buf, sizeof(buf))) return 0;
    int major = atoi(buf);
    return major > 0 ? major : 0;
}

static void gl_dict_set(uint64_t dict, const char *key, uint64_t value)
{
    if (!r_is_objc_ptr(dict) || !r_is_objc_ptr(value)) return;
    uint64_t k = gl_key(key);
    if (!r_is_objc_ptr(k)) return;
    r_msg2(dict, "setObject:forKey:", value, k, 0, 0);
    gl_release(k);
}

static uint64_t gl_dict_get(uint64_t dict, const char *key)
{
    if (!r_is_objc_ptr(dict)) return 0;
    uint64_t k = gl_key(key);
    if (!r_is_objc_ptr(k)) return 0;
    uint64_t value = r_msg2(dict, "objectForKey:", k, 0, 0, 0);
    gl_release(k);
    return value;
}

static void gl_array_add(uint64_t array, uint64_t obj)
{
    if (!r_is_objc_ptr(array) || !r_is_objc_ptr(obj)) return;
    r_msg2(array, "addObject:", obj, 0, 0, 0);
}

static uint64_t gl_array_count(uint64_t array)
{
    if (!r_is_objc_ptr(array)) return 0;
    return r_msg2(array, "count", 0, 0, 0, 0);
}

static uint64_t gl_array_object(uint64_t array, uint64_t index)
{
    if (!r_is_objc_ptr(array)) return 0;
    return r_msg2(array, "objectAtIndex:", index, 0, 0, 0);
}

static uint64_t gl_subviews(uint64_t view)
{
    return gl_safe_msg(view, "subviews", 0, 0, 0, 0);
}

static bool gl_ptr_seen(uint64_t ptr, const uint64_t *items, int count)
{
    for (int i = 0; i < count; i++) {
        if (items[i] == ptr) return true;
    }
    return false;
}

static void gl_set_double(uint64_t obj, const char *selName, double value)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return;
    r_msg2_main_raw(obj, selName,
                    &value, sizeof(value),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void gl_set_bool(uint64_t obj, const char *selName, bool value)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return;
    uint8_t v = value ? 1 : 0;
    r_msg2_main_raw(obj, selName,
                    &v, sizeof(v),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void gl_set_integer(uint64_t obj, const char *selName, uint64_t value)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return;
    r_msg2_main(obj, selName, value, 0, 0, 0);
}

static uint64_t gl_get_integer(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return 0;
    return r_msg2_main(obj, selName, 0, 0, 0, 0);
}

static bool gl_get_rect(uint64_t obj, const char *selName, GL_CGRect *out)
{
    if (!r_is_objc_ptr(obj) || !selName || !out || !r_responds_main(obj, selName)) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(obj, selName,
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static void gl_set_rect(uint64_t obj, const char *selName, GL_CGRect rect)
{
    if (!r_is_objc_ptr(obj) || !selName || !r_responds_main(obj, selName)) return;
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

static uint64_t gl_value_with_rect(GL_CGRect rect)
{
    uint64_t cls = r_class("NSValue");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2_main_raw(cls, "valueWithCGRect:",
                           &rect, sizeof(rect),
                           NULL, 0, NULL, 0, NULL, 0);
}

static bool gl_rect_from_value(uint64_t value, GL_CGRect *out)
{
    if (!r_is_objc_ptr(value) || !out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(value, "CGRectValue",
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static bool gl_rect_valid(GL_CGRect rect)
{
    return rect.w > 1.0 && rect.h > 1.0;
}

static GL_CGRect gl_rect_intersection(GL_CGRect a, GL_CGRect b)
{
    double x1 = fmax(a.x, b.x);
    double y1 = fmax(a.y, b.y);
    double x2 = fmin(a.x + a.w, b.x + b.w);
    double y2 = fmin(a.y + a.h, b.y + b.h);
    if (x2 <= x1 || y2 <= y1) return (GL_CGRect){0};
    return (GL_CGRect){x1, y1, x2 - x1, y2 - y1};
}

static bool gl_rect_overlaps_bounds(GL_CGRect rect, GL_CGRect bounds)
{
    double maxX = rect.x + rect.w;
    double maxY = rect.y + rect.h;
    return maxX > 1.0 &&
           maxY > 1.0 &&
           rect.x < bounds.w - 1.0 &&
           rect.y < bounds.h - 1.0;
}

static GL_CGRect gl_rect_scale_about_center(GL_CGRect rect, double scale)
{
    if (scale <= 0.0) return rect;
    double newW = rect.w * scale;
    double newH = rect.h * scale;
    rect.x -= (newW - rect.w) * 0.5;
    rect.y -= (newH - rect.h) * 0.5;
    rect.w = newW;
    rect.h = newH;
    return rect;
}

static uint64_t gl_view_window(uint64_t view)
{
    return gl_safe_msg(view, "window", 0, 0, 0, 0);
}

static bool gl_convert_rect_to_view(uint64_t view,
                                    GL_CGRect rect,
                                    uint64_t targetView,
                                    GL_CGRect *out)
{
    if (!r_is_objc_ptr(view) || !out || !r_responds_main(view, "convertRect:toView:")) return false;
    uint64_t target = targetView;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(view, "convertRect:toView:",
                                  out, sizeof(*out),
                                  &rect, sizeof(rect),
                                  &target, sizeof(target),
                                  NULL, 0, NULL, 0);
}

static bool gl_view_is_hidden(uint64_t view)
{
    if (!r_is_objc_ptr(view)) return true;
    if (r_responds_main(view, "isHidden") && r_msg2_main(view, "isHidden", 0, 0, 0, 0)) return true;
    return false;
}

static bool gl_view_has_visible_window_rect(uint64_t view)
{
    uint64_t window = gl_view_window(view);
    if (!r_is_objc_ptr(window) || gl_view_is_hidden(view)) return false;

    GL_CGRect bounds;
    GL_CGRect windowBounds;
    GL_CGRect inWindow;
    if (!gl_get_rect(view, "bounds", &bounds) || !gl_rect_valid(bounds)) return false;
    if (!gl_get_rect(window, "bounds", &windowBounds) || !gl_rect_valid(windowBounds)) return false;
    if (!gl_convert_rect_to_view(view, bounds, window, &inWindow) || !gl_rect_valid(inWindow)) return false;

    double maxX = inWindow.x + inWindow.w;
    double maxY = inWindow.y + inWindow.h;
    return maxX > 1.0 &&
           maxY > 1.0 &&
           inWindow.x < windowBounds.w - 1.0 &&
           inWindow.y < windowBounds.h - 1.0;
}

static void gl_reset_transform(uint64_t view)
{
    if (!r_is_objc_ptr(view) || !r_responds_main(view, "setTransform:")) return;
    GL_CGAffineTransform t = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
    r_msg2_main_raw(view, "setTransform:",
                    &t, sizeof(t),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void gl_layout_list_view(uint64_t listView)
{
    if (!r_is_objc_ptr(listView)) return;

    if (r_responds_main(listView, "setIconsNeedLayout")) {
        r_msg2_main(listView, "setIconsNeedLayout", 0, 0, 0, 0);
    }
    if (r_responds_main(listView, "layoutIconsIfNeeded:domino:")) {
        double duration = 0.2;
        uint8_t no = 0;
        r_msg2_main_raw(listView, "layoutIconsIfNeeded:domino:",
                        &duration, sizeof(duration),
                        &no, sizeof(no),
                        NULL, 0, NULL, 0);
    } else {
        gl_safe_msg(listView, "setNeedsLayout", 0, 0, 0, 0);
        gl_safe_msg(listView, "layoutIfNeeded", 0, 0, 0, 0);
    }
}

static uint64_t gl_alloc_init_with_items(const char *className, uint64_t items)
{
    uint64_t cls = r_class(className);
    if (!r_is_objc_ptr(cls) || !r_is_objc_ptr(items)) return 0;
    uint64_t obj = r_msg2(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t inited = r_msg2_main(obj, "initWithItems:", items, 0, 0, 0);
    return r_is_objc_ptr(inited) ? inited : obj;
}

static uint64_t gl_animator_for_reference_view(uint64_t referenceView)
{
    uint64_t cls = r_class("UIDynamicAnimator");
    if (!r_is_objc_ptr(cls) || !r_is_objc_ptr(referenceView)) return 0;
    uint64_t obj = r_msg2(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t inited = r_msg2_main(obj, "initWithReferenceView:", referenceView, 0, 0, 0);
    return r_is_objc_ptr(inited) ? inited : obj;
}

static uint64_t gl_view_with_frame(GL_CGRect frame)
{
    uint64_t cls = r_class("UIView");
    if (!r_is_objc_ptr(cls) || !gl_rect_valid(frame)) return 0;
    uint64_t obj = r_msg2(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t inited = r_msg2_main_raw(obj, "initWithFrame:",
                                      &frame, sizeof(frame),
                                      NULL, 0, NULL, 0, NULL, 0);
    return r_is_objc_ptr(inited) ? inited : obj;
}

static uint64_t gl_snapshot_for_view(uint64_t view,
                                     GL_CGRect sourceBounds,
                                     GL_CGRect frame,
                                     bool afterUpdates,
                                     bool preferRectSnapshot)
{
    if (!r_is_objc_ptr(view)) return 0;
    uint64_t snapshot = 0;
    if (preferRectSnapshot && r_responds_main(view, "resizableSnapshotViewFromRect:afterScreenUpdates:withCapInsets:")) {
        uint8_t updates = afterUpdates ? 1 : 0;
        GL_UIEdgeInsets insets = {0};
        snapshot = r_msg2_main_raw(view, "resizableSnapshotViewFromRect:afterScreenUpdates:withCapInsets:",
                                   &sourceBounds, sizeof(sourceBounds),
                                   &updates, sizeof(updates),
                                   &insets, sizeof(insets),
                                   NULL, 0);
    }
    if (!r_is_objc_ptr(snapshot)) {
        snapshot = gl_safe_msg(view, "snapshotViewAfterScreenUpdates:", afterUpdates ? 1 : 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(snapshot)) return 0;
    gl_set_rect(snapshot, "setFrame:", frame);
    return snapshot;
}

static uint64_t gl_overlay_for_list_view(uint64_t listView, GL_CGRect *overlayFrameOut)
{
    uint64_t window = gl_view_window(listView);
    if (!r_is_objc_ptr(window)) return 0;

    GL_CGRect listBounds;
    GL_CGRect overlayFrame;
    GL_CGRect windowBounds;
    if (!gl_get_rect(listView, "bounds", &listBounds) || !gl_rect_valid(listBounds)) return 0;
    if (!gl_get_rect(window, "bounds", &windowBounds) || !gl_rect_valid(windowBounds)) return 0;
    if (!gl_convert_rect_to_view(listView, listBounds, window, &overlayFrame) ||
        !gl_rect_valid(overlayFrame)) {
        return 0;
    }

    GL_CGRect clippedFrame = gl_rect_intersection(overlayFrame, windowBounds);
    if (!gl_rect_valid(clippedFrame) || clippedFrame.w < overlayFrame.w * 0.5) {
        return 0;
    }
    overlayFrame = clippedFrame;

    uint64_t overlay = gl_view_with_frame(overlayFrame);
    if (!r_is_objc_ptr(overlay)) return 0;
    gl_set_integer(overlay, "setTag:", kGravityLiteOverlayTag);
    gl_set_bool(overlay, "setClipsToBounds:", true);
    gl_set_bool(overlay, "setUserInteractionEnabled:", false);
    r_msg2_main(window, "addSubview:", overlay, 0, 0, 0);
    if (overlayFrameOut) *overlayFrameOut = overlayFrame;
    return overlay;
}

static uint64_t gl_overlay_for_list_view_ios26_legacy(uint64_t listView, GL_CGRect *overlayFrameOut)
{
    uint64_t window = gl_view_window(listView);
    if (!r_is_objc_ptr(window)) return 0;

    GL_CGRect listBounds;
    GL_CGRect overlayFrame;
    if (!gl_get_rect(listView, "bounds", &listBounds) || !gl_rect_valid(listBounds)) return 0;
    if (!gl_convert_rect_to_view(listView, listBounds, window, &overlayFrame) ||
        !gl_rect_valid(overlayFrame)) {
        return 0;
    }

    uint64_t overlay = gl_view_with_frame(overlayFrame);
    if (!r_is_objc_ptr(overlay)) return 0;
    gl_set_bool(overlay, "setClipsToBounds:", true);
    gl_set_bool(overlay, "setUserInteractionEnabled:", false);
    r_msg2_main(window, "addSubview:", overlay, 0, 0, 0);
    if (overlayFrameOut) *overlayFrameOut = overlayFrame;
    return overlay;
}

static void gl_set_array_views_alpha(uint64_t views, double alpha)
{
    uint64_t count = gl_array_count(views);
    if (count > 256) count = 256;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t view = gl_array_object(views, i);
        if (r_is_objc_ptr(view)) gl_set_double(view, "setAlpha:", alpha);
    }
}

static int gl_unhide_icon_array(uint64_t icons)
{
    uint64_t count = gl_array_count(icons);
    if (count > 256) count = 256;

    int restored = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t icon = gl_array_object(icons, i);
        if (!r_is_objc_ptr(icon)) continue;
        gl_set_bool(icon, "setHidden:", false);
        gl_reset_transform(icon);
        restored++;
    }
    return restored;
}

static int gl_restore_live_items(uint64_t items, uint64_t parents, uint64_t frames)
{
    uint64_t count = gl_array_count(items);
    uint64_t parentCount = gl_array_count(parents);
    uint64_t frameCount = gl_array_count(frames);
    if (count > parentCount) count = parentCount;
    if (count > frameCount) count = frameCount;
    if (count > 64) count = 64;

    int restored = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t item = gl_array_object(items, i);
        uint64_t parent = gl_array_object(parents, i);
        uint64_t frameValue = gl_array_object(frames, i);
        GL_CGRect frame;
        if (!r_is_objc_ptr(item) ||
            !r_is_objc_ptr(parent) ||
            !gl_rect_from_value(frameValue, &frame) ||
            !gl_rect_valid(frame)) {
            continue;
        }

        r_msg2_main(parent, "addSubview:", item, 0, 0, 0);
        gl_set_rect(item, "setFrame:", frame);
        restored++;
    }
    return restored;
}

static int gl_cleanup_gravity_overlays_in_window(uint64_t window, uint64_t uiViewCls)
{
    (void)uiViewCls;
    uint64_t subviews = gl_subviews(window);
    uint64_t count = gl_array_count(subviews);
    if (count > 512) count = 512;

    uint64_t selTag = r_sel("tag");
    if (!selTag) return 0;

    int removed = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t view = gl_array_object(subviews, i);
        if (!r_is_objc_ptr(view)) continue;

        if (r_msg(view, selTag, 0, 0, 0, 0) != kGravityLiteOverlayTag) continue;

        r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);
        removed++;
    }
    return removed;
}

static int gl_cleanup_gravity_overlays_in_app_windows(void)
{
    uint64_t uiViewCls = r_class("UIView");
    uint64_t appCls = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(appCls) ? r_msg2_main(appCls, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t windows = r_is_objc_ptr(app) ? gl_safe_msg(app, "windows", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(uiViewCls) || !r_is_objc_ptr(windows)) return 0;

    uint64_t count = gl_array_count(windows);
    if (count > 64) count = 64;

    int removed = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t window = gl_array_object(windows, i);
        if (!r_is_objc_ptr(window)) continue;
        removed += gl_cleanup_gravity_overlays_in_window(window, uiViewCls);
    }
    return removed;
}

static void gl_remove_push_behaviors(uint64_t animator)
{
    if (!r_is_objc_ptr(animator)) return;
    uint64_t pushCls = r_class("UIPushBehavior");
    uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
    if (!r_is_objc_ptr(pushCls) || !r_is_objc_ptr(behaviors)) return;

    uint64_t copy = r_msg2(behaviors, "copy", 0, 0, 0, 0);
    uint64_t list = r_is_objc_ptr(copy) ? copy : behaviors;
    uint64_t count = gl_array_count(list);
    if (count > 256) count = 256;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t behavior = gl_array_object(list, i);
        if (!r_is_objc_ptr(behavior)) continue;
        if (!r_msg2(behavior, "isKindOfClass:", pushCls, 0, 0, 0)) continue;
        r_msg2_main(animator, "removeBehavior:", behavior, 0, 0, 0);
    }
    if (copy) gl_release(copy);
}

static uint64_t gl_root_folder_controller(uint64_t ctrl, uint64_t mgr)
{
    uint64_t roots[] = { mgr, ctrl };
    const char *sels[] = {
        "rootFolderController",
        "_rootFolderController",
        "rootFolderViewController",
        NULL,
    };
    for (int i = 0; i < 2; i++) {
        uint64_t root = roots[i];
        if (!r_is_objc_ptr(root)) continue;
        for (int s = 0; sels[s]; s++) {
            uint64_t fc = gl_safe_msg(root, sels[s], 0, 0, 0, 0);
            if (r_is_objc_ptr(fc)) return fc;
        }
    }
    return 0;
}

static uint64_t gl_usable_icon_list_candidate(uint64_t candidate, uint64_t iconViewCls);

static uint64_t gl_icon_list_from_array(uint64_t lists, uint64_t iconViewCls)
{
    uint64_t count = gl_array_count(lists);
    if (count > 16) count = 16;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t list = gl_array_object(lists, i);
        uint64_t usable = gl_usable_icon_list_candidate(list, iconViewCls);
        if (r_is_objc_ptr(usable)) return usable;
    }
    return 0;
}

static uint64_t gl_icon_list_from_folder_controller(uint64_t folderController,
                                                    uint64_t iconViewCls)
{
    if (!r_is_objc_ptr(folderController)) return 0;

    const char *singleSels[] = {
        "currentIconListView",
        "currentRootIconListView",
        "currentIconList",
        "currentRootIconList",
        NULL,
    };
    for (int i = 0; singleSels[i]; i++) {
        uint64_t list = gl_safe_msg(folderController, singleSels[i], 0, 0, 0, 0);
        uint64_t usable = gl_usable_icon_list_candidate(list, iconViewCls);
        if (r_is_objc_ptr(usable)) return usable;
    }

    const char *arraySels[] = { "visibleIconListViews", "iconListViews", NULL };
    for (int i = 0; arraySels[i]; i++) {
        uint64_t lists = gl_safe_msg(folderController, arraySels[i], 0, 0, 0, 0);
        uint64_t usable = gl_icon_list_from_array(lists, iconViewCls);
        if (r_is_objc_ptr(usable)) return usable;
    }

    if (r_responds_main(folderController, "iconListViewCount") &&
        r_responds_main(folderController, "iconListViewAtIndex:")) {
        uint64_t count = gl_get_integer(folderController, "iconListViewCount");
        if (count > 16) count = 16;
        for (uint64_t i = 0; i < count; i++) {
            uint64_t list = r_msg2_main(folderController, "iconListViewAtIndex:", i, 0, 0, 0);
            uint64_t usable = gl_usable_icon_list_candidate(list, iconViewCls);
            if (r_is_objc_ptr(usable)) return usable;
        }
    }

    return 0;
}

static uint64_t gl_current_root_list_view(uint64_t ctrl, uint64_t mgr)
{
    uint64_t list = 0;
    if (gl_safe_msg(ctrl, "hasOpenFolder", 0, 0, 0, 0)) {
        list = gl_safe_msg(ctrl, "currentFolderIconList", 0, 0, 0, 0);
        if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentFolderIconListView", 0, 0, 0, 0);
    }

    uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(mgr, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(mgr, "currentIconListView", 0, 0, 0, 0);
    return list;
}

static uint64_t gl_current_root_list_view_ios26_legacy(uint64_t ctrl)
{
    uint64_t list = 0;
    if (gl_safe_msg(ctrl, "hasOpenFolder", 0, 0, 0, 0)) {
        list = gl_safe_msg(ctrl, "currentFolderIconList", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentIconListView", 0, 0, 0, 0);
    return list;
}

static int gl_icon_views_from_list(uint64_t listView, uint64_t iconViewCls,
                                   uint64_t *out, int cap)
{
    (void)iconViewCls;
    int found = 0;

    const char *directSels[] = {"visibleIconViews", "iconViews", NULL};
    for (int s = 0; directSels[s]; s++) {
        if (!r_responds_main(listView, directSels[s])) continue;
        uint64_t arr = r_msg2_main(listView, directSels[s], 0, 0, 0, 0);
        if (!r_is_objc_ptr(arr)) continue;
        uint64_t n = r_msg2_main(arr, "count", 0, 0, 0, 0);
        if (n == 0 || n > 256) continue;
        for (uint64_t i = 0; i < n && found < cap; i++) {
            uint64_t icon = r_msg2_main(arr, "objectAtIndex:", i, 0, 0, 0);
            if (r_is_objc_ptr(icon) && !gl_ptr_seen(icon, out, found)) out[found++] = icon;
        }
    }

    const char *iconArraySels[] = {"visibleIcons", "icons", NULL};
    const char *viewForIconSels[] = {"displayedIconViewForIcon:", "iconViewForIcon:", "_iconViewForIcon:", NULL};
    for (int a = 0; iconArraySels[a]; a++) {
        if (!r_responds_main(listView, iconArraySels[a])) continue;
        uint64_t icons = r_msg2_main(listView, iconArraySels[a], 0, 0, 0, 0);
        if (!r_is_objc_ptr(icons)) continue;
        uint64_t n = r_msg2_main(icons, "count", 0, 0, 0, 0);
        if (n == 0 || n > 256) continue;

        for (int v = 0; viewForIconSels[v]; v++) {
            if (!r_responds_main(listView, viewForIconSels[v])) continue;
            for (uint64_t i = 0; i < n && found < cap; i++) {
                uint64_t icon = r_msg2_main(icons, "objectAtIndex:", i, 0, 0, 0);
                if (!r_is_objc_ptr(icon)) continue;
                uint64_t iconView = r_msg2_main(listView, viewForIconSels[v], icon, 0, 0, 0);
                if (r_is_objc_ptr(iconView) && !gl_ptr_seen(iconView, out, found)) out[found++] = iconView;
            }
        }
    }

    return found;
}

static bool gl_list_has_icon_views(uint64_t listView, uint64_t iconViewCls)
{
    if (!r_is_objc_ptr(listView) || !r_is_objc_ptr(iconViewCls)) return false;
    uint64_t sample[4] = {0};
    uint32_t oldSettle = r_settle_us(0);
    int count = gl_icon_views_from_list(listView, iconViewCls, sample, 4);
    r_settle_us(oldSettle);
    return count > 0;
}

static uint64_t gl_usable_icon_list_candidate(uint64_t candidate, uint64_t iconViewCls)
{
    if (!r_is_objc_ptr(candidate)) return 0;
    return gl_list_has_icon_views(candidate, iconViewCls) ? candidate : 0;
}

static uint64_t gl_find_home_icon_list_view_ios26(uint64_t ctrl, uint64_t mgr, uint64_t iconViewCls)
{
    uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
    uint64_t usable = gl_icon_list_from_folder_controller(rootFC, iconViewCls);
    if (r_is_objc_ptr(usable)) return usable;

    uint64_t direct = gl_current_root_list_view(ctrl, mgr);
    usable = gl_usable_icon_list_candidate(direct, iconViewCls);
    if (r_is_objc_ptr(usable)) return usable;

    uint64_t roots[] = { ctrl, mgr };
    const char *singleSels[] = {
        "currentIconListView",
        "currentRootIconListView",
        "currentIconList",
        "currentRootIconList",
        NULL,
    };
    for (int r = 0; r < 2; r++) {
        uint64_t root = roots[r];
        if (!r_is_objc_ptr(root)) continue;
        for (int s = 0; singleSels[s]; s++) {
            uint64_t list = gl_safe_msg(root, singleSels[s], 0, 0, 0, 0);
            usable = gl_usable_icon_list_candidate(list, iconViewCls);
            if (r_is_objc_ptr(usable)) return usable;
        }
    }

    return 0;
}

static uint64_t gl_find_home_icon_list_view_legacy(uint64_t ctrl, uint64_t mgr, uint64_t iconViewCls)
{
    uint64_t direct = gl_current_root_list_view(ctrl, mgr);
    uint64_t usable = gl_usable_icon_list_candidate(direct, iconViewCls);
    if (r_is_objc_ptr(usable)) return usable;

    uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
    usable = gl_icon_list_from_folder_controller(rootFC, iconViewCls);
    if (r_is_objc_ptr(usable)) return usable;

    uint64_t roots[] = { ctrl, mgr };
    const char *singleSels[] = {
        "currentIconListView",
        "currentRootIconListView",
        "currentIconList",
        "currentRootIconList",
        NULL,
    };
    for (int r = 0; r < 2; r++) {
        uint64_t root = roots[r];
        if (!r_is_objc_ptr(root)) continue;
        for (int s = 0; singleSels[s]; s++) {
            uint64_t list = gl_safe_msg(root, singleSels[s], 0, 0, 0, 0);
            usable = gl_usable_icon_list_candidate(list, iconViewCls);
            if (r_is_objc_ptr(usable)) return usable;
        }
    }

    const char *arraySels[] = { "visibleIconListViews", "iconListViews", NULL };
    for (int r = 0; r < 2; r++) {
        uint64_t root = roots[r];
        if (!r_is_objc_ptr(root)) continue;
        for (int s = 0; arraySels[s]; s++) {
            uint64_t lists = gl_safe_msg(root, arraySels[s], 0, 0, 0, 0);
            usable = gl_icon_list_from_array(lists, iconViewCls);
            if (r_is_objc_ptr(usable)) return usable;
        }
    }

    return 0;
}

static uint64_t gl_find_home_icon_list_view(uint64_t ctrl,
                                            uint64_t mgr,
                                            uint64_t iconViewCls,
                                            bool useIOS26Path)
{
    if (useIOS26Path) return gl_find_home_icon_list_view_ios26(ctrl, mgr, iconViewCls);
    return gl_find_home_icon_list_view_legacy(ctrl, mgr, iconViewCls);
}

static bool gl_item_seen(const uint64_t *items, int count, uint64_t item)
{
    if (!r_is_objc_ptr(item)) return true;
    for (int i = 0; i < count; i++) {
        if (items[i] == item) return true;
    }
    return false;
}

static bool gl_large_item_rect(uint64_t view,
                               uint64_t overlay,
                               GL_CGRect overlayBounds,
                               GL_CGRect *outRect)
{
    if (!r_is_objc_ptr(view) || gl_view_is_hidden(view)) return false;

    GL_CGRect bounds;
    GL_CGRect inOverlay;
    if (!gl_get_rect(view, "bounds", &bounds) || !gl_rect_valid(bounds)) return false;
    if (!gl_convert_rect_to_view(view, bounds, overlay, &inOverlay) ||
        !gl_rect_valid(inOverlay)) {
        return false;
    }
    if (!gl_rect_overlaps_bounds(inOverlay, overlayBounds)) return false;

    double area = inOverlay.w * inOverlay.h;
    double overlayArea = overlayBounds.w * overlayBounds.h;
    if (inOverlay.w < 88.0 || inOverlay.h < 88.0) return false;
    if (overlayArea > 0.0 && area > overlayArea * 0.65) return false;
    if (inOverlay.w > overlayBounds.w * 0.92 && inOverlay.h > overlayBounds.h * 0.75) return false;

    if (outRect) *outRect = inOverlay;
    return true;
}

static int gl_collect_large_item_views(uint64_t listView,
                                       uint64_t iconViewCls,
                                       uint64_t overlay,
                                       GL_CGRect overlayBounds,
                                       uint64_t *items,
                                       int existing,
                                       int cap)
{
    if (!r_is_objc_ptr(listView) || !r_is_objc_ptr(overlay) || !items || existing >= cap) {
        return 0;
    }

    uint64_t selSub = r_sel("subviews");
    uint64_t selCnt = r_sel("count");
    uint64_t selObj = r_sel("objectAtIndex:");
    uint64_t selKind = r_sel("isKindOfClass:");
    if (!selSub || !selCnt || !selObj || !selKind) return 0;

    enum { QMAX = 192 };
    uint64_t q[QMAX] = {0};
    uint8_t depth[QMAX] = {0};
    int head = 0, tail = 0;

    uint64_t subs = r_msg(listView, selSub, 0, 0, 0, 0);
    uint64_t count = r_is_objc_ptr(subs) ? r_msg(subs, selCnt, 0, 0, 0, 0) : 0;
    if (count > 96) count = 96;
    for (uint64_t i = 0; i < count && tail < QMAX; i++) {
        uint64_t child = r_msg(subs, selObj, i, 0, 0, 0);
        if (r_is_objc_ptr(child)) {
            q[tail] = child;
            depth[tail] = 0;
            tail++;
        }
    }

    int added = 0;
    while (head < tail && existing + added < cap) {
        uint64_t view = q[head];
        uint8_t d = depth[head];
        head++;
        if (!r_is_objc_ptr(view) || gl_item_seen(items, existing + added, view)) continue;

        bool isIconView = r_is_objc_ptr(iconViewCls) &&
                          (r_msg(view, selKind, iconViewCls, 0, 0, 0) & 0xff) != 0;
        if (isIconView) continue;

        GL_CGRect rect;
        if (gl_large_item_rect(view, overlay, overlayBounds, &rect)) {
            items[existing + added++] = view;
            continue;
        }

        if (d >= 3) continue;
        uint64_t childSubs = r_msg(view, selSub, 0, 0, 0, 0);
        uint64_t childCount = r_is_objc_ptr(childSubs) ? r_msg(childSubs, selCnt, 0, 0, 0, 0) : 0;
        if (childCount > 64) childCount = 64;
        for (uint64_t i = 0; i < childCount && tail < QMAX; i++) {
            uint64_t child = r_msg(childSubs, selObj, i, 0, 0, 0);
            if (!r_is_objc_ptr(child) || gl_item_seen(items, existing + added, child)) continue;
            q[tail] = child;
            depth[tail] = d + 1;
            tail++;
        }
    }

    return added;
}

static bool gl_build_group_ios26_per_icon(uint64_t groups,
                                          uint64_t listView,
                                          uint64_t iconViewCls,
                                          GravityLiteConfig config,
                                          bool isDock)
{
    enum { ICON_CAP = 256 };
    uint64_t iconViews[ICON_CAP] = {0};
    int iconCount = sb_collect_views_main(listView, iconViewCls, iconViews, ICON_CAP);
    if (iconCount <= 0) return false;

    uint64_t icons = gl_new_remote("NSMutableArray");
    if (!r_is_objc_ptr(icons)) return false;

    uint64_t liveItems = gl_new_remote("NSMutableArray");
    uint64_t liveParents = gl_new_remote("NSMutableArray");
    uint64_t liveFrames = gl_new_remote("NSMutableArray");
    GL_CGRect overlayFrame = {0};
    uint64_t overlay = gl_overlay_for_list_view_ios26_legacy(listView, &overlayFrame);
    if (!r_is_objc_ptr(liveItems) ||
        !r_is_objc_ptr(liveParents) ||
        !r_is_objc_ptr(liveFrames) ||
        !r_is_objc_ptr(overlay)) {
        if (r_is_objc_ptr(overlay)) {
            r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
            gl_release(overlay);
        }
        gl_release(icons);
        if (liveItems) gl_release(liveItems);
        if (liveParents) gl_release(liveParents);
        if (liveFrames) gl_release(liveFrames);
        return false;
    }

    GL_CGRect overlayBounds = {0.0, 0.0, overlayFrame.w, overlayFrame.h};
    int added = 0;

    uint32_t oldSettle = r_settle_us(0);
    for (int i = 0; i < iconCount; i++) {
        uint64_t icon = iconViews[i];
        if (!r_is_objc_ptr(icon) || gl_view_is_hidden(icon)) continue;

        uint64_t parent = gl_safe_msg(icon, "superview", 0, 0, 0, 0);
        GL_CGRect originalFrame;
        GL_CGRect iconBounds;
        GL_CGRect iconInOverlay;
        if (!r_is_objc_ptr(parent) ||
            !gl_get_rect(icon, "frame", &originalFrame) ||
            !gl_get_rect(icon, "bounds", &iconBounds) ||
            !gl_convert_rect_to_view(icon, iconBounds, overlay, &iconInOverlay) ||
            !gl_rect_valid(iconInOverlay) ||
            !gl_rect_overlaps_bounds(iconInOverlay, overlayBounds)) {
            continue;
        }

        uint64_t frameValue = gl_value_with_rect(originalFrame);
        if (!r_is_objc_ptr(frameValue)) continue;

        gl_reset_transform(icon);
        gl_array_add(liveItems, icon);
        gl_array_add(liveParents, parent);
        gl_array_add(liveFrames, frameValue);
        r_msg2_main(overlay, "addSubview:", icon, 0, 0, 0);
        gl_set_rect(icon, "setFrame:", iconInOverlay);
        gl_array_add(icons, icon);
        added++;
    }
    r_settle_us(oldSettle);

    if (added <= 0) {
        printf("[GRAVITY] No visible icons found for this group.\n");
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(overlay);
        gl_release(icons);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }

    uint64_t animator = gl_animator_for_reference_view(overlay);
    if (!r_is_objc_ptr(animator)) {
        printf("[GRAVITY] Could not start physics for this icon group.\n");
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(overlay);
        gl_release(icons);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }

    uint64_t collision = gl_alloc_init_with_items("UICollisionBehavior", icons);
    if (r_is_objc_ptr(collision)) {
        gl_set_bool(collision, "setTranslatesReferenceBoundsIntoBoundary:", true);
        r_msg2_main(animator, "addBehavior:", collision, 0, 0, 0);
        gl_release(collision);
    }

    uint64_t itemBehavior = gl_alloc_init_with_items("UIDynamicItemBehavior", icons);
    if (r_is_objc_ptr(itemBehavior)) {
        gl_set_double(itemBehavior, "setElasticity:", 0.3);
        gl_set_double(itemBehavior, "setFriction:", 0.2);
        gl_set_double(itemBehavior, "setDensity:", 1.0);
        gl_set_double(itemBehavior, "setResistance:", 0.0);
        gl_set_double(itemBehavior, "setAngularResistance:", 0.0);
        gl_set_bool(itemBehavior, "setAllowsRotation:", config.allowsRotation);
        r_msg2_main(animator, "addBehavior:", itemBehavior, 0, 0, 0);
        gl_release(itemBehavior);
    }

    uint64_t gravity = gl_alloc_init_with_items("UIGravityBehavior", icons);
    if (r_is_objc_ptr(gravity)) {
        gl_set_double(gravity, "setAngle:", M_PI_2);
        gl_set_double(gravity, "setMagnitude:", 3.0);
        r_msg2_main(animator, "addBehavior:", gravity, 0, 0, 0);
        int n = __atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED);
        if (n < 8) {
            s_gravity_ptrs[n] = gravity;
            __atomic_store_n(&s_gravity_ptr_count, n + 1, __ATOMIC_SEQ_CST);
        }
        gl_release(gravity);
    }

    uint64_t group = gl_new_remote("NSMutableDictionary");
    if (r_is_objc_ptr(group)) {
        gl_dict_set(group, "animator", animator);
        gl_dict_set(group, "icons", icons);
        gl_dict_set(group, "snapshots", icons);
        gl_dict_set(group, "liveItems", liveItems);
        gl_dict_set(group, "liveParents", liveParents);
        gl_dict_set(group, "liveFrames", liveFrames);
        gl_dict_set(group, "listView", listView);
        gl_dict_set(group, "referenceView", overlay);
        gl_dict_set(group, "overlay", overlay);
        gl_array_add(groups, group);
        gl_release(group);
    } else {
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(animator);
        gl_release(overlay);
        gl_release(icons);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }

    uint64_t isRunning = gl_safe_msg(animator, "isRunning", 0, 0, 0, 0);
    uint64_t behaviorCount = gl_array_count(gl_safe_msg(animator, "behaviors", 0, 0, 0, 0));
    printf("[GRAVITY] Captured %s: %d live item(s) (%.0f×%.0f pt), physics=%s behaviors=%llu\n",
           isDock ? "dock" : "home screen",
           added,
           overlayFrame.w, overlayFrame.h,
           isRunning ? "running" : "starting",
           behaviorCount);

    gl_release(animator);
    gl_release(overlay);
    gl_release(icons);
    gl_release(liveItems);
    gl_release(liveParents);
    gl_release(liveFrames);
    return true;
}

static bool gl_build_group(uint64_t groups,
                           uint64_t listView,
                           uint64_t iconViewCls,
                           GravityLiteConfig config,
                           bool isDock,
                           bool useIOS26Path)
{
    if (useIOS26Path) {
        return gl_build_group_ios26_per_icon(groups,
                                             listView,
                                             iconViewCls,
                                             config,
                                             isDock);
    }

    enum { ICON_CAP = 256 };
    uint64_t itemViews[ICON_CAP] = {0};
    uint32_t oldCollectSettle = r_settle_us(0);
    int iconCount = gl_icon_views_from_list(listView, iconViewCls, itemViews, ICON_CAP);
    r_settle_us(oldCollectSettle);
    if (iconCount <= 0) return false;

    GL_CGRect overlayFrame = {0};
    uint64_t overlay = gl_overlay_for_list_view(listView, &overlayFrame);
    if (!r_is_objc_ptr(overlay)) return false;
    // Keep this non-interactive. Gesture recognizers attached through
    // RemoteCall made startup slower and could pin live SBIconViews into the
    // overlay corner by fighting SpringBoard's own gesture/layout machinery.

    uint64_t snapshots = gl_new_remote("NSMutableArray");
    uint64_t liveItems = gl_new_remote("NSMutableArray");
    uint64_t liveParents = gl_new_remote("NSMutableArray");
    uint64_t liveFrames = gl_new_remote("NSMutableArray");
    if (!r_is_objc_ptr(snapshots) ||
        !r_is_objc_ptr(liveItems) ||
        !r_is_objc_ptr(liveParents) ||
        !r_is_objc_ptr(liveFrames)) {
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(overlay);
        if (snapshots) gl_release(snapshots);
        if (liveItems) gl_release(liveItems);
        if (liveParents) gl_release(liveParents);
        if (liveFrames) gl_release(liveFrames);
        return false;
    }

    int added = 0;
    uint32_t oldSettle = r_settle_us(0);
    GL_CGRect overlayBounds = {0.0, 0.0, overlayFrame.w, overlayFrame.h};
    int largeItemCount = 0;
    if (!isDock) {
        largeItemCount = gl_collect_large_item_views(listView,
                                                     iconViewCls,
                                                     overlay,
                                                     overlayBounds,
                                                     itemViews,
                                                     iconCount,
                                                     ICON_CAP);
    }
    int itemCount = iconCount + largeItemCount;
    for (int i = 0; i < itemCount; i++) {
        uint64_t icon = itemViews[i];
        if (!r_is_objc_ptr(icon) || gl_view_is_hidden(icon)) continue;

        GL_CGRect iconBounds;
        GL_CGRect iconInOverlay;
        if (!gl_get_rect(icon, "bounds", &iconBounds) || !gl_rect_valid(iconBounds)) continue;
        if (!gl_convert_rect_to_view(icon, iconBounds, overlay, &iconInOverlay) ||
            !gl_rect_valid(iconInOverlay)) continue;
        if (!gl_rect_overlaps_bounds(iconInOverlay, overlayBounds)) continue;

        bool widgetSizedItem = !isDock &&
                               (iconInOverlay.w >= 88.0 || iconInOverlay.h >= 88.0);
        if (!widgetSizedItem) {
            iconInOverlay = gl_rect_scale_about_center(iconInOverlay, kGravityLiteSnapshotScale);
        }
        uint64_t physicsItem = 0;
        if (widgetSizedItem) {
            uint64_t parent = gl_safe_msg(icon, "superview", 0, 0, 0, 0);
            GL_CGRect originalFrame;
            if (!r_is_objc_ptr(parent) || !gl_get_rect(icon, "frame", &originalFrame)) continue;
            uint64_t frameValue = gl_value_with_rect(originalFrame);
            if (!r_is_objc_ptr(frameValue)) continue;

            gl_array_add(liveItems, icon);
            gl_array_add(liveParents, parent);
            gl_array_add(liveFrames, frameValue);
            r_msg2_main(overlay, "addSubview:", icon, 0, 0, 0);
            gl_set_rect(icon, "setFrame:", iconInOverlay);
            physicsItem = icon;
        } else {
            uint64_t snapshot = gl_snapshot_for_view(icon,
                                                     iconBounds,
                                                     iconInOverlay,
                                                     false,
                                                     false);
            if (!r_is_objc_ptr(snapshot)) continue;
            r_msg2_main(overlay, "addSubview:", snapshot, 0, 0, 0);
            physicsItem = snapshot;
        }

        gl_array_add(snapshots, physicsItem);
        added++;
    }
    r_settle_us(oldSettle);

    if (added <= 0) {
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(overlay);
        gl_release(snapshots);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }
    gl_set_double(listView, "setAlpha:", 0.0);

    uint64_t animator = gl_animator_for_reference_view(overlay);
    if (!r_is_objc_ptr(animator)) {
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        gl_set_double(listView, "setAlpha:", 1.0);
        gl_layout_list_view(listView);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(overlay);
        gl_release(snapshots);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }

    uint64_t collision = gl_alloc_init_with_items("UICollisionBehavior", snapshots);
    if (r_is_objc_ptr(collision)) {
        gl_set_bool(collision, "setTranslatesReferenceBoundsIntoBoundary:", true);
        if (r_responds_main(collision, "setCollisionMode:")) {
            r_msg2_main(collision, "setCollisionMode:", 3, 0, 0, 0);
        }
        r_msg2_main(animator, "addBehavior:", collision, 0, 0, 0);
        gl_release(collision);
    }

    uint64_t itemBehavior = gl_alloc_init_with_items("UIDynamicItemBehavior", snapshots);
    if (r_is_objc_ptr(itemBehavior)) {
        gl_set_double(itemBehavior, "setElasticity:", config.bounce);
        gl_set_double(itemBehavior, "setFriction:", config.friction);
        gl_set_double(itemBehavior, "setDensity:", 1.0);
        gl_set_double(itemBehavior, "setResistance:", config.resistance);
        gl_set_double(itemBehavior, "setAngularResistance:", config.angularResistance);
        gl_set_bool(itemBehavior, "setAllowsRotation:", config.allowsRotation);
        r_msg2_main(animator, "addBehavior:", itemBehavior, 0, 0, 0);
        gl_release(itemBehavior);
    }

    uint64_t gravity = gl_alloc_init_with_items("UIGravityBehavior", snapshots);
    if (r_is_objc_ptr(gravity)) {
        gl_set_double(gravity, "setAngle:", M_PI_2);
        gl_set_double(gravity, "setMagnitude:", config.magnitude);
        r_msg2_main(animator, "addBehavior:", gravity, 0, 0, 0);
        int n = __atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED);
        if (n < 8) {
            s_gravity_ptrs[n] = gravity;
            __atomic_store_n(&s_gravity_ptr_count, n + 1, __ATOMIC_SEQ_CST);
        }
        gl_release(gravity);
    }

    uint64_t group = gl_new_remote("NSMutableDictionary");
    if (r_is_objc_ptr(group)) {
        gl_dict_set(group, "animator", animator);
        gl_dict_set(group, "snapshots", snapshots);
        gl_dict_set(group, "liveItems", liveItems);
        gl_dict_set(group, "liveParents", liveParents);
        gl_dict_set(group, "liveFrames", liveFrames);
        gl_dict_set(group, "listView", listView);
        gl_dict_set(group, "overlay", overlay);
        gl_array_add(groups, group);
        gl_release(group);
    } else {
        gl_restore_live_items(liveItems, liveParents, liveFrames);
        gl_set_double(listView, "setAlpha:", 1.0);
        gl_layout_list_view(listView);
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        gl_release(animator);
        gl_release(overlay);
        gl_release(snapshots);
        gl_release(liveItems);
        gl_release(liveParents);
        gl_release(liveFrames);
        return false;
    }


    printf("[GRAVITY] Captured %s snapshots: %d item(s), %d icon API view(s) + %d widget-sized view(s) (%.0f×%.0f pt)\n",
           isDock ? "dock" : "home screen",
           added,
           iconCount,
           largeItemCount,
           overlayFrame.w, overlayFrame.h);

    gl_release(animator);
    gl_release(overlay);
    gl_release(snapshots);
    gl_release(liveItems);
    gl_release(liveParents);
    gl_release(liveFrames);
    return true;
}

bool gravitylite_stop_in_session(void)
{
    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));

    uint64_t ctrl = gl_icon_controller();
    if (!r_is_objc_ptr(ctrl)) {
        printf("[GRAVITY] stop: SBIconController missing\n");
        return false;
    }

    uint64_t state = gl_get_state(ctrl);
    if (!r_is_objc_ptr(state)) {
        int orphans = gl_cleanup_gravity_overlays_in_app_windows();
        if (orphans > 0)
            printf("[GRAVITY] stop: removed %d orphaned overlay(s).\n", orphans);
        return true;
    }

    uint64_t groups = gl_dict_get(state, "groups");
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;
    int restoredIcons = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        uint64_t animator  = gl_dict_get(group, "animator");
        uint64_t icons     = gl_dict_get(group, "icons");
        uint64_t snapshots = gl_dict_get(group, "snapshots");
        uint64_t liveItems = gl_dict_get(group, "liveItems");
        uint64_t liveParents = gl_dict_get(group, "liveParents");
        uint64_t liveFrames = gl_dict_get(group, "liveFrames");
        uint64_t originalIcons = gl_dict_get(group, "originalIcons");
        uint64_t sources   = gl_dict_get(group, "sources");
        uint64_t listView  = gl_dict_get(group, "listView");
        uint64_t overlay   = gl_dict_get(group, "overlay");

        if (r_is_objc_ptr(animator)) {
            r_msg2_main(animator, "removeAllBehaviors", 0, 0, 0, 0);
        }

        uint64_t resetItems = r_is_objc_ptr(icons) ? icons : snapshots;
        uint64_t n = gl_array_count(resetItems);
        if (n > 256) n = 256;
        for (uint64_t j = 0; j < n; j++) {
            uint64_t item = gl_array_object(resetItems, j);
            if (!r_is_objc_ptr(item)) continue;
            gl_reset_transform(item);
            restoredIcons++;
        }

        gl_restore_live_items(liveItems, liveParents, liveFrames);
        restoredIcons += gl_unhide_icon_array(originalIcons);
        gl_set_array_views_alpha(sources, 1.0);
        if (r_is_objc_ptr(listView)) {
            gl_set_double(listView, "setAlpha:", 1.0);
            gl_layout_list_view(listView);
        }

        if (r_is_objc_ptr(overlay)) {
            r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
        }
    }
    gl_set_state(ctrl, 0);
    int orphans = gl_cleanup_gravity_overlays_in_app_windows();
    if (orphans > 0)
        printf("[GRAVITY] Cleaned up %d orphaned overlay(s) and restored %d icons.\n", orphans, restoredIcons);
    else
        printf("[GRAVITY] Restored %d icons to the home screen.\n", restoredIcons);
    return true;
}

bool gravitylite_apply_in_session(GravityLiteConfig config)
{
    if (config.magnitude <= 0.0) config.magnitude = 1.0;
    if (config.bounce < 0.0) config.bounce = 0.0;
    if (config.bounce > 1.0) config.bounce = 1.0;
    if (config.friction < 0.0) config.friction = 0.0;
    if (config.friction > 1.0) config.friction = 1.0;
    if (config.resistance < 0.0) config.resistance = 0.0;
    if (config.explosionForce <= 0.0) config.explosionForce = 1.0;

    uint64_t ctrl = gl_icon_controller();
    if (!r_is_objc_ptr(ctrl)) {
        printf("[GRAVITY] SBIconController missing\n");
        return false;
    }
    (void)gravitylite_stop_in_session();
    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));

    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(iconViewCls)) {
        printf("[GRAVITY] SpringBoard icon classes not found.\n");
        return false;
    }
    int iosMajor = gl_remote_ios_major();
    bool ios26Detected = iosMajor >= 26;
    bool ios17Detected = iosMajor == 17;
    bool useLiveIconPath = ios26Detected || ios17Detected;
    printf("[GRAVITY] Using iOS %d %s path.\n",
           iosMajor > 0 ? iosMajor : 0,
           useLiveIconPath
               ? "live icon"
               : "snapshot");
    printf("[GRAVITY] Resolving SpringBoard icon lists...\n");

    uint64_t mgr = gl_icon_manager(ctrl);

    uint64_t state = gl_new_remote("NSMutableDictionary");
    uint64_t groups = gl_new_remote("NSMutableArray");
    if (!r_is_objc_ptr(state) || !r_is_objc_ptr(groups)) {
        if (state) gl_release(state);
        if (groups) gl_release(groups);
        printf("[GRAVITY] state allocation failed\n");
        return false;
    }

    int built = 0;
    bool homeBuilt = false;
    bool dockBuilt = false;

    if (useLiveIconPath) {
        uint64_t listViewCls = r_class("SBIconListView");
        if (!r_is_objc_ptr(listViewCls)) {
            gl_release(groups);
            gl_release(state);
            printf("[GRAVITY] Home screen icon list class lookup failed.\n");
            return false;
        }

        enum { LV_CAP = 64 };
        uint64_t processed[LV_CAP] = {0};
        int processedCount = 0;
        uint64_t dockListView = gl_dock_list_view(ctrl, mgr);

        uint64_t currentListView = gl_current_root_list_view_ios26_legacy(ctrl);
        if (r_is_objc_ptr(currentListView) &&
            r_msg2(currentListView, "isKindOfClass:", listViewCls, 0, 0, 0)) {
            printf("[GRAVITY] Capturing current home screen page...\n");
            if (gl_build_group(groups, currentListView, iconViewCls, config, false, true)) {
                if (processedCount < LV_CAP) processed[processedCount++] = currentListView;
                built++;
                homeBuilt = true;
            } else {
                printf("[GRAVITY] Current page was not ready; checking visible pages...\n");
            }
        }

        uint64_t listViews[LV_CAP] = {0};
        int count = sb_collect_views_in_windows_main(listViewCls, listViews, LV_CAP);
        if (count <= 0) {
            uint64_t rootFC = gl_safe_msg(mgr, "rootFolderController", 0, 0, 0, 0);
            if (!r_is_objc_ptr(rootFC)) rootFC = gl_safe_msg(mgr, "_rootFolderController", 0, 0, 0, 0);
            uint64_t rootView = gl_safe_msg(rootFC, "rootFolderView", 0, 0, 0, 0);
            if (r_is_objc_ptr(rootView)) {
                count = sb_collect_views_main(rootView, listViewCls, listViews, LV_CAP);
            }
        }

        for (int i = 0; i < count && !homeBuilt; i++) {
            uint64_t listView = listViews[i];
            if (!r_is_objc_ptr(listView)) continue;
            if (gl_ptr_seen(listView, processed, processedCount)) continue;

            bool isDock = (dockListView && listView == dockListView);
            if (isDock) continue;
            if (!gl_view_has_visible_window_rect(listView)) continue;
            if (processedCount < LV_CAP) processed[processedCount++] = listView;

            printf("[GRAVITY] Capturing visible home screen page %d/%d...\n",
                   i + 1, count);
            if (gl_build_group(groups, listView, iconViewCls, config, false, true)) {
                built++;
                homeBuilt = true;
            }
        }

        if (r_is_objc_ptr(dockListView) && config.includeDock &&
            !gl_ptr_seen(dockListView, processed, processedCount)) {
            if (processedCount < LV_CAP) processed[processedCount++] = dockListView;
            printf("[GRAVITY] Capturing dock icons...\n");
            if (gl_build_group(groups, dockListView, iconViewCls, config, true, true)) {
                built++;
                dockBuilt = true;
            } else {
                printf("[GRAVITY] Dock icons were not ready.\n");
            }
        }

        if (built <= 0) {
            gl_release(groups);
            gl_release(state);
            printf("[GRAVITY] No icon groups could be captured from %d visible page(s).\n",
                   count);
            return false;
        }

        printf("[GRAVITY] Installing physics behaviors in SpringBoard...\n");
        gl_dict_set(state, "groups", groups);
        gl_set_state(ctrl, state);
        printf("[GRAVITY] Physics started — groups=%d home=%d dock=%d visiblePages=%d\n",
               built, homeBuilt, dockBuilt, count);
        printf("[WARN] TO STOP GRAVITY: USE APP SWITCHER TO RETURN TO CYANIDE AND DEACTIVATE.\n");

        gl_release(groups);
        gl_release(state);
        return true;
    }

    uint64_t currentListView = 0;
    bool homeListResolved = false;
    bool homeCaptureLogged = false;
    for (int attempt = 0; attempt < 12 && !homeBuilt; attempt++) {
        currentListView = gl_find_home_icon_list_view(ctrl, mgr, iconViewCls, false);
        if (r_is_objc_ptr(currentListView)) {
            homeListResolved = true;
            if (!homeCaptureLogged) {
                printf("[GRAVITY] Capturing home screen icon snapshots...\n");
                homeCaptureLogged = true;
            }
            if (gl_build_group(groups, currentListView, iconViewCls, config, false, false)) {
                built++;
                homeBuilt = true;
                break;
            }
        }
        if (attempt == 0) printf("[GRAVITY] Waiting for home screen icon list/window...\n");
        usleep(100000);
    }

    if (!homeBuilt) {
        printf("[GRAVITY] Home screen icon list %s on %s path.\n",
               homeListResolved ? "was found, but could not be captured" : "was not found",
               "snapshot");
        gl_release(groups);
        gl_release(state);
        return false;
    }

    if (config.includeDock) {
        printf("[GRAVITY] Resolving dock icon list...\n");
        uint64_t dockListView = gl_dock_list_view_for_path(ctrl, mgr, false);
        if (r_is_objc_ptr(dockListView)) {
            printf("[GRAVITY] Capturing dock icon snapshots...\n");
            if (gl_build_group(groups, dockListView, iconViewCls, config, true, false)) {
                built++;
                dockBuilt = true;
            }
        }
    }

    if (built <= 0) {
        gl_release(groups);
        gl_release(state);
        printf("[GRAVITY] No icon groups created.\n");
        return false;
    }

    printf("[GRAVITY] Installing physics behaviors in SpringBoard...\n");
    gl_dict_set(state, "groups", groups);
    gl_set_state(ctrl, state);
    printf("[GRAVITY] Physics started — magnitude=%.1fx, bounce=%.2f, friction=%.2f%s\n",
           config.magnitude, config.bounce, config.friction,
           dockBuilt ? ", dock included" : "");
    printf("[WARN] TO STOP GRAVITY: USE APP SWITCHER TO RETURN TO CYANIDE AND DEACTIVATE.\n");

    gl_release(groups);
    gl_release(state);
    return true;
}

bool gravitylite_explosion_in_session(double force)
{
    if (force <= 0.0) force = 1.0;

    uint64_t ctrl = gl_icon_controller();
    uint64_t state = r_is_objc_ptr(ctrl) ? gl_get_state(ctrl) : 0;
    if (!r_is_objc_ptr(state)) return false;

    uint64_t pushCls = r_class("UIPushBehavior");
    if (!r_is_objc_ptr(pushCls)) return false;

    uint64_t groups = gl_dict_get(state, "groups");
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;

    int pulses = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        uint64_t animator  = gl_dict_get(group, "animator");
        uint64_t snapshots = gl_dict_get(group, "snapshots");
        if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(snapshots)) continue;

        gl_remove_push_behaviors(animator);

        uint64_t obj = r_msg2(pushCls, "alloc", 0, 0, 0, 0);
        uint64_t push = r_is_objc_ptr(obj)
            ? r_msg2_main(obj, "initWithItems:mode:", snapshots, 1, 0, 0)
            : 0;
        if (!r_is_objc_ptr(push)) continue;

        double angle = ((double)arc4random_uniform(62832) / 10000.0);
        gl_set_double(push, "setAngle:", angle);
        gl_set_double(push, "setMagnitude:", force);
        r_msg2_main(animator, "addBehavior:", push, 0, 0, 0);
        gl_set_bool(push, "setActive:", true);
        gl_release(push);
        pulses++;
    }

    if (pulses > 0)
        printf("[GRAVITY] Shake pulse applied to %d group(s).\n", pulses);
    return pulses > 0;
}

bool gravitylite_update_gravity_angle_in_session(double angle, double magnitude)
{
    int count = __atomic_load_n(&s_gravity_ptr_count, __ATOMIC_SEQ_CST);
    if (count <= 0) return false;
    uint32_t oldSettle = r_settle_us(0);
    for (int i = 0; i < count; i++) {
        uint64_t gb = s_gravity_ptrs[i];
        if (!r_is_objc_ptr(gb)) continue;
        gl_set_double(gb, "setAngle:", angle);
        gl_set_double(gb, "setMagnitude:", magnitude);
    }
    r_settle_us(oldSettle);
    return true;
}

void gravitylite_forget_remote_state(void)
{
    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));
}
