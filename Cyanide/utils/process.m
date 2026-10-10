//
//  process.c
//  Cyanide
//
//  Created by seo on 3/26/26.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include "process.h"
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <mach/thread_info.h>
#include <mach/task_policy.h>
#include <mach/vm_page_size.h>
#include "kutils.h"

// libproc.h / sys/proc_info.h aren't exposed in the iOS SDK, so declare the bits
// we use ourselves (ABI-stable). PROC_PIDTASKINFO flavor = 4.
#define PM_PROC_PIDTASKINFO 4
struct pm_proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
};
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

// PROC_PIDTBSDINFO flavor = 3. First fields match xnu's struct proc_bsdinfo
// (bsd/sys/proc_info.h): pbi_status (the p_stat) sits at offset 4. The buffer
// is padded well past the kernel's struct size; proc_pidinfo fills what it
// knows and returns the byte count.
#define PM_PROC_PIDTBSDINFO 3
struct pm_proc_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint8_t  reserved[256];
};

// proc_pid_rusage (also libproc) — gives ri_phys_footprint (the memory number
// jetsam/Activity Monitor use). Flavor 0 = RUSAGE_INFO_V0, which already has it.
extern int proc_pid_rusage(int pid, int flavor, void *buffer);
struct pm_rusage_v0 {
    uint8_t  ri_uuid[16];
    uint64_t ri_user_time;
    uint64_t ri_system_time;
    uint64_t ri_pkg_idle_wkups;
    uint64_t ri_interrupt_wkups;
    uint64_t ri_pageins;
    uint64_t ri_wired_size;
    uint64_t ri_resident_size;
    uint64_t ri_phys_footprint;
    uint64_t ri_proc_start_abstime;
    uint64_t ri_proc_exit_abstime;
};
#include "../kexploit/krw.h"
#include "../kexploit/xpaci.h"
#include "../kexploit/offsets.h"
#include "../kexploit/ksafe.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kpf/patchfinder.h"

// --- Process Manager --------------------------------------------------------

// MUST match early_kread()'s is_kaddr_valid exactly: it accepts
// [VM_MIN_KERNEL_ADDRESS, VM_MAX_KERNEL_ADDRESS] on this build, which is
// NARROWER than a plain top-bits test (the old (p >> 40) == 0xffffff check
// accepted 0xffffff00...–0xffffffdb... addresses that early_kread then
// rejected with a deliberate app crash). Any pointer this guard lets through
// must also pass the primitive's own range check.
static inline bool procmgr_is_kern_ptr(uint64_t p) {
    return is_kaddr_valid(p);
}

// Zone elements never straddle a page, so a struct scan starting at a valid
// zone pointer may safely read up to the END OF ITS PAGE — but never past it:
// if the element ends exactly at the page boundary, the next page can be
// unmapped and the KRW read faults the KERNEL (panic-full: GZAlloc reported
// our 0x800 thread scan reading 17 bytes past a 1928-byte threads element
// whose end coincided with the page end). Capping at the page boundary is
// lossless: every real struct field lives inside the element, and the element
// always fits in the rest of the page.
static uint32_t pm_scan_cap(uint64_t base, uint32_t want) {
    uint64_t pageMask = (uint64_t)vm_page_size - 1;
    uint64_t pageLeft = (uint64_t)vm_page_size - (base & pageMask);
    return (uint32_t)MIN((uint64_t)want, pageLeft);
}

bool procmgr_pid_is_protected(int pid) {
    // kernel_task (0) and launchd (1): force-quitting either panics the device.
    // Our OWN process (Cyanide): it holds the kernel r/w primitive; killing it
    // abruptly skips the KRW cleanup and leaves the socket filter dangling, so
    // the next kernel access panics the device. Never kill ourselves.
    return pid <= 1 || pid == (int)getpid();
}

// comm-based kill protection (round 5): a SpringBoard SIGKILL delivered from
// inside launchd panicked the device with "initproc exited" at 19:45:45
// (iOS 17.3.1) — whether through the target's role in launchd's bookkeeping or
// a garbled dispatch, killing critical user-space processes through a hijacked
// launchd thread is not survivable. Never offer or perform it.
bool procmgr_comm_is_protected(const char *comm) {
    if (!comm || !comm[0]) return false;
    return strcmp(comm, "launchd") == 0 ||
           strcmp(comm, "SpringBoard") == 0 ||
           strcmp(comm, "backboardd") == 0;
}

// Resolve a pid's comm via KRW ("" on any failure). For the kill hard-stops;
// a lookup failure is NOT proof of safety — callers must keep the pid checks.
int procmgr_comm_for_pid(int pid, char *buf, size_t len) {
    return procmgr_identity_for_pid(pid, buf, len, NULL);
}

int procmgr_identity_for_pid(int pid, char *buf, size_t len, uint64_t *kprocOut) {
    if (kprocOut) *kprocOut = 0;
    if (!buf || len == 0) return -1;
    buf[0] = '\0';
    if (pid <= 0) return -1;
    if (!kexploit_krw_session_active()) return -1;
    krw_set_nonfatal(true);
    uint64_t proc = proc_find(pid);
    if (kprocOut && procmgr_is_kern_ptr(proc)) *kprocOut = proc;
    if (procmgr_is_kern_ptr(proc)) {
        char *nm = proc_get_p_name(proc);   // static buffer — copy out now
        if (nm) {
            strncpy(buf, nm, len - 1);
            buf[len - 1] = '\0';
        }
    }
    krw_set_nonfatal(false);
    return buf[0] ? 0 : -1;
}

// Returns the proc's p_stat (PM_SRUN, PM_SSTOP, PM_SZOMB, ...) via libproc,
// or -1 when proc_pidinfo can't inspect the pid. Read-only, never crashes.
int procmgr_pstat(int pid) {
    struct pm_proc_bsdinfo bi;
    memset(&bi, 0, sizeof(bi));
    int rc = proc_pidinfo(pid, PM_PROC_PIDTBSDINFO, 0, &bi, (int)sizeof(bi));
    if (rc < 8) return -1;  // needs at least pbi_flags + pbi_status
    return (int)bi.pbi_status;
}

// Same p_stat (PM_SRUN, PM_SSTOP, PM_SZOMB, ...) but read straight out of
// struct proc via KRW — kernel ground truth. libproc's pbi_status can lag or
// stay SRUN for a suspended process, and after a kill() issued through a
// remote session this is the authoritative check of whether the pid is really
// gone (SZOMB counts as dead). -1 when KRW or the pid is unavailable.
int procmgr_pstat_krw(int pid) {
    if (!off_proc_p_stat) return -1;
    if (!kexploit_krw_ready()) return -1;
    krw_set_nonfatal(true);
    int rc = -1;
    uint64_t proc = proc_find(pid);
    if (procmgr_is_kern_ptr(proc)) {
        // p_stat is a char; reading 32 bits is safe inside struct proc.
        uint32_t v = kread32(proc + off_proc_p_stat);
        rc = (int)(v & 0xFF);
    }
    krw_set_nonfatal(false);
    return rc;
}

// Round 13: ONE allproc walk for both kill-verdict inputs — present (still in
// the list) and p_stat. The verdict loop and the UI's post-kill check used to
// walk twice per checkpoint (procmgr_pid_alive + procmgr_pstat_krw), and each
// walk is 2 kreads per proc until the pid is found. Semantics match the old
// pair exactly: present=false when KRW is down or the pid is gone; pstat=-1
// when KRW/the offset/the pid is unavailable (so "present + pstat=-1" is the
// old alive=true + kst=-1 inconclusive case).
int procmgr_pid_status_krw(int pid, bool *outPresent, bool *outKnown) {
    if (outPresent) *outPresent = false;
    if (outKnown) *outKnown = false;
    if (!kexploit_krw_ready()) return -1;
    uint64_t errorsBefore = krw_op_error_count();
    krw_set_nonfatal(true);
    int stat = -1;
    uint64_t proc = proc_find(pid);
    if (procmgr_is_kern_ptr(proc)) {
        if (outPresent) *outPresent = true;
        if (off_proc_p_stat) {
            // p_stat is a char; reading 32 bits is safe inside struct proc.
            uint32_t v = kread32(proc + off_proc_p_stat);
            stat = (int)(v & 0xFF);
        }
    }
    krw_set_nonfatal(false);
    // Any failed-safe read during this walk (ours, or a concurrent one -- we
    // can't tell them apart, so err on "unknown") may have zero-filled a link
    // and ended the walk early: then "not found" proves nothing.
    if (outKnown) *outKnown = (krw_op_error_count() == errorsBefore);
    return stat;
}

// --- task->bsd_info back-pointer (TOCTOU guard, round 14) -------------------
// Every proc->task path in the poll loop has the same race: the process can
// exit between proc_find() and the task dereference, leaving us reading a
// freed — or worse, REALLOCATED — task. A reallocated task still passes the
// kern-ptr range check, and a freed task on a zone page trimmed after the
// (one-time) ksafe snapshot faults the kernel synchronously on the first
// read. xnu keeps a back-pointer from the task to its proc (bsd_info);
// comparing it against the proc we started from catches reuse (names another
// proc) and teardown (cleared to NULL). The offset is calibrated by scanning
// OUR OWN task for the qword equal to our own proc pointer, cross-checked
// against launchd's task (must point back at launchd's proc); a UNIQUE match
// is required. Uncalibrated -> callers keep the old kern-ptr-only behavior
// (fail-open, exactly as before this guard existed).
static uint32_t g_pm_off_task_bsdinfo = 0;
// Fallback guard: on xnu-10002+ struct task has no bsd_info back-pointer —
// proc and task are ONE allocation (task = proc + proc_struct_size), so the
// back-pointer scan finds nothing (live log 2026-10-07: matches=0 on every
// attempt, guards silently off). There the invariant is the fixed delta
// task - proc, proven on our own proc and cross-checked on launchd's.
static uint64_t g_pm_task_proc_delta = 0;
static int      g_pm_bsdinfo_attempts = 0;
#define PM_BSDINFO_MAX_ATTEMPTS 3   // then give up for the session (log-quiet)

static void pm_calibrate_bsdinfo(void) {
    if (g_pm_off_task_bsdinfo || g_pm_task_proc_delta) return;
    if (g_pm_bsdinfo_attempts >= PM_BSDINFO_MAX_ATTEMPTS) return;
    g_pm_bsdinfo_attempts++;
    if (!kexploit_krw_ready()) return;

    krw_set_nonfatal(true);
    uint64_t selfProc = proc_self();
    uint64_t task = proc_task(selfProc);
    uint32_t cap = procmgr_is_kern_ptr(task) ? pm_scan_cap(task, 0x800) : 0;
    uint64_t lproc = proc_find(1);
    uint64_t ltask = procmgr_is_kern_ptr(lproc) ? proc_task(lproc) : 0;
    bool haveLaunchd = procmgr_is_kern_ptr(ltask);

    uint32_t found = 0;
    int matches = 0;
    if (cap >= 0x40 + 8) {
        uint8_t tb[0x800];
        kreadbuf(task, tb, cap);
        for (uint32_t off = 0x40; off + 8 <= cap; off += 8) {
            if (*(uint64_t *)(tb + off) != selfProc) continue;   // == our proc
            if (haveLaunchd && kread64(ltask + off) != lproc) continue;
            matches++;
            found = off;
        }
    }
    krw_set_nonfatal(false);

    if (found && matches == 1) {
        g_pm_off_task_bsdinfo = found;
        printf("[PROCMGR] bsd_info calibrated: task=+0x%x (launchd xcheck=%d)\n",
               found, haveLaunchd ? 1 : 0);
    } else if (matches == 0 && procmgr_is_kern_ptr(task) && haveLaunchd &&
               task > selfProc && task - selfProc <= 0x2000 &&
               ltask - lproc == task - selfProc) {
        g_pm_task_proc_delta = task - selfProc;
        printf("[PROCMGR] proc->task guard: no bsd_info field; using fixed "
               "proc+task delta 0x%llx (launchd xcheck=1)\n", g_pm_task_proc_delta);
    } else {
        printf("[PROCMGR] bsd_info calibration failed (attempt %d/%d, matches=%d "
               "launchd=%d) — proc->task guards stay kern-ptr-only\n",
               g_pm_bsdinfo_attempts, PM_BSDINFO_MAX_ATTEMPTS, matches,
               haveLaunchd ? 1 : 0);
    }
}

// 1 = task's bsd_info back-pointer still names proc; 0 = mismatch (freed or
// reallocated — do NOT dereference the task further); -1 = uncalibrated, no
// verdict (callers fall through to the pre-guard behavior).
static int pm_task_matches_proc(uint64_t task, uint64_t proc) {
    if (g_pm_task_proc_delta) {
        // Co-allocated proc+task: a task that doesn't sit at the fixed delta
        // is not this proc's (stale proc_ro / reused proc). Still mapped-check
        // it — the caller's next step dereferences it.
        if (task - proc != g_pm_task_proc_delta) return 0;
        if (ksafe_available() && !kaddr_is_mapped(task, 8)) return 0;
        return 1;
    }
    if (!g_pm_off_task_bsdinfo) return -1;
    // This is the liveness guard, but kread64(task + bsdinfo) is itself the
    // FIRST dereference of `task` — gate it with ksafe first, like
    // pm_kernel_stats and the kutils thread path do. Caller's procmgr_is_kern_ptr
    // is only a VA-range check; a stale task pointer into a never-committed zone
    // window would fault the kernel here (nonfatal can't intercept a kernel data
    // abort). Treat an unmapped task as "no match" so callers skip the read.
    if (ksafe_available() && !kaddr_is_mapped(task, g_pm_off_task_bsdinfo + 8))
        return 0;
    return kread64(task + g_pm_off_task_bsdinfo) == proc ? 1 : 0;
}

// --- task->suspend_count: is a process task-suspended (preloaded)? -----------
// struct task (xnu-10002 AND xnu-11417) lays out, consecutively:
//     int thread_count; uint32_t active_thread_count; int suspend_count;
// so suspend_count = thread_count + 8. A task-suspended process (iOS-preloaded
// / prewarmed or SpringBoard-backgrounded app) has suspend_count > 0 — which
// libproc's p_stat does NOT reliably show (it can stay SRUN). Ground truth for
// thread_count is proc_pidinfo's pti_threadnum. Calibrated once per run (no
// NSUserDefaults cache), validated against launchd (pid 1: always running,
// suspend_count == 0).
static uint32_t g_pm_off_task_suspcount = 0;
static int      g_pm_suspcount_attempts = 0;
#define PM_SUSPCOUNT_MAX_ATTEMPTS 5   // then give up for the session (log-quiet)

static bool pm_taskinfo_threadnum(int pid, uint32_t *out) {
    struct pm_proc_taskinfo ti;
    memset(&ti, 0, sizeof(ti));
    if (proc_pidinfo(pid, PM_PROC_PIDTASKINFO, 0, &ti, (int)sizeof(ti)) < (int)sizeof(ti))
        return false;
    if (!ti.pti_threadnum || ti.pti_threadnum > 4096) return false;
    *out = (uint32_t)ti.pti_threadnum;
    return true;
}

