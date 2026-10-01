/*
 * at-tty - send AT commands to a serial tty and print whatever comes back.
 *
 * OpenWrt's busybox on this target has neither `stty` nor `microcom`, so there is
 * no way to set a line speed or talk to an AT port from the shell. This is the
 * smallest thing that does both: configure the port (raw, no echo, no flow
 * control, a chosen baud), write the commands, and read until the line goes
 * quiet.
 *
 * Build (inside the OpenWrt build container):
 *   mipsel-openwrt-linux-musl-gcc -static -Os -o at-tty at-tty.c
 *
 * Usage:
 *   at-tty /dev/ttyUSB2 115200 'AT' 'AT+CGREG?' 'AT+CGDCONT?'
 *
 * NB: the AT port is /dev/ttyUSB2 (USB interface 1-1:1.2). Interface 1-1:1.1 is the module's
 * ADB interface (class ff/42/01) and does not answer AT - an earlier version of this comment
 * pointed at ttyUSB1, which is what lte-reset's blanket `option1/new_id` exposes there.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <sys/select.h>

static speed_t baud_to_const(int baud)
{
	switch (baud) {
	case 9600:   return B9600;
	case 19200:  return B19200;
	case 38400:  return B38400;
	case 57600:  return B57600;
	case 115200: return B115200;
	case 230400: return B230400;
#ifdef B460800
	case 460800: return B460800;
#endif
#ifdef B921600
	case 921600: return B921600;
#endif
	default:     return B115200;
	}
}

/* Read until the port has been quiet for ~300 ms, or the total budget runs out. */
static void drain(int fd, int budget_ms)
{
	char buf[4096];
	int idle = 0;

	while (idle < 3 && budget_ms > 0) {
		fd_set rf;
		struct timeval tv = { 0, 100000 }; /* 100 ms */
		int r;

		FD_ZERO(&rf);
		FD_SET(fd, &rf);
		r = select(fd + 1, &rf, NULL, NULL, &tv);
		budget_ms -= 100;
		if (r > 0) {
			ssize_t n = read(fd, buf, sizeof buf);

			if (n > 0) {
				fwrite(buf, 1, (size_t)n, stdout);
				fflush(stdout);
				idle = 0;
			} else {
				idle++;
			}
		} else {
			idle++;
		}
	}
}

int main(int argc, char **argv)
{
	int fd, i;
	struct termios tio;
	speed_t sp;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <device> <baud> <command>...\n", argv[0]);
		return 2;
	}

	fd = open(argv[1], O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	if (tcgetattr(fd, &tio) < 0) {
		perror("tcgetattr");
		return 1;
	}

	cfmakeraw(&tio);
	sp = baud_to_const(atoi(argv[2]));
	cfsetispeed(&tio, sp);
	cfsetospeed(&tio, sp);
	tio.c_cflag |= (CLOCAL | CREAD);
	tio.c_cflag &= ~CRTSCTS;
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;

	if (tcsetattr(fd, TCSANOW, &tio) < 0) {
		perror("tcsetattr");
		return 1;
	}
	tcflush(fd, TCIOFLUSH);

	for (i = 3; i < argc; i++) {
		char line[512];

		snprintf(line, sizeof line, "%s\r", argv[i]);
		printf("\n>>> %s\n", argv[i]);
		fflush(stdout);

		if (write(fd, line, strlen(line)) < 0)
			perror("write");

		drain(fd, 3000);
	}

	close(fd);
	return 0;
}
