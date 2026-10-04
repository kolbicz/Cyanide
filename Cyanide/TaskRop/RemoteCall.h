//
//  RemoteCall.h
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#ifndef RemoteCall_h
#define RemoteCall_h

#import <mach/mach.h>
#import <stdatomic.h>
#import <time.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

struct VMShmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool     used;
};

// from Duy Tran's TaskPortHaxxApp
// https://github.com/khanhduytran0/TaskPortHaxxApp/blob/pacbypass/TaskPortHaxxApp/Header.h#L83
typedef struct {
    uint64_t __x[29];       /* General purpose registers x0-x28 */
    uint64_t __fp; /* Frame pointer x29 */
    uint64_t __lr; /* Link register x30 */
    uint64_t __sp; /* Stack pointer x31 */
    uint64_t __pc; /* Program counter */
    uint32_t __cpsr;        /* Current program status register */
    uint32_t __flags; /* Flags describing structure format */
} arm_thread_state64_internal;

typedef enum {
    RemoteCallInitFailureNone = 0,
    RemoteCallInitFailureKRWUnavailable,
    RemoteCallInitFailureProcessMissing,
    RemoteCallInitFailureInvalidTask,
    RemoteCallInitFailureExceptionPort,
    RemoteCallInitFailureTaskGuard,
    RemoteCallInitFailureLocalThread,
    RemoteCallInitFailureNoTargetThreads,
    RemoteCallInitFailureFirstExceptionTimeout,
    // Round 24: init refused (at entry) or aborted (mid-walk/mid-hijack)
    // because the excport lifecycle gate was closed — backgrounded or
    // terminating. Distinct from Other so the fastkill path can tell "try
    // again" (transient) from "we were backgrounded" (deterministic).
    RemoteCallInitFailureLifecycleGated,
    // Round 43: init refused at entry because a tro-dance helper wedged
    // earlier this session (fail-closed latch). Distinct so the kill path
    // can fail FAST (no 3-attempt retry storm — every arm would be refused)
    // and surface a "restart the app" message instead of "try again".
    RemoteCallInitFailureHelperWedged,
    RemoteCallInitFailureOther,
} RemoteCallInitFailure;