static void pm_calibrate_suspcount(void) {
    if (g_pm_off_task_suspcount) return;
    if (g_pm_suspcount_attempts >= PM_SUSPCOUNT_MAX_ATTEMPTS) return;
    if (!kexploit_krw_ready()) return;
    g_pm_suspcount_attempts++;

    uint32_t nSelf = 0;
    if (!pm_taskinfo_threadnum(getpid(), &nSelf)) {
        printf("[PROCMGR] suspend_count calib: own threadnum unavailable\n");
        return;
    }

    krw_set_nonfatal(true);
    uint64_t task = proc_task(proc_self());
    uint32_t cap = procmgr_is_kern_ptr(task) ? pm_scan_cap(task, 0x800) : 0;
    if (cap < 0x40 + 12) {
        krw_set_nonfatal(false);
        printf("[PROCMGR] suspend_count calib deferred: task at page edge (cap=0x%x)\n", cap);
        return;
    }
    uint8_t tb[0x800];
    kreadbuf(task, tb, cap);

    // Cross-check against launchd (pid 1), read DIRECTLY via KRW.
    //
    // We deliberately do NOT use proc_pidinfo(1) for the reference thread count:
    // the app sandbox blocks task-info on other processes, so that path failed
    // every pass on device ("launchd reference unavailable") and suspend_count
    // never calibrated — which is why preloaded/suspended apps (p_stat stays
    // SRUN) were never dimmed. Instead we validate the candidate offset against
    // launchd's own task struct fields: launchd always has a plausible
    // thread_count, an active count close to it, and suspend_count == 0 (it is
    // never suspended). That needs only kernel reads, which work.
    uint64_t lproc = proc_find(1);
    uint64_t ltask = procmgr_is_kern_ptr(lproc) ? proc_task(lproc) : 0;
    uint32_t lcap  = procmgr_is_kern_ptr(ltask) ? pm_scan_cap(ltask, 0x800) : 0;
    bool haveLaunchd = procmgr_is_kern_ptr(ltask) && lcap >= 0x40 + 12;

    // Require a UNIQUE candidate: the layout is three consecutive int32
    //   thread_count == nSelf, active_thread_count ~= nSelf, suspend_count == 0
    // which is specific, but if more than one offset fits we cannot tell which
    // is really suspend_count, so we defer rather than guess wrong.
    uint32_t found = 0;
    int matches = 0;
    for (uint32_t off = 0x40; off + 12 <= cap; off += 4) {
        if (*(uint32_t *)(tb + off) != nSelf) continue;          // thread_count
        uint32_t act = *(uint32_t *)(tb + off + 4);              // active_thread_count
        uint32_t lo = nSelf > 2 ? nSelf - 2 : 1;
        if (act < lo || act > nSelf) continue;
        if (*(uint32_t *)(tb + off + 8) != 0) continue;          // our suspend_count == 0

        if (haveLaunchd && off + 12 <= lcap) {
            uint32_t ltc  = kread32(ltask + off);                // launchd thread_count
            uint32_t lact = kread32(ltask + off + 4);            // launchd active count
            uint32_t lsc  = kread32(ltask + off + 8);            // launchd suspend_count
            if (ltc < 1 || ltc > 4096) continue;                 // implausible
            uint32_t llo = ltc > 4 ? ltc - 4 : 1;
            if (lact < llo || lact > ltc) continue;              // active near total
            if (lsc != 0) continue;                              // launchd never suspended
        }
        matches++;
        found = off;
    }
    krw_set_nonfatal(false);

    if (found && matches == 1) {
        g_pm_off_task_suspcount = found + 8;
        printf("[PROCMGR] suspend_count calibrated: task=+0x%x (launchd xcheck=%d)\n",
               g_pm_off_task_suspcount, haveLaunchd ? 1 : 0);
    } else {
        printf("[PROCMGR] suspend_count calibration failed (attempt %d/%d, matches=%d launchd=%d)\n",
               g_pm_suspcount_attempts, PM_SUSPCOUNT_MAX_ATTEMPTS, matches, haveLaunchd ? 1 : 0);
    }
}

// Runtime-calibrated task->suspend_count for pid. Returns -1 when
// uncalibrated/unavailable, else the count (>0 means the task is suspended:
// iOS-preloaded or background-suspended apps). Read-only.
int procmgr_suspend_count(int pid) {
    if (!g_pm_off_task_suspcount) return -1;
    if (!kexploit_krw_ready()) return -1;
    krw_set_nonfatal(true);
    int rc = -1;
    uint64_t proc = proc_find(pid);
    if (procmgr_is_kern_ptr(proc)) {
        uint64_t task = proc_task(proc);
        // TOCTOU guard (round 14): the proc can exit between the walk and
        // this read; require the task's bsd_info back-pointer to still name
        // this proc (uncalibrated -> no verdict, read as before).
        if (procmgr_is_kern_ptr(task) && pm_task_matches_proc(task, proc) != 0) {
            uint32_t sc = kread32(task + g_pm_off_task_suspcount);
            if (sc <= 64) rc = (int)sc;     // >64 is implausible: torn/bad read
        }
    }
    krw_set_nonfatal(false);
    return rc;
}

// offsetof(task, thread_count) from the suspend_count calibration (the three
// counters are consecutive: thread_count, active, suspend_count). Runs the
// calibration on first use; -1 when it can't calibrate this session.
int procmgr_task_thread_count_offset(void) {
    if (!g_pm_off_task_suspcount) pm_calibrate_suspcount();
    if (!g_pm_off_task_suspcount) return -1;
    return (int)g_pm_off_task_suspcount - 8;
}

// --- task category role (foreground / background app vs daemon) -------------
// The Mach task-category role (TASK_FOREGROUND_APPLICATION, ...) lives in a
// packed bitfield inside struct task's policy. CocoaTop reads it with
// task_policy_get(TASK_CATEGORY_POLICY), which needs a task port we don't have
// for other processes — but we can read it out of the task struct via KRW once
// we know where the field is. Locate it by perturbation: we CAN read and set
// our OWN role (task_policy_get/set on mach_task_self), so flip our role, see
// which nibble of our task struct moved, and restore it. Cosmetic feature — a
// wrong or absent calibration only mislabels rows, never crashes (read-only).
static bool     g_pm_role_cal   = false;
static bool     g_pm_role_tried = false; // calibration attempted (once per session)
static uint32_t g_pm_off_role   = 0;   // byte offset of the uint64 holding the role
static uint32_t g_pm_role_shift = 0;   // bit position of the role field
static uint64_t g_pm_role_mask  = 0;   // field mask (0x7 or 0xF)

static void pm_calibrate_task_role(void) {
    // DISABLED. This used to locate the task category-role field by flipping our
    // OWN role (task_policy_set on mach_task_self) and diffing the task struct.
    // Two fatal problems, both seen on device:
    //   1. iOS does not let an app change its own category role, so the flip was
    //      always a no-op and calibration never succeeded.
    //   2. Far worse: task_policy_set takes the task-policy / coalition kernel
    //      locks that the system power monitor (PerfPowerServices'
    //      PLProcessMonitorAgent) also holds. Running it on the process-viewer
    //      poll while the RemoteCall anchor was hijacking a launchd thread
    //      produced an ABBA lock-ordering DEADLOCK — a Cyanide thread ended up
    //      owning a global kernel mutex that launchd and ~90 daemons all block
    //      on, wedging the whole system until the watchdog rebooted the device
    //      (panic-full-2026-09-28-175201: "no checkins from watchdogd in 92s").
    // So we never call task_policy_set again. The role field must be sourced
    // another way (hardcoded per-version offset in offsets.m); until then the
    // readers below stay uncalibrated and the Process Viewer marks nothing.
    g_pm_role_tried = true;
}

// Mach task-category role for pid (TASK_FOREGROUND_APPLICATION=1,
// TASK_BACKGROUND_APPLICATION=2, TASK_UNSPECIFIED=0, ...). -1 when
// uncalibrated/unavailable. Read-only.
int procmgr_task_role(int pid) {
    if (!g_pm_role_cal) return -1;
    if (!kexploit_krw_ready()) return -1;
    krw_set_nonfatal(true);
    int role = -1;
    uint64_t proc = proc_find(pid);
    if (procmgr_is_kern_ptr(proc)) {
        uint64_t task = proc_task(proc);
        // TOCTOU guard (round 14): same freed/reused-task race as
        // procmgr_stats — verify the bsd_info back-pointer first.
        if (procmgr_is_kern_ptr(task) && pm_task_matches_proc(task, proc) != 0) {
            uint64_t v = kread64(task + g_pm_off_role);
            role = (int)((v >> g_pm_role_shift) & g_pm_role_mask);
        }
    }
    krw_set_nonfatal(false);
    return role;
}

bool procmgr_role_is_foreground(int role) { return role == TASK_FOREGROUND_APPLICATION; }
bool procmgr_role_is_switcher(int role)   { return role == TASK_BACKGROUND_APPLICATION; }
bool procmgr_role_is_app(int role) {
    return role == TASK_FOREGROUND_APPLICATION || role == TASK_BACKGROUND_APPLICATION;
}

// --- app vs service classification via executable path (KRW) -----------------
// proc->p_textvp is the vnode of the process's executable; walking v_parent up
// to a filesystem root and joining v_name components reconstructs its path.
// User-facing apps (the app-switcher kind) live under
// .../containers/Bundle/Application/ (third-party; possibly mount-truncated
// where the walk stops at the /var filesystem root) or /Applications/ (system
// apps). Everything else — /usr/libexec, /usr/sbin, /System/..., SpringBoard
// itself — counts as a background service.
//
// This replaces the task-category-role route for telling apps from daemons:
// pm_calibrate_task_role is disabled by design (task_policy_set deadlocked the
// system — see its comment), so the role field was never calibrated and NO
// row was ever marked on iOS 18. The path route is read-only and never touches
// task policy. Classification is cached per pid for the app run: a live pid's
// executable never changes (a recycled pid could be mislabeled; accepted —
// the viewer is cosmetic).

// Read a NUL-terminated string from the kernel a few bytes at a time, never
// past the end of the current page (a name string at a page edge whose next
// page is unmapped would fault the KERNEL — same rule as pm_scan_cap), and
// through the ksafe map when it is up.
static size_t pm_kread_cstr(uint64_t kaddr, char *out, size_t cap) {
    if (!cap) return 0;
    size_t total = 0;
    uint64_t pageMask = (uint64_t)vm_page_size - 1;
    while (total < cap - 1) {
        size_t pageLeft = (size_t)((uint64_t)vm_page_size - ((kaddr + total) & pageMask));
        size_t chunk = MIN((size_t)16, MIN(pageLeft, cap - 1 - total));
        // kreadbuf moves 8-byte units (krw.m:171 early_kread64), so a chunk of
        // 9-15 would read up to 7 bytes PAST the range kaddr_is_mapped just
        // validated — possibly into an unmapped next page (kernel fault).
        // Round DOWN to a multiple of 8 so reads never span past validated bytes.
        chunk &= ~(size_t)7;
        if (chunk < 8) break;               // kreadbuf moves 8-byte units
        if (ksafe_available() && !kaddr_is_mapped(kaddr + total, chunk)) break;
        char tmp[16] = {0};
        kreadbuf(kaddr + total, tmp, chunk);
        memcpy(out + total, tmp, chunk);
        total += chunk;
        if (memchr(tmp, 0, chunk)) break;
    }
    out[MIN(total, cap - 1)] = '\0';
    return strnlen(out, cap);
}

static bool pm_vnode_name(uint64_t vp, char *out, size_t cap) {
    uint64_t namep = kread64(vp + off_vnode_v_name);   // same raw read as vnode_get_v_name()
    if (!namep || !procmgr_is_kern_ptr(namep)) return false;
    return pm_kread_cstr(namep, out, cap) > 0;
}

// Reconstruct the executable path for a proc. Components whose names were
// purged from the namecache come out empty and are skipped; the result may be
// mount-truncated (missing the "/private/var" prefix when /var is its own
// filesystem) — classifiers must substring-match, not prefix-match.
static bool pm_exe_path_for_proc(uint64_t proc, char *buf, size_t buflen) {
    if (!off_proc_p_textvp || !off_vnode_v_name || !off_vnode_v_parent) return false;
    uint64_t vp = xpaci(kread64(proc + off_proc_p_textvp));
    if (!procmgr_is_kern_ptr(vp)) return false;

    char comps[24][65];
    int nc = 0;
    for (int depth = 0; depth < 24; depth++) {
        if (!procmgr_is_kern_ptr(vp)) break;
        // v_name (0xb8) and v_parent (0xc0) both live in the first 0xd0 bytes.
        if (ksafe_available() && !kaddr_is_mapped(vp, 0xd0)) break;
        char name[65] = {0};
        pm_vnode_name(vp, name, sizeof(name));
        uint64_t parent = xpaci(kread64(vp + off_vnode_v_parent));
        if (parent == vp || !procmgr_is_kern_ptr(parent)) break;   // filesystem root
        if (name[0] && nc < 24) {
            strncpy(comps[nc], name, 64);
            comps[nc][64] = '\0';
            nc++;
        }
        vp = parent;
    }
    if (!nc) return false;
    size_t pos = 0;
    buf[0] = '\0';
    for (int i = nc - 1; i >= 0 && pos + 2 < buflen; i--) {
        int w = snprintf(buf + pos, buflen - pos, "/%s", comps[i]);
        if (w < 0) break;
        pos += MIN((size_t)w, buflen - 1 - pos);
    }
    return buf[0] != '\0';
}

static int pm_classify_path(const char *path) {
    if (strstr(path, "/containers/Bundle/Application/")) return PM_KIND_APP;   // third-party apps
    if (strncmp(path, "/Applications/", 14) == 0) return PM_KIND_APP;          // system apps
    return PM_KIND_SERVICE;
}

static NSMutableDictionary<NSNumber *, NSNumber *> *g_pm_kind_cache = nil;
static pthread_mutex_t g_pm_kind_lock = PTHREAD_MUTEX_INITIALIZER;

int procmgr_exe_kind(int pid) {
    pthread_mutex_lock(&g_pm_kind_lock);
    NSNumber *hit = g_pm_kind_cache[@(pid)];
    pthread_mutex_unlock(&g_pm_kind_lock);
    if (hit) return hit.intValue;

    // Cheap liveness only: reloadProcs already validated the session this pass,
    // and kexploit_krw_ready() per pid would add ~500 setsockopt validations.
    if (!kexploit_krw_session_active()) return PM_KIND_SERVICE;

    krw_set_nonfatal(true);
    char path[1024];
    path[0] = '\0';
    bool ok = false;
    uint64_t proc = proc_find(pid);
    if (procmgr_is_kern_ptr(proc))
        ok = pm_exe_path_for_proc(proc, path, sizeof(path));
    krw_set_nonfatal(false);

    int kind = ok ? pm_classify_path(path) : PM_KIND_SERVICE;   // unreadable -> muted
    pthread_mutex_lock(&g_pm_kind_lock);
    if (!g_pm_kind_cache) g_pm_kind_cache = [NSMutableDictionary dictionary];
    if (g_pm_kind_cache.count > 2048) [g_pm_kind_cache removeAllObjects];  // bound it
    g_pm_kind_cache[@(pid)] = @(kind);
    pthread_mutex_unlock(&g_pm_kind_lock);
    printf("[PROCMGR] classify: pid %d -> %s (%s)\n", pid,
           kind == PM_KIND_APP ? "app" : "service", ok ? path : "no path");
    return kind;
}

// Read one proc's pid+name into an entry. Returns false if the proc looks bogus.
static bool procmgr_fill_entry(uint64_t proc, procmgr_entry_t *e) {
    if (!procmgr_is_kern_ptr(proc)) return false;
    uint32_t pid = kread32(proc + off_proc_p_pid);
    if (pid > 500000) return false;                 // sanity: not a real pid
    e->pid = (int)pid;
    e->kproc = proc;
    e->name[0] = '\0';
    char *nm = proc_get_p_name(proc);               // fills a static buffer
    if (nm) { strncpy(e->name, nm, sizeof(e->name) - 1); e->name[sizeof(e->name) - 1] = '\0'; }
    if (e->name[0] == '\0') snprintf(e->name, sizeof(e->name), "pid %u", pid);
    return true;
}

