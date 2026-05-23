// Phase B.1.c+d — userland test for /dev/mlrift_pci.
//
// Build:  cc -O2 -o /tmp/mlrift_pci_test examples/mlrift_pci_test.c
// Run:    /tmp/mlrift_pci_test [BDF]   (default BDF: 0000:00:00.0)
//
// Calls MLRIFT_OPEN_PCI on the given BDF. On success, prints the slot
// index (0..3) returned by the driver. On failure, prints errno.

#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>

// IOCTL number (must match examples/mlrift_pci.kr):
//   MLRIFT_OPEN_PCI = _IOW('M', 1, char[13])
//   = (1<<30) | (13<<16) | ('M'<<8) | 1 = 0x400D4D01
#define MLRIFT_OPEN_PCI 0x400D4D01u

int main(int argc, char **argv) {
    const char *bdf = (argc >= 2) ? argv[1] : "0000:00:00.0";
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
    printf("MLRIFT_OPEN_PCI(%s) -> slot %ld\n", bdf, rc);
    close(fd);
    return 0;
}
