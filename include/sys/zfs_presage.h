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

#ifndef	_SYS_ZFS_PRESAGE_H
#define	_SYS_ZFS_PRESAGE_H

#include <sys/zfs_znode.h>
#include <sys/fs/zfs.h>

#ifdef	__cplusplus
extern "C" {
#endif

/*
 * Presage reservations: "keep [off, len) of this file resident in ARC from
 * start for ttl seconds".  A reservation outlives the ioctl that made it:
 * it may start in the future, it re-sweeps its range while active so blocks
 * written during the window are covered, and it can be killed.  Reservations
 * identify their file the way NFS file handles do (objset, object,
 * generation), hold nothing open, and cancel themselves if the file or
 * dataset is gone when they fire.
 */

/* Maximum number of reservations in the system; EAGAIN beyond this. */
#define	ZFS_PRESAGE_MAX_RESERVATIONS	4096
/* Furthest allowed start time and longest TTL, seconds. */
#define	ZFS_PRESAGE_MAX_SECONDS		(30 * 24 * 3600)
/* Active reservations re-sweep their range at most this often, seconds. */
#define	ZFS_PRESAGE_RESWEEP_SECONDS	5
#define	ZFS_PRESAGE_CANCEL_GRACE	10
/* A volume or file is held one chunk at a time on the zthr. */
#define	ZFS_PRESAGE_ZVOL_CHUNK		(64ULL << 20)

/* What a reservation names: a file (znode) or a volume (ZVOL_OBJ). */
typedef enum {
	PR_FILE = 0,
	PR_ZVOL = 1
} zfs_presage_kind_t;

void zfs_presage_init(void);
void zfs_presage_fini(void);

/* The ioctl entry point (zfs_vnops.c) hands requests here. */
int zfs_presage_request(znode_t *zp, zfs_presage_args_t *args);
int zfs_presage_kill(znode_t *zp, zfs_presage_args_t *args);
void zfs_presage_status(znode_t *zp, zfs_presage_args_t *args);
/* The dataset-named ioctl (zfs_ioctl.c): volumes by name. */
int zfs_presage_dataset(const char *name, zfs_presage_args_t *args);
/* spa_export_common() drops every reservation on the pool. */
void zfs_presage_drop_pool(uint64_t spa_guid);
/* A restore replaced a dataset's contents: cancel and release (any context). */
void zfs_presage_drop_objset(uint64_t spa_guid, uint64_t objset);
/* Unmount and key unload release what the dataset has presaged. */
typedef struct zfs_presage_fence zfs_presage_fence_t;
void zfs_presage_unmount(objset_t *os);
zfs_presage_fence_t *zfs_presage_unload_key(const char *dsname);
void zfs_presage_unload_key_end(zfs_presage_fence_t *f);
/* The rollback and receive ioctls bracket a restore with these. */
zfs_presage_fence_t *zfs_presage_restore_begin(const char *dsname);
void zfs_presage_restore_end(zfs_presage_fence_t *f, boolean_t restored);

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_ZFS_PRESAGE_H */
