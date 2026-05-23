// Phase B.4 — userland test for MSI-X interrupts on /dev/mlrift_pci.
//
// Build: cc -O2 -o /tmp/mlrift_irq_test examples/mlrift_irq_test.c
// Run:   /tmp/mlrift_irq_test [BDF]   (default 0000:03:00.0)
//
// PREREQUISITE: dGPU unbound from vfio-pci + mlrift_pci.ko loaded. Root.
//
// Flow: OPEN -> IRQ_ENABLE (allocate MSI-X vectors) -> create an eventfd
// -> IRQ_SET_EVENTFD(vector 0) (registers the hard-IRQ handler) ->
// IRQ_FIRE_TEST(0) (driver software-signals the eventfd, exactly as the
// hard-IRQ handler would) -> read the eventfd and confirm the counter ->
// IRQ_DISABLE -> CLOSE.
//
// This validates MSI-X allocation, IRQ registration, and the userland
// notification path end-to-end. A REAL hardware interrupt (the GPU
// firing the vector) validates later, once the GPU is doing work — the
// handler makes the identical eventfd_signal_mask call FIRE_TEST does.

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/eventfd.h>

#define MLRIFT_OPEN_PCI        0x400D4D01u
#define MLRIFT_CLOSE_PCI       0x00004D02u
#define MLRIFT_IRQ_ENABLE      0x40044D07u
#define MLRIFT_IRQ_SET_EVENTFD 0x40084D08u
#define MLRIFT_IRQ_DISABLE     0x00004D09u
#define MLRIFT_IRQ_FIRE_TEST   0x40044D0Au

struct set_eventfd { uint32_t vector; uint32_t efd; };

int main(int argc, char **argv) {
    const char *bdf = (argc >= 2) ? argv[1] : "0000:03:00.0";
    if (strlen(bdf) != 12) { fprintf(stderr, "BDF must be 12 chars\n"); return 1; }

    int fd = open("/dev/mlrift_pci", O_RDWR);
    if (fd < 0) { perror("open /dev/mlrift_pci"); return 1; }

    char bdfbuf[13] = {0};
    memcpy(bdfbuf, bdf, 12);
    if (ioctl(fd, MLRIFT_OPEN_PCI, bdfbuf) < 0) {
        fprintf(stderr, "OPEN_PCI errno=%d (%s)\n", errno, strerror(errno)); close(fd); return 1;
    }
    printf("OPEN_PCI(%s) ok\n", bdf);

    uint32_t want = 4;
    long nvec = ioctl(fd, MLRIFT_IRQ_ENABLE, &want);
    if (nvec < 0) {
        fprintf(stderr, "IRQ_ENABLE errno=%d (%s)\n", errno, strerror(errno));
        ioctl(fd, MLRIFT_CLOSE_PCI, 0); close(fd); return 1;
    }
    printf("IRQ_ENABLE(req %u) -> %ld MSI-X vectors allocated\n", want, nvec);

    int efd = eventfd(0, EFD_NONBLOCK);
    if (efd < 0) { perror("eventfd"); ioctl(fd, MLRIFT_IRQ_DISABLE, 0); ioctl(fd, MLRIFT_CLOSE_PCI, 0); close(fd); return 1; }

    struct set_eventfd se = { 0, (uint32_t)efd };
    if (ioctl(fd, MLRIFT_IRQ_SET_EVENTFD, &se) < 0) {
        fprintf(stderr, "IRQ_SET_EVENTFD errno=%d (%s)\n", errno, strerror(errno));
        close(efd); ioctl(fd, MLRIFT_IRQ_DISABLE, 0); ioctl(fd, MLRIFT_CLOSE_PCI, 0); close(fd); return 1;
    }
    printf("IRQ_SET_EVENTFD(vector 0) ok (handler registered)\n");

    // Confirm the eventfd is empty pre-fire.
    uint64_t cnt = 0;
    if (read(efd, &cnt, 8) >= 0) { fprintf(stderr, "WARN: eventfd had data before fire (%llu)\n", (unsigned long long)cnt); }

    uint32_t vec = 0;
    if (ioctl(fd, MLRIFT_IRQ_FIRE_TEST, &vec) < 0) {
        fprintf(stderr, "IRQ_FIRE_TEST errno=%d (%s)\n", errno, strerror(errno));
        close(efd); ioctl(fd, MLRIFT_IRQ_DISABLE, 0); ioctl(fd, MLRIFT_CLOSE_PCI, 0); close(fd); return 1;
    }

    cnt = 0;
    int fail = 0;
    if (read(efd, &cnt, 8) != 8) { fprintf(stderr, "FAIL: eventfd read got nothing after fire\n"); fail = 1; }
    else if (cnt != 1)            { fprintf(stderr, "FAIL: eventfd counter=%llu (want 1)\n", (unsigned long long)cnt); fail = 1; }
    else                           { printf("IRQ_FIRE_TEST -> eventfd notified (counter=1)\n"); }

    close(efd);
    ioctl(fd, MLRIFT_IRQ_DISABLE, 0);
    printf("IRQ_DISABLE ok\n");
    ioctl(fd, MLRIFT_CLOSE_PCI, 0);
    close(fd);
    printf(fail ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return fail;
}
