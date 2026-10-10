//
//  remote_objc.m
//

#import "remote_objc.h"
// printf in this TU went to stdout only, so [R_OBJC] never reached the chain
// log. LogTextView.h mirrors printf into the in-app log; the macro evaluates
// its arguments twice, and all three printf sites here pass plain reads.
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

extern uint64_t remote_read64(uint64_t src);

// Blanket delay paid before every remote ObjC interaction. It exists to give
// SpringBoard a moment to finish whatever the previous call kicked off, but it
// was applied unconditionally — including to pure queries that have no side
// effects at all. At 50ms a tweak issuing a few hundred messages spends most of
// its wall-clock time asleep here. r_settle_us() tunes it at runtime.
static useconds_t gSettleUS = 50000;

// Settle policy. The default reproduces the historical behaviour exactly.
//   RSettleCompatible - 50 ms before every mutating message (as shipped).
//   RSettleFast       - same rule, 5 ms.
//   RSettleAsyncOnly  - only settle when work is genuinely still in flight,
//                       i.e. after an r_msg2_main_async() dispatch made with
//                       waitUntilDone:NO. Every other path goes through
//                       do_remote_call_stable(), which does not return until
//                       the target has finished running the selector, so there
//                       is nothing left to wait for.
static int gSettleMode = 0;
static bool gSettleOwed = false;

// Rough accounting so the cost is visible in the log instead of guessed at.
static uint64_t gRemoteMsgCount = 0;
static uint64_t gSettleCount = 0;
static uint64_t gSettleSleptUS = 0;
// Every RemoteCall made through this file (r_msg, r_msg_main's internals,
// malloc/free, ...), not just the settled messages counted above.
static uint64_t gRoundTripCount = 0;
// Synchronous main-thread dispatches and the time spent blocked in them
// (round trip + SpringBoard main-queue wait + the selector itself).
static uint64_t gMainCallCount = 0;
static uint64_t gMainWaitUS = 0;

// Sends a prepared invocation to SpringBoard's main thread and waits.
static void r_invoke_on_main_wait(uint64_t inv, uint64_t performSel, uint64_t invokeSel)
{
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    r_msg(inv, performSel, invokeSel, 0, 1, 0);
    uint64_t t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    __atomic_fetch_add(&gMainCallCount, 1, __ATOMIC_RELAXED);
    __atomic_fetch_add(&gMainWaitUS, (t1 - t0) / 1000, __ATOMIC_RELAXED);
}

#define R_OBJC_CACHE_CAP 192
#define R_OBJC_CACHE_NAME_MAX 96

typedef struct {
    int pid;
    char name[R_OBJC_CACHE_NAME_MAX];
    uint64_t value;
} RemoteObjCCacheEntry;

static pthread_mutex_t gObjCCacheLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gRemoteCallLock = PTHREAD_MUTEX_INITIALIZER;
static RemoteObjCCacheEntry gSelCache[R_OBJC_CACHE_CAP];
static RemoteObjCCacheEntry gClassCache[R_OBJC_CACHE_CAP];
static int gSelCacheNext = 0;
static int gClassCacheNext = 0;

static bool r_cacheable_name(const char *name)
{
    return name && name[0] && strlen(name) < R_OBJC_CACHE_NAME_MAX;
}

static uint64_t r_cache_lookup(RemoteObjCCacheEntry *cache, int pid, const char *name)
{
    if (pid <= 0 || !r_cacheable_name(name)) return 0;

    uint64_t value = 0;
    pthread_mutex_lock(&gObjCCacheLock);
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == pid && cache[i].value && strcmp(cache[i].name, name) == 0) {
            value = cache[i].value;
            break;
        }
    }
    pthread_mutex_unlock(&gObjCCacheLock);
    return value;
}

static void r_cache_store(RemoteObjCCacheEntry *cache, int *nextSlot, int pid, const char *name, uint64_t value)
{
    if (pid <= 0 || !value || !r_cacheable_name(name)) return;

    pthread_mutex_lock(&gObjCCacheLock);
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == pid && strcmp(cache[i].name, name) == 0) {
            cache[i].value = value;
            pthread_mutex_unlock(&gObjCCacheLock);
            return;
        }
    }

    int slot = -1;
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == 0 || cache[i].value == 0) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        slot = *nextSlot;
        *nextSlot = (*nextSlot + 1) % R_OBJC_CACHE_CAP;
    }

    cache[slot].pid = pid;
    strncpy(cache[slot].name, name, sizeof(cache[slot].name) - 1);
    cache[slot].name[sizeof(cache[slot].name) - 1] = '\0';
    cache[slot].value = value;
    pthread_mutex_unlock(&gObjCCacheLock);
}

static void r_settle(void)
{
    gRemoteMsgCount++;
    if (gSettleMode == 2) {
        // Async-only: pay the debt left by a fire-and-forget dispatch, nothing else.
        if (!gSettleOwed) return;
        gSettleOwed = false;
    }
    if (gSettleUS) {
        gSettleCount++;
        gSettleSleptUS += gSettleUS;
        usleep(gSettleUS);
    }
    // Periodic cost report — a tweak that feels slow can be checked against
    // this instead of guessed at.
    if ((gRemoteMsgCount % 250) == 0) {
        printf("[R_OBJC] %llu remote messages, %llu settles, %llu ms slept in settles\n",
               gRemoteMsgCount, gSettleCount, gSettleSleptUS / 1000);
    }
}

