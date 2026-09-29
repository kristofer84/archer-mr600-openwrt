/*
 * flash0 - read/write the MR600 v1's raw SPI flash through the vendor device
 * /dev/flash0 (drivers/mtd/ralink/ralink_bbu_spi.c). Bypasses MTD and its
 * read-only partition flags; the only bound is the whole chip.
 *
 * ioctl numbers and struct from the shipped driver (GPL source lines 1760/1771):
 *   #define FLASH_IOCTL_READ   (0x01)
 *   #define FLASH_IOCTL_WRITE  (0x02)
 *   struct flash_opt { unsigned int *src; unsigned int *dest;
 *                      unsigned int bytes; unsigned int start_addr;
 *                      unsigned int end_addr; int result; };
 *
 * WRITE semantics: src = userland buffer, dest = flash address.
 * READ  semantics: src = flash address,    dest = userland buffer.
 *
 * WARNING: writing the kernel region (dest == 0x20000) sets the driver's
 * need_reboot flag and calls machine_restart() - the device reboots into
 * whatever is now at 0x20000. That is the whole point of the closed-case
 * install, and also the reason a bad write is a brick.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#define FLASH_DEV         "/dev/flash0"
#define FLASH_IOCTL_READ  0x01
#define FLASH_IOCTL_WRITE 0x02

struct flash_opt {
    unsigned int *src;
    unsigned int *dest;
    unsigned int  bytes;
    unsigned int  start_addr;
    unsigned int  end_addr;
    int           result;
};

static int flash_op(int fd, unsigned int cmd, void *buf,
                    unsigned int addr, unsigned int bytes)
{
    struct flash_opt opt;
    memset(&opt, 0, sizeof(opt));
    if (cmd == FLASH_IOCTL_WRITE) {
        opt.src   = (unsigned int *)buf;
        opt.dest  = (unsigned int *)(unsigned long)addr;
    } else {
        opt.src   = (unsigned int *)(unsigned long)addr;
        opt.dest  = (unsigned int *)buf;
    }
    opt.bytes = bytes;
    return ioctl(fd, cmd, &opt);
}

static int read_file(const char *path, unsigned char **out, size_t *outlen)
{
    FILE *f = fopen(path, "rb");
    struct stat st;
    unsigned char *buf;
    if (!f) { perror(path); return -1; }
    if (fstat(fileno(f), &st) != 0) { perror("fstat"); fclose(f); return -1; }
    buf = malloc((size_t)st.st_size);
    if (!buf) { fprintf(stderr, "malloc %ld failed\n", (long)st.st_size); fclose(f); return -1; }
    if (fread(buf, 1, (size_t)st.st_size, f) != (size_t)st.st_size) {
        perror("fread"); free(buf); fclose(f); return -1;
    }
    fclose(f);
    *out = buf; *outlen = (size_t)st.st_size;
    return 0;
}

int main(int argc, char **argv)
{
    int fd, r;
    if (argc == 5 && strcmp(argv[1], "read") == 0) {
        unsigned int addr = (unsigned int)strtoul(argv[2], NULL, 0);
        unsigned int len  = (unsigned int)strtoul(argv[3], NULL, 0);
        FILE *out = fopen(argv[4], "wb");
        unsigned char *buf = malloc(len);
        if (!out || !buf) { perror("open/malloc"); return 1; }
        fd = open(FLASH_DEV, O_RDWR);
        if (fd < 0) { perror(FLASH_DEV); return 1; }
        r = flash_op(fd, FLASH_IOCTL_READ, buf, addr, len);
        if (r != 0) { perror("ioctl read"); return 1; }
        fwrite(buf, 1, len, out);
        fclose(out); free(buf); close(fd);
        fprintf(stderr, "read 0x%x bytes at 0x%x -> %s\n", len, addr, argv[4]);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "write") == 0) {
        unsigned int addr = (unsigned int)strtoul(argv[2], NULL, 0);
        unsigned char *buf; size_t len;
        if (read_file(argv[3], &buf, &len) != 0) return 1;
        if ((len & 0xFFFF) != 0 || (addr & 0xFFFF) != 0) {
            fprintf(stderr, "len 0x%lx and addr 0x%x must be 64KB-aligned/multiple\n",
                    (unsigned long)len, addr);
            return 1;
        }
        fd = open(FLASH_DEV, O_RDWR);
        if (fd < 0) { perror(FLASH_DEV); return 1; }
        fprintf(stderr, "writing %lu bytes at 0x%x (single ioctl)\n",
                (unsigned long)len, addr);
        r = flash_op(fd, FLASH_IOCTL_WRITE, buf, addr, (unsigned int)len);
        if (r != 0) { perror("ioctl write"); return 1; }
        fprintf(stderr, "write ioctl returned %d\n", r);
        return 0;
    }
    fprintf(stderr, "usage: %s read  <addr> <len> <outfile>\n", argv[0]);
    fprintf(stderr, "       %s write <addr> <infile>\n", argv[0]);
    return 2;
}
