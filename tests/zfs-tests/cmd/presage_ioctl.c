// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026, Vesta Corporation.
 * Copyright (c) 2026, Todd Curry.
 */

/*
 * Issue presage requests the zfs command cannot make, to prove the rules
 * that keep the ioctl extensible: a non-zero reserved word, an undefined
 * flag bit and the kernel-internal reset bit are refused with EINVAL, so
 * a field added later is refused cleanly by an older kernel.
 *
 * usage: presage_ioctl <mode> <file|volume>
 *
 *   reserved  ZFS_IOC_PRESAGE on the file, reserved[0] = 1, otherwise
 *             valid; expects EINVAL
 *   flag      ZFS_IOC_PRESAGE, flags = 1 << 7 (undefined); expects EINVAL
 *   internal  ZFS_IOC_PRESAGE, flags = ZFS_PRESAGE_RESET; expects EINVAL
 *   ok        ZFS_IOC_PRESAGE, a valid 60 s request; expects 0
 *   lzc_flag  lzc_presage() on the volume, flags = 1 << 7; expects EINVAL
 *   lzc_ok    lzc_presage() on the volume, a valid 60 s request; expects 0
 *
 * Prints "errno=<n>" and exits 0 when the call returned what the mode
 * expects, 1 when it returned anything else, 2 on a usage or open error.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/fs/zfs.h>
#include <libzfs_core.h>

#define	PRESAGE_TTL		60
#define	PRESAGE_UNKNOWN_FLAG	(1ULL << 7)

static void
usage(void)
{
	(void) fprintf(stderr, "usage: presage_ioctl "
	    "reserved|flag|internal|ok|lzc_flag|lzc_ok <file|volume>\n");
	exit(2);
}

static int
fd_request(const char *path, uint64_t flags, uint64_t reserved0)
{
	zfs_presage_args_t args;
	int fd, err;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		(void) fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		exit(2);
	}
	memset(&args, 0, sizeof (args));
	args.ttl = PRESAGE_TTL;
	args.flags = flags;
	args.reserved[0] = reserved0;
	err = ioctl(fd, ZFS_IOC_PRESAGE, &args) < 0 ? errno : 0;
	(void) close(fd);
	return (err);
}

static int
lzc_request(const char *volname, uint64_t flags)
{
	nvlist_t *result = NULL;
	int err;

	if (libzfs_core_init() != 0) {
		(void) fprintf(stderr, "libzfs_core_init: %s\n",
		    strerror(errno));
		exit(2);
	}
	err = lzc_presage(volname, 0, 0, 0, PRESAGE_TTL, flags, &result);
	nvlist_free(result);
	libzfs_core_fini();
	return (err);
}

int
main(int argc, char *argv[])
{
	const char *mode, *target;
	int err, expected;

	if (argc != 3)
		usage();
	mode = argv[1];
	target = argv[2];

	if (strcmp(mode, "reserved") == 0) {
		err = fd_request(target, 0, 1);
		expected = EINVAL;
	} else if (strcmp(mode, "flag") == 0) {
		err = fd_request(target, PRESAGE_UNKNOWN_FLAG, 0);
		expected = EINVAL;
	} else if (strcmp(mode, "internal") == 0) {
		err = fd_request(target, ZFS_PRESAGE_RESET, 0);
		expected = EINVAL;
	} else if (strcmp(mode, "ok") == 0) {
		err = fd_request(target, 0, 0);
		expected = 0;
	} else if (strcmp(mode, "lzc_flag") == 0) {
		err = lzc_request(target, PRESAGE_UNKNOWN_FLAG);
		expected = EINVAL;
	} else if (strcmp(mode, "lzc_ok") == 0) {
		err = lzc_request(target, 0);
		expected = 0;
	} else {
		usage();
		return (2);
	}

	(void) printf("errno=%d\n", err);
	if (err != expected) {
		(void) fprintf(stderr, "%s %s: got %d (%s), expected %d\n",
		    mode, target, err, strerror(err), expected);
		return (1);
	}
	return (0);
}
