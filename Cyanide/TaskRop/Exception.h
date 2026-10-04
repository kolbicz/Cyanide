//
//  Exception.h
//  Cyanide
//
//  Created by seo on 4/4/26.
//

#import <mach/mach.h>
#import "RemoteCall.h"

// from pe_main.js
typedef struct {
    mach_msg_header_t       Head;
    uint64_t                NDR;
    uint32_t                exception;
    uint32_t                codeCnt;
    uint64_t                codeFirst;
    uint64_t                codeSecond;
    uint32_t                flavor;
    uint32_t                old_stateCnt;
    arm_thread_state64_internal    threadState;
    uint64_t                padding[2];
} ExceptionMessage;

typedef struct {
    mach_msg_header_t   Head;
    uint64_t            NDR;
    uint32_t            RetCode;
    uint32_t            flavor;
    uint32_t            new_stateCnt;
    arm_thread_state64_internal threadState;
} __attribute__((packed)) ExceptionReply;

mach_port_t create_exception_port(void);
void destroy_exception_port(mach_port_t exceptionPort);
bool wait_exception(mach_port_t exceptionPort, ExceptionMessage *excBuffer, int timeout, bool debug);
void reply_with_state(ExceptionMessage *exc, arm_thread_state64_internal *state);

// ---- Round 21 (panics 1+3, Cyanide<->runningboardd ABBA) -------------------
// Own-process exception-port traps (thread_set_exception_ports family) can
// deadlock ABBA against runningboardd's task_policy_set on this task: our
// thread inside the trap (AMFI getOSEntitlementsFromProcSecure path) holds
// one lock while rbd's policy thread holds the other and waits for ours.
// rbd policy-manages this task around LIFECYCLE transitions, so the defensive
// surface is: (1) never INITIATE such a trap while the app is backgrounded or
// terminating, and (2) serialize all of them process-wide so two of our
// threads are never inside the trap family at once. Lifecycle hooks feed the
// gate; the trap sites (PAC signing, RemoteCall thread arming) go through
// excport_op_begin/end.
void excport_gate_set_backgrounded(bool backgrounded);
void excport_gate_set_terminating(void);
// True when exception-port traps must not be initiated.
bool excport_gate_blocked(void);
// Round 31: snapshot of the two gate flags for the early launch trace
// (cyanide_launch_trace). Pure atomic reads, no locking, no printf — safe
// from main() before any app machinery exists.
void excport_gate_snapshot(int *backgrounded, int *terminating);
// Begin one serialized exception-port operation. Returns false (clean
// refusal, never spin) when the gate is blocked. Every true return MUST be
// paired with excport_op_end().
bool excport_op_begin(const char *what);
void excport_op_end(void);
// ---- Round 22-regression: teardown bypass ----------------------------------
// The gate exists to stop INITIATING exception-port traps against a
// backgrounded/terminating app (the runningboardd ABBA). But teardown is
// different: the drain's trojan restore and the synthetic exit dispatch must
// sign states through the gate precisely when the gate is blocked — refusing
// them strands launchd threads parked at protocol sentinels on ports that
// are seconds from destruction (the 123329/123448 SIGKILL-of-launchd panics).
// destroy_remote_call()/abandon_remote_call() wrap their bodies with
// begin/end; every true begin MUST be paired with end. Re-entrant (depth
// counter) so nested teardown paths stay correct.
void excport_teardown_bypass_begin(const char *where);
void excport_teardown_bypass_end(const char *where);