mach_port_t create_exception_port(void);
int disable_excguard_kill(uint64_t task);
// One-shot override consumed by the next call to init_remote_call. When
// non-zero, init_remote_call skips its proc_find_by_name lookup and uses
// this kernel proc address directly. Useful when there are multiple
// processes with the same name (e.g. system vs per-user cfprefsd) and we
// need to target a specific one. Reset to 0 by init_remote_call.
extern uint64_t g_RC_targetProcOverride;
// Round 41: one-shot override consumed by the NEXT init_remote_call whose
// process name matches (cleared on the next init regardless of match, so a
// stale value can never leak into a later unrelated init — e.g. the PERSIST
// launchd anchoring, which must keep the default). Caps how many candidate
// threads the arm walk injects. The fastkill (Process Viewer) launchd
// sessions use 2: every armed launchd thread is a thread that can be
// stranded/SIGKILLed if the app dies mid-session (082220: a 5-arm warm hung
// into "unexpected SIGKILL of launchd"), and the kill path can tolerate a
// slightly later first trap. The initial PERSIST/exploit anchoring inits
// keep the default 6 (round 7: warm-up latency is the min over injected
// threads; those are one-shot bootstraps where a fast first trap matters
// more than strand surface).
void remote_call_set_next_init_target_threads(const char *process, int count);
int init_remote_call(const char* process, bool useMigFilterBypass);
// Round 7 warm-up telemetry: stats of the most recent init_remote_call —
// injected thread count and the first-trap wait in ms (0/0 if none yet).
int remote_call_last_init_injected(void);
uint64_t remote_call_last_init_trap_ms(void);
// Enable/disable verbose RemoteCall logging at runtime (Settings debug toggle).
// Off by default; the per-call guard-acquire/release and RC_DEBUG lines only
// print when this is on (they flood the log after a tweak apply otherwise).
void remote_call_set_verbose(bool on);
int init_remote_call_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS);
int init_remote_call_original_thread_only_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS);
uint64_t do_remote_call_stable(int timeout, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
// Signs pc/lr into a trapped thread's state. FALSE = signing failed (KRW lost
// mid-call); the caller must reply with the UNMODIFIED trapped state instead
// of dispatching — a garbage PC/LR inside launchd is fatal to the device.
bool sign_state(uint64_t signingThread, arm_thread_state64_internal *state, uint64_t pc, uint64_t lr);
uint64_t remote_pac(uint64_t remoteThreadAddr, uint64_t address, uint64_t modifier);
// Round 17: session-cached PAC keys (captured at init while the trojan thread
// is provably alive). remote_pac() prefers these over re-reading a possibly
// dead thread. FALSE = no cached keys this session.
bool rc_session_pac_keys(uint64_t *outA, uint64_t *outB);
bool remote_read(uint64_t src, void *dst, uint64_t size);
uint64_t remote_read64(uint64_t src);
void remote_hexdump(uint64_t remoteAddr, size_t size);
bool remote_write(uint64_t dst, const void *src, uint64_t size);
bool remote_write64(uint64_t dst, uint64_t val);
bool remote_writeStr(uint64_t dst, const char *str);
uint64_t remote_call_trojan_mem(void);
int destroy_remote_call(void);
// Drop every piece of local RemoteCall state without trying to IPC the remote
// task. Use this when the remote task is known dead (e.g. SpringBoard just
// crashed and respawned) — destroy_remote_call would otherwise hang for
// 100s on its munmap/pthread_exit calls into a vanished trojan thread.
void abandon_remote_call(void);
bool remote_call_has_local_state(void);
bool remote_call_current_success(void);
int remote_call_current_pid(void);
bool remote_call_uses_vphone_bridge(void);
int remote_call_set_stable_timeout_floor_ms(int timeoutMS);
RemoteCallInitFailure remote_call_last_init_failure(void);
uint32_t remote_call_last_init_failure_pid(void);
const char *remote_call_init_failure_description(RemoteCallInitFailure failure);

// In-flight guard. A RemoteCall operation (EXC_GUARD hijack, remote call, or
// session teardown) holds corrupted/redirected threads inside the target
// process — for launchd that means a thread whose restoration REQUIRES the
// KRW sockets to stay alive. If the background/lock/idle detach path tears
// the sockets down mid-flight, the trapped launchd thread is never put back
// and the device watchdogs ~30 s later (live 9.log: 13:42:57, 16:24:58).
// Detach paths MUST NOT run while remote_call_inflight_count() > 0; they
// should call remote_call_request_stop() and remote_call_inflight_wait_drained_ms()
// first, and skip the detach if the wait times out.
int  remote_call_inflight_count(void);
// Round 41: tro-dance helpers that never returned from the kernel (wedged).
// This is NOT included in remote_call_inflight_count() (that counts guard
// begin/end ops). >0 means a Cyanide thread is parked in-kernel: the
// process must not exit (un-reaped corpse → black screen on reopen), and
// arming is already fail-closed process-wide once this is nonzero. The
// round-40 suspend/exit drains poll this too.
int  remote_call_helper_unaccounted_count(void);
bool remote_call_inflight_wait_drained_ms(int timeoutMs);
void remote_call_request_stop(const char *reason);   // ask in-flight ops to abort ASAP
bool remote_call_stop_requested(void);

// Detach gate: while held (acquire → detach → release), new RemoteCall
// acquisitions fail-fast — closes the drain-wait → next-acquire race that let
// a background detach land in the same millisecond as a kill call
// (live 10.log, 17:50:30.483 → panic 17:50:55). acquire returns true with the
// gate HELD CLOSED once in-flight ops have drained (caller detaches, then
// releases); returns false with the gate re-opened on timeout (skip detach).
bool remote_call_detach_gate_acquire(int timeoutMs, const char *reason);
void remote_call_detach_gate_release(const char *reason);

// External hold for composite ops (fastkill: warm-up + kill under ONE hold).
bool remote_call_guard_acquire_external(const char *what);
void remote_call_guard_release_external(const char *what);

#ifdef __OBJC__
@class RemotePointer;

@interface RemoteCallSession : NSObject

@property(nonatomic, readonly) uint64_t taskAddr;
@property(nonatomic, readonly) uint64_t trojanMem;
@property(nonatomic, readonly) int pid;

- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass;
- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS;
- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
              originalThreadOnly:(BOOL)originalThreadOnly;
- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7;
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
                                       x7:(uint64_t)x7;
- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size;
- (uint64_t)remoteRead64:(uint64_t)src;
- (BOOL)remoteWrite:(uint64_t)dst from:(const void *)src size:(uint64_t)size;
- (BOOL)remoteWrite64:(uint64_t)dst value:(uint64_t)val;
- (BOOL)remoteWriteString:(uint64_t)dst value:(const char *)str;
- (int)destroyRemoteCall;
- (void)abandonRemoteCall;
- (BOOL)hasLocalState;
// Round 20: YES when the first-port responder saw a protocol park trap/crash
// and exited — session has no responder and a parked launchd thread; tear it
// down instead of reusing or keeping it warm.
- (BOOL)isAnomalous;
- (RemotePointer *)objectAtIndexedSubscript:(NSUInteger)address;

@end

@interface RemotePointer : NSObject

@property(nonatomic, strong, readonly) RemoteCallSession *session;
@property(nonatomic, readonly) uint64_t address;

@property(nonatomic, copy) NSString *string;
@property(nonatomic) uint8_t value8;
@property(nonatomic) uint16_t value16;
@property(nonatomic) uint32_t value32;
@property(nonatomic) uint64_t value64;

- (instancetype)initWithSession:(RemoteCallSession *)session address:(uint64_t)address;
- (BOOL)writeCString:(const char *)string;
- (BOOL)readTo:(void *)dst size:(uint64_t)size;
- (BOOL)writeFrom:(const void *)src size:(uint64_t)size;
- (NSString *)stringWithMaxLength:(size_t)maxLength;

@end

void remote_call_with_session(RemoteCallSession *session, void (^block)(void));
#endif

#endif /* RemoteCall_h */