int procmgr_list(procmgr_entry_t *entries, int max) {
    if (!entries || max <= 0) return 0;
    if (!kexploit_krw_ready()) return -1;

    // A polling UI loop must never take the app down on a transient KRW
    // hiccup: nonfatal mode zero-fills failed reads instead of crashing.
    krw_set_nonfatal(true);
    uint64_t errorsBefore = krw_op_error_count();

    uint64_t self = proc_self();
    if (!procmgr_is_kern_ptr(self)) { krw_set_nonfatal(false); return -1; }

    int n = 0;
    // Round 13: one krwLock hold + one final repark for the whole list walk
    // (~6 kreads/proc — the per-op repark was a third syscall on every read of
    // every poll). procmgr_fill_entry() is pure kreads, so this is batch-safe.
    bool batched = krw_batch_begin();
    // The proc list is a doubly-linked LIST anchored at allproc. p_list.le_next
    // sits at offset 0 of proc, so le_prev conveniently reads back as the prior
    // proc pointer (same trick kutils uses). Walk both ways from self.
    if (n < max && procmgr_fill_entry(self, &entries[n])) n++;

    uint64_t p = kread64(self + off_proc_p_list_le_next);
    for (int i = 0; i < 8192 && n < max && procmgr_is_kern_ptr(p); i++) {
        if (procmgr_fill_entry(p, &entries[n])) n++;
        uint64_t nx = kread64(p + off_proc_p_list_le_next);
        if (nx == p) break;
        p = nx;
    }

    p = kread64(self + off_proc_p_list_le_prev);
    for (int i = 0; i < 8192 && n < max && procmgr_is_kern_ptr(p); i++) {
        procmgr_entry_t tmp;
        if (!procmgr_fill_entry(p, &tmp)) break;    // walked off the list head
        entries[n++] = tmp;
        uint64_t pv = kread64(p + off_proc_p_list_le_prev);
        if (pv == p) break;
        p = pv;
    }
    if (batched) krw_batch_end();

    krw_set_nonfatal(false);
    // A failed-safe read anywhere in the walk (ours or a concurrent one -- we
    // can't tell them apart) may have zero-filled a link and ended it early:
    // report "incomplete" so the caller keeps its previous list.
    if (krw_op_error_count() != errorsBefore) return -1;
    return n;
}

// --- credential escalation (borrow launchd's ucred) -------------------------
//
// Round 45: UNUSED — proven dead on 18.4+ (iPhone17,2/22F76, live 46): proc_ro
// is write-protected, so the p_ucred kwrite64 below EFAULTs (errno 14); the
// fail-safe KRW skips the write (no panic — the old "panics on 18.4+" comment
// was right about the write being impossible, wrong about it panicking) and
// the self-check backs off cleanly, but every attempt still burns two failing
// kwrites + op-error latch noise. Round 45's unsandbox rung hit the same
// wall (MAC labels in read-only kalloc on SPTM — round 46 removed it too).
// Kept for reference; do not re-add to the kill path on 18.4+.

static uint64_t g_pm_saved_cred = 0;      // our original p_ucred value
static uint64_t g_pm_ucred_slot = 0;      // &(self proc_ro).p_ucred

int procmgr_escalate(void) {
    if (getuid() == 0 && geteuid() == 0) return 0;   // already root
    if (!kexploit_krw_ready()) return -1;

    uint64_t self = proc_self();
    uint64_t launchd = proc_find(1);
    if (!procmgr_is_kern_ptr(self) || !procmgr_is_kern_ptr(launchd)) return -2;

    uint64_t selfRo    = kread64(self    + off_proc_p_proc_ro);
    uint64_t launchdRo = kread64(launchd + off_proc_p_proc_ro);
    if (!procmgr_is_kern_ptr(selfRo) || !procmgr_is_kern_ptr(launchdRo)) return -3;

    uint64_t slot        = selfRo + off_proc_ro_p_ucred;
    uint64_t curCred     = kread64(slot);
    uint64_t launchdCred = kread64(launchdRo + off_proc_ro_p_ucred);
    if (!procmgr_is_kern_ptr(curCred) || !procmgr_is_kern_ptr(launchdCred)) return -4;

    if (!g_pm_saved_cred) { g_pm_saved_cred = curCred; g_pm_ucred_slot = slot; }
    kwrite64(slot, launchdCred);

    // Self-check: proc_ro is a read-only struct; if this KRW can't write it, the
    // value won't stick. Verify both the raw write and the functional result.
    if (kread64(slot) != launchdCred || getuid() != 0) {
        kwrite64(slot, curCred);          // undo whatever partial change took
        g_pm_saved_cred = 0; g_pm_ucred_slot = 0;
        printf("[PROCMGR] escalate failed: proc_ro not writable (uid=%d)\n", getuid());
        return -5;
    }
    printf("[PROCMGR] escalated (borrowed launchd ucred 0x%llx)\n", launchdCred);
    return 0;
}

void procmgr_deescalate(void) {
    if (g_pm_saved_cred && g_pm_ucred_slot && kexploit_krw_ready()) {
        kwrite64(g_pm_ucred_slot, g_pm_saved_cred);
        printf("[PROCMGR] de-escalated (restored ucred 0x%llx)\n", g_pm_saved_cred);
    }
    g_pm_saved_cred = 0; g_pm_ucred_slot = 0;
}

bool procmgr_is_escalated(void) {
    return getuid() == 0;
}

// --- light unsandbox (clear the sandbox slot in our cred label) --------------
//
// Round 46: UNUSED — proven dead on BOTH supported builds (live 46/47): the
// kwrite to the label's sandbox slot EFAULTs (errno 14) on 21D61 AND 22F76 —
// MAC labels live in read-only kalloc on SPTM devices, so the zone-safe write
// below cannot take; reads of the label succeed (only the write is blocked).
// Same wall as proc_ro (procmgr_escalate, round 44/45): kernel memory holding
// credentials is write-protected on 18.4+. The launchd RemoteCall is the only
// privileged kill path. Kept for reference; do not re-add to the kill path.

static uint64_t g_pm_sb_slot = 0;
static uint64_t g_pm_sb_saved = 0;
static bool     g_pm_sb_removed = false;

// The MAC label is a small (32-byte) zone object. A plain kwrite64 at offset 0x10
// makes the KRW engine's 32-byte-granular write spill past the object and trips
// iOS 18's zone bound checks -> panic. So rewrite the WHOLE element in-bounds with
// kwrite_zone_element (the same zone-safe primitive utils/sandbox.m uses).
#define PM_LABEL_ELEM_SIZE 0x20

int procmgr_unsandbox(void) {
    if (g_pm_sb_removed) return 0;
    if (!kexploit_krw_ready()) return -1;
    uint64_t self = proc_self();
    if (!procmgr_is_kern_ptr(self)) return -2;
    uint64_t label = proc_get_cred_label(self);   // proc_ro->ucred->cr_label (reads)
    if (!procmgr_is_kern_ptr(label)) return -3;
    if (off_label_l_perpolicy_sandbox + 8 > PM_LABEL_ELEM_SIZE) return -6;  // sanity

    uint8_t buf[PM_LABEL_ELEM_SIZE];
    kreadbuf(label, buf, sizeof(buf));
    uint64_t *slot = (uint64_t *)(buf + off_label_l_perpolicy_sandbox);
    g_pm_sb_slot  = label;        // element base (we rewrite the whole element)
    g_pm_sb_saved = *slot;
    if (g_pm_sb_saved == 0) { g_pm_sb_removed = true; return 0; }  // already unsandboxed

    *slot = 0;                    // 0 == no sandbox policy
    kwrite_zone_element(label, buf, sizeof(buf));   // in-bounds full-element write
    if (kread64(label + off_label_l_perpolicy_sandbox) != 0) {   // didn't take
        g_pm_sb_slot = 0; g_pm_sb_saved = 0;
        return -4;
    }
    g_pm_sb_removed = true;
    printf("[PROCMGR] unsandboxed (label 0x%llx sandbox slot 0x%llx -> 0)\n",
           label, g_pm_sb_saved);
    return 0;
}

void procmgr_resandbox(void) {
    if (g_pm_sb_removed && g_pm_sb_slot && g_pm_sb_saved && kexploit_krw_ready()) {
        uint8_t buf[PM_LABEL_ELEM_SIZE];
        kreadbuf(g_pm_sb_slot, buf, sizeof(buf));
        *(uint64_t *)(buf + off_label_l_perpolicy_sandbox) = g_pm_sb_saved;
        kwrite_zone_element(g_pm_sb_slot, buf, sizeof(buf));
        printf("[PROCMGR] re-sandboxed (label 0x%llx restored 0x%llx)\n",
               g_pm_sb_slot, g_pm_sb_saved);
    }
    g_pm_sb_removed = false; g_pm_sb_slot = 0; g_pm_sb_saved = 0;
}

// --- self-calibrated kernel-struct offsets (read-only) -----------------------
//
// Offsets are discovered at runtime by matching our OWN process's known stats
// (proc_pidinfo / thread_info / proc_pid_rusage) against values read out of
// our own kernel structs, then cached in NSUserDefaults keyed by OS build.
// All of it is READ-ONLY: no kernel writes anywhere in these paths.
//
// CPU layout note: task->total_user_time/total_system_time count TERMINATED
// threads only. The full per-process CPU is those dead-thread counters PLUS
// the sum over live threads of thread->user_timer.t_sum + system_timer.t_sum.
// That dead/live split is why matching proc_pidinfo totals against raw task
// fields alone can never work — both halves are calibrated separately.

static bool     g_pm_mem_cal = false;
static uint32_t g_pm_off_task_ledger = 0;   // task -> ledger pointer
static uint32_t g_pm_off_ledger_fp   = 0;   // ledger -> footprint entry le_credit (debit at +8)

static bool     g_pm_cpu_cal = false;
static uint32_t g_pm_off_task_cpu_u = 0;    // task -> total_user_time (terminated threads)
static uint32_t g_pm_off_task_cpu_s = 0;    // task -> total_system_time
static bool     g_pm_cpu_abstime = false;   // task counters are mach-abstime (need ns convert)
// Stop retrying CPU calibration once it has clearly failed. It never succeeds
// on some devices, and pm_calibrate_task_totals is expensive (vm_allocate
// perturbation + pthread_create); retrying it 3x on EVERY poll pins the CPU and
// pounds KRW, which (racing a background detach) helped kill the parked socket.
// After this many failed passes, give up for the session — CPU column shows "—".
static int      g_pm_cpu_fail_passes = 0;
static bool     g_pm_cpu_gaveup = false;
#define PM_CPU_GIVEUP_PASSES 5
// Same give-up for the thread-timer and memory stages: each failing pass burns
// CPU (thread) or touches 32 MB and scans candidates (memory).
static int      g_pm_thr_fail_passes = 0;
static bool     g_pm_thr_gaveup = false;
static int      g_pm_mem_fail_passes = 0;
static bool     g_pm_mem_gaveup = false;

static bool     g_pm_thr_cal = false;
static uint32_t g_pm_off_thread_utime = 0;  // thread -> user_timer.t_sum
static uint32_t g_pm_off_thread_stime = 0;  // thread -> system_timer.t_sum
static bool     g_pm_thr_abstime = false;   // thread timers are mach-abstime

// Recount-based thread timing (iOS 15+): per-thread CPU times are NOT plain
// fields of struct thread — thread_info() reads them from
// thread->th_recount.rth_lifetime, a zalloc'd array of recount_track with one
// track per CPU kind. Track layout:
//   +0x00            rt_pad (u32, always 0) / rt_sync (u32)
//   +0x08            ru_metrics[RCT_LVL_KERNEL].rm_time_mach   (system, mach)
//   +0x08+lvlStride  ru_metrics[RCT_LVL_USER].rm_time_mach     (user, mach)
// lvlStride = 8 (+16 with CONFIG_PERVASIVE_CPI); track stride =
// 8 + levels*lvlStride (+8 with CONFIG_PERVASIVE_ENERGY); levels = 2 or 3
// (RECOUNT_SECURE_METRICS). All discovered at runtime against thread_info
// ground truth and verified with movement burns.
static bool     g_pm_rc_cal = false;
static uint32_t g_pm_rc_lifetime_off = 0;   // thread -> th_recount.rth_lifetime ptr
static uint32_t g_pm_rc_track_stride = 0;
static uint32_t g_pm_rc_lvl_stride = 0;
static uint32_t g_pm_rc_count = 0;

static int      g_pm_xpf_attempts = 0;      // init_xpf() tries to bring up ksafe (bounded)
static uint64_t g_pm_xpf_last_ns = 0;       // when the last try ran

// Memory reads are only possible when the mapped-check (ksafe) is up:
// they dereference a per-process ledger POINTER, and a stale/wrong one among
// hundreds of processes faults the kernel without that gate. CPU reads are
// inline struct reads reached via the safe proc->task / task->thread chains
// and need no mapped-check.
bool procmgr_mem_calibrated(void) { return g_pm_mem_cal && ksafe_available(); }
bool procmgr_cpu_calibrated(void) { return g_pm_thr_cal && g_pm_cpu_cal; }

static uint64_t procmgr_own_footprint(void) {
    struct pm_rusage_v0 ri;
    memset(&ri, 0, sizeof(ri));
    if (proc_pid_rusage(getpid(), 0, &ri) != 0) return 0;
    return ri.ri_phys_footprint;
}

static uint64_t pm_abs_to_ns(uint64_t abs);   // fwd — defined just below

static void procmgr_own_cpu_ns(uint64_t *u, uint64_t *s) {
    struct pm_proc_taskinfo ti;
    if (proc_pidinfo(getpid(), PM_PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) >= (int)sizeof(ti)) {
        // pti_total_user/system are MACH ABSOLUTE TICKS, not nanoseconds
        // (native timebase units; equal to ns only on Intel where the
        // timebase ratio is 1). Convert before mixing with ns values.
        *u = pm_abs_to_ns(ti.pti_total_user);
        *s = pm_abs_to_ns(ti.pti_total_system);
    } else { *u = 0; *s = 0; }
}

static uint64_t pm_ns_to_abs(uint64_t ns) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    if (!tb.numer) return ns;
    return (uint64_t)((unsigned __int128)ns * tb.denom / tb.numer);
}
static uint64_t pm_abs_to_ns(uint64_t abs) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    if (!tb.denom) return abs;
    return (uint64_t)((unsigned __int128)abs * tb.numer / tb.denom);
}
// Bracketed match: the userspace reference is sampled BEFORE and AFTER the
// kernel-struct read; a candidate kernel value V matches if it sits between
// the two samples with MARGIN slack, plus a ~10% relative tolerance on the
// high side. All three values must be in the same unit.
#define PM_MARGIN_NS 5000000ULL     // 5ms
static bool pm_bracket(uint64_t v, uint64_t rBefore, uint64_t rAfter, uint64_t margin) {
    uint64_t lo = rBefore < rAfter ? rBefore : rAfter;
    uint64_t hi = rBefore > rAfter ? rBefore : rAfter;
    if (v + margin < lo) return false;
    return v <= hi + hi / 10 + margin;
}

// thread_info(THREAD_BASIC_INFO) times for one of our own threads, in ns.
static bool pm_thread_times_ns(mach_port_t tp, uint64_t *uNs, uint64_t *sNs) {
    struct thread_basic_info tbi;
    mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
    if (thread_info(tp, THREAD_BASIC_INFO, (thread_info_t)&tbi, &cnt) != KERN_SUCCESS)
        return false;
    *uNs = (uint64_t)tbi.user_time.seconds   * 1000000000ULL + (uint64_t)tbi.user_time.microseconds   * 1000ULL;
    *sNs = (uint64_t)tbi.system_time.seconds * 1000000000ULL + (uint64_t)tbi.system_time.microseconds * 1000ULL;
    return true;
}