// respondsToSelector: and friends are pure queries: they mutate nothing, so
// there is nothing for SpringBoard to settle after. Count them, never sleep.
static void r_settle_query(void)
{
    gRemoteMsgCount++;
}

// Deliberately conservative allowlist of selectors that only read state.
// Enumerating an array or asking a view for its superview cannot leave
// SpringBoard with work in flight, so paying the settle for them is pure loss —
// and these are exactly the selectors that appear inside the per-page and
// per-window loops that make a tweak apply feel slow. Anything that allocates,
// mutates, or triggers layout must NOT be added here.
static bool r_selector_is_pure_query(const char *selName)
{
    static const char *const kPureQueries[] = {
        "count",
        "objectAtIndex:",
        "objectForKey:",
        "superview",
        "subviews",
        "windows",
        "isKindOfClass:",
        "respondsToSelector:",
        "isDock",
        // Property getters on SBIconListView / SBIconListModel. These are the
        // hottest selectors in the SBC arrange path -- every page_model_at() is
        // a "model" and every icon count is an "icons" -- and neither mutates
        // anything, so settling after them was pure loss.
        "model",
        "icons",
        "iconListViewCount",
        "iconListViewAtIndex:",
        "visibleIconListViews",
        "iconListViews",
        NULL,
    };
    for (int i = 0; kPureQueries[i]; i++) {
        if (strcmp(selName, kPureQueries[i]) == 0) return true;
    }
    return false;
}

// Settle unless the selector is a known read-only query.
static void r_settle_for(const char *selName)
{
    if (selName && r_selector_is_pure_query(selName)) {
        r_settle_query();
        return;
    }
    r_settle();
}

void r_perf_report(const char *label)
{
    printf("[R_OBJC] %s: %llu remote messages, %llu settles, %llu ms slept\n",
           label ?: "totals", gRemoteMsgCount, gSettleCount, gSettleSleptUS / 1000);
}

void r_settle_set_mode(int mode)
{
    if (mode < 0 || mode > 2) mode = 0;
    gSettleMode = mode;
    gSettleUS = (mode == 1) ? 5000 : 50000;
    gSettleOwed = false;
    printf("[R_OBJC] settle mode=%d (%s), settle=%u us\n", mode,
           mode == 0 ? "compatible" : mode == 1 ? "fast" : "async-only",
           (unsigned)gSettleUS);
}

int r_settle_get_mode(void)
{
    return gSettleMode;
}

uint64_t r_perf_round_trips(void)
{
    return gRoundTripCount;
}

void r_perf_snapshot(RPerfSnapshot *out)
{
    if (!out) return;
    out->rcCalls = remote_call_total_calls();
    out->mainCalls = __atomic_load_n(&gMainCallCount, __ATOMIC_RELAXED);
    out->mainWaitUS = __atomic_load_n(&gMainWaitUS, __ATOMIC_RELAXED);
    out->settleSleptUS = gSettleSleptUS;
}

void r_perf_reset(void)
{
    gRemoteMsgCount = 0;
    gSettleCount = 0;
    gSettleSleptUS = 0;
}

// Per-thread call status (see r_last_call_ok / r_last_main_ok).
static __thread bool t_r_last_ok = false;
static __thread bool t_r_main_ok = false;

bool r_last_call_ok(void) { return t_r_last_ok; }
bool r_last_main_ok(void) { return t_r_main_ok; }

static uint64_t r_call_stable(int timeout, const char *fnName,
                              uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    pthread_mutex_lock(&gRemoteCallLock);
    gRoundTripCount++;
    uint64_t ret = do_remote_call_stable(timeout, fnName,
                                         a0, a1, a2, a3,
                                         a4, a5, a6, a7);
    t_r_last_ok = remote_call_last_call_ok();
    pthread_mutex_unlock(&gRemoteCallLock);
    return ret;
}

uint32_t r_settle_us(uint32_t usec)
{
    uint32_t old = (uint32_t)gSettleUS;
    gSettleUS = (useconds_t)usec;
    return old;
}

bool r_is_objc_ptr(uint64_t ptr)
{
    return ptr >= 0x100000000ULL;
}

uint64_t r_dlsym_call(int timeout, const char *fnName,
                      uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                      uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    return r_call_stable(timeout, fnName, a0, a1, a2, a3, a4, a5, a6, a7);
}

uint64_t r_alloc_str(const char *s)
{
    if (!s) return 0;
    uint64_t len = strlen(s) + 1;
    uint64_t buf = r_call_stable(R_TIMEOUT, "malloc", len, 0, 0, 0, 0, 0, 0, 0);
    if (buf) remote_writeStr(buf, s);
    return buf;
}

void r_free(uint64_t ptr)
{
    if (!ptr) return;
    r_call_stable(R_TIMEOUT, "free", ptr, 0, 0, 0, 0, 0, 0, 0);
}

uint64_t r_sel(const char *name)
{
    int pid = remote_call_current_pid();
    uint64_t cached = r_cache_lookup(gSelCache, pid, name);
    if (cached) return cached;

    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t sel = r_call_stable(R_TIMEOUT, "sel_registerName", s, 0, 0, 0, 0, 0, 0, 0);
    r_free(s);
    r_cache_store(gSelCache, &gSelCacheNext, pid, name, sel);
    return sel;
}

