// Phase B.3.b — userland test for MLRIFT_PIN_TEST.
//
// Build:  cc -O2 -o /tmp/mlrift_pin_test examples/mlrift_pin_test.c
// Run:    /tmp/mlrift_pin_test [size_bytes]   (default 16384 = 4 pages)
//
// mmaps an anonymous buffer, faults it in, and asks the driver to pin it
// + build a scatter-gather table. The driver returns the SG segment
// count (orig_nents) and tears everything back down. This exercises
// pin_user_pages_fast + the 7-arg sg_alloc_table_from_pages_segment in
// kernel context WITHOUT any IOMMU or device access — safe to run with
// the dGPU still bound to vfio-pci.

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

// _IOW('M', 3, char[16]) = (1<<30)|(16<<16)|('M'<<8)|3 = 0x40104D03
#define MLRIFT_PIN_TEST 0x40104D03u

struct pin_req { uint64_t uaddr; uint64_t size; };

int main(int argc, char **argv) {
    size_t size = (argc >= 2) ? strtoul(argv[1], NULL, 0) : 16384;
    if (size == 0) { fprintf(stderr, "size must be > 0\n"); return 1; }

    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) { perror("open /dev/mlrift_pci"); return 1; }

    void *buf = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    memset(buf, 0xAB, size);   // fault the pages in before pinning

    struct pin_req req = { (uint64_t)(uintptr_t)buf, (uint64_t)size };
    long rc = ioctl(fd, MLRIFT_PIN_TEST, &req);
    if (rc < 0) {
        fprintf(stderr, "MLRIFT_PIN_TEST rc=%ld errno=%d (%s)\n",
                rc, errno, strerror(errno));
        munmap(buf, size); close(fd);
        return 1;
    }
    printf("MLRIFT_PIN_TEST(uaddr=%p size=%zu, %zu pages) -> sg orig_nents=%ld\n",
           buf, size, (size + 4095) / 4096, rc);
    printf("(pinned + SG table built + freed in kernel; no IOMMU touched)\n");

    munmap(buf, size);
    close(fd);
    return 0;
}