static uint64_t pm_self_thread_cpu_ns(void) {
    mach_port_t tp = mach_thread_self();
    uint64_t u = 0, s = 0;
    pm_thread_times_ns(tp, &u, &s);
    mach_port_deallocate(mach_task_self(), tp);
    return u + s;
}

// Pure-userspace spin: mach_absolute_time() lives in the commpage (no trap),
// so this burns user CPU only. Used for perturbation checks.
static void pm_burn_user_ns(uint64_t ns) {
    uint64_t start = mach_absolute_time();
    uint64_t limit = pm_ns_to_abs(ns);
    volatile uint64_t x = 1;
    while (mach_absolute_time() - start < limit)
        x = x * 1103515245ULL + 12345ULL;
    (void)x;
}

// Deterministic dead-thread sample: ~10ms of user CPU plus a little system
// time, then exits so its time lands in task->total_user_time/total_system_time.
static void *pm_busy_fn(void *arg) {
    (void)arg;
    uint64_t cpu0  = pm_self_thread_cpu_ns();
    uint64_t wall0 = mach_absolute_time();
    volatile uint64_t x = 1;
    while (pm_self_thread_cpu_ns() - cpu0 < 10000000ULL) {
        for (int i = 0; i < 20000; i++) x = x * 1103515245ULL + 12345ULL;  // user burn
        for (int i = 0; i < 20; i++) (void)getpid();                       // system burn
        if (mach_absolute_time() - wall0 > pm_ns_to_abs(1000000000ULL)) break;  // 1s wall cap
    }
    return NULL;
}

static bool pm_thread_sums_recount(uint64_t th, uint64_t *uMach, uint64_t *sMach);

// Sum the calibrated timers of all LIVE threads of a task, in the thread
// calibration's unit (abstime if g_pm_thr_abstime). Walks
// task->threads -> chain of thread->task_threads.next, stopping when it loops
// back to the first thread. Returns false if the walk broke early.
//
// A thread can EXIT between the chain-pointer read and the timer reads; its
// freed struct is usually still zone-mapped (garbage, filtered later), but when
// the page-table walker is up we mapped-check the whole span we are about to
// touch, narrowing the unmapped-read panic window to the race itself.
static bool pm_live_thread_sums(uint64_t task, uint64_t *uOut, uint64_t *sOut) {
    if (!g_pm_thr_cal) return false;
    bool mappedGate = ksafe_available();
    uint32_t loOff, hiOff;
    if (g_pm_rc_cal) {
        loOff = MIN(g_pm_rc_lifetime_off, off_thread_task_threads_next);
        hiOff = MAX(g_pm_rc_lifetime_off, off_thread_task_threads_next) + 8;
    } else {
        loOff = MIN(MIN(g_pm_off_thread_utime, g_pm_off_thread_stime),
                    off_thread_task_threads_next);
        hiOff = MAX(MAX(g_pm_off_thread_utime, g_pm_off_thread_stime),
                    off_thread_task_threads_next) + 8;
    }
    uint64_t head = task + off_task_threads_next;
    uint64_t first = kread64(head);
    if (first == head) { *uOut = 0; *sOut = 0; return true; }   // no live threads
    if (!procmgr_is_kern_ptr(first)) {
        static int dbg0 = 0;
        if (dbg0++ < 3)
            printf("[PROCMGR] thread walk: task+off_task_threads_next(0x%x)=0x%llx not a kern ptr (task=0x%llx)\n",
                   off_task_threads_next, first, task);
        return false;
    }
    uint64_t u = 0, s = 0;
    uint64_t t = first;
    int i = 0, skips = 0;
    for (; i < 256; i++) {
        if (!procmgr_is_kern_ptr(t)) {
            static int dbg1 = 0;
            if (dbg1++ < 3)
                printf("[PROCMGR] thread walk: chain broke at i=%d t=0x%llx\n", i, t);
            return false;
        }
        if (mappedGate && !kaddr_is_mapped(t + loOff, hiOff - loOff)) {
            // Thread exited and its struct got unmapped mid-walk. The span
            // includes task_threads.next, so there is no safe way on to the
            // next thread: drop this sample (the caller shows no CPU for the
            // process this refresh) rather than read the link we just failed
            // to prove mapped -- that read is the panic this gate exists for.
            static int dbgU = 0;
            if (dbgU++ < 3)
                printf("[PROCMGR] thread walk: thread 0x%llx unmapped at i=%d — sample dropped\n", t, i);
            return false;
        }
        if (g_pm_rc_cal) {
            uint64_t tu = 0, ts = 0;
            if (!pm_thread_sums_recount(t, &tu, &ts)) {
                uint64_t P = kread64(t + g_pm_rc_lifetime_off);
                if (P == 0) {
                    // Thread exited mid-walk: rth_lifetime already freed and its
                    // time rolled into task->total_* via recount rollup. A LIVE-
                    // thread sum must contribute 0 for it — skip, don't fail.
                } else {
                    static int dbg2 = 0;
                    if (dbg2++ < 3)
                        printf("[PROCMGR] thread walk: recount sums failed at i=%d t=0x%llx lifetime=0x%llx\n",
                               i, t, P);
                    if (++skips > 8) return false;
                }
                goto next_thread;
            }
            u += tu; s += ts;
        } else {
            u += kread64(t + g_pm_off_thread_utime);
            s += kread64(t + g_pm_off_thread_stime);
        }
next_thread:;
        uint64_t next = kread64(t + off_thread_task_threads_next);
        // NULL terminates the list on this kernel (also hit when a thread
        // dies mid-walk and its links are torn down) — that is a clean end,
        // not corruption. Looping back to the first thread also ends it.
        // task->threads is a queue_head_t: the LAST thread's next points back
        // at the head inside the task (task + off_task_threads_next), not at
        // the first thread. Without this check the head was walked as if it
        // were a thread — task fields read as timer / recount pointers, and
        // the walk "ended" only when task+head+next_off happened to be 0
        // (live log 2026-10-07: "next=0x100000000 invalid at i=5"), failing
        // CPU for those tasks and poisoning the task-total calibration.
        if (next == first || next == 0 || next == head) break;
        if (!procmgr_is_kern_ptr(next)) {
            static int dbg3 = 0;
            if (dbg3++ < 3)
                printf("[PROCMGR] thread walk: next=0x%llx invalid at i=%d (t=0x%llx off=0x%x)\n",
                       next, i, t, off_thread_task_threads_next);
            return false;
        }
        t = next;
    }
    if (i >= 256) return false;
    *uOut = u; *sOut = s;
    return true;
}

// A bounded, real syscall workload is declared before the calibration checks
// that use it. A commpage-served libc call is not a system-time perturbation.
static bool pm_burn_system_ns(uint64_t ns);

// Two-phase perturbation verify for a thread user/system offset pair:
// phase 1 — a pure-userspace burn must move ONLY oU (by roughly the burn);
// phase 2 — a pure-syscall burn must move ONLY oS. Look-alike time fields
// (which bracket-match but don't track burns) are rejected by this.
static bool pm_thread_pair_verify(uint64_t th, uint32_t oU, uint32_t oS, bool abstime) {
    uint64_t m = abstime ? pm_ns_to_abs(PM_MARGIN_NS) : PM_MARGIN_NS;

    uint64_t u0 = kread64(th + oU), s0 = kread64(th + oS);
    pm_burn_user_ns(3000000);
    usleep(2000);                                       // flush timers
    uint64_t u1 = kread64(th + oU), s1 = kread64(th + oS);
    uint64_t burnU = abstime ? pm_ns_to_abs(3000000ULL) : 3000000ULL;
    if (u1 < u0 || s1 < s0) return false;
    if (!(u1 - u0 >= burnU / 2 && u1 - u0 <= burnU * 4 && s1 - s0 <= m)) return false;

    uint64_t s2 = kread64(th + oS), u2 = kread64(th + oU);
    // getpid() is served from the commpage on Darwin and is not a syscall.
    // Use a bounded /dev/zero read workload so this really perturbs system
    // time before accepting the candidate offsets.
    if (!pm_burn_system_ns(15000000)) return false;
    usleep(2000);                                       // flush timers
    uint64_t s3 = kread64(th + oS), u3 = kread64(th + oU);
    if (s3 < s2 || u3 < u2) return false;
    if (!(s3 - s2 >= m / 5 && u3 - u2 <= m)) return false;
    return true;
}

// --- recount-based thread timing -------------------------------------------------

// Sum one thread's recount lifetime tracks (mach units) using the calibrated
// layout.
static bool pm_thread_sums_recount(uint64_t th, uint64_t *uMach, uint64_t *sMach) {
    uint64_t P = kread64(th + g_pm_rc_lifetime_off);
    if (!procmgr_is_kern_ptr(P)) return false;
    if (ksafe_available() &&
        !kaddr_is_mapped(P, 8 + g_pm_rc_count * g_pm_rc_track_stride)) return false;
    uint64_t u = 0, s = 0;
    for (uint32_t i = 0; i < g_pm_rc_count; i++) {
        uint64_t b = P + (uint64_t)i * g_pm_rc_track_stride;
        s += kread64(b + 8);
        u += kread64(b + 8 + g_pm_rc_lvl_stride);
    }
    *uMach = u; *sMach = s;
    return true;
}

// Sum with explicit layout parameters (used during calibration discovery).
static void pm_recount_read_sums(uint64_t th, uint32_t off, uint32_t ts,
                                 uint32_t ls, uint32_t cnt,
                                 uint64_t *uMach, uint64_t *sMach) {
    uint64_t P = kread64(th + off);
    // A failed read zero-fills (fail-safe early_kread), and P=0 would make the
    // loop below read 0x8, 0x8+ls, … — garbage sums at best. Treat a non-kernel
    // P as "no data this pass"; the value-match against thread_info rejects the
    // candidate either way.
    if (!procmgr_is_kern_ptr(P)) { *uMach = 0; *sMach = 0; return; }
    uint64_t u = 0, s = 0;
    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t b = P + (uint64_t)i * ts;
        s += kread64(b + 8);
        u += kread64(b + 8 + ls);
    }
    *uMach = u; *sMach = s;
}

// Definite-trap system burn: read() on /dev/zero. getpid() is served from the
// commpage on Darwin arm64 and never enters the kernel, so it is deliberately
// not a fallback. If the device cannot be opened, calibration rejects the
// candidate instead of claiming that a non-syscall perturbation was measured.
static bool pm_burn_system_ns(uint64_t ns) {
    static int zfd = -2;
    if (zfd == -2) zfd = open("/dev/zero", O_RDONLY);
    if (zfd < 0) return false;
    uint64_t start = mach_absolute_time();
    uint64_t limit = pm_ns_to_abs(ns);
    char buf[64];
    while (mach_absolute_time() - start < limit) {
        for (int i = 0; i < 64; i++) (void)read(zfd, buf, sizeof(buf));
    }
    return true;
}

// Discover the recount layout on our own thread: value-match the track sums
// against thread_info ground truth, then movement-verify with both burns.
static bool pm_calibrate_thread_recount(uint64_t th, uint32_t scanLen) {
    usleep(4000);                                   // flush recount snapshot
    mach_port_t tp = mach_thread_self();
    uint64_t U0ns = 0, S0ns = 0;
    bool ok = pm_thread_times_ns(tp, &U0ns, &S0ns);
    mach_port_deallocate(mach_task_self(), tp);
    if (!ok || U0ns < 1000000ULL) {
        printf("[PROCMGR] recount calib: no usable thread_info totals (u=%lluns)\n",
               (unsigned long long)U0ns);
        return false;
    }
    uint64_t U0 = pm_ns_to_abs(U0ns), S0 = pm_ns_to_abs(S0ns);

    static const struct { uint8_t cpi, lvls, nrg; } combos[] = {
        {1,3,1},{1,3,0},{1,2,1},{1,2,0},{0,3,1},{0,3,0},{0,2,1},{0,2,0},
    };
    for (uint32_t off = 0x100; off + 8 <= scanLen; off += 8) {
        // Mid-pass bail: the scan runs long (burns + sleeps per candidate) and
        // a background detach can land mid-pass. With the sockets gone every
        // read zero-fills; bail instead of burning seconds on garbage.
        if (!kexploit_krw_session_active()) {
            printf("[PROCMGR] recount calib: aborted mid-pass (KRW detached)\n");
            return false;
        }
        uint64_t P = kread64(th + off);
        if ((P & 0xF) != 0) continue;
        uint64_t band32 = P >> 32;
        if (band32 < 0xFFFFFFC0 || band32 > 0xFFFFFFEF) continue;   // kernel heap
        uint32_t cap = pm_scan_cap(P, 0x400);
        if (cap < 0x30) continue;
        if (ksafe_available() && !kaddr_is_mapped(P, MIN(cap, 0x200U))) continue;
        if ((uint32_t)kread64(P) != 0) continue;                    // rt_pad == 0

        for (size_t c = 0; c < sizeof(combos) / sizeof(combos[0]); c++) {
            uint32_t ls = 8 + combos[c].cpi * 16;
            uint32_t ts = 8 + combos[c].lvls * ls + combos[c].nrg * 8;
            for (uint32_t cnt = 1; cnt <= 4; cnt++) {
                if (8 + cnt * ts > cap) break;
                uint64_t su = 0, ss = 0;
                pm_recount_read_sums(th, off, ts, ls, cnt, &su, &ss);
                // thread_info sums the same data -> near-exact match
                if (su < U0 * 85 / 100 || su > U0 * 115 / 100) continue;
                if (ss < S0 * 70 / 100 || ss > S0 * 130 / 100) continue;

                // Movement verify: user burn moves only the user sum...
                uint64_t u0 = su, s0 = ss, u1 = 0, s1 = 0, u2 = 0, s2 = 0;
                pm_burn_user_ns(5000000);
                usleep(3000);
                pm_recount_read_sums(th, off, ts, ls, cnt, &u1, &s1);
                uint64_t duMin = pm_ns_to_abs(2500000ULL), duMax = pm_ns_to_abs(25000000ULL);
                uint64_t quiet  = pm_ns_to_abs(2000000ULL);
                if (u1 < u0 || s1 < s0) continue;
                if (!(u1 - u0 >= duMin && u1 - u0 <= duMax && s1 - s0 <= quiet)) continue;

                // ...system burn moves only the system sum.
                if (!pm_burn_system_ns(15000000)) continue;
                usleep(3000);
                pm_recount_read_sums(th, off, ts, ls, cnt, &u2, &s2);
                uint64_t dsMin = pm_ns_to_abs(8000000ULL), dsMax = pm_ns_to_abs(90000000ULL);
                uint64_t quietU = pm_ns_to_abs(6000000ULL);
                if (s2 < s1 || u2 < u1) continue;
                if (!(s2 - s1 >= dsMin && s2 - s1 <= dsMax && u2 - u1 <= quietU)) continue;

                g_pm_rc_lifetime_off = off;
                g_pm_rc_track_stride = ts;
                g_pm_rc_lvl_stride   = ls;
                g_pm_rc_count        = cnt;
                g_pm_rc_cal          = true;
                g_pm_thr_cal         = true;
                g_pm_thr_abstime     = true;    // recount rm_time_mach is mach time
                printf("[PROCMGR] recount calibrated: lifetime=+0x%x stride=0x%x "
                       "lvlStride=0x%x count=%u (u=%lluns s=%lluns)\n",
                       off, ts, ls, cnt,
                       (unsigned long long)pm_abs_to_ns(u2),
                       (unsigned long long)pm_abs_to_ns(s2));
                return true;
            }
        }
    }
    printf("[PROCMGR] recount calib: no lifetime track candidate matched\n");
    return false;
}

