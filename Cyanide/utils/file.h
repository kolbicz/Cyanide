//
//  file.h
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#ifndef file_h
#define file_h

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/types.h>

// xnu-10002.81.5/bsd/sys/vnode_internal.h
#define VISSHADOW       0x008000        /* vnode is a shadow file */
// xnu-10002.81.5/bsd/sys/mount.h
#define MNT_RDONLY      0x00000001      /* read only filesystem */

uint64_t hide_path(const char* path);
uint64_t reveal_path_by_vnode(uint64_t vnode);
int zero_system_file_page(const char* path, off_t offset);

#endif /* file_h */
