// B.2.b test: open a PCI device, mmap its BAR0, verify the mapping
// succeeds. Does NOT read the mapped MMIO (safe).
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#define MLRIFT_OPEN_PCI 0x400D4D01u
int main(int argc, char**argv){
    const char*bdf = argc>=2?argv[1]:"0000:03:00.0";
    int fd=open("/dev/mlrift_pci",O_RDWR);
    if(fd<0){perror("open");return 1;}
    char buf[13]={0}; memcpy(buf,bdf,12);
    long slot=ioctl(fd,MLRIFT_OPEN_PCI,buf);
    if(slot<0){fprintf(stderr,"OPEN_PCI(%s) rc=%ld errno=%d %s\n",bdf,slot,errno,strerror(errno));close(fd);return 1;}
    printf("OPEN_PCI(%s) -> slot %ld\n",bdf,slot);
    void*p=mmap(NULL,4096,PROT_READ,MAP_SHARED,fd,0);
    if(p==MAP_FAILED){fprintf(stderr,"mmap BAR0 failed: errno=%d %s\n",errno,strerror(errno));close(fd);return 1;}
    printf("mmap BAR0 -> %p (mapping succeeded; NOT reading MMIO)\n",p);
    munmap(p,4096);
    close(fd);
    return 0;
}