// --- thread-timer calibration (do this FIRST; task-total calibration and all
//     per-process CPU stats depend on the live-thread walk) -------------------
//
// Movement-signature identification: snapshot the whole thread struct, burn
// pure user CPU, snapshot again, burn pure system CPU, snapshot a third time.
// The user timer is the field that tracks the user burn and stays quiet
// during syscalls; the system timer is the mirror image. The thread_info
// deltas are measured on the SAME burns, so they double as the unit reference
// (ns vs mach-abstime) and as a value tiebreak among look-alikes. The old
// bracket-against-samples design needed both true fields to co-occur in two
// candidate sets at once — which the logs showed almost never happens.
static bool pm_calibrate_thread_timers(void) {
    if (g_pm_thr_cal) return true;

    mach_port_t tp = mach_thread_self();
    uint64_t task = task_self();
    uint64_t th = task ? task_get_ipc_port_kobject(task, tp) : 0;
    if (!procmgr_is_kern_ptr(th)) {
        mach_port_deallocate(mach_task_self(), tp);
        printf("[PROCMGR] thread calib failed: no kobject for own thread\n");
        return false;
    }

    enum { THREAD_SCAN = 0x800 };
    // Never read past the end of the thread's page: the threads-zone element
    // is smaller than THREAD_SCAN (1928 = 0x788 bytes on 22F76) and when it
    // ends at a page boundary the overrun read panics the kernel.
    uint32_t scanLen = pm_scan_cap(th, THREAD_SCAN);
    if (scanLen < 0x400) {   // timers live at >=0x100; too little room this pass
        mach_port_deallocate(mach_task_self(), tp);
        printf("[PROCMGR] thread calib deferred: thread at page edge (cap=0x%x)\n", scanLen);
        return false;
    }

    // Preferred path on iOS 15+: recount lifetime tracks. The classic
    // user_timer/system_timer fields this function scans for below do not
    // exist in struct thread anymore — every field that moves with a burn
    // turns out to be a wall-clock timestamp (see mover dumps).
    if (pm_calibrate_thread_recount(th, scanLen)) {
        mach_port_deallocate(mach_task_self(), tp);
        return true;
    }

    uint8_t *snapA = malloc(scanLen), *snapB = malloc(scanLen), *snapC = malloc(scanLen);
    if (!snapA || !snapB || !snapC) {
        free(snapA); free(snapB); free(snapC);
        mach_port_deallocate(mach_task_self(), tp);
        return false;
    }

    uint64_t ru0 = 0, rs0 = 0, ru1 = 0, rs1 = 0, ru2 = 0, rs2 = 0;
    bool ok = pm_thread_times_ns(tp, &ru0, &rs0);
    usleep(3000);                                   // settle + flush timers
    kreadbuf(th, snapA, scanLen);
    // Pure user burn; wall clock is the magnitude reference (user spin is
    // ~100% user time, and thread_info updates reliably here).
    uint64_t wU0 = mach_absolute_time();
    pm_burn_user_ns(5000000);                       // ~5ms pure user CPU
    uint64_t wallU_ns = pm_abs_to_ns(mach_absolute_time() - wU0);
    usleep(3000);                                   // flush
    ok = ok && pm_thread_times_ns(tp, &ru1, &rs1);
    kreadbuf(th, snapB, scanLen);
    // Pure system burn. thread_info's system_time for the running thread can
    // lag until the next context switch, so it cannot pace the loop — burn a
    // fixed ~12ms of WALL time in getpid() instead and use the wall duration
    // as the magnitude reference (syscall loops are ~all system time).
    uint64_t wS0 = mach_absolute_time();
    uint64_t sTarget = pm_ns_to_abs(12000000ULL);   // 12ms wall
    uint64_t sCap    = pm_ns_to_abs(2000000000ULL); // 2s wall cap
    while (mach_absolute_time() - wS0 < sTarget) {
        for (int i = 0; i < 8192; i++) (void)getpid();
        if (mach_absolute_time() - wS0 > sCap) break;
    }
    uint64_t wallS_ns = pm_abs_to_ns(mach_absolute_time() - wS0);
    usleep(3000);                                   // flush
    ok = ok && pm_thread_times_ns(tp, &ru2, &rs2);
    kreadbuf(th, snapC, scanLen);
    mach_port_deallocate(mach_task_self(), tp);
    if (!ok) {
        printf("[PROCMGR] thread calib failed: thread_info error\n");
        free(snapA); free(snapB); free(snapC);
        return false;
    }

    // Reference magnitudes: thread_info user time is reliable (updated on the
    // post-burn context switch), so refU comes from thread_info; system time
    // lags, so refS stays wall-based. If the user burn got preempted hard,
    // refU collapses and we retry the pass later instead of miscalibrating.
    uint64_t refU_ns = ru1 - ru0, refS_ns = wallS_ns;
    if (refU_ns < 3000000ULL || refS_ns < 6000000ULL) {
        printf("[PROCMGR] thread calib: burns too weak (tiU=%lluns wallS=%lluns)\n",
               (unsigned long long)refU_ns, (unsigned long long)refS_ns);
        free(snapA); free(snapB); free(snapC);
        return false;
    }

    // Diagnostics: remember the biggest movers seen during the abstime pass.
    struct pm_mover { uint32_t off; uint64_t dU, dS; };
    struct pm_mover topU[8] = {{0}}, topS[8] = {{0}};
    int nChanged = 0;

    bool found = false;
    for (int unit = 0; unit < 2 && !found; unit++) {           // try abstime, then ns
        bool abs = (unit == 0);
        uint64_t refU  = abs ? pm_ns_to_abs(refU_ns) : refU_ns;
        uint64_t refS  = abs ? pm_ns_to_abs(refS_ns) : refS_ns;
        uint64_t quiet = abs ? pm_ns_to_abs(1000000ULL) : 1000000ULL;   // 1ms
        uint64_t quietS = refS / 4;   // syscall stubs burn some user time too
        uint64_t valU  = abs ? pm_ns_to_abs(ru1) : ru1;     // value tiebreak refs
        uint64_t valS  = abs ? pm_ns_to_abs(rs2) : rs2;

        uint32_t bestU = 0, bestS = 0;
        uint64_t bestUd = UINT64_MAX, bestSd = UINT64_MAX;
        int nU = 0, nS = 0;
        for (uint32_t o = 0x100; o + 8 <= scanLen; o += 8) {
            uint64_t va = *(uint64_t *)(snapA + o);
            uint64_t vb = *(uint64_t *)(snapB + o);
            uint64_t vc = *(uint64_t *)(snapC + o);
            if (vb < va || vc < vb) continue;               // timers are monotonic
            uint64_t dU = vb - va, dS = vc - vb;
            if (abs && (dU || dS)) {
                nChanged++;
                if (dU) {
                    int mi = 0;
                    for (int k = 1; k < 8; k++) if (topU[k].dU < topU[mi].dU) mi = k;
                    if (dU > topU[mi].dU) topU[mi] = (struct pm_mover){ o, dU, dS };
                }
                if (dS) {
                    int mi = 0;
                    for (int k = 1; k < 8; k++) if (topS[k].dS < topS[mi].dS) mi = k;
                    if (dS > topS[mi].dS) topS[mi] = (struct pm_mover){ o, dU, dS };
                }
            }
            if (dU >= refU / 2 && dU <= refU * 4 && dS <= quiet) {   // user signature
                nU++;
                uint64_t dev = vb > valU ? vb - valU : valU - vb;
                if (dev < bestUd) { bestUd = dev; bestU = o; }
            }
            if (dS >= refS / 3 && dS <= refS * 4 && dU <= quietS) {  // system signature
                nS++;
                uint64_t dev = vc > valS ? vc - valS : valS - vc;
                if (dev < bestSd) { bestSd = dev; bestS = o; }
            }
        }
        printf("[PROCMGR] thread pass: unit=%s sigU=%d sigS=%d "
               "(refU=%lluns refS=%lluns scan=0x%x)\n",
               abs ? "abstime" : "ns", nU, nS,
               (unsigned long long)refU_ns, (unsigned long long)refS_ns, scanLen);
        if (!nU || !nS || bestU == bestS) continue;

        // Final gate: the chosen pair must survive a fresh two-phase burn.
        if (pm_thread_pair_verify(th, bestU, bestS, abs)) {
            g_pm_off_thread_utime = bestU;
            g_pm_off_thread_stime = bestS;
            g_pm_thr_abstime = abs;
            g_pm_thr_cal = true;
            found = true;
            printf("[PROCMGR] thread timers calibrated: user=+0x%x system=+0x%x abstime=%d\n",
                   bestU, bestS, abs);
        } else {
            printf("[PROCMGR] thread signature pair +0x%x/+0x%x failed final verify\n",
                   bestU, bestS);
        }
    }

    free(snapA); free(snapB); free(snapC);
    if (!found) {
        printf("[PROCMGR] thread timer calibration failed this pass\n");
        printf("[PROCMGR] movers: changed=%d\n", nChanged);
        printf("[PROCMGR] top dU (ns):");
        for (int k = 0; k < 8 && topU[k].dU; k++)
            printf(" +0x%x:%llu", topU[k].off,
                   (unsigned long long)pm_abs_to_ns(topU[k].dU));
        printf("\n[PROCMGR] top dS (ns):");
        for (int k = 0; k < 8 && topS[k].dS; k++)
            printf(" +0x%x:%llu", topS[k].off,
                   (unsigned long long)pm_abs_to_ns(topS[k].dS));
        printf("\n");
    }
    return found;
}

// Perturbation verify for task totals: a fresh ~10ms dead thread must raise
// total_user_time by roughly that much and total_system_time by at most a
// bounded amount. oU/oS in the unit selected by `abstime`.
// Verify thread: ~10ms of user CPU, then ~10ms (wall) of syscall-heavy work so
// BOTH task totals must move when it dies.
static void *pm_verify_busy_fn(void *arg) {
    (void)arg;
    pm_burn_user_ns(10000000ULL);
    pm_burn_system_ns(10000000ULL);
    return NULL;
}

static bool pm_verify_task_totals(uint64_t task, uint32_t oU, uint32_t oS, bool abstime) {
    uint64_t u0 = kread64(task + oU), s0 = kread64(task + oS);
    pthread_t pt;
    if (pthread_create(&pt, NULL, pm_verify_busy_fn, NULL) != 0) return false;
    pthread_join(pt, NULL);
    uint64_t lo  = abstime ? pm_ns_to_abs(2000000ULL)    : 2000000ULL;     // >= 2ms user
    uint64_t loS = abstime ? pm_ns_to_abs(1000000ULL)    : 1000000ULL;     // >= 1ms system
    uint64_t hi  = abstime ? pm_ns_to_abs(200000000ULL)  : 200000000ULL;   // <= 200ms either
    // pthread_join returns before the kernel finishes terminating the thread
    // and rolls its time into the task totals; the 2026-10-07 log showed the
    // SAME user offset reading dU=0 four times and then passing on the fifth
    // candidate (the earlier threads' time landing late) — so whichever system
    // candidate was under test then "won". Poll up to ~100ms for the rollup.
    uint64_t u1 = u0, s1 = s0;
    for (int i = 0; i < 20; i++) {
        u1 = kread64(task + oU);
        s1 = kread64(task + oS);
        if (u1 >= u0 + lo && s1 >= s0 + loS) break;
        usleep(5000);
    }
    if (u1 < u0 || s1 < s0) return false;
    uint64_t dU = u1 - u0, dS = s1 - s0;
    // dS must MOVE: the old check only bounded it from above, so any static
    // small field passed as total_system_time.
    bool ok = (dU >= lo && dU <= hi && dS >= loS && dS <= hi);
    printf("[PROCMGR] task-total verify: dU=%llu dS=%llu (unit=%s) -> %s\n",
           (unsigned long long)dU, (unsigned long long)dS,
           abstime ? "abs" : "ns", ok ? "OK" : "FAIL");
    return ok;
}

// --- task total_user_time/total_system_time (terminated-thread counters) -----
static bool pm_calibrate_task_totals(uint64_t task) {
    if (g_pm_cpu_cal) return true;
    if (!g_pm_thr_cal) return false;    // need live-thread sums to isolate dead time

    // Dead-thread sample: its CPU moves into the task totals on exit.
    pthread_t pt;
    if (pthread_create(&pt, NULL, pm_busy_fn, NULL) != 0) {
        printf("[PROCMGR] task-total calib: pthread_create failed\n");
        return false;
    }
    pthread_join(pt, NULL);

    enum { TASK_SCAN = 0x1400 };
    // Same page-boundary cap as the thread scan: if the task element ends at
    // a page boundary, reading past it panics the kernel.
    uint32_t taskScan = pm_scan_cap(task, TASK_SCAN);
    if (taskScan < 0x400) {
        printf("[PROCMGR] task-total calib deferred: task at page edge (cap=0x%x)\n", taskScan);
        return false;
    }
    uint8_t *tb = malloc(TASK_SCAN);
    if (!tb) return false;

    // Bracket: proc_pidinfo AND the live-thread sum around the task read.
    // usleep first so OUR running thread's timer is flushed into t_sum and the
    // live sum is not short by our current quantum.
    usleep(2000);
    uint64_t pu0 = 0, ps0 = 0, pu1 = 0, ps1 = 0;
    uint64_t lu0 = 0, ls0 = 0, lu1 = 0, ls1 = 0;
    procmgr_own_cpu_ns(&pu0, &ps0);
    bool ok = pm_live_thread_sums(task, &lu0, &ls0);
    kreadbuf(task, tb, taskScan);
    usleep(2000);
    procmgr_own_cpu_ns(&pu1, &ps1);
    ok = ok && pm_live_thread_sums(task, &lu1, &ls1);
    if (!ok) {
        printf("[PROCMGR] task-total calib: live thread walk failed\n");
        free(tb);
        return false;
    }
    if (g_pm_thr_abstime) {
        lu0 = pm_abs_to_ns(lu0); ls0 = pm_abs_to_ns(ls0);
        lu1 = pm_abs_to_ns(lu1); ls1 = pm_abs_to_ns(ls1);
    }

    // deadUser/deadSystem = pti_total - sum(live thread timers), bracketed.
    int64_t du0 = (int64_t)pu0 - (int64_t)lu0, du1 = (int64_t)pu1 - (int64_t)lu1;
    int64_t ds0 = (int64_t)ps0 - (int64_t)ls0, ds1 = (int64_t)ps1 - (int64_t)ls1;
    if (ds0 < 0) ds0 = 0;
    if (ds1 < 0) ds1 = 0;
    if (du0 <= 0 || du1 <= 0) {
        // The sample thread's time hasn't landed in the task totals yet —
        // retry on a later refresh; never fatal.
        printf("[PROCMGR] task-total calib: deadUser not positive yet (%lld/%lld), retry later\n",
               (long long)du0, (long long)du1);
        free(tb);
        return false;
    }

    bool found = false;
    for (int unit = 0; unit < 2 && !found; unit++) {           // try abstime, then ns
        bool abs = (unit == 0);
        uint64_t m  = abs ? pm_ns_to_abs(PM_MARGIN_NS) : PM_MARGIN_NS;
        uint64_t u0 = abs ? pm_ns_to_abs((uint64_t)du0) : (uint64_t)du0;
        uint64_t u1 = abs ? pm_ns_to_abs((uint64_t)du1) : (uint64_t)du1;
        uint64_t s0 = abs ? pm_ns_to_abs((uint64_t)ds0) : (uint64_t)ds0;
        uint64_t s1 = abs ? pm_ns_to_abs((uint64_t)ds1) : (uint64_t)ds1;

        // Collect ALL candidate pairs, then verify each — a verify failure
        // must not end the scan (which look-alike matches first drifts between
        // runs). Preferred: adjacent pairs total_user_time@o, total_system_time@o+8.
        enum { MAX_PAIRS = 16 };
        uint32_t pU[MAX_PAIRS], pS[MAX_PAIRS];
        int nP = 0;
        for (uint32_t o = 0x8; o + 16 <= taskScan && nP < MAX_PAIRS; o += 8) {
            uint64_t vu = *(uint64_t *)(tb + o), vs = *(uint64_t *)(tb + o + 8);
            if (!vu) continue;
            if (pm_bracket(vu, u0, u1, m) && pm_bracket(vs, s0, s1, m)) {
                pU[nP] = o; pS[nP] = o + 8; nP++;
            }
        }
        // Fallback: independent offset pairs (cross-product of both candidate sets).
        if (!nP) {
            uint32_t cU[MAX_PAIRS], cS[MAX_PAIRS];
            int nCU = 0, nCS = 0;
            for (uint32_t o = 0x8; o + 8 <= taskScan; o += 8) {
                uint64_t v = *(uint64_t *)(tb + o);
                if (nCU < MAX_PAIRS && v && pm_bracket(v, u0, u1, m)) cU[nCU++] = o;
                if (nCS < MAX_PAIRS && pm_bracket(v, s0, s1, m)) cS[nCS++] = o;
            }
            for (int i = 0; i < nCU && nP < MAX_PAIRS; i++)
                for (int j = 0; j < nCS && nP < MAX_PAIRS; j++)
                    if (cU[i] != cS[j]) { pU[nP] = cU[i]; pS[nP] = cS[j]; nP++; }
        }

        for (int i = 0; i < nP && !found; i++) {
            if (pm_verify_task_totals(task, pU[i], pS[i], abs)) {
                g_pm_off_task_cpu_u = pU[i];
                g_pm_off_task_cpu_s = pS[i];
                g_pm_cpu_abstime = abs;
                found = true;
            } else {
                printf("[PROCMGR] task candidate +0x%x/+0x%x failed perturbation verify\n",
                       pU[i], pS[i]);
            }
        }
    }

    if (found) {
        g_pm_cpu_cal = true;
        printf("[PROCMGR] cpu calibrated: task.totalU=+0x%x totalS=+0x%x abstime=%d "
               "(deadU=%lld..%lldns deadS=%lld..%lldns)\n",
               g_pm_off_task_cpu_u, g_pm_off_task_cpu_s, g_pm_cpu_abstime,
               (long long)du0, (long long)du1, (long long)ds0, (long long)ds1);
    } else {
        printf("[PROCMGR] cpu calibration failed this pass\n");
    }
    free(tb);
    return found;
}

