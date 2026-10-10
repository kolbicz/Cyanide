//
//  process.h
//  Cyanide
//
//  Created by seo on 3/26/26.
//

#ifndef process_h
#define process_h

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

struct arm_saved_state64
{
  uint64_t x[29];
  uint64_t fp;
  uint64_t lr;
  uint64_t sp;
  uint64_t pc;
  uint32_t cpsr;
  uint32_t aspsr;
  uint64_t far;
  uint32_t esr;
  uint32_t exception;
  uint64_t jophash;
};

int crash_process(const char* name);
int watch_process(const char* name);

int disable_aslr(void);
int enable_aslr(void);

// --- Process Manager --------------------------------------------------------
typedef struct {
    int      pid;
    char     name[32];
    uint64_t kproc;     // struct proc address from the list walk (for procmgr_row_info)
} procmgr_entry_t;

// Enumerate live processes into entries[] (up to max). Returns the count, or
// -1 if kernel r/w is not currently armed, or if any read failed during the
// walk (a zero-filled link may have cut it short: the list is incomplete).
// Requires an active KRW session.
int procmgr_list(procmgr_entry_t *entries, int max);

// comm (as procmgr_comm_for_pid) plus the struct proc address currently
// registered for pid, for identity checks before a kill: a pid that exited and
// was reused by a new process gets a new struct proc. Returns 0 on success.
int procmgr_identity_for_pid(int pid, char *comm, size_t len, uint64_t *kprocOut);

// True if a process with this pid currently exists in the kernel proc list.
bool procmgr_pid_alive(int pid);

// Process state constants (p_stat) from xnu bsd/sys/proc.h. Defined here (not
// just in process.m) because the Process Viewer UI compares against them.
#define PM_SRUN  2   /* Currently runnable. */
#define PM_SSTOP 4   /* Process debugging or suspension. */
#define PM_SZOMB 5   /* Awaiting collection by parent. */

// Returns the proc's p_stat (PM_SRUN, PM_SSTOP, PM_SZOMB, ...) via libproc,
// or -1 when proc_pidinfo can't inspect the pid. Read-only, never crashes.
int procmgr_pstat(int pid);

// Same p_stat but read directly from struct proc via KRW — kernel ground
// truth (libproc can lag or misreport suspended apps). -1 when KRW or the
// pid is unavailable. Read-only.
int procmgr_pstat_krw(int pid);

// Round 13: both kill-verdict inputs from ONE allproc walk — *outPresent gets
// whether the pid is still in the proc list, and the return value is its
// p_stat (-1 when KRW/the offset/the pid is unavailable). Replaces a
// procmgr_pid_alive + procmgr_pstat_krw pair (two walks) on the kill path.
// *outKnown is true only when the walk really ran with every read succeeding:
// when false (KRW not ready, or a read failed safely and was zero-filled),
// "not present" means "could not check", NOT "the process is gone".
int procmgr_pid_status_krw(int pid, bool *outPresent, bool *outKnown);

// Runtime-calibrated task->suspend_count for pid. Returns -1 when
// uncalibrated/unavailable, else the count (>0 means the task is suspended:
// iOS-preloaded or background-suspended apps). Read-only.
int procmgr_suspend_count(int pid);

// Runtime-calibrated offsetof(task, thread_count), or -1 when uncalibrated.
// Derived by the suspend_count calibration above (task layout: thread_count,
// active_thread_count, suspend_count consecutive, so thread_count sits at
// suspend_count - 8), which proves the offset unique against our own task and
// cross-checks it against launchd's — never a hardcoded guess. Read-only.
int procmgr_task_thread_count_offset(void);

// Mach task-category role for pid: TASK_UNSPECIFIED(0) for daemons,
// TASK_FOREGROUND_APPLICATION(1) for the frontmost UI app,
// TASK_BACKGROUND_APPLICATION(2) for a backgrounded UI app (i.e. in the app
// switcher), and so on. -1 when uncalibrated/unavailable. Read-only; the field
// offset is self-calibrated by flipping our own role once and seeing which
// task-struct nibble moves. Same GUI-app signal CocoaTop shows.
int procmgr_task_role(int pid);
bool procmgr_role_is_foreground(int role);  // frontmost UI app
bool procmgr_role_is_switcher(int role);    // backgrounded UI app (in switcher)
bool procmgr_role_is_app(int role);         // either of the above (a GUI app)

// Classify a process by its executable path, read via KRW (proc->p_textvp →
// vnode v_parent/v_name walk) and cached per pid for the app run.
// Returns PM_KIND_APP for user-facing apps (.../containers/Bundle/Application/
// or /Applications/), PM_KIND_SERVICE for daemons/services — also the default
// when the path can't be read. Read-only, never crashes.
#define PM_KIND_APP     1
#define PM_KIND_SERVICE 0
int procmgr_exe_kind(int pid);

