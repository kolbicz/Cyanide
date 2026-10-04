//
//  Exception.m
//  Cyanide
//
//  Created by seo on 4/4/26.
//

#import "../kexploit/kexploit_opa334.h"
#import "Exception.h"
#import "RemoteCall.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

// xnu-10002.81.5/osfmk/mach/port.h
#define MPO_PROVISIONAL_ID_PROT_OPTOUT     0x8000  /* Opted out of EXCEPTION_IDENTITY_PROTECTED violation for now */

// from pe_main.js
#define EXCEPTION_MSG_SIZE              0x160
#define EXCEPTION_REPLY_SIZE            0x13c

// ---- Round 21: exception-port trap gate/serializer (see Exception.h) -------
// Round 24 (reviewer note E2): _Atomic with C11 atomic_* ops (stdatomic.h),
// matching the round-15 sweep pattern (gKrwNonfatalDepth / g_rc_verbose) —
// this toolchain's GNU __atomic_* builtins reject _Atomic-qualified pointers.
static _Atomic int g_excport_backgrounded = 0;
static _Atomic int g_excport_terminating = 0;
// Round 22-regression: teardown-owned exception-port operations (the drain's
// trojan restore, the synthetic exit dispatch, trojan restore in destroy)
// MUST sign even while the gate is blocked — the round-21 gate refusing them
// during backgrounding teardown is precisely what stranded launchd threads
// parked at sentinels and produced the two SIGKILL-of-launchd panics
// (panic-full-2026-10-03-123329 / -123448). This depth counter lets the
// teardown path pass the gate while every other caller stays refused.
// Residual: this re-opens the small ABBA window for teardown-owned ops —
// accepted; the proven-fatal alternative is a parked sentinel thread.
static _Atomic int g_excport_teardown_depth = 0;
static pthread_mutex_t g_excport_mutex = PTHREAD_MUTEX_INITIALIZER;

void excport_teardown_bypass_begin(const char *where)
{
    int depth = atomic_fetch_add(&g_excport_teardown_depth, 1) + 1;
    if (depth == 1 && excport_gate_blocked())
        printf("[EXCPORT] gate: teardown bypass ACTIVE (%s) — teardown-owned "
               "exception-port ops allowed through the blocked gate; leaving a "
               "thread parked at a sentinel is the proven-fatal alternative\n",
               where ?: "teardown");
}

void excport_teardown_bypass_end(const char *where)
{
    int depth = atomic_fetch_sub(&g_excport_teardown_depth, 1) - 1;
    if (depth < 0) {   // unpaired end — clamp, scream
        atomic_store(&g_excport_teardown_depth, 0);
        printf("[EXCPORT] gate: teardown bypass UNDERFLOW (%s) — unpaired "
               "begin/end, clamped to 0\n", where ?: "teardown");
    }
}

static bool excport_gate_blocked_for_caller(void)
{
    if (atomic_load(&g_excport_teardown_depth) > 0)
        return false;   // teardown owns this window
    return excport_gate_blocked();
}

void excport_gate_set_backgrounded(bool backgrounded)
{
    int prev = atomic_exchange(&g_excport_backgrounded, backgrounded ? 1 : 0);
    if (prev != (backgrounded ? 1 : 0))
        printf("[EXCPORT] gate: backgrounded=%d — own-process exception-port "
               "traps %s\n", backgrounded ? 1 : 0,
               backgrounded ? "now REFUSED" : "allowed again");
}

void excport_gate_set_terminating(void)
{
    if (!atomic_exchange(&g_excport_terminating, 1))
        printf("[EXCPORT] gate: terminating — own-process exception-port traps "
               "now REFUSED\n");
}

bool excport_gate_blocked(void)
{
    return atomic_load(&g_excport_backgrounded) != 0 ||
           atomic_load(&g_excport_terminating) != 0;
}

void excport_gate_snapshot(int *backgrounded, int *terminating)
{
    if (backgrounded) *backgrounded = atomic_load(&g_excport_backgrounded);
    if (terminating) *terminating = atomic_load(&g_excport_terminating);
}