// A KRW read of an unmapped kernel address faults the kernel (panic), so a
// candidate pointer must ALSO sit in the same kernel-heap band as a known-good
// heap pointer (our task) before we even spend page-table walks on it. This is
// just the cheap pre-filter — kaddr_is_mapped() (the kernel_map snapshot) is the
// actual mapping guarantee and gates every dereference.
static bool pm_same_band(uint64_t p, uint64_t anchor) {
    if (!is_kaddr_valid(p)) return false;
    return (p & 0xfffffff000000000ULL) == (anchor & 0xfffffff000000000ULL);
}

// Grow-and-touch helper for the footprint perturbation below. A fresh VM
// region, one volatile byte per 16KB page, so our physical footprint visibly
// moves. mach_vm_allocate, NOT malloc: malloc serves retried passes from its
// large-block cache of already-resident pages, so the footprint stops moving
// (F2 == F1 forever, observed on-device). The touch goes through a volatile
// pointer — a plain memset on a soon-freed buffer is dead-store-eliminated
// by clang.
static bool pm_grow_region(vm_address_t *addr, vm_size_t size) {
    if (vm_allocate(mach_task_self(), addr, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return false;
    volatile uint8_t *gv = (volatile uint8_t *)*addr;
    for (vm_size_t gi = 0; gi < size; gi += 0x4000)  // one byte per 16KB page
        gv[gi] = 0x41;
    return true;
}

// --- memory calibration: task->ledger -> physical-footprint ledger entry ------
// ONLY runs when ksafe_available(): every candidate ledger pointer is gated by
// kaddr_is_mapped() before it is dereferenced. Strengthened with perturbation:
// we grow our own footprint by 32MB between two reference samples and accept a
// candidate entry only if its balance tracks the POST-growth footprint.
//
// WHY THE EARLY-EXIT ORDER MATTERS (do not reintroduce "collect all
// candidates, then verify"): our KRW read is a copyout
// (getsockopt(IPPROTO_ICMPV6, ICMP6_FILTER)), and on iOS 17 (xnu-10002) AND
// iOS 18 (xnu-11417) every copyin/copyout runs
// zone_element_bounds_check(kernel_addr, len), which PANICS with "zone bound
// checks: address ... is a per-cpu allocation" if the kernel-side address is a
// per-cpu zone allocation — observed twice on iOS 17.3.1 (21D61). struct task
// contains FIVE such per-cpu pointers (counter_alloc → zalloc_percpu):
// faults, pageins, cow_faults, messages_sent, messages_received. In both xnu
// versions, `ledger_t ledger` (osfmk/kern/task.h line 252) is declared
// IMMEDIATELY BEFORE those counters (lines 262-266), with only
// semaphore_list/semaphores_owned/priv_flags/MACHINE_TASK in between. The old
// two-phase scan dereferenced EVERY gated pointer in the task — including the
// per-cpu counters, which pass both gates on iOS 17 — and panicked the
// kernel. So this scan is ascending and one-at-a-time: it must never
// dereference candidates past the first shrink-verified ledger hit.
static bool pm_calibrate_mem(uint64_t task) {
    if (g_pm_mem_cal) return true;
    if (!ksafe_available()) {
        printf("[PROCMGR] mem calib skipped: ksafe (mapped-check) unavailable\n");
        return false;
    }

    uint64_t f1 = procmgr_own_footprint();
    if (f1 < 0x100000) {
        printf("[PROCMGR] mem calib: own footprint implausible (%llu)\n",
               (unsigned long long)f1);
        return false;
    }

    const vm_size_t growSz = 32 * 1024 * 1024;
    vm_address_t gaddr = 0;
    enum { TASK_SCAN = 0x1400, LEDGER_SCAN = 0x800, MAX_RESUME = 4 };
    bool found = false;
    uint8_t *tb = malloc(TASK_SCAN);
    uint8_t *lb = malloc(LEDGER_SCAN);
    uint32_t taskScan = pm_scan_cap(task, TASK_SCAN);   // page-boundary cap
    const int64_t tol = 0x300000;                       // 3MB
    if (!tb || !lb || taskScan < 0x400) {
        printf("[PROCMGR] mem calib aborted: tb=%p lb=%p taskScan=0x%x\n",
               tb, lb, taskScan);
        goto out;
    }
    kreadbuf(task, tb, taskScan);

    uint32_t to = 0;    // ascending scan cursor; survives regrows
    int resumes = 0;    // shrink-verify failures recovered so far
    uint64_t f2 = 0;

grow:   // (re)grow the 32MB perturbation region and take fresh F1/F2 refs
    if (!pm_grow_region(&gaddr, growSz)) {
        printf("[PROCMGR] mem calib: vm_allocate(32MB) failed\n");
        goto out;
    }
    f2 = procmgr_own_footprint();
    printf("[PROCMGR] mem calib: footprint F1=%llu F2=%llu%s\n",
           (unsigned long long)f1, (unsigned long long)f2,
           resumes ? " (regrow)" : "");
    if (f2 <= f1 + growSz / 2) {
        printf("[PROCMGR] mem calib aborted: perturbation did not move footprint%s\n",
               resumes ? " after regrow" : "");
        goto out;
    }

    // Ascending one-at-a-time scan: the FIRST balance match stops the scan
    // immediately — nothing past it is ever dereferenced (see header comment).
    for (; to + 8 <= taskScan; to += 8) {
        uint64_t cand = xpaci(*(uint64_t *)(tb + to));
        if (!pm_same_band(cand, task)) continue;            // cheap pre-filter
        if (!kaddr_is_mapped(cand, LEDGER_SCAN)) continue;  // THE safety gate
        kreadbuf(cand, lb, LEDGER_SCAN);
        for (uint32_t lo = 0; lo + 16 <= LEDGER_SCAN; lo += 8) {
            int64_t bal = (int64_t)(*(uint64_t *)(lb + lo))
                        - (int64_t)(*(uint64_t *)(lb + lo + 8));
            if (bal <= 0x80000) continue;
            int64_t d2 = llabs(bal - (int64_t)f2);
            int64_t d1 = llabs(bal - (int64_t)f1);
            if (d2 > tol || d1 <= 2 * tol) continue;

            // Match: STOP scanning. Shrink-verify THIS candidate only: drop
            // the region and require the balance to fall back to baseline. A
            // coincidental value pair inside some other kernel object
            // (task->map at +0x28 matched once!) does NOT track our footprint
            // back down — only the real ledger entry does.
            vm_deallocate(mach_task_self(), gaddr, growSz);
            gaddr = 0;
            usleep(4000);
            uint64_t f3 = procmgr_own_footprint();
            int64_t bal3 = 0;
            bool ok = false;
            if (kaddr_is_mapped(cand + lo, 16)) {
                bal3 = (int64_t)kread64(cand + lo)
                     - (int64_t)kread64(cand + lo + 8);
                ok = llabs(bal3 - (int64_t)f3) <= tol &&
                     llabs(bal3 - (int64_t)f2) > 2 * tol;
            }
            if (ok) {
                g_pm_off_task_ledger = to;
                g_pm_off_ledger_fp   = lo;
                g_pm_mem_cal = true;
                found = true;
                printf("[PROCMGR] mem calibrated: task.ledger=+0x%x ledger.fp=+0x%x "
                       "(F2=%llu F3=%llu bal3=%lld)\n",
                       to, lo, (unsigned long long)f2,
                       (unsigned long long)f3, (long long)bal3);
                goto out;
            }
            printf("[PROCMGR] mem candidate +0x%x/+0x%x failed shrink verify "
                   "(bal3=%lld F3=%llu)\n",
                   to, lo, (long long)bal3, (unsigned long long)f3);

            // Resume: regrow a fresh region, refresh F1/F2, and continue the
            // ascending scan AFTER the failed candidate. Bounded so repeated
            // look-alikes cannot loop the perturbation forever.
            to += 8;
            if (++resumes > MAX_RESUME) {
                printf("[PROCMGR] mem calib: %d shrink-verify failures, giving up this pass\n",
                       MAX_RESUME);
                goto out;
            }
            f1 = procmgr_own_footprint();   // fresh post-shrink baseline
            goto grow;
        }
    }
    printf("[PROCMGR] mem calibration failed this pass (F1=%llu F2=%llu)\n",
           (unsigned long long)f1, (unsigned long long)f2);
out:
    if (gaddr) vm_deallocate(mach_task_self(), gaddr, growSz);
    free(tb);
    free(lb);
    return found;
}

// Persist the discovered offsets so the risky scan runs at most once per OS
// build. cy_pmcal3_: cy_pmcal2_ entries predate recount-based thread timing.
static NSString *pm_cache_key(void) {
    char osv[64] = {0}; size_t len = sizeof(osv);
    if (sysctlbyname("kern.osversion", osv, &len, NULL, 0) != 0) osv[0] = '\0';
    // Stays v3 on purpose: bumping the key re-runs the memory scan, which is
    // the risky one (task-pointer derefs; a different ledger entry was picked
    // on the 2026-10-07 re-run). Only the CPU block is versioned — see "cpuv".
    return [NSString stringWithFormat:@"cy_pmcal3_%s", osv];
}
static bool pm_load_cache(void) {
    // Drop the short-lived cy_pmcal4_ entry (test builds of 2026-10-07): its
    // memory offsets came from a re-run of the memory scan, not the v3 result.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:
        [pm_cache_key() stringByReplacingOccurrencesOfString:@"cy_pmcal3_"
                                                  withString:@"cy_pmcal4_"]];
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:pm_cache_key()];
    if (!d) return false;
    // Bounds-check every cached offset before trusting it: a corrupt entry
    // would otherwise send kreads past the end of our own task/thread
    // elements, and an out-of-element read at a page boundary panics the
    // kernel. The thread bound 0x780 = sizeof(thread)-8 on this build family
    // (element is 1928=0x788; the cache key is per-OS-build so the bound
    // travels with the struct layout it was calibrated on).
    if (d[@"rc"]) {
        uint32_t lo = [d[@"rclo"] unsignedIntValue], ts = [d[@"rcts"] unsignedIntValue];
        uint32_t ls = [d[@"rcls"] unsignedIntValue], cnt = [d[@"rccnt"] unsignedIntValue];
        if (lo >= 0x100 && lo <= 0x780 && ts >= 0x18 && ts <= 0x60 &&
            (ls == 8 || ls == 24) && cnt >= 1 && cnt <= 4) {
            g_pm_rc_lifetime_off = lo;
            g_pm_rc_track_stride = ts;
            g_pm_rc_lvl_stride   = ls;
            g_pm_rc_count        = cnt;
            g_pm_rc_cal          = true;
            g_pm_thr_cal         = true;
            g_pm_thr_abstime     = true;
        } else {
            printf("[PROCMGR] cache recount params out of bounds — dropped\n");
        }
    }
    if (d[@"mem"]) {
        uint32_t tl = [d[@"tl"] unsignedIntValue], lf = [d[@"lf"] unsignedIntValue];
        if (tl >= 0x8 && tl + 8 <= 0x1400 && lf + 16 <= 0x800) {
            g_pm_off_task_ledger = tl;
            g_pm_off_ledger_fp   = lf;
            g_pm_mem_cal = true;
        } else {
            printf("[PROCMGR] cache mem offsets out of bounds (tl=0x%x lf=0x%x) — dropped\n", tl, lf);
        }
    }
    if (d[@"thr"]) {
        uint32_t thu = [d[@"thu"] unsignedIntValue], ths = [d[@"ths"] unsignedIntValue];
        if (thu >= 0x100 && thu <= 0x780 && ths >= 0x100 && ths <= 0x780) {
            g_pm_off_thread_utime = thu;
            g_pm_off_thread_stime = ths;
            g_pm_thr_abstime      = [d[@"thab"] boolValue];
            g_pm_thr_cal = true;
        } else {
            printf("[PROCMGR] cache thread offsets out of bounds (thu=0x%x ths=0x%x) — dropped\n", thu, ths);
        }
    }
    // cpuv 2: task totals calibrated with the queue-head-terminated thread
    // walk and the dual user+system verify. Older CPU entries were matched
    // against a live-thread sum that walked past the list head, and their
    // system-time offset was effectively unverified — drop them (CPU-only
    // recalibration reads nothing but our own task).
    if (d[@"cpu"] && [d[@"cpuv"] intValue] != 2)
        printf("[PROCMGR] cache cpu offsets predate cpuv2 — recalibrating CPU only\n");
    else if (d[@"cpu"]) {
        uint32_t tcu = [d[@"tcu"] unsignedIntValue], tcs = [d[@"tcs"] unsignedIntValue];
        if (tcu >= 0x8 && tcu + 8 <= 0x1400 && tcs >= 0x8 && tcs + 8 <= 0x1400) {
            g_pm_off_task_cpu_u = tcu;
            g_pm_off_task_cpu_s = tcs;
            g_pm_cpu_abstime    = [d[@"cab"] boolValue];
            g_pm_cpu_cal = true;
        } else {
            printf("[PROCMGR] cache cpu offsets out of bounds (tcu=0x%x tcs=0x%x) — dropped\n", tcu, tcs);
        }
    }
    // CPU stats need the live-thread walk; task totals alone are incomplete.
    if (g_pm_cpu_cal && !g_pm_thr_cal) {
        printf("[PROCMGR] cache has cpu without thread timers — discarding cpu\n");
        g_pm_cpu_cal = false;
    }
    return g_pm_mem_cal || g_pm_cpu_cal || g_pm_thr_cal;
}
static void pm_save_cache(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (g_pm_rc_cal) { d[@"rc"]=@1; d[@"rclo"]=@(g_pm_rc_lifetime_off); d[@"rcts"]=@(g_pm_rc_track_stride);
                       d[@"rcls"]=@(g_pm_rc_lvl_stride); d[@"rccnt"]=@(g_pm_rc_count); }
    if (g_pm_mem_cal) { d[@"mem"]=@1; d[@"tl"]=@(g_pm_off_task_ledger); d[@"lf"]=@(g_pm_off_ledger_fp); }
    if (g_pm_thr_cal && !g_pm_rc_cal) { d[@"thr"]=@1; d[@"thu"]=@(g_pm_off_thread_utime); d[@"ths"]=@(g_pm_off_thread_stime); d[@"thab"]=@(g_pm_thr_abstime); }
    if (g_pm_cpu_cal) { d[@"cpu"]=@1; d[@"cpuv"]=@2; d[@"tcu"]=@(g_pm_off_task_cpu_u); d[@"tcs"]=@(g_pm_off_task_cpu_s); d[@"cab"]=@(g_pm_cpu_abstime); }
    if (d.count) [[NSUserDefaults standardUserDefaults] setObject:d forKey:pm_cache_key()];
}