uint64_t r_class(const char *name)
{
    int pid = remote_call_current_pid();
    uint64_t cached = r_cache_lookup(gClassCache, pid, name);
    if (cached) return cached;

    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t c = r_call_stable(R_TIMEOUT, "objc_getClass", s, 0, 0, 0, 0, 0, 0, 0);
    r_free(s);
    r_cache_store(gClassCache, &gClassCacheNext, pid, name, c);
    return c;
}

uint64_t r_msg(uint64_t obj, uint64_t sel,
               uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !sel) { t_r_last_ok = false; return 0; }
    return r_call_stable(R_TIMEOUT, "objc_msgSend",
                         obj, sel, a0, a1, a2, a3, 0, 0);
}

static uint64_t r_msg_retained_return(uint64_t obj, uint64_t sel,
                                      uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !sel) return 0;

    if (remote_call_uses_vphone_bridge()) {
        return r_call_stable(R_TIMEOUT, "objc_msgSend_retain",
                             obj, sel, a0, a1, a2, a3, 0, 0);
    }

    uint64_t ret = r_msg(obj, sel, a0, a1, a2, a3);
    if (r_is_objc_ptr(ret)) {
        uint64_t retained = r_msg(ret, r_sel("retain"), 0, 0, 0, 0);
        if (r_is_objc_ptr(retained)) ret = retained;
    }
    return ret;
}

uint64_t r_msg2(uint64_t obj, const char *selName,
                uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !selName) return 0;
    uint64_t sel = r_sel(selName);
    if (!sel) return 0;
    r_settle_for(selName);
    return r_msg(obj, sel, a0, a1, a2, a3);
}