// Force-quit a process by pid via thread saved-state corruption (KRW). Returns
// 0 on success; negative on refusal/error:
//   -1 protected pid (0/1)  -2 KRW not ready  -3 proc not found
//   -4 task/thread unavailable
int procmgr_kill(int pid);

// A pid that must never be force-quit (kernel_task, launchd) — the UI greys
// these out. Returns true if pid is in the protected set.
bool procmgr_pid_is_protected(int pid);

// comm-based kill protection (round 5): launchd / SpringBoard / backboardd.
// A SpringBoard kill delivered from inside launchd panicked an iOS 17.3.1
// device with "initproc exited" — never offer or perform these kills.
bool procmgr_comm_is_protected(const char *comm);

// Resolve a pid's comm via KRW into buf ("" on failure, returns -1). A failed
// lookup is not proof of safety — keep the pid checks regardless.
int procmgr_comm_for_pid(int pid, char *buf, size_t len);

// Borrow launchd's credentials (root + unsandboxed) by pointing our own
// proc_ro->p_ucred at them, so libproc can read stats for every process. Saves
// the original and self-checks the write took. Returns 0 on success; negative
// if KRW isn't ready or proc_ro couldn't be written. Idempotent.
// Round 45: UNUSED — proc_ro is write-protected on 18.4+ and the p_ucred
// write EFAULTs (live 46, 22F76). Kept for reference; do not re-add to the
// kill path on 18.4+. Use procmgr_unsandbox() instead.
int procmgr_escalate(void);
// Restore our original credentials. Safe to call when not escalated.
void procmgr_deescalate(void);
// True if this process currently has root (the escalation is in effect).
bool procmgr_is_escalated(void);

// Temporarily remove our own sandbox so proc_pidinfo can read OTHER same-user
// processes (the sandbox process-info gate blocks it otherwise). This writes the
// sandbox slot in our cred LABEL to 0. Saves the original; resandbox
// restores it. Returns 0 on success, negative on failure. Idempotent.
// Round 46: UNUSED — proven dead on-device (live 46/47): MAC labels live in
// read-only kalloc on SPTM devices; the kwrite EFAULTs (errno 14) on BOTH
// 21D61 and 22F76 (reads succeed — only the write is blocked). Kept for
// reference; do not re-add to the kill path on 18.4+.
int procmgr_unsandbox(void);
void procmgr_resandbox(void);

// Self-calibrate kernel-struct offsets by reading OUR OWN process's known stats
// (proc_pidinfo / thread_info / proc_pid_rusage) and scanning our own kernel
// structs for the matching values. Read-only, version-independent, no writes.
// On first call per session it lazily snapshots kernel_map's entry list once
// to bring up the mapped-check (ksafe), which gates every ledger-pointer
// dereference for the memory path. Results are cached in NSUserDefaults per
// OS build. Call once per session after KRW is ready (reloadProcs does this
// on a background queue); safe to call again — failed steps retry, succeeded
// steps are cached.
// Returns nonzero if at least one of memory/CPU calibration succeeded.
int  procmgr_calibrate(void);
// True when the memory (ledger footprint) path is fully usable: offsets
// calibrated AND the mapped-check is up this session.
bool procmgr_mem_calibrated(void);
// True when the CPU path is fully usable: thread-timer AND task-total offsets
// calibrated (live-thread sum + terminated-thread counters).
bool procmgr_cpu_calibrated(void);

// Per-process stats. libproc first (own pid, or others when permitted), then
// read-only KRW fallbacks for any pid once calibrated: memory from the task's
// ledger physical-footprint entry (mapped-checked), CPU from the task's
// terminated-thread totals PLUS the sum of live threads' timer t_sums.
// Fills residentBytes (physical memory) and cpuNs (cumulative user+system CPU
// time in nanoseconds). Returns 0 on success, negative on error.
int procmgr_stats(int pid, uint64_t *residentBytes, uint64_t *cpuNs);

// Everything the Process Viewer needs for one row, read from the proc pointer
// procmgr_list() already found — no per-call allproc walk (procmgr_pstat_krw /
// procmgr_stats / procmgr_suspend_count each re-walk the whole list) and no
// per-call kexploit_krw_ready() probe. The caller must have verified KRW once
// for the pass. The pointer is re-validated (p_pid must still equal pid)
// before anything else is read; returns false when it no longer names pid or
// its task guard fails (exited / recycled / tearing down) — the row should then
// be shown as exiting and treated as unusable.
typedef struct {
    int      pstat;          // p_stat, -1 when unavailable
    int      suspend_count;  // -1 when uncalibrated/unavailable
    bool     have_stats;     // mem and/or cpu valid
    bool     have_cpu;       // cpu is a real reading THIS pass (not a 0 fill)
    uint64_t mem;            // physical footprint, bytes
    uint64_t cpu;            // cumulative user+system CPU, ns
} procmgr_row_info_t;
bool procmgr_row_info(uint64_t kproc, int pid, procmgr_row_info_t *out);

#endif /* process_h */