// Read one process's memory footprint and CPU time straight from the kernel
// task/thread structs using the calibrated offsets. Returns a bitmask:
// bit 0 = memOut valid, bit 1 = cpuOut valid.
//
// Torn-read hardening: the kernel mutates these counters while we read them
// one 8-byte word at a time through the primitive. Every block is read TWICE
// and only accepted when the two reads agree within what the counter can
// physically move during the read window. A torn read (a word changed
// mid-block, or a thread exited between reads and its total jumped into the
// task counters) is reported invalid instead of producing garbage values —
// the caller keeps the libproc value for that cycle and the next poll
// retries. Rejecting the cycle is also semantically right for a thread-exit
// race, because "task totals + live threads" could double-count the exiting
// thread for that one sample.
static int pm_kernel_stats(uint64_t task, uint64_t *memOut, uint64_t *cpuOut) {
    int valid = 0;

    // --- memory: ledger physical-footprint entry (credit - debit) ---
    if (g_pm_mem_cal && ksafe_available()) {
        uint64_t ledger = kread_ptr(task + g_pm_off_task_ledger);
        // The ledger is a separate kernel object: mapped-check the exact
        // 16 bytes we are about to read before touching them.
        if (procmgr_is_kern_ptr(ledger) &&
            kaddr_is_mapped(ledger + g_pm_off_ledger_fp, 16)) {
            uint64_t a = ledger + g_pm_off_ledger_fp;
            int64_t bal1 = (int64_t)kread64(a)     - (int64_t)kread64(a + 8);
            int64_t bal2 = (int64_t)kread64(a)     - (int64_t)kread64(a + 8);
            // Footprint moves at most a few MB in the µs between the two
            // reads; a torn word shows up as a huge jump.
            if (bal2 > 0 && (uint64_t)bal2 <= (256ULL << 30) &&
                llabs(bal2 - bal1) <= (32LL << 20)) {
                *memOut = (uint64_t)bal2;
                valid |= 1;
            }
        }
    }

    // --- cpu: task totals (terminated threads) + live thread timers ---
    // Live-only fallback when the task-total offsets aren't calibrated (the
    // terminated-thread counters have proven hard to pin down: 2026-10-07 runs
    // matched +0x98 only against a live sum that walked past the list head,
    // and gave up outright on others). The viewer shows %CPU as a delta
    // between refreshes, so live threads carry it; only time from threads
    // that exit between two refreshes is missed (that interval clamps to 0).
    // The thread timers themselves are verified against our own threads.
    if (g_pm_thr_cal && !g_pm_cpu_cal) {
        uint64_t lu = 0, ls = 0;
        if (pm_live_thread_sums(task, &lu, &ls)) {
            if (g_pm_thr_abstime) { lu = pm_abs_to_ns(lu); ls = pm_abs_to_ns(ls); }
            uint64_t tot = lu + ls;
            if (tot) { *cpuOut = tot; valid |= 2; }
        }
    }
    if (g_pm_cpu_cal && g_pm_thr_cal) {
        // The task totals only move when a thread terminates (its time is
        // folded in at exit), so any change across the bracket means a thread
        // may be counted both in u2/s2 and in the live walk. Retry the bracket;
        // if it still moved, no CPU sample this pass. 4 attempts, not 2: a
        // process that keeps starting and ending threads moved its totals
        // during both of 2 brackets often enough to show "—" (and lose its
        // %CPU baseline) on many refreshes. The check itself stays exact --
        // any tolerance would let one exiting thread's lifetime be counted
        // twice or not at all.
        uint64_t u1 = 0, s1 = 0, u2 = 0, s2 = 0, lu = 0, ls = 0;
        bool walkOk = false;
        for (int attempt = 0; attempt < 4; attempt++) {
            u1 = kread64(task + g_pm_off_task_cpu_u);
            s1 = kread64(task + g_pm_off_task_cpu_s);
            lu = 0; ls = 0;
            walkOk = pm_live_thread_sums(task, &lu, &ls);
            u2 = kread64(task + g_pm_off_task_cpu_u);
            s2 = kread64(task + g_pm_off_task_cpu_s);
            if (u2 == u1 && s2 == s1) break;
        }
        if (walkOk && u2 == u1 && s2 == s1) {
            uint64_t u = u2, s = s2;
            if (g_pm_cpu_abstime) { u = pm_abs_to_ns(u); s = pm_abs_to_ns(s); }
            if (g_pm_thr_abstime) { lu = pm_abs_to_ns(lu); ls = pm_abs_to_ns(ls); }
            uint64_t tot = u + s + lu + ls;
            // Zero means the nonfatal path zero-filled a failed read — never
            // report it as a valid kernel value, or cache validation would
            // mistake a transient read failure for a bad cache.
            if (tot) { *cpuOut = tot; valid |= 2; }
        }
        // If the live-thread walk fails, cpu stays invalid: dead-only totals
        // would underreport.
    }

    return valid;
}

// A wrong cached calibration used to be trusted blindly until the OS build
// changed or the entry was wiped by hand — that is what made second launches
// unstable after a bad first calibration. Validate the loaded offsets by
// running them against OUR OWN process, whose true footprint and CPU time we
// know from userspace; anything that does not reproduce reality is discarded
// and recalibrated below. Validation only ever reads our own task/thread
// structs (always mapped), so a stale cache cannot panic here.
static bool pm_validate_cache(void) {
    if (!kexploit_krw_ready()) return false;
    if (!g_pm_thr_cal && !g_pm_cpu_cal && !g_pm_mem_cal) return true;

    uint64_t task = proc_task(proc_self());
    if (!procmgr_is_kern_ptr(task)) return false;

    // An inconclusive check (stats read came back without a value) is retried
    // on the next poll; after a few, whatever is still unverified is dropped
    // and recalibrated rather than trusted.
    static int sInconclusive = 0;
    bool inconclusive = false;

    // Once only: on a retry the flags may come from this session's own
    // (self-verified) discovery rather than the cache.
    static bool sThrOnlyChecked = false;
    if (!sThrOnlyChecked && g_pm_thr_cal && !g_pm_cpu_cal) {
        // Live-thread-only: without the dead-thread totals there is no own-task
        // ground truth to compare the sum against, so the cached thread offsets
        // can't be validated. Rediscover them (discovery verifies itself).
        printf("[PROCMGR] cached thread offsets without task totals — recalibrating\n");
        g_pm_thr_cal = false;
        g_pm_rc_cal = false;
    }
    sThrOnlyChecked = true;
    if (g_pm_thr_cal && g_pm_cpu_cal) {
        uint64_t mem = 0, cpu = 0;
        if (pm_kernel_stats(task, &mem, &cpu) & 2) {
            uint64_t ru = 0, rs = 0;
            procmgr_own_cpu_ns(&ru, &rs);
            uint64_t ref = ru + rs;
            uint64_t diff = cpu > ref ? cpu - ref : ref - cpu;
            // Must reproduce our own CPU within 25% + 50ms slack.
            if (diff > ref / 4 + 50000000ULL) {
                printf("[PROCMGR] cache cpu validation failed (kernel=%llums ref=%llums) — recalibrating\n",
                       cpu / 1000000ULL, ref / 1000000ULL);
                g_pm_cpu_cal = false;
                g_pm_thr_cal = false;   // cpu depends on the thread walk
                // ...and so does the timing backend it used. Leaving g_pm_rc_cal
                // set let a classic-timer rediscovery "succeed" while the walk
                // kept reading the rejected recount layout. Its offsets are
                // rewritten by whichever discovery succeeds next.
                g_pm_rc_cal = false;
            }
        } else if (sInconclusive >= 2) {
            printf("[PROCMGR] cache cpu validation inconclusive — recalibrating\n");
            g_pm_cpu_cal = false;
            g_pm_thr_cal = false;
            g_pm_rc_cal = false;
        } else {
            inconclusive = true;
        }
    }
    if (g_pm_mem_cal && ksafe_available()) {
        uint64_t mem = 0, cpu = 0;
        if (pm_kernel_stats(task, &mem, &cpu) & 1) {
            uint64_t ref = procmgr_own_footprint();
            uint64_t diff = mem > ref ? mem - ref : ref - mem;
            // Calibration matched within 3MB; allow 25% + 32MB drift.
            if (diff > ref / 4 + (32ULL << 20)) {
                printf("[PROCMGR] cache mem validation failed (kernel=%lluMB ref=%lluMB) — recalibrating\n",
                       mem >> 20, ref >> 20);
                g_pm_mem_cal = false;
            }
        } else if (sInconclusive >= 2) {
            printf("[PROCMGR] cache mem validation inconclusive — recalibrating\n");
            g_pm_mem_cal = false;
        } else {
            inconclusive = true;
        }
    }
    if (inconclusive) { sInconclusive++; return false; }
    return true;
}

// Discover the offsets by matching our OWN known footprint + CPU times. All
// reads, no writes. Failures just leave the feature disabled until the next
// refresh retries. Runs on a background queue from reloadProcs.
int procmgr_calibrate(void) {
    // Gate the WHOLE pass on a live session: the sub-calibrators below
    // (suspend_count, task role, cache validation) read kernel memory BEFORE
    // the kexploit_krw_ready() check further down, so a detached session used
    // to reach them un-gated — the 18:50:56 crash pass started exactly like
    // that. Cheap probe only (session_active does not reattach or log); the
    // caller's start-gate already ran the authoritative ready() check.
    static bool sCalibSkipLogged = false;   // edge-triggered: one line per outage
    if (!kexploit_krw_session_active()) {
        if (!sCalibSkipLogged) {
            sCalibSkipLogged = true;
            printf("[PROCMGR] calibrate: pass skipped (KRW not ready/detached) — "
                   "further skips quiet until a pass runs\n");
        }
        return 0;
    }
    sCalibSkipLogged = false;

    // ksafe (the mapped-address gate) comes up BEFORE any offset discovery:
    // the sub-calibrators below probe speculative offsets, and an unmapped
    // read panics the device. Up to 3 tries, at least 10 s apart (it was a
    // one-shot: one failed bring-up left every later pass ungated).
    if (!ksafe_available() && g_pm_xpf_attempts < 3) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (!g_pm_xpf_last_ns || now - g_pm_xpf_last_ns >= 10000000000ULL) {
            g_pm_xpf_attempts++;
            g_pm_xpf_last_ns = now;
            printf("[PROCMGR] bringing up kernel_map snapshot (try %d/3)...\n", g_pm_xpf_attempts);
            krw_set_nonfatal(true);
            init_xpf();
            krw_set_nonfatal(false);
            printf("[PROCMGR] bring-up done; ksafe_available=%d\n", ksafe_available());
        }
    }
    // Fail closed: without the gate, no speculative discovery this pass.
    bool discoverySafe = ksafe_available();
    static bool sNoGateLogged = false;
    if (!discoverySafe && !sNoGateLogged) {
        sNoGateLogged = true;
        printf("[PROCMGR] calibrate: mapped-address gate unavailable — offset discovery "
               "skipped (CPU/suspend columns stay empty) until it comes up\n");
    }

    // suspend_count offset calibration is independent of the stat calibrations
    // below and manages its own nonfatal window, so run it first (its exit
    // reset would otherwise silently end the window the stages below rely on).
    if (!g_pm_off_task_suspcount && discoverySafe)
        pm_calibrate_suspcount();
    // Same for the bsd_info back-pointer guard: independent, own nonfatal
    // window, capped retries. Arms the TOCTOU check used by every proc->task
    // path in the poll loop (stats / suspend_count / role).
    if (discoverySafe) pm_calibrate_bsdinfo();
    // App-switcher marking is disabled (see pm_calibrate_task_role) — call once
    // so the tried-flag is set, never per poll.
    if (!g_pm_role_tried)
        pm_calibrate_task_role();

    // Nonfatal for the whole calibration: this runs on a UI background queue
    // and a transient KRW hiccup (idle-detach race, reattach failure) must
    // degrade to a failed pass — never crash the app.
    krw_set_nonfatal(true);


    // Log the cache-load ONCE, not every poll. procmgr_calibrate() runs on
    // every process-viewer refresh; a per-poll log line here is one write every
    // couple of seconds, and each write trips the logger's F_FULLFSYNC — on APFS
    // that commits a full journal transaction, so a single steady-state line
    // amplifies into ~1 GB of disk writes over a long session and can trip a
    // silent disk-writes resource kill (no crash .ips, KRW left un-parked). The
    // steady-state poll must produce zero log writes.
    //
    // Load + validate ONCE per app run, not every poll: the offsets are fixed
    // for the boot, and re-running both every refresh cost an NSUserDefaults
    // read, a rewrite of every calibration global, and two full own-task
    // stat reads (thread walk included) per poll. Retried until validation
    // actually ran (it bails when KRW isn't ready).
    static bool sCacheChecked = false;
    static bool sCacheLoaded = false;
    if (!sCacheChecked) {
        // Load once; only the validation is retried. Reloading would clobber
        // offsets that the stages below rediscovered in the meantime.
        if (!sCacheLoaded && (sCacheLoaded = true) && pm_load_cache())
            printf("[PROCMGR] calibration loaded from cache (thr=%d cpu=%d mem=%d)\n",
                   g_pm_thr_cal, g_pm_cpu_cal, g_pm_mem_cal);
        // Don't trust the cache blindly: replay it against our own process and
        // drop whatever doesn't reproduce the userspace truth. Cleared flags are
        // recalibrated by the stages below and the fixed cache is re-saved.
        sCacheChecked = pm_validate_cache();
    }

    bool memPossible = ksafe_available();
    // "Settled" = succeeded or given up. CPU calibration needs the thread walk,
    // so a given-up thread stage settles CPU too.
    bool thrDone = g_pm_thr_cal || g_pm_thr_gaveup;
    bool cpuDone = g_pm_cpu_cal || g_pm_cpu_gaveup || g_pm_thr_gaveup;
    bool memDone = g_pm_mem_cal || g_pm_mem_gaveup || !memPossible;
    if (thrDone && cpuDone && memDone) {
        krw_set_nonfatal(false);
        return 1;
    }
    // The cached offsets above were checked against our own process only;
    // discovering new ones probes candidates and needs the gate.
    if (!discoverySafe) { krw_set_nonfatal(false); return 0; }
    if (!kexploit_krw_ready()) { krw_set_nonfatal(false); return 0; }

    uint64_t task = proc_task(proc_self());
    if (!procmgr_is_kern_ptr(task)) { krw_set_nonfatal(false); return 0; }

    // 1) Thread timers FIRST: the task-total match subtracts the live-thread
    //    sum, and per-process CPU stats need the same walk.
    for (int attempt = 0; attempt < 3 && !g_pm_thr_cal && !g_pm_thr_gaveup; attempt++) {
        if (pm_calibrate_thread_timers()) break;
        if (attempt < 2) usleep(50000);
    }
    if (!g_pm_thr_cal && !g_pm_thr_gaveup &&
        ++g_pm_thr_fail_passes >= PM_CPU_GIVEUP_PASSES) {
        g_pm_thr_gaveup = true;
        printf("[PROCMGR] thread calibration given up after %d passes — CPU column "
               "unavailable this session\n", g_pm_thr_fail_passes);
    }

    // 2) Task totals (terminated-thread counters) matched against
    //    proc_pidinfo minus the live-thread sum, with a deterministic
    //    dead-thread sample and a perturbation verify. Give up after a few
    //    failed passes so we stop running this expensive path on every poll.
    for (int attempt = 0; attempt < 3 && g_pm_thr_cal && !g_pm_cpu_cal && !g_pm_cpu_gaveup; attempt++) {
        if (pm_calibrate_task_totals(task)) break;
        if (attempt < 2) usleep(50000);
    }
    if (g_pm_thr_cal && !g_pm_cpu_cal && !g_pm_cpu_gaveup &&
        ++g_pm_cpu_fail_passes >= PM_CPU_GIVEUP_PASSES) {
        g_pm_cpu_gaveup = true;
        printf("[PROCMGR] cpu calibration given up after %d passes — CPU column "
               "unavailable this session\n", g_pm_cpu_fail_passes);
    }

    // 3) Memory (ledger physical footprint) — only with the mapped-check up.
    if (!g_pm_mem_cal && !g_pm_mem_gaveup && memPossible) {
        pm_calibrate_mem(task);
        if (!g_pm_mem_cal && ++g_pm_mem_fail_passes >= PM_CPU_GIVEUP_PASSES) {
            g_pm_mem_gaveup = true;
            printf("[PROCMGR] mem calibration given up after %d passes — memory "
                   "column falls back to libproc this session\n", g_pm_mem_fail_passes);
        }
    }

    pm_save_cache();
    // Log only on change: an unsettled stage reaches here every poll, and a
    // per-poll line is the F_FULLFSYNC disk-write pattern described above.
    static int sLoggedState = -1;
    int state = (g_pm_thr_cal ? 1 : 0) | (g_pm_cpu_cal ? 2 : 0) | (g_pm_mem_cal ? 4 : 0) |
                (memPossible ? 8 : 0);
    if (state != sLoggedState) {
        sLoggedState = state;
        if (!g_pm_mem_cal && !memPossible)
            printf("[PROCMGR] mem calibration deferred: ksafe unavailable\n");
        printf("[PROCMGR] calibration state: thr=%d cpu=%d mem=%d\n",
               g_pm_thr_cal, g_pm_cpu_cal, g_pm_mem_cal);
    }
    krw_set_nonfatal(false);
    return (g_pm_mem_cal || g_pm_cpu_cal) ? 1 : 0;
}

