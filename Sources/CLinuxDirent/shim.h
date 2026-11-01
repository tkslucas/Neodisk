#ifndef NEODISK_CLINUXDIRENT_SHIM_H
#define NEODISK_CLINUXDIRENT_SHIM_H

#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

// getdents64 straight into a caller-owned buffer: Swift can't call the variadic syscall(2), and glibc only
// declares getdents64() under _GNU_SOURCE.
static inline ssize_t neodisk_getdents64(int fd, void *buffer, size_t length) {
    return (ssize_t)syscall(SYS_getdents64, fd, buffer, length);
}

#endif
