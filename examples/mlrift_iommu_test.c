// Phase B.3.c — userland test for MLRIFT_IOMMU_MAP / _UNMAP.
//
// Build:  cc -O2 -o /tmp/mlrift_iommu_test examples/mlrift_iommu_test.c
// Run:    /tmp/mlrift_iommu_test [BDF] [size] [iova]
//           default BDF  = 0000:03:00.0
//           default size = 16384 (4 pages)
//           default iova = 0x100000000 (4 GiB, page-aligned)
//
// PREREQUISITE: the target device must be UNBOUND from vfio-pci first,
// so the driver can attach its own IOMMU paging domain:
//   echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
// (If still bound, IOMMU_MAP returns -EIO and dmesg says so — no crash.)
//
// Flow: OPEN_PCI -> mmap+fault a buffer -> IOMMU_MAP (driver allocs +
// attaches a paging domain, pins, maps at `iova`, returns the backing
// phys via iommu_iova_to_phys) -> IOMMU_UNMAP -> CLOSE_PCI.

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define MLRIFT_OPEN_PCI    0x400D4D01u   // _IOW('M',1,char[13])
#define MLRIFT_CLOSE_PCI   0x00004D02u   // _IO('M',2)
#define MLRIFT_IOMMU_MAP   0x40184D04u   // _IOW('M',4,char[24])
#define MLRIFT_IOMMU_UNMAP 0x40104D05u   // _IOW('M',5,char[16])

struct map_req   { uint64_t uaddr; uint64_t iova; uint64_t size; };
struct unmap_req { uint64_t iova;  uint64_t size; };

int main(int argc, char **argv) {
    const char *bdf = (argc >= 2) ? argv[1] : "0000:03:00.0";
    size_t   size   = (argc >= 3) ? strtoul(argv[2], NULL, 0) : 16384;
    uint64_t iova   = (argc >= 4) ? strtoull(argv[3], NULL, 0) : 0x100000000ULL;

    if (strlen(bdf) != 12) { fprintf(stderr, "BDF must be 12 chars\n"); return 1; }

    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) { perror("open /dev/mlrift_pci"); return 1; }

    char bdfbuf[13] = {0};
    memcpy(bdfbuf, bdf, 12);
    long slot = ioctl(fd, MLRIFT_OPEN_PCI, bdfbuf);
    if (slot < 0) { fprintf(stderr, "OPEN_PCI rc=%ld errno=%d (%s)\n", slot, errno, strerror(errno)); close(fd); return 1; }
    printf("OPEN_PCI(%s) -> slot %ld\n", bdf, slot);

    void *buf = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    memset(buf, 0xCD, size);   // fault pages in

    struct map_req mreq = { (uint64_t)(uintptr_t)buf, iova, (uint64_t)size };
    long phys = ioctl(fd, MLRIFT_IOMMU_MAP, &mreq);
    if (phys < 0) {
        fprintf(stderr, "IOMMU_MAP rc=%ld errno=%d (%s)\n", phys, errno, strerror(errno));
        fprintf(stderr, "  (if errno=EIO, the device is probably still bound to vfio-pci)\n");
        munmap(buf, size); close(fd); return 1;
    }
    printf("IOMMU_MAP uaddr=%p iova=0x%llx size=%zu -> iova_to_phys=0x%lx\n",
           buf, (unsigned long long)iova, size, phys);
    if (phys == 0) {
        fprintf(stderr, "  WARNING: iova_to_phys returned 0 — mapping did NOT resolve!\n");
    } else {
        printf("  OK: the IOMMU resolves iova 0x%llx -> phys 0x%lx (mapping live)\n",
               (unsigned long long)iova, phys);
    }

    struct unmap_req ureq = { iova, (uint64_t)size };
    long urc = ioctl(fd, MLRIFT_IOMMU_UNMAP, &ureq);
    if (urc < 0) { fprintf(stderr, "IOMMU_UNMAP rc=%ld errno=%d (%s)\n", urc, errno, strerror(errno)); }
    else         { printf("IOMMU_UNMAP iova=0x%llx -> ok\n", (unsigned long long)iova); }

    long crc = ioctl(fd, MLRIFT_CLOSE_PCI, slot);
    if (crc < 0) { fprintf(stderr, "CLOSE_PCI rc=%ld errno=%d (%s)\n", crc, errno, strerror(errno)); }
    else         { printf("CLOSE_PCI(slot %ld) -> ok\n", slot); }

    munmap(buf, size);
    close(fd);
    return 0;
}
