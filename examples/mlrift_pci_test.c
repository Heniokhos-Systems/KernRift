// Phase B.1.c — userland test for /dev/mlrift_pci.
// Builds with: cc -O2 -o /tmp/mlrift_pci_test /tmp/mlrift_pci_test.c
//
// Opens /dev/mlrift_pci, calls one IOCTL, prints the return value.
// The kernel-side handler in our LKM logs "mlrift_pci: ioctl called"
// to dmesg and returns 0 — so this program prints "ioctl rc=0".

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>

// MLRIFT_ECHO = _IOWR('M', 1, unsigned long) for the future B.1.d
// shape. For now any number reaches our handler (which ignores cmd).
#define MLRIFT_ECHO 0xC0084D01u

int main(void) {
    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mlrift_pci: %s\n", strerror(errno));
        return 1;
    }
    unsigned long arg = 42;
    long rc = ioctl(fd, MLRIFT_ECHO, &arg);
    printf("ioctl rc=%ld errno=%d (%s)\n", rc, errno, rc < 0 ? strerror(errno) : "ok");
    close(fd);
    return 0;
}