bool excport_op_begin(const char *what)
{
    if (excport_gate_blocked_for_caller()) {
        printf("[EXCPORT] refusing %s: app backgrounded/terminating\n",
               what ?: "op");
        return false;
    }
    pthread_mutex_lock(&g_excport_mutex);
    // Re-check under the mutex: a lifecycle transition may have landed while
    // we waited for the previous operation to finish.
    if (excport_gate_blocked_for_caller()) {
        pthread_mutex_unlock(&g_excport_mutex);
        printf("[EXCPORT] refusing %s: lifecycle transition landed while "
               "waiting\n", what ?: "op");
        return false;
    }
    return true;
}

void excport_op_end(void)
{
    pthread_mutex_unlock(&g_excport_mutex);
}

mach_port_t create_exception_port(void)
{
    mach_port_options_t options = {
        .flags = MPO_INSERT_SEND_RIGHT | MPO_PROVISIONAL_ID_PROT_OPTOUT,
        .mpl   = { .mpl_qlimit = 0 }
    };

    mach_port_t exceptionPort = MACH_PORT_NULL;

    kern_return_t kr = mach_port_construct(mach_task_self_, &options, 0, &exceptionPort);
    if (kr != KERN_SUCCESS)
    {
        printf("[%s:%d] Failed to create exception port: %s (kr=%d)", __FUNCTION__, __LINE__, mach_error_string(kr), kr);
        return MACH_PORT_NULL;
    }

    return exceptionPort;
}

void destroy_exception_port(mach_port_t exceptionPort)
{
    if (!MACH_PORT_VALID(exceptionPort)) return;

    mach_port_type_t type = 0;
    kern_return_t kr = mach_port_type(mach_task_self_, exceptionPort, &type);
    if (kr == KERN_SUCCESS && (type & MACH_PORT_TYPE_SEND)) {
        kr = mach_port_mod_refs(mach_task_self_, exceptionPort, MACH_PORT_RIGHT_SEND, -1);
        if (kr != KERN_SUCCESS &&
            kr != KERN_INVALID_NAME &&
            kr != KERN_INVALID_RIGHT &&
            kr != KERN_INVALID_VALUE) {
            printf("[%s:%d] Failed to drop exception port send right 0x%x: %s (kr=%d)\n",
                   __FUNCTION__, __LINE__, exceptionPort, mach_error_string(kr), kr);
        }
    }

    kr = mach_port_destruct(mach_task_self_, exceptionPort, 0, 0);
    if (kr != KERN_SUCCESS && kr != KERN_INVALID_NAME)
        printf("[%s:%d] Failed to destroy exception port 0x%x: %s (kr=%d)\n",
               __FUNCTION__, __LINE__, exceptionPort, mach_error_string(kr), kr);
}

bool wait_exception(mach_port_t exceptionPort, ExceptionMessage *excBuffer, int timeout, bool debug) {
    kern_return_t kr = mach_msg(&excBuffer->Head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, EXCEPTION_MSG_SIZE, exceptionPort, timeout, MACH_PORT_NULL);
    
    if(kr != KERN_SUCCESS)  return false;

    return true;
}

void reply_with_state(ExceptionMessage *exc, arm_thread_state64_internal *state)
{
    uint8_t replyBuf[EXCEPTION_REPLY_SIZE];
    memset(replyBuf, 0, sizeof(replyBuf));
    ExceptionReply *reply = (ExceptionReply *)replyBuf;

    reply->Head.msgh_bits        = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply->Head.msgh_size        = EXCEPTION_REPLY_SIZE;
    reply->Head.msgh_remote_port = exc->Head.msgh_remote_port;
    reply->Head.msgh_local_port  = MACH_PORT_NULL;
    reply->Head.msgh_id          = exc->Head.msgh_id + 100;
    reply->NDR                   = exc->NDR;
    reply->RetCode               = 0;
    reply->flavor                = ARM_THREAD_STATE64;
    reply->new_stateCnt          = ARM_THREAD_STATE64_COUNT;
    memcpy(&reply->threadState, state, sizeof(arm_thread_state64_t));

    kern_return_t kr = mach_msg((mach_msg_header_t *)replyBuf,
                                MACH_SEND_MSG,
                                EXCEPTION_REPLY_SIZE, 0,
                                MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        printf("[%s:%d] reply_with_state failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(kr));
}

// (Round 24, reviewer note E1: reply_exc_failure was REMOVED — verified dead
// code. It had zero call sites anywhere in the tree: the round-17 crash-reply
// path it served was superseded by the excport gate and the park/re-park
// protocol, which answer every trap explicitly.)