static uint64_t r_method_signature(uint64_t obj, uint64_t sel)
{
    if (!r_is_objc_ptr(obj) || !sel) return 0;

    uint64_t sigSel = r_sel("methodSignatureForSelector:");
    uint64_t sig = r_msg_retained_return(obj, sigSel, sel, 0, 0, 0);
    if (r_is_objc_ptr(sig)) return sig;

    uint64_t cls = r_call_stable(R_TIMEOUT, "object_getClass",
                                 obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return 0;

    uint64_t method = r_call_stable(R_TIMEOUT, "class_getInstanceMethod",
                                    cls, sel, 0, 0, 0, 0, 0, 0);
    if (!method) return 0;

    uint64_t types = r_call_stable(R_TIMEOUT, "method_getTypeEncoding",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    if (!types) return 0;

    uint64_t NSMethodSignature = r_class("NSMethodSignature");
    if (!r_is_objc_ptr(NSMethodSignature)) return 0;
    return r_msg_retained_return(NSMethodSignature,
                                 r_sel("signatureWithObjCTypes:"),
                                 types, 0, 0, 0);
}

static bool r_write_remote_arg(uint64_t remoteBuf, const void *arg, size_t argSize, size_t remoteSize)
{
    if (!remoteBuf || remoteSize == 0) return false;

    uint8_t stackBuf[64];
    void *localBuf = stackBuf;
    if (remoteSize > sizeof(stackBuf)) {
        localBuf = calloc(1, remoteSize);
        if (!localBuf) return false;
    } else {
        memset(stackBuf, 0, remoteSize);
    }

    if (arg && argSize) {
        size_t copySize = (argSize < remoteSize) ? argSize : remoteSize;
        memcpy(localBuf, arg, copySize);
    }

    bool ok = remote_write(remoteBuf, localBuf, remoteSize);
    if (localBuf != stackBuf) free(localBuf);
    return ok;
}

// Cached main-thread invocations.
//
// The slow path below builds a fresh NSInvocation for every main-thread
// message: signature, invocation, numberOfArguments, setTarget, setSelector,
// a malloc/write/setArgument/free per argument, retainArguments, the perform,
// methodReturnLength, a malloc/getReturnValue/free, release -- ~23 RemoteCall
// round trips. Here one retained invocation is kept per (process, class,
// selector) with its argument count and return length, and a call only
// retargets it, copies the arguments in from a per-process scratch buffer and
// performs it: object_getClass + setTarget + one setArgument per argument +
// perform + getReturnValue, 4-8 round trips.
//
// Safe to reuse because the perform waits for completion (waitUntilDone:YES)
// and gInvLock is held for the whole call, so no two calls share an
// invocation at once.
//
// Object lifetimes must match the slow path, which callers were written
// against. That path's invocation had retainArguments, so it retained the
// returned object INSIDE -invoke on the main thread, and then leaked (its
// worker-thread autorelease pool never drains), keeping that object alive for
// good. Callers rely on it: r_msg2_main_retained fetches -windows / -subviews
// and only retains the autoreleased array on a SECOND main-thread hop; with
// nothing holding it, SpringBoard's run loop drained its pool in between and
// the retain hop's object_getClass PAC-faulted on the freed array (SpringBoard
// crash 2026-10-09 11:43:55, Double Tap to Lock). So each cached invocation
// has retainArguments too (target, object arguments and the return value are
// retained as they are set), and every returned object gets one more retain
// held in gInvKeep and released, on the main thread, only after
// R_INV_KEEP_CAP newer returns. Keyed by class (not object), because a
// freed object's address can be reused by another class with a different
// signature; a class object is keyed by its metaclass. A new SpringBoard
// (respring) has a new pid, so its entries never match. Anything unusual --
// an argument larger than a slot, a return value larger than the return
// slot, a failed build -- falls back to the slow path.
#define R_INV_CACHE_CAP 128
#define R_INV_ARG_SLOT  64
#define R_INV_RET_SLOT  64
#define R_INV_SCRATCH   (4 * R_INV_ARG_SLOT + R_INV_RET_SLOT)
#define R_INV_KEEP_CAP  512

typedef struct {
    int pid;
    uint64_t cls;
    uint64_t sel;
    uint64_t inv;        // retained; 0 = this (class, selector) uses the slow path
    uint64_t numUserArgs;
    uint64_t retLen;
    bool retIsObject;    // return type '@': kept alive in gInvKeep
    uint64_t lastUse;
} RemoteInvocationEntry;

static pthread_mutex_t gInvLock = PTHREAD_MUTEX_INITIALIZER;
static RemoteInvocationEntry gInvCache[R_INV_CACHE_CAP];
static uint64_t gInvClock = 0;
static int gInvScratchPid = 0;
static uint64_t gInvScratch = 0;   // 4 argument slots, then the return slot
static int gInvKeepPid = 0;
static uint64_t gInvKeep[R_INV_KEEP_CAP];
static int gInvKeepNext = 0;

// Release on SpringBoard's main thread, async: a release can be the last one,
// and a UIView (or an array of them) must not be deallocated on our worker.
static void r_release_on_main_async(uint64_t obj)
{
    if (!obj) return;
    r_msg(obj, r_sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
          r_sel("release"), 0, 0, 0);
}

static void r_inv_keep(int pid, uint64_t obj)
{
    if (gInvKeepPid != pid) {   // new process: the old entries died with it
        memset(gInvKeep, 0, sizeof(gInvKeep));
        gInvKeepNext = 0;
        gInvKeepPid = pid;
    }
    r_msg(obj, r_sel("retain"), 0, 0, 0, 0);
    uint64_t old = gInvKeep[gInvKeepNext];
    gInvKeep[gInvKeepNext] = obj;
    gInvKeepNext = (gInvKeepNext + 1) % R_INV_KEEP_CAP;
    r_release_on_main_async(old);
}

static RemoteInvocationEntry *r_inv_entry(int pid, uint64_t obj, uint64_t cls, uint64_t sel)
{
    RemoteInvocationEntry *victim = &gInvCache[0];
    for (int i = 0; i < R_INV_CACHE_CAP; i++) {
        RemoteInvocationEntry *e = &gInvCache[i];
        if (e->pid == pid && e->cls == cls && e->sel == sel) {
            e->lastUse = ++gInvClock;
            return e;
        }
        if (e->pid == 0) { victim = e; break; }
        if (e->lastUse < victim->lastUse) victim = e;
    }
    // Evict (an invocation from a dead process is just dropped).
    if (victim->pid == pid && victim->inv) r_release_on_main_async(victim->inv);
    memset(victim, 0, sizeof(*victim));

    uint64_t inv = 0, numUserArgs = 0, retLen = 0;
    bool retIsObject = false;
    uint64_t sig = r_method_signature(obj, sel);   // retained
    uint64_t NSInvocation = r_class("NSInvocation");
    if (r_is_objc_ptr(sig) && r_is_objc_ptr(NSInvocation)) {
        uint64_t numArgs = r_msg(sig, r_sel("numberOfArguments"), 0, 0, 0, 0);
        numUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
        if (numUserArgs > 4) numUserArgs = 4;
        retLen = r_msg(sig, r_sel("methodReturnLength"), 0, 0, 0, 0);
        // Is the return type '@'? Not via remote_read: the type string lives
        // in the dyld shared cache, which the shmem page mapping cannot map
        // (each attempt logged 3 errors and wiped the whole shmem cache).
        // strchr(t, '@') == t exactly when t[0] == '@': one call, no read.
        uint64_t retType = r_msg(sig, r_sel("methodReturnType"), 0, 0, 0, 0);
        retIsObject = retType &&
            r_call_stable(R_TIMEOUT, "strchr", retType, '@', 0, 0, 0, 0, 0, 0) == retType;
        if (retLen <= R_INV_RET_SLOT) {
            inv = r_msg_retained_return(NSInvocation, r_sel("invocationWithMethodSignature:"),
                                        sig, 0, 0, 0);
            if (r_is_objc_ptr(inv)) {
                r_msg(inv, r_sel("setSelector:"), sel, 0, 0, 0);
                // Before any target/argument is set, so every later setter and
                // -invoke's return value are retained as they happen.
                r_msg(inv, r_sel("retainArguments"), 0, 0, 0, 0);
            } else {
                inv = 0;
            }
        }
    }
    if (r_is_objc_ptr(sig)) r_msg(sig, r_sel("release"), 0, 0, 0, 0);

    victim->pid = pid;
    victim->cls = cls;
    victim->sel = sel;
    victim->inv = inv;
    victim->numUserArgs = numUserArgs;
    victim->retLen = retLen;
    victim->retIsObject = retIsObject;
    victim->lastUse = ++gInvClock;
    return victim;
}

// Outcome of the cached fast path. Only NOT_DISPATCHED may fall back to the
// slow path: once the invoke has been sent, the selector may already have run,
// and replaying a mutator would run it twice.
typedef enum {
    R_CACHED_NOT_DISPATCHED = 0,   // nothing ran; caller may use the slow path
    R_CACHED_OK,                   // ran, *retOut is its return value
    R_CACHED_FAILED,               // dispatch or result failed; *retOut = 0
} RCachedResult;

static RCachedResult r_msg_main_cached(uint64_t obj, uint64_t sel,
                                       const void *const args[4], const size_t sizes[4],
                                       uint64_t *retOut)
{
    int pid = remote_call_current_pid();
    if (pid <= 0) return R_CACHED_NOT_DISPATCHED;
    for (int i = 0; i < 4; i++) if (sizes[i] > R_INV_ARG_SLOT) return R_CACHED_NOT_DISPATCHED;

    pthread_mutex_lock(&gInvLock);
    RCachedResult result = R_CACHED_NOT_DISPATCHED;
    do {
        if (gInvScratchPid != pid || !gInvScratch) {
            gInvScratch = r_call_stable(R_TIMEOUT, "calloc", 1, R_INV_SCRATCH, 0, 0, 0, 0, 0, 0);
            gInvScratchPid = gInvScratch ? pid : 0;
            if (!gInvScratch) break;
        }
        uint64_t cls = r_call_stable(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
        if (!r_is_objc_ptr(cls)) break;
        RemoteInvocationEntry *e = r_inv_entry(pid, obj, cls, sel);
        if (!e->inv) break;

        if (e->numUserArgs) {
            uint8_t local[4 * R_INV_ARG_SLOT];
            memset(local, 0, sizeof(local));
            for (uint64_t i = 0; i < e->numUserArgs; i++) {
                if (args[i] && sizes[i]) memcpy(local + i * R_INV_ARG_SLOT, args[i], sizes[i]);
            }
            if (!remote_write(gInvScratch, local, (size_t)(e->numUserArgs * R_INV_ARG_SLOT))) break;
        }
        uint64_t retSlot = gInvScratch + 4 * R_INV_ARG_SLOT;
        if (e->retLen && !remote_write64(retSlot, 0)) break;

        // The invocation is reused: a target or argument that failed to set
        // would leave the previous call's in place, and invoking would hit
        // the wrong object. Every setter must land before the invoke.
        r_msg(e->inv, r_sel("setTarget:"), obj, 0, 0, 0);
        if (!t_r_last_ok) break;
        uint64_t selSetArg = r_sel("setArgument:atIndex:");
        bool argsSet = true;
        for (uint64_t i = 0; i < e->numUserArgs && argsSet; i++) {
            r_msg(e->inv, selSetArg, gInvScratch + i * R_INV_ARG_SLOT, i + 2, 0, 0);
            argsSet = t_r_last_ok;
        }
        if (!argsSet) break;

        uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
        uint64_t invokeSel = r_sel("invoke");
        if (!performSel || !invokeSel) break;
        // From here on the selector may have run: never fall back.
        result = R_CACHED_FAILED;
        *retOut = 0;
        r_invoke_on_main_wait(e->inv, performSel, invokeSel);
        if (!t_r_last_ok) {
            printf("[R_OBJC] main-thread dispatch failed (completion unknown)\n");
            break;
        }

        uint64_t ret = 0;
        if (e->retLen) {
            // Without a confirmed getReturnValue:, the invocation's buffer
            // (or the zeroed slot) says nothing about this call.
            r_msg(e->inv, r_sel("getReturnValue:"), retSlot, 0, 0, 0);
            if (!t_r_last_ok) break;
            ret = remote_read64(retSlot);
            // The invocation already holds it (retainArguments); this keeps it
            // alive past the next call on the same invocation, as the slow
            // path's leaked invocations did.
            if (e->retIsObject && ret) r_inv_keep(pid, ret);
        }
        *retOut = ret;
        result = R_CACHED_OK;
    } while (0);
    pthread_mutex_unlock(&gInvLock);
    return result;
}

uint64_t r_msg_main_raw(uint64_t obj, uint64_t sel,
                        const void *a0, size_t a0Size,
                        const void *a1, size_t a1Size,
                        const void *a2, size_t a2Size,
                        const void *a3, size_t a3Size)
{
    if (!r_is_objc_ptr(obj) || !sel) { t_r_main_ok = false; return 0; }

    const void *const cachedArgs[4] = { a0, a1, a2, a3 };
    const size_t cachedSizes[4] = { a0Size, a1Size, a2Size, a3Size };
    uint64_t cachedRet = 0;
    RCachedResult cached = r_msg_main_cached(obj, sel, cachedArgs, cachedSizes, &cachedRet);
    if (cached != R_CACHED_NOT_DISPATCHED) {
        t_r_main_ok = (cached == R_CACHED_OK);
        return cachedRet;
    }
    t_r_main_ok = false;

    uint64_t sig = r_method_signature(obj, sel);
    if (!r_is_objc_ptr(sig)) return 0;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return 0;

    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return 0;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    bool argsOK = t_r_last_ok;
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);
    argsOK = argsOK && t_r_last_ok;

    const void *argData[4] = { a0, a1, a2, a3 };
    size_t argSizes[4] = { a0Size, a1Size, a2Size, a3Size };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        size_t argBufLen = (argSizes[i] > 8) ? argSizes[i] : 8;
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        argBufLen, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        if (r_write_remote_arg(argBuf, argData[i], argSizes[i], argBufLen)) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
            if (!t_r_last_ok) argsOK = false;
        } else {
            argsOK = false;
        }
        r_free(argBuf);
    }

    if (!argsOK) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return 0;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (!performSel || !invokeSel) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return 0;
    }
    r_invoke_on_main_wait(inv, performSel, invokeSel);
    if (!t_r_last_ok) {
        // The selector may or may not have run; report failure, don't retry.
        printf("[R_OBJC] main-thread dispatch failed (completion unknown)\n");
        r_msg2(inv, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t ret = 0;
    bool retOK = true;
    uint64_t retLen = r_msg2(sig, "methodReturnLength", 0, 0, 0, 0);
    if (!t_r_last_ok) retOK = false;
    if (retLen > 0) {
        uint64_t retBufLen = (retLen > 8) ? retLen : 8;
        uint64_t retBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        retBufLen, 0, 0, 0, 0, 0, 0, 0);
        retOK = retOK && retBuf && remote_write64(retBuf, 0);
        if (retOK) {
            r_msg2(inv, "getReturnValue:", retBuf, 0, 0, 0);
            retOK = t_r_last_ok;
            if (retOK) ret = remote_read64(retBuf);
        }
        if (retBuf) r_free(retBuf);
    }

    r_msg2(inv, "release", 0, 0, 0, 0);
    t_r_main_ok = retOK;
    return ret;
}