int procmgr_stats(int pid, uint64_t *residentBytes, uint64_t *cpuNs) {
    // libproc first — always works for our own pid (and others when permitted).
    struct pm_proc_taskinfo ti;
    bool havePI = proc_pidinfo(pid, PM_PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) >= (int)sizeof(ti);
    uint64_t mem = havePI ? ti.pti_resident_size : 0;
    uint64_t cpu = havePI ? pm_abs_to_ns(ti.pti_total_user + ti.pti_total_system) : 0;   // ticks → ns

    // Kernel reads (any pid) once calibrated — read-only, no privilege
    // needed. pm_kernel_stats double-reads every counter and only reports
    // values that survived the consistency check; a torn cycle falls back to
    // the libproc value instead of flashing garbage in the UI. Nonfatal: a
    // KRW hiccup during a UI poll must degrade, never crash. Gated on a live
    // session: detached sockets would zero-fill every read and poison the
    // deltas with garbage.
    krw_set_nonfatal(true);
    if (kexploit_krw_session_active() &&
        ((g_pm_mem_cal && ksafe_available()) || g_pm_thr_cal)) {
        uint64_t proc = proc_find(pid);
        if (procmgr_is_kern_ptr(proc)) {
            uint64_t task = proc_task(proc);
            // TOCTOU guard (round 14): the process can exit between the
            // allproc walk and this dereference. A freed-but-mapped task
            // still passes the kern-ptr range check (and a reused one reads
            // as valid garbage); a freed task on a zone page trimmed after
            // the one-time ksafe snapshot faults the KERNEL synchronously on
            // the first read. Verify the task's bsd_info back-pointer still
            // names THIS proc before touching ledgers/threads (uncalibrated
            // -> no verdict, read as before this guard existed).
            if (procmgr_is_kern_ptr(task) && pm_task_matches_proc(task, proc) != 0) {
                uint64_t kMem = 0, kCpu = 0;
                int kv = pm_kernel_stats(task, &kMem, &kCpu);
                // Re-verify after the reads: a death mid-read with fast task
                // reuse can tear past the double-read consistency checks.
                if (pm_task_matches_proc(task, proc) != 0) {
                    if (kv & 1) mem = kMem;
                    if ((kv & 2) && kCpu) cpu = kCpu;
                }
            }
        }
    }
    krw_set_nonfatal(false);

    if (mem == 0 && cpu == 0) return -1;
    if (residentBytes) *residentBytes = mem;
    if (cpuNs)         *cpuNs = cpu;
    return 0;
}

// One row of the Process Viewer from the proc pointer procmgr_list() found.
// Replaces the per-row procmgr_pstat_krw + procmgr_stats +
// procmgr_suspend_count trio, each of which re-walked allproc from the start
// (~2 kreads per proc, so a refresh was O(N^2) — ~400k kreads at 450
// processes) and re-ran the full kexploit_krw_ready() probe. Here: one
// mapped-check + p_pid re-validation, then a handful of direct reads inside
// a single krw batch (one lock hold, one repark). Same TOCTOU guards as the
// old path: bsd_info back-pointer before the task is used, re-checked after
// the stat reads; zombies / mid-reap p_stat skip the task entirely.
//
// The pointer is older than proc_find's would be (it comes from the list walk
// at the start of the pass), but the pass is now short, the proc can only be
// freed after exit AND reap, and p_pid is re-checked through the ksafe gate
// first. Net kernel-read exposure is ~100x lower than the walk-per-call path.
bool procmgr_row_info(uint64_t kproc, int pid, procmgr_row_info_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    out->pstat = -1;
    out->suspend_count = -1;
    if (!procmgr_is_kern_ptr(kproc) || !kexploit_krw_session_active()) return false;

    krw_set_nonfatal(true);
    bool batched = krw_batch_begin();
    bool valid = false;
    bool exiting = false;
    uint64_t kMem = 0, kCpu = 0;
    int kv = 0;
    do {
        // Gate the first dereference of the (possibly stale) proc pointer.
        uint32_t span = MAX(off_proc_p_pid + 4, off_proc_p_proc_ro + 8);
        if (off_proc_p_stat) span = MAX(span, off_proc_p_stat + 4);
        if (ksafe_available() && !kaddr_is_mapped(kproc, span)) break;
        if ((int)kread32(kproc + off_proc_p_pid) != pid) break;   // exited / recycled
        valid = true;

        if (off_proc_p_stat)
            out->pstat = (int)(kread32(kproc + off_proc_p_stat) & 0xFF);   // p_stat is a char
        // Zombie or mid-reap garbage (outside SIDL..SZOMB): task already torn
        // down — skip every task read (same convention as the kill verdict).
        exiting = (out->pstat == PM_SZOMB) ||
                  (out->pstat >= 0 && (out->pstat < 1 || out->pstat > 7));
        if (exiting) break;

        uint64_t task = proc_task(kproc);
        if (!procmgr_is_kern_ptr(task) || pm_task_matches_proc(task, kproc) == 0) {
            // The proc pointer still had this pid, but its task was torn down
            // or no longer belongs to it. That is not a live, usable row:
            // return false so the controller marks it exiting/non-selectable.
            valid = false;
            break;
        }

        if (!procmgr_process_reads_safe()) { valid = false; break; }

        if (g_pm_off_task_suspcount) {
            uint32_t sc = kread32(task + g_pm_off_task_suspcount);
            if (sc <= 64) out->suspend_count = (int)sc;     // >64 is implausible: torn/bad read
        }
        if ((g_pm_mem_cal && ksafe_available()) || g_pm_thr_cal) {
            uint64_t errorsBefore = krw_op_error_count();
            kv = pm_kernel_stats(task, &kMem, &kCpu);
            // Re-verify after the reads: a death mid-read with fast task
            // reuse can tear past the double-read consistency checks.
            if (pm_task_matches_proc(task, kproc) == 0) kv = 0;
            // A failed-safe read zero-fills silently; a zeroed word can still
            // pass the double-read checks (e.g. 0 == 0), so any read error
            // during the stats reads voids the kernel values for this row.
            if (krw_op_error_count() != errorsBefore) kv = 0;
        }
    } while (0);
    if (batched) krw_batch_end();
    krw_set_nonfatal(false);

    if (!valid || exiting) return valid;

    // libproc first (our own pid, or others when permitted), kernel values
    // override — same precedence as procmgr_stats.
    struct pm_proc_taskinfo ti;
    bool havePI = proc_pidinfo(pid, PM_PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) >= (int)sizeof(ti);
    uint64_t mem = havePI ? ti.pti_resident_size : 0;
    uint64_t cpu = havePI ? pm_abs_to_ns(ti.pti_total_user + ti.pti_total_system) : 0;   // ticks → ns
    if (kv & 1) mem = kMem;
    if ((kv & 2) && kCpu) cpu = kCpu;
    // A failed CPU read leaves cpu 0 (libproc is sandboxed for other pids).
    // It must not become the %CPU baseline: the next good read would turn the
    // process's whole lifetime CPU into one refresh interval (the 800% rows).
    out->have_cpu = cpu != 0;
    if (mem || cpu) {
        out->have_stats = true;
        out->mem = mem;
        out->cpu = cpu;
    }
    return true;
}

bool procmgr_pid_alive(int pid) {
    if (!kexploit_krw_ready()) return false;
    krw_set_nonfatal(true);
    bool alive = procmgr_is_kern_ptr(proc_find(pid));
    krw_set_nonfatal(false);
    return alive;
}

int procmgr_kill(int pid) {
    if (procmgr_pid_is_protected(pid)) return -1;
    if (!kexploit_krw_ready()) return -2;
    // Hard-stop by comm too (round 5): UI state is not the enforcement point.
    // FAIL CLOSED: a failed comm lookup must REFUSE, not skip the check —
    // SpringBoard/backboardd have ordinary pids, so a transient KRW read
    // failure would otherwise re-open the proven "initproc exited" panic vector.
    char killComm[64];
    if (procmgr_comm_for_pid(pid, killComm, sizeof(killComm)) != 0) {
        printf("[PROCMGR] kill: REFUSING pid %d — comm lookup failed, cannot "
               "verify it is not a protected process\n", pid);
        return -1;
    }
    if (procmgr_comm_is_protected(killComm)) {
        printf("[PROCMGR] kill: REFUSING protected process pid %d (%s)\n", pid, killComm);
        return -1;
    }

    // Legit route: SIGKILL. The kernel terminates the process (including
    // suspended tasks) cleanly. This is the only stable force-quit.
    if (kill(pid, SIGKILL) == 0) return 0;
    if (errno == ESRCH) return -3;

    // EPERM: the target is outside our signal permission. The crash-trick
    // fallback below (corrupting a thread's saved state) can panic the kernel —
    // if that thread is mid-syscall holding a mutex, its forced fault trips
    // "Mutex is unexpectedly not owned by thread" (lock_mtx.c) on 18.5. There is
    // no safe way to gate that from userspace, so it is DISABLED for stability.
    // Report permission-denied instead of risking a reboot; the caller
    // (SettingsViewController Force Quit) falls back to the launchd
    // RemoteCall session. Both middle rungs are proven dead on-device and
    // were removed: round 44's ucred-swap (proc_ro write-protected on 18.4+)
    // and round 45's unsandbox (MAC labels in read-only kalloc on SPTM
    // devices; the kwrite EFAULTs on 21D61 AND 22F76 — live 46/47).
    // Credential-adjacent kernel memory is not writable on 18.4+; the
    // launchd RemoteCall is the only privileged kill path.
    static const bool kEnableCrashKill = false;
    if (!kEnableCrashKill) return -6;   // no safe way to force-quit this one

    krw_set_nonfatal(true);     // the lookup reads below degrade, not crash
    uint64_t proc = proc_find(pid);
    if (!procmgr_is_kern_ptr(proc)) { krw_set_nonfatal(false); return -3; }
    uint64_t task = proc_task(proc);
    if (!procmgr_is_kern_ptr(task)) { krw_set_nonfatal(false); return -4; }
    uint64_t threads = kread64(task + off_task_threads_next);
    if (!procmgr_is_kern_ptr(threads)) { krw_set_nonfatal(false); return -4; }

    // The process can exit between the lookup above and the write below; the
    // write would then land in a freed/reused thread struct and corrupt the
    // kernel heap (suspected cause of a kernel_task data-abort panic on 18.5).
    // Re-verify the target before writing: the task's first thread must still
    // be the same pointer, and the thread must still be linked in the task's
    // thread list (off_thread_task_threads_next chain, like pm_live_thread_sums).
    if (kread64(task + off_task_threads_next) != threads) {
        krw_set_nonfatal(false);
        return -5;                          // thread list changed — exiting
    }
    bool linked = false;
    uint64_t t = threads;
    for (int i = 0; i < 256 && procmgr_is_kern_ptr(t); i++) {
        if (t == threads) { linked = true; break; }
        t = kread64(t + off_thread_task_threads_next);
    }
    if (!linked) { krw_set_nonfatal(false); return -5; }

    // Same technique as crash_process(): corrupt the first thread's saved-state
    // stack pointer so the process faults and is killed by the kernel.
    uint64_t upcb = kread64(threads + off_thread_machine_upcb);
    upcb = xpaci(upcb);
    uint64_t state = upcb + off_arm_saved_state_uss_ss_64;
    uint64_t spAddr = state + offsetof(struct arm_saved_state64, sp);
    if (ksafe_available() && !kaddr_is_mapped(spAddr, 8)) {
        krw_set_nonfatal(false);
        return -5;                          // target page went away — exiting
    }
    kwrite64(spAddr, 0x1337133713371337);
    krw_set_nonfatal(false);
    return 0;
}

int crash_process(const char* name) {
    uint64_t proc = proc_find_by_name(name);
    uint64_t task = proc_task(proc);
    
    uint64_t threads = kread64(task + off_task_threads_next);
    
    uint64_t upcb = kread64(threads + off_thread_machine_upcb);
    upcb = xpaci(upcb);
    
    uint64_t state = upcb + off_arm_saved_state_uss_ss_64;
    
    kwrite64(state + offsetof(struct arm_saved_state64, sp), 0x1337133713371337);
    
    return 0;
}

// xnu-10002.81.5/bsd/sys/proc.h
#define P_DISABLE_ASLR  0x00001000      /* Disable address space layout randomization */
int disable_aslr(void) {

    uint64_t launchd_proc = proc_find(1);
    uint32_t p_flag = kread32(launchd_proc + off_proc_p_flag);

    kwrite32(launchd_proc + off_proc_p_flag, p_flag | P_DISABLE_ASLR);

    return 0;
}

int enable_aslr(void) {

    uint64_t launchd_proc = proc_find(1);
    uint32_t p_flag = kread32(launchd_proc + off_proc_p_flag);

    kwrite32(launchd_proc + off_proc_p_flag, p_flag &~P_DISABLE_ASLR);

    return 0;
}
