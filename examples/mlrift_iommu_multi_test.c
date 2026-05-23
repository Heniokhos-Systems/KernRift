// Phase B.3 follow-up — multi-mapping test for /dev/mlrift_pci.
//
// Build: cc -O2 -o /tmp/mlrift_iommu_multi_test examples/mlrift_iommu_multi_test.c
// Run:   /tmp/mlrift_iommu_multi_test [BDF]   (default 0000:03:00.0)
//
// PREREQUISITE: target device unbound from vfio-pci (see mlrift_iommu_test.c).
//
// Exercises the mapping table: maps 4 buffers concurrently at distinct
// IOVAs, checks each resolves to a distinct phys, verifies duplicate-IOVA
// rejection (-EBUSY), unmaps two in the middle, re-maps a freed slot, then
// unmaps the rest. Closes (which also tears down the domain).

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define MLRIFT_OPEN_PCI    0x400D4D01u
#define MLRIFT_CLOSE_PCI   0x00004D02u
#define MLRIFT_IOMMU_MAP   0x40184D04u
#define MLRIFT_IOMMU_UNMAP 0x40104D05u

struct map_req   { uint64_t uaddr; uint64_t iova; uint64_t size; };
struct unmap_req { uint64_t iova;  uint64_t size; };

#define N 4

int main(int argc, char **argv) {
    const char *bdf = (argc >= 2) ? argv[1] : "0000:03:00.0";
    if (strlen(bdf) != 12) { fprintf(stderr, "BDF must be 12 chars\n"); return 1; }

    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) { perror("open /dev/mlrift_pci"); return 1; }

    char bdfbuf[13] = {0};
    memcpy(bdfbuf, bdf, 12);
    long slot = ioctl(fd, MLRIFT_OPEN_PCI, bdfbuf);
    if (slot < 0) { fprintf(stderr, "OPEN_PCI rc=%ld (%s)\n", slot, strerror(errno)); close(fd); return 1; }
    printf("OPEN_PCI(%s) -> slot %ld\n", bdf, slot);

    size_t   sizes[N] = { 4096, 16384, 65536, 8192 };
    void    *bufs[N];
    uint64_t iovas[N];
    long     physes[N];
    int fail = 0;

    // Map N buffers at distinct IOVAs (256 MiB apart).
    for (int i = 0; i < N; i++) {
        bufs[i] = mmap(NULL, sizes[i], PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (bufs[i] == MAP_FAILED) { perror("mmap"); return 1; }
        memset(bufs[i], 0xE0 + i, sizes[i]);
        iovas[i] = 0x100000000ULL + (uint64_t)i * 0x10000000ULL;
        struct map_req m = { (uint64_t)(uintptr_t)bufs[i], iovas[i], sizes[i] };
        physes[i] = ioctl(fd, MLRIFT_IOMMU_MAP, &m);
        if (physes[i] <= 0) {
            fprintf(stderr, "MAP[%d] iova=0x%llx FAILED rc=%ld (%s)\n",
                    i, (unsigned long long)iovas[i], physes[i], strerror(errno));
            fail = 1;
        } else {
            printf("MAP[%d] iova=0x%llx size=%zu -> phys=0x%lx\n",
                   i, (unsigned long long)iovas[i], sizes[i], physes[i]);
        }
    }

    // Distinct phys check.
    for (int i = 0; i < N; i++)
        for (int j = i + 1; j < N; j++)
            if (physes[i] > 0 && physes[i] == physes[j]) {
                fprintf(stderr, "  FAIL: MAP[%d] and MAP[%d] share phys 0x%lx\n", i, j, physes[i]);
                fail = 1;
            }

    // Duplicate-IOVA rejection: re-map iova[0] -> expect failure (-EBUSY).
    {
        struct map_req m = { (uint64_t)(uintptr_t)bufs[0], iovas[0], sizes[0] };
        long rc = ioctl(fd, MLRIFT_IOMMU_MAP, &m);
        if (rc >= 0) { fprintf(stderr, "  FAIL: duplicate iova 0x%llx was accepted (rc=%ld)\n",
                               (unsigned long long)iovas[0], rc); fail = 1; }
        else         { printf("dup iova 0x%llx correctly rejected (errno=%d %s)\n",
                              (unsigned long long)iovas[0], errno, strerror(errno)); }
    }

    // Unmap the two middle mappings (mixed order: 2 then 1).
    for (int k = 0; k < 2; k++) {
        int i = (k == 0) ? 2 : 1;
        struct unmap_req u = { iovas[i], sizes[i] };
        long rc = ioctl(fd, MLRIFT_IOMMU_UNMAP, &u);
        if (rc < 0) { fprintf(stderr, "UNMAP[%d] FAILED rc=%ld (%s)\n", i, rc, strerror(errno)); fail = 1; }
        else        { printf("UNMAP[%d] iova=0x%llx -> ok\n", i, (unsigned long long)iovas[i]); }
    }

    // Re-map a freed slot (iova[1] again) -> should succeed now.
    {
        struct map_req m = { (uint64_t)(uintptr_t)bufs[1], iovas[1], sizes[1] };
        long rc = ioctl(fd, MLRIFT_IOMMU_MAP, &m);
        if (rc <= 0) { fprintf(stderr, "  FAIL: re-map of freed iova 0x%llx rejected rc=%ld (%s)\n",
                               (unsigned long long)iovas[1], rc, strerror(errno)); fail = 1; }
        else         { printf("re-map iova=0x%llx -> phys=0x%lx (slot reused)\n",
                              (unsigned long long)iovas[1], rc); }
    }

    // Unmap remaining (0, 1, 3); close tears down anything left anyway.
    int rest[3] = { 0, 1, 3 };
    for (int r = 0; r < 3; r++) {
        struct unmap_req u = { iovas[rest[r]], sizes[rest[r]] };
        long rc = ioctl(fd, MLRIFT_IOMMU_UNMAP, &u);
        if (rc < 0) fprintf(stderr, "UNMAP[%d] rc=%ld (%s)\n", rest[r], rc, strerror(errno));
    }

    long crc = ioctl(fd, MLRIFT_CLOSE_PCI, slot);
    printf("CLOSE_PCI(slot %ld) -> %s\n", slot, crc < 0 ? strerror(errno) : "ok");

    for (int i = 0; i < N; i++) munmap(bufs[i], sizes[i]);
    close(fd);
    printf(fail ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return fail;
}