uint64_t r_msg_main(uint64_t obj, uint64_t sel,
                    uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (remote_call_uses_vphone_bridge()) {
        uint64_t ret = r_call_stable(R_TIMEOUT, "objc_msgSend_main",
                                     obj, sel, a0, a1, a2, a3, 0, 0);
        t_r_main_ok = t_r_last_ok;
        return ret;
    }

    uint64_t args[4] = { a0, a1, a2, a3 };
    return r_msg_main_raw(obj, sel,
                          &args[0], sizeof(args[0]),
                          &args[1], sizeof(args[1]),
                          &args[2], sizeof(args[2]),
                          &args[3], sizeof(args[3]));
}

uint64_t r_msg2_main(uint64_t obj, const char *selName,
                     uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !selName) { t_r_main_ok = false; return 0; }
    uint64_t sel = r_sel(selName);
    if (!sel) { t_r_main_ok = false; return 0; }
    r_settle_for(selName);
    return r_msg_main(obj, sel, a0, a1, a2, a3);
}

// Fire-and-forget variant: dispatches the call to main thread with
// waitUntilDone:NO and skips the return-value plumbing. Use this when the
// selector returns void and we don't need to wait — main thread retains the
// NSInvocation for the duration of the call, so it's safe to release here.
void r_msg2_main_async(uint64_t obj, const char *selName,
                       uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!r_is_objc_ptr(obj) || !selName) return;
    uint64_t sel = r_sel(selName);
    if (!sel) return;
    r_settle_for(selName);

    uint64_t sig = 0;
    {
        uint64_t sigSel = r_sel("methodSignatureForSelector:");
        sig = r_msg(obj, sigSel, sel, 0, 0, 0);
    }
    if (!r_is_objc_ptr(sig)) return;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return;
    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);

    bool argsOK = true;
    uint64_t userArgs[4] = { a0, a1, a2, a3 };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        8, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        if (remote_write64(argBuf, userArgs[i])) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
        } else {
            argsOK = false;
        }
        r_free(argBuf);
    }

    if (!argsOK) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (performSel && invokeSel) r_msg(inv, performSel, invokeSel, 0, 0, 0);
    // performSelectorOnMainThread: retains the receiver until it has run.
    r_msg2(inv, "release", 0, 0, 0, 0);

    // Fire-and-forget: the main thread may still be running this when we
    // return, so the next remote interaction owes a settle.
    gSettleOwed = true;
}

