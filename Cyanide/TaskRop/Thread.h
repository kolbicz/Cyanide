//
//  Thread.h
//  Cyanide
//
//  Created by seo on 4/4/26.
//

#import <stdbool.h>
#import <stdint.h>

#import "RemoteCall.h"

bool inject_guard_exception(uint64_t thread, uint64_t code);
// Un-arms a thread we armed. Returns true when the thread is verifiably NOT
// armed afterwards (cleared, or already unarmed); false when it could not be
// checked or the clear did not take (it may still carry our guard).
bool clear_guard_exception(uint64_t thread);
bool thread_get_state_wrapper(mach_port_t machThread, arm_thread_state64_internal *outState);
bool thread_set_state_wrapper(mach_port_t machThread, uint64_t threadAddr, arm_thread_state64_internal *state);
bool thread_resume_wrapper(mach_port_t machThread);
void thread_set_pac_keys(uint64_t threadAddr, uint64_t keyA, uint64_t keyB);
