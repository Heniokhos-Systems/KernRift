// Phase B.1.c+d+f — userland test for /dev/mlrift_pci.
//
// Build:  cc -O2 -o /tmp/mlrift_pci_test examples/mlrift_pci_test.c
// Run:    /tmp/mlrift_pci_test [BDF] [close]
//           default BDF: 0000:00:00.0
//           pass "close" as 2nd arg to issue MLRIFT_CLOSE_PCI on the
//           returned slot before exiting (exercises the explicit-close
//           path). Omit it to leave the slot open — then `rmmod` fires
//           the @module_exit teardown hook, which releases the leaked
//           pci_dev ref (look for "released open PCI device refs" in
//           dmesg). Before Phase B.1.f that ref leaked silently.
//
// Calls MLRIFT_OPEN_PCI on the given BDF. On success, prints the slot
// index (0..3) returned by the driver. On failure, prints errno.

#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>

// IOCTL numbers (must match examples/mlrift_pci.kr):
//   MLRIFT_OPEN_PCI  = _IOW('M', 1, char[13])
//                    = (1<<30) | (13<<16) | ('M'<<8) | 1 = 0x400D4D01
//   MLRIFT_CLOSE_PCI = _IO('M', 2) = ('M'<<8) | 2 = 0x00004D02
//                      (arg carries the slot index to release)
#define MLRIFT_OPEN_PCI  0x400D4D01u
#define MLRIFT_CLOSE_PCI 0x00004D02u

int main(int argc, char **argv) {
    const char *bdf = (argc >= 2) ? argv[1] : "0000:00:00.0";
    int do_close = (argc >= 3) && (strcmp(argv[2], "close") == 0);
    if (strlen(bdf) != 12) {
        fprintf(stderr, "BDF must be 12 chars (got %zu): %s\n", strlen(bdf), bdf);
        return 1;
    }
    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) { perror("open /dev/mlrift_pci"); return 1; }

    char buf[13] = {0};
    memcpy(buf, bdf, 12);

    long rc = ioctl(fd, MLRIFT_OPEN_PCI, buf);
    if (rc < 0) {
        fprintf(stderr, "MLRIFT_OPEN_PCI(%s): rc=%ld errno=%d (%s)\n",
                bdf, rc, errno, strerror(errno));
        close(fd);
        return 1;
    }
    long slot = rc;
    printf("MLRIFT_OPEN_PCI(%s) -> slot %ld\n", bdf, slot);

    if (do_close) {
        long crc = ioctl(fd, MLRIFT_CLOSE_PCI, slot);
        if (crc < 0) {
            fprintf(stderr, "MLRIFT_CLOSE_PCI(slot %ld): rc=%ld errno=%d (%s)\n",
                    slot, crc, errno, strerror(errno));
            close(fd);
            return 1;
        }
        printf("MLRIFT_CLOSE_PCI(slot %ld) -> ok (pci_dev ref released)\n", slot);
    } else {
        printf("slot %ld left open; `sudo rmmod mlrift_pci` will release it "
               "via the teardown hook\n", slot);
    }
    close(fd);
    return 0;
}