uint64_t r_msg2_main_raw(uint64_t obj, const char *selName,
                         const void *a0, size_t a0Size,
                         const void *a1, size_t a1Size,
                         const void *a2, size_t a2Size,
                         const void *a3, size_t a3Size)
{
    if (!obj || !selName) { t_r_main_ok = false; return 0; }
    uint64_t sel = r_sel(selName);
    if (!sel) { t_r_main_ok = false; return 0; }
    r_settle_for(selName);
    return r_msg_main_raw(obj, sel, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size);
}

// Same flow as r_msg_main_raw, but copies the full method return buffer back
// into outBuf instead of truncating to 8 bytes. Used for selectors that return
// a struct larger than a register pair (e.g. CGRect from -convertRect:toView:).
bool r_msg2_main_struct_ret(uint64_t obj, const char *selName,
                            void *outBuf, size_t outSize,
                            const void *a0, size_t a0Size,
                            const void *a1, size_t a1Size,
                            const void *a2, size_t a2Size,
                            const void *a3, size_t a3Size)
{
    if (!r_is_objc_ptr(obj) || !selName || !outBuf || outSize == 0) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    r_settle_for(selName);

    uint64_t sig = r_method_signature(obj, sel);
    if (!r_is_objc_ptr(sig)) return false;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return false;

    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return false;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);

    bool argsOK = true;
    const void *argData[4] = { a0, a1, a2, a3 };
    size_t argSizes[4] = { a0Size, a1Size, a2Size, a3Size };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        size_t argBufLen = (argSizes[i] > 8) ? argSizes[i] : 8;
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        argBufLen, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        if (r_write_remote_arg(argBuf, argData[i], argSizes[i], argBufLen)) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
        } else {
            argsOK = false;
        }
        r_free(argBuf);
    }

    if (!argsOK) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return false;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (!performSel || !invokeSel) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return false;
    }
    r_invoke_on_main_wait(inv, performSel, invokeSel);

    bool ok = false;
    uint64_t retLen = r_msg2(sig, "methodReturnLength", 0, 0, 0, 0);
    if (retLen >= outSize) {
        uint64_t retBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        retLen, 0, 0, 0, 0, 0, 0, 0);
        if (retBuf) {
            r_msg2(inv, "getReturnValue:", retBuf, 0, 0, 0);
            ok = remote_read(retBuf, outBuf, outSize);
            r_free(retBuf);
        }
    }

    r_msg2(inv, "release", 0, 0, 0, 0);
    return ok;
}

uint64_t r_perform_main(uint64_t obj, uint64_t sel, uint64_t object, bool wait)
{
    if (!r_is_objc_ptr(obj) || !sel) return 0;
    if (remote_call_uses_vphone_bridge()) {
        return r_msg_main(obj, sel, object, 0, 0, 0);
    }

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!performSel) return 0;
    return r_msg(obj, performSel, sel, object, wait ? 1 : 0, 0);
}

uint64_t r_cfstr(const char *s)
{
    if (!s) return 0;
    uint64_t buf = r_alloc_str(s);
    if (!buf) return 0;
    // CFStringCreateWithCString(alloc=NULL, cstr, encoding=kCFStringEncodingUTF8=0x08000100)
    uint64_t cf = r_call_stable(R_TIMEOUT, "CFStringCreateWithCString",
                                0, buf, 0x08000100, 0, 0, 0, 0, 0);
    r_free(buf);
    return cf;
}

uint64_t r_nsstr_retained(const char *s)
{
    if (!s) return 0;
    uint64_t buf = r_alloc_str(s);
    if (!buf) return 0;
    uint64_t NSString = r_class("NSString");
    if (!r_is_objc_ptr(NSString)) { r_free(buf); return 0; }
    uint64_t allocated = r_msg2(NSString, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(allocated)) { r_free(buf); return 0; }
    uint64_t ns = r_msg2(allocated, "initWithUTF8String:", buf, 0, 0, 0);
    r_free(buf);
    return ns;
}

bool r_responds(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj)) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    uint64_t respondsSel = r_sel("respondsToSelector:");
    if (!respondsSel) return false;
    r_settle_query();  // pure query: nothing to settle
    uint64_t r = r_msg(obj, respondsSel, sel, 0, 0, 0);
    return (r & 0xff) != 0;
}

bool r_responds_main(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj)) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    uint64_t respondsSel = r_sel("respondsToSelector:");
    if (!respondsSel) return false;
    r_settle_query();  // pure query: nothing to settle
    uint64_t r = r_msg_main(obj, respondsSel, sel, 0, 0, 0);
    return (r & 0xff) != 0;
}

uint64_t r_ivar_value(uint64_t obj, const char *ivarName)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t cls = r_call_stable(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!cls) return 0;
    uint64_t nameBuf = r_alloc_str(ivarName);
    if (!nameBuf) return 0;
    uint64_t ivar = r_call_stable(R_TIMEOUT, "class_getInstanceVariable",
                                  cls, nameBuf, 0, 0, 0, 0, 0, 0);
    r_free(nameBuf);
    if (!ivar) return 0;
    uint64_t offset = r_call_stable(R_TIMEOUT, "ivar_getOffset",
                                    ivar, 0, 0, 0, 0, 0, 0, 0);
    return remote_read64(obj + offset);
}

uint64_t r_msg2_main_retained(uint64_t obj, const char *selName)
{
    uint64_t value = r_msg2_main(obj, selName, 0, 0, 0, 0);
    if (!r_is_objc_ptr(value)) return 0;
    // retain is an atomic refcount bump, safe from any thread (r_release is
    // already off-main); a second main-thread hop only added ~5 round trips.
    r_msg(value, r_sel("retain"), 0, 0, 0, 0);
    return value;
}

void r_release(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg(obj, r_sel("release"), 0, 0, 0, 0);
}

int r_array_items_of_class(uint64_t array, uint64_t cls, uint64_t *out, int cap)
{
    if (!r_is_objc_ptr(array) || cap <= 0) return 0;
    uint64_t n = r_msg(array, r_sel("count"), 0, 0, 0, 0);
    if (n > 512) n = 512;
    uint64_t selObjAt = r_sel("objectAtIndex:");
    uint64_t selKind  = r_sel("isKindOfClass:");
    int found = 0;
    for (uint64_t i = 0; i < n && found < cap; i++) {
        uint64_t v = r_msg(array, selObjAt, i, 0, 0, 0);
        if (!r_is_objc_ptr(v)) continue;
        if (cls && !r_msg(v, selKind, cls, 0, 0, 0)) continue;
        out[found++] = v;
    }
    return found;
}

uint64_t r_invocation_retained(uint64_t sample, const char *selName,
                               const void *arg, size_t argSize)
{
    uint64_t sel = r_sel(selName);
    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(sample) || !sel || !r_is_objc_ptr(NSInvocation)) return 0;
    uint64_t sig = r_msg(sample, r_sel("methodSignatureForSelector:"), sel, 0, 0, 0);
    if (!r_is_objc_ptr(sig)) return 0;
    uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return 0;
    r_msg(inv, r_sel("retain"), 0, 0, 0, 0);
    r_msg(inv, r_sel("setSelector:"), sel, 0, 0, 0);
    // NSInvocation copies the argument bytes, so the buffer is freed here.
    uint64_t mem = r_call_stable(R_TIMEOUT, "calloc", 1, argSize < 8 ? 8 : argSize,
                                 0, 0, 0, 0, 0, 0);
    bool ok = mem && remote_write(mem, arg, argSize);
    if (ok) r_msg(inv, r_sel("setArgument:atIndex:"), mem, 2, 0, 0);
    if (mem) r_free(mem);
    if (!ok) {
        r_release(inv);
        return 0;
    }
    return inv;
}

void r_invocation_invoke_main(uint64_t inv, uint64_t target)
{
    if (!r_is_objc_ptr(inv) || !r_is_objc_ptr(target)) return;
    r_msg(inv, r_sel("setTarget:"), target, 0, 0, 0);
    r_invoke_on_main_wait(inv, r_sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
                          r_sel("invoke"));
}

bool r_read_nsstring(uint64_t str, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(str) || !out || outLen == 0) return false;
    memset(out, 0, outLen);

    uint64_t buf = r_dlsym_call(R_TIMEOUT, "malloc", outLen, 0, 0, 0, 0, 0, 0, 0);
    if (!buf) return false;
    r_dlsym_call(R_TIMEOUT, "memset", buf, 0, outLen, 0, 0, 0, 0, 0);

    bool copied = false;
    if (r_responds(str, "getCString:maxLength:encoding:")) {
        uint64_t ok = r_msg2(str, "getCString:maxLength:encoding:", buf, outLen, 4, 0);
        if ((ok & 0xff) && remote_read(buf, out, outLen - 1)) {
            out[outLen - 1] = '\0';
            copied = out[0] != '\0';
        }
    }

    r_free(buf);
    return copied;
}

#ifdef __OBJC__
#define R_SESSION_RETURN(session, type, fallback, expr) do { \
    if (!(session)) return (expr); \
    __block type result = (fallback); \
    remote_call_with_session((session), ^{ result = (expr); }); \
    return result; \
} while (0)

#define R_SESSION_VOID(session, expr) do { \
    if (!(session)) { expr; return; } \
    remote_call_with_session((session), ^{ expr; }); \
} while (0)

uint64_t r_session_dlsym_call(RemoteCallSession *session, int timeout, const char *fnName,
                              uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_dlsym_call(timeout, fnName, a0, a1, a2, a3, a4, a5, a6, a7));
}

uint64_t r_session_alloc_str(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_alloc_str(s));
}

void r_session_free(RemoteCallSession *session, uint64_t ptr)
{
    R_SESSION_VOID(session, r_free(ptr));
}

uint64_t r_session_sel(RemoteCallSession *session, const char *name)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_sel(name));
}

uint64_t r_session_class(RemoteCallSession *session, const char *name)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_class(name));
}

uint64_t r_session_msg(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                       uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg(obj, sel, a0, a1, a2, a3));
}

uint64_t r_session_msg2(RemoteCallSession *session, uint64_t obj, const char *selName,
                        uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg2(obj, selName, a0, a1, a2, a3));
}

uint64_t r_session_msg_main(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                            uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg_main(obj, sel, a0, a1, a2, a3));
}

uint64_t r_session_msg2_main(RemoteCallSession *session, uint64_t obj, const char *selName,
                             uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg2_main(obj, selName, a0, a1, a2, a3));
}

void r_session_msg2_main_async(RemoteCallSession *session, uint64_t obj, const char *selName,
                               uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_VOID(session, r_msg2_main_async(obj, selName, a0, a1, a2, a3));
}

uint64_t r_session_msg_main_raw(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                                const void *a0, size_t a0Size,
                                const void *a1, size_t a1Size,
                                const void *a2, size_t a2Size,
                                const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_msg_main_raw(obj, sel, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

uint64_t r_session_msg2_main_raw(RemoteCallSession *session, uint64_t obj, const char *selName,
                                 const void *a0, size_t a0Size,
                                 const void *a1, size_t a1Size,
                                 const void *a2, size_t a2Size,
                                 const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_msg2_main_raw(obj, selName, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

bool r_session_msg2_main_struct_ret(RemoteCallSession *session, uint64_t obj, const char *selName,
                                    void *outBuf, size_t outSize,
                                    const void *a0, size_t a0Size,
                                    const void *a1, size_t a1Size,
                                    const void *a2, size_t a2Size,
                                    const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, bool, false,
                     r_msg2_main_struct_ret(obj, selName, outBuf, outSize,
                                            a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

uint64_t r_session_perform_main(RemoteCallSession *session, uint64_t obj, uint64_t sel, uint64_t object, bool wait)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_perform_main(obj, sel, object, wait));
}

uint64_t r_session_cfstr(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_cfstr(s));
}

uint64_t r_session_nsstr_retained(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_nsstr_retained(s));
}

bool r_session_responds(RemoteCallSession *session, uint64_t obj, const char *selName)
{
    R_SESSION_RETURN(session, bool, false, r_responds(obj, selName));
}

bool r_session_responds_main(RemoteCallSession *session, uint64_t obj, const char *selName)
{
    R_SESSION_RETURN(session, bool, false, r_responds_main(obj, selName));
}

uint64_t r_session_ivar_value(RemoteCallSession *session, uint64_t obj, const char *ivarName)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_ivar_value(obj, ivarName));
}

#undef R_SESSION_VOID
#undef R_SESSION_RETURN
#endif
