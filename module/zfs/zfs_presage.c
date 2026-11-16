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
 * Presage reservations.  See zfs_presage.h for the model.
 *
 * Data structure: one AVL tree of reservations keyed by
 * (pool guid, objset, object, off, len), protected by zfs_presage_lock.
 * A reservation is on a file (object = a znode, generation = its z_gen)
 * or on a volume (object = ZVOL_OBJ, generation = the dataset's guid);
 * object 1 of a filesystem is the master node, never a file, so the two
 * never alias.
 * A one-second zthr fires pending reservations whose start time has come,
 * re-sweeps active ones so blocks written during the window get marked,
 * and retires expired ones.  Loads run on the zthr itself (they block on
 * I/O; the ARC eviction thread is never involved), serialised, which is
 * fine: a start time means "begin warming at".
 *
 * Clock: the ioctl carries wall-clock seconds; they are converted once, at
 * request time, to seconds since boot (lbolt/hz), the clock the ARC header
 * expiry uses.  Wall-clock steps after that do not move reservations.
 */

#include <sys/zfs_context.h>
#include <sys/zfs_presage.h>
#include <sys/zfs_znode.h>
#include <sys/zfs_vfsops.h>
#include <sys/zfs_vnops.h>
#include <sys/zfs_ioctl.h>
#include <sys/zfs_ioctl_impl.h>
#include <sys/sa.h>
#include <sys/spa.h>
#include <sys/dsl_pool.h>
#include <sys/dsl_dataset.h>
#include <sys/dmu_objset.h>
#include <sys/dmu.h>
#include <sys/dnode.h>
#include <sys/zthr.h>
#include <sys/avl.h>
#include <sys/arc.h>
#include <sys/zap.h>
#include <sys/zvol.h>

typedef enum {
	PRS_PENDING,		/* start time in the future */
	PRS_ACTIVE,		/* loaded (or loading); re-swept each tick */
	PRS_CANCELLED		/* dataset restored under it; release, free */
} zfs_presage_state_t;

typedef struct zfs_presage_res {
	avl_node_t	pr_node;
	uint64_t	pr_id;		/* unique, monotonic */
	/* identity: the file handle */
	uint8_t		pr_kind;	/* zfs_presage_kind_t */
	uint64_t	pr_spa_guid;
	char		pr_pool[ZFS_MAX_DATASET_NAME_LEN];
	uint64_t	pr_objset;	/* dsl dataset object number */
	uint64_t	pr_object;
	uint64_t	pr_gen;		/* znode generation, or dataset guid */
	uint64_t	pr_off;
	uint64_t	pr_len;		/* 0 = to EOF at each sweep */
	/* timing, seconds since boot */
	uint64_t	pr_fire;
	uint64_t	pr_expire;
	uint64_t	pr_resweep;	/* next re-sweep, 0 = never */
	/* timing, wall clock, for status */
	uint64_t	pr_wall_expire;
	uint64_t	pr_warmed_at;	/* 0 until the first load finished */
	/* change detector for cheap re-sweeps */
	uint64_t	pr_seen_maxblkid;
	uint64_t	pr_seen_used;
	uint64_t	pr_bytes;	/* presaged bytes at the last sweep */
	zfs_presage_state_t pr_state;
	boolean_t	pr_busy;	/* a load is in flight on the zthr */
	boolean_t	pr_force;	/* re-sweep even if unchanged */
	boolean_t	pr_restoring;	/* behind a fence: hands off */
	boolean_t	pr_owed;	/* its range's release is owed */
} zfs_presage_res_t;

static kmutex_t zfs_presage_lock;
static kcondvar_t zfs_presage_cv;	/* a pr_busy was cleared */
static avl_tree_t zfs_presage_tree;

/*
 * A fence: a restore of one dataset, or a key unload, which covers every
 * volume on its pool, is in flight.  Nothing in its scope is loaded or
 * walked while it is up; what falls due meanwhile waits for it to come
 * down.  Under the lock.
 */
struct zfs_presage_fence {
	list_node_t	pf_node;
	uint64_t	pf_spa_guid;
	uint64_t	pf_objset;	/* 0: every volume on the pool */
};
static list_t zfs_presage_fences;
/*
 * A walk in flight that no busy entry stands for (expiry, kill, status);
 * a fence waits for the ones in its scope.  Under the lock.
 */
typedef struct zfs_presage_walk {
	list_node_t	pw_node;
	uint64_t	pw_spa_guid;
	uint64_t	pw_objset;
	uint8_t		pw_kind;
} zfs_presage_walk_t;
static list_t zfs_presage_walks;
static uint64_t zfs_presage_next_id = 1;
static uint64_t zfs_presage_next_due = UINT64_MAX;	/* seconds since boot */
/* Entries the tick would end at once if presage were switched off. */
static uint64_t zfs_presage_judgeable;
static zthr_t *zfs_presage_zthr;
static boolean_t zfs_presage_ready;
/*
 * Holds and filesystem entries taken in one function and dropped in
 * another use this tag: rrwlock matches a reader's enter and exit by tag.
 */
static const char zfs_presage_tag[] = "zfs_presage";

/*
 * kstat zfs/presage: live counts, read on demand.  "holds" is the number
 * of dataset (volume) and filesystem holds presage has taken and not yet
 * released; it is 0 whenever no load or sweep is running, which is what
 * a test checks to show that a destroy or export left nothing behind.
 */
typedef struct zfs_presage_stats {
	kstat_named_t zps_reservations;	/* entries in the tree */
	kstat_named_t zps_pending;	/* of which start in the future */
	kstat_named_t zps_active;	/* of which loaded or loading */
	kstat_named_t zps_loads;	/* loads or sweeps in flight */
	kstat_named_t zps_holds;	/* dataset or filesystem holds held */
} zfs_presage_stats_t;

static zfs_presage_stats_t zfs_presage_stats = {
	{ "reservations",		KSTAT_DATA_UINT64 },
	{ "pending",			KSTAT_DATA_UINT64 },
	{ "active",			KSTAT_DATA_UINT64 },
	{ "loads",			KSTAT_DATA_UINT64 },
	{ "holds",			KSTAT_DATA_UINT64 },
};
static kstat_t *zfs_presage_ksp;
static uint64_t zfs_presage_holds;	/* atomic */

static int
zfs_presage_kstat_update(kstat_t *ksp, int rw)
{
	zfs_presage_stats_t *zs = ksp->ks_data;
	uint64_t n = 0, pending = 0, active = 0, loads = 0;

	if (rw == KSTAT_WRITE)
		return (SET_ERROR(EACCES));

	mutex_enter(&zfs_presage_lock);
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		n++;
		if (r->pr_state == PRS_PENDING)
			pending++;
		else if (r->pr_state == PRS_ACTIVE)
			active++;
		if (r->pr_busy)
			loads++;
	}
	mutex_exit(&zfs_presage_lock);

	zs->zps_reservations.value.ui64 = n;
	zs->zps_pending.value.ui64 = pending;
	zs->zps_active.value.ui64 = active;
	zs->zps_loads.value.ui64 = loads;
	zs->zps_holds.value.ui64 = zfs_presage_holds;
	return (0);
}

static inline uint64_t
zfs_presage_now(void)
{
	return ((uint64_t)(ddi_get_lbolt64() / hz));
}

static int
zfs_presage_compare(const void *a, const void *b)
{
	const zfs_presage_res_t *x = a, *y = b;
	int c;

	if ((c = TREE_CMP(x->pr_spa_guid, y->pr_spa_guid)) != 0)
		return (c);
	if ((c = TREE_CMP(x->pr_objset, y->pr_objset)) != 0)
		return (c);
	if ((c = TREE_CMP(x->pr_object, y->pr_object)) != 0)
		return (c);
	if ((c = TREE_CMP(x->pr_off, y->pr_off)) != 0)
		return (c);
	return (TREE_CMP(x->pr_len, y->pr_len));
}

static boolean_t
zfs_presage_in_fence(const zfs_presage_fence_t *f, uint64_t spa_guid,
    uint64_t objset, uint8_t kind)
{
	return (f->pf_spa_guid == spa_guid && (f->pf_objset == objset ||
	    (f->pf_objset == 0 && kind == PR_ZVOL)));
}

/* Is the dataset behind a fence?  Lock held. */
static boolean_t
zfs_presage_fenced(uint64_t spa_guid, uint64_t objset, uint8_t kind)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	for (zfs_presage_fence_t *f = list_head(&zfs_presage_fences);
	    f != NULL; f = list_next(&zfs_presage_fences, f)) {
		if (zfs_presage_in_fence(f, spa_guid, objset, kind))
			return (B_TRUE);
	}
	return (B_FALSE);
}

/* The same for a reservation. */
static boolean_t
zfs_presage_res_fenced(const zfs_presage_res_t *r)
{
	return (zfs_presage_fenced(r->pr_spa_guid, r->pr_objset,
	    r->pr_kind));
}

/* Is a registered walk in the fence's scope?  Lock held. */
static boolean_t
zfs_presage_walking(const zfs_presage_fence_t *f)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	for (zfs_presage_walk_t *w = list_head(&zfs_presage_walks);
	    w != NULL; w = list_next(&zfs_presage_walks, w)) {
		if (zfs_presage_in_fence(f, w->pw_spa_guid, w->pw_objset,
		    w->pw_kind))
			return (B_TRUE);
	}
	return (B_FALSE);
}

/* Register a walk on the dataset.  Lock held. */
static void
zfs_presage_walk_enter(zfs_presage_walk_t *w, uint64_t spa_guid,
    uint64_t objset, uint8_t kind)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	w->pw_spa_guid = spa_guid;
	w->pw_objset = objset;
	w->pw_kind = kind;
	list_insert_tail(&zfs_presage_walks, w);
}

/*
 * Register a walk on the dataset, unless it is behind a fence (B_FALSE):
 * a walk then either started before the fence went up, and the fence
 * waits for it, or does not start.  Lock held.
 */
static boolean_t
zfs_presage_walk_begin(zfs_presage_walk_t *w, uint64_t spa_guid,
    uint64_t objset, uint8_t kind)
{
	if (zfs_presage_fenced(spa_guid, objset, kind))
		return (B_FALSE);
	zfs_presage_walk_enter(w, spa_guid, objset, kind);
	return (B_TRUE);
}

static void
zfs_presage_walk_end(zfs_presage_walk_t *w)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	list_remove(&zfs_presage_walks, w);
	cv_broadcast(&zfs_presage_cv);
}

/* Cancel a reservation: the zthr releases its range, then frees it. */
static void
zfs_presage_cancel_entry(zfs_presage_res_t *r)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	r->pr_state = PRS_CANCELLED;
	r->pr_restoring = B_FALSE;
	r->pr_owed = B_FALSE;
	r->pr_resweep = 0;
	r->pr_fire = zfs_presage_now() + ZFS_PRESAGE_CANCEL_GRACE;
}

/*
 * Recompute the earliest time anything needs the zthr; lock held.  Only
 * times zfs_presage_tick() acts on count: one it skips would rerun the
 * zthr without a pause.  The loader of a busy entry recomputes when it
 * ends, and so does the end of a restore; a restoring entry still counts
 * by its expiry, at which the tick retires it.
 */
static void
zfs_presage_recompute_due(void)
{
	uint64_t due = UINT64_MAX;
	uint64_t judge = 0;

	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_busy)
			continue;
		if (r->pr_state == PRS_CANCELLED) {
			if (!zfs_presage_res_fenced(r))
				due = MIN(due, r->pr_resweep);
			continue;
		}
		judge++;
		due = MIN(due, r->pr_expire);
		if (r->pr_restoring)
			continue;
		if (r->pr_owed)
			due = 0;
		if (r->pr_state == PRS_PENDING)
			due = MIN(due, r->pr_fire);
		else if (r->pr_resweep != 0)
			due = MIN(due, r->pr_resweep);
	}
	zfs_presage_next_due = due;
	zfs_presage_judgeable = judge;
}

static void
zfs_presage_free(zfs_presage_res_t *r)
{
	avl_remove(&zfs_presage_tree, r);
	kmem_free(r, sizeof (*r));
}

/*
 * Resolve a reservation's file.  On success *zpp is held (zrele it) and
 * *zfvpp is referenced and entered (zfs_exit + zfs_vfs_rele it).  ENOENT
 * when the filesystem cannot be reached: pool exported, dataset unmounted
 * or destroyed.  During a suspend for a restore this blocks until the
 * filesystem resumes (zfs_enter() waits; it does not fail).  ESTALE
 * when it can and the file is not in it: object freed or reused
 * (generation mismatch).  A cancelled reservation waits out the first and
 * is dropped at once on the second.
 */
static int
zfs_presage_resolve(const zfs_presage_res_t *r, znode_t **zpp,
    zfsvfs_t **zfvpp)
{
	spa_t *spa;
	dsl_pool_t *dp;
	dsl_dataset_t *ds;
	objset_t *os;
	zfsvfs_t *zfsvfs = NULL;
	znode_t *zp;
	uint64_t gen = 0;
	int err;

	if ((err = spa_open(r->pr_pool, &spa, FTAG)) != 0)
		return (SET_ERROR(ENOENT));
	if (spa_guid(spa) != r->pr_spa_guid) {
		spa_close(spa, FTAG);
		return (SET_ERROR(ENOENT));
	}
	dp = spa_get_dsl(spa);
	dsl_pool_config_enter(dp, FTAG);
	err = dsl_dataset_hold_obj(dp, r->pr_objset, FTAG, &ds);
	if (err == 0) {
		err = dmu_objset_from_ds(ds, &os);
		if (err == 0)
			err = getzfsvfs_impl(os, &zfsvfs);
		dsl_dataset_rele(ds, FTAG);
	}
	dsl_pool_config_exit(dp, FTAG);
	spa_close(spa, FTAG);
	if (err != 0)
		return (SET_ERROR(ENOENT));

	if ((err = zfs_enter(zfsvfs, zfs_presage_tag)) != 0) {
		zfs_vfs_rele(zfsvfs);
		return (SET_ERROR(ENOENT));
	}
	if ((err = zfs_zget(zfsvfs, r->pr_object, &zp)) != 0) {
		zfs_exit(zfsvfs, zfs_presage_tag);
		zfs_vfs_rele(zfsvfs);
		return (SET_ERROR(ESTALE));
	}
	(void) sa_lookup(zp->z_sa_hdl, SA_ZPL_GEN(zfsvfs), &gen,
	    sizeof (gen));
	if (gen != r->pr_gen || (zp->z_pflags & ZFS_XATTR)) {
		zrele(zp);
		zfs_exit(zfsvfs, zfs_presage_tag);
		zfs_vfs_rele(zfsvfs);
		return (SET_ERROR(ESTALE));
	}
	*zpp = zp;
	*zfvpp = zfsvfs;
	atomic_inc_64(&zfs_presage_holds);
	return (0);
}

static void
zfs_presage_release(znode_t *zp, zfsvfs_t *zfsvfs)
{
	zrele(zp);
	zfs_exit(zfsvfs, zfs_presage_tag);
	zfs_vfs_rele(zfsvfs);
	atomic_dec_64(&zfs_presage_holds);
}

/*
 * Resolve a volume reservation's dataset for one chunk of work.  On
 * success *dsp is held and long-held (zfs_presage_zvol_rele it), *osp is
 * its objset and *sizep its volsize.  The long hold keeps the dataset
 * from being destroyed or promoted under the DMU walk without owning it
 * (a zvol open owns it) and without the pool config lock, which is only
 * taken to look the dataset up.  ENOENT for anything that means "this
 * volume is gone": pool exported, dataset destroyed or its object number
 * reused (guid mismatch), or not a live volume any more; EACCES for an
 * encrypted volume whose key is not loaded.  zvol_state_t is
 * never involved: an unopened volume (volmode=none, VMs not started) is
 * the normal case.
 */
static int
zfs_presage_zvol_hold(const zfs_presage_res_t *r, dsl_dataset_t **dsp,
    objset_t **osp, uint64_t *sizep)
{
	spa_t *spa;
	dsl_pool_t *dp;
	dsl_dataset_t *ds = NULL;
	objset_t *os = NULL;
	int err;

	if ((err = spa_open(r->pr_pool, &spa, FTAG)) != 0)
		return (SET_ERROR(ENOENT));
	if (spa_guid(spa) != r->pr_spa_guid) {
		spa_close(spa, FTAG);
		return (SET_ERROR(ENOENT));
	}
	dp = spa_get_dsl(spa);
	dsl_pool_config_enter(dp, FTAG);
	/*
	 * With a key mapping: an unopened volume has none of its own, and
	 * without one the load of an encrypted volume reads every block and
	 * keeps none.  EACCES when the key is not loaded.
	 */
	err = dsl_dataset_hold_obj_flags(dp, r->pr_objset,
	    DS_HOLD_FLAG_DECRYPT, zfs_presage_tag, &ds);
	if (err == 0) {
		if (dsl_dataset_phys(ds)->ds_guid != r->pr_gen ||
		    ds->ds_is_snapshot)
			err = SET_ERROR(ENOENT);
		else if ((err = dmu_objset_from_ds(ds, &os)) == 0 &&
		    dmu_objset_type(os) != DMU_OST_ZVOL)
			err = SET_ERROR(ENOENT);
		if (err == 0) {
			dsl_dataset_long_hold(ds, zfs_presage_tag);
		} else {
			dsl_dataset_rele_flags(ds, DS_HOLD_FLAG_DECRYPT,
			    zfs_presage_tag);
			err = SET_ERROR(ENOENT);
		}
	} else if (err != EACCES) {
		err = SET_ERROR(ENOENT);
	}
	dsl_pool_config_exit(dp, FTAG);
	spa_close(spa, FTAG);
	if (err != 0)
		return (err);

	if (zap_lookup(os, ZVOL_ZAP_OBJ, "size", 8, 1, sizep) != 0)
		*sizep = 0;
	*dsp = ds;
	*osp = os;
	atomic_inc_64(&zfs_presage_holds);
	return (0);
}

static void
zfs_presage_zvol_rele(dsl_dataset_t *ds)
{
	dsl_dataset_long_rele(ds, zfs_presage_tag);
	dsl_dataset_rele_flags(ds, DS_HOLD_FLAG_DECRYPT, zfs_presage_tag);
	atomic_dec_64(&zfs_presage_holds);
}

/*
 * Should a chunked walk for reservation id stop before its next chunk?
 * Yes when the reservation was killed or cancelled or has run out, or
 * when a restore of its dataset is in flight: nothing is loaded for a
 * state that is about to be, or has just been, replaced.
 */
static boolean_t
zfs_presage_stopped(uint64_t id)
{
	boolean_t stop = B_TRUE;

	mutex_enter(&zfs_presage_lock);
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_id != id)
			continue;
		stop = (r->pr_state == PRS_CANCELLED || r->pr_restoring ||
		    r->pr_expire <= zfs_presage_now());
		break;
	}
	mutex_exit(&zfs_presage_lock);
	return (stop);
}

/*
 * Load and mark [off, len) of a file until deadline (the reservation's,
 * on the zfs_presage_now() clock, so every block expires with it however
 * long the load takes; 0 for a release or status walk); len == 0 means to
 * size.  The ioctl caller holds the znode and has entered the filesystem,
 * so nothing can suspend it under this walk, and a rollback or receive
 * that has to suspend it waits for the ioctl.  The walk is therefore cut
 * into chunks, and a load (id != 0) stops, without error, at the first
 * chunk boundary after reservation id was killed or its dataset began a
 * restore (zfs_presage_stopped()): the restore waits for one chunk, not
 * for the file.  Returns the presaged byte count through *bytes.
 */
static int
zfs_presage_znode_apply(znode_t *zp, uint64_t id, uint64_t off, uint64_t len,
    uint32_t deadline, uint32_t flags, uint64_t *bytes, uint64_t *cached,
    uint64_t *uncached)
{
	objset_t *os = ZTOZSB(zp)->z_os;
	uint64_t size = zp->z_size;
	uint64_t pos = off, end = off, b = 0, c = 0, u = 0;
	int err = 0;

	if (off < size)
		end = (len == 0 || len > size - off) ? size : off + len;
	while (pos < end) {
		uint64_t pb = 0, pc = 0, pu = 0, mylen;

		if (id != 0 && zfs_presage_stopped(id))
			break;
		/* End on a chunk boundary so no block is counted twice. */
		mylen = MIN(P2ROUNDUP(pos + 1, ZFS_PRESAGE_ZVOL_CHUNK) - pos,
		    end - pos);
		err = dmu_presage(os, zp->z_id, pos, mylen, deadline, flags,
		    &pb, &pc, &pu);
		b += pb;
		c += pc;
		u += pu;
		pos += mylen;
		if (err != 0)
			break;
	}
	*bytes = b;
	if (cached != NULL)
		*cached = c;
	if (uncached != NULL)
		*uncached = u;
	return (err);
}

/*
 * The same for a volume, one chunk per dataset hold so that a destroy,
 * rollback or export racing with a long load waits at most one chunk.
 * volsize is read at every call: a shrink below off yields 0 bytes.
 * With id != 0 the walk also stops, without error, at the first chunk
 * boundary after reservation id was cancelled or its dataset began a
 * restore (zfs_presage_stopped()).
 */
static int
zfs_presage_zvol_apply(const zfs_presage_res_t *r, uint64_t id, uint64_t off,
    uint64_t len, uint32_t deadline, uint32_t flags, uint64_t *bytes,
    uint64_t *cached, uint64_t *uncached)
{
	uint64_t end = 0, pos = off, b = 0, c = 0, u = 0;
	boolean_t first = B_TRUE;
	int err = 0;

	for (;;) {
		dsl_dataset_t *ds;
		objset_t *os;
		uint64_t size, pb = 0, pc = 0, pu = 0, mylen;

		/* id != 0: a load, which stops at a chunk boundary. */
		if (id != 0 && zfs_presage_stopped(id))
			break;
		if ((err = zfs_presage_zvol_hold(r, &ds, &os, &size)) != 0)
			break;
		if (first) {
			first = B_FALSE;
			if (off >= size)
				end = off;
			else if (len == 0 || len > size - off)
				end = size;
			else
				end = off + len;
		}
		if (pos >= end) {
			zfs_presage_zvol_rele(ds);
			break;
		}
		/* End on a chunk boundary so no block is counted twice. */
		mylen = MIN(P2ROUNDUP(pos + 1, ZFS_PRESAGE_ZVOL_CHUNK) - pos,
		    end - pos);
		err = dmu_presage(os, ZVOL_OBJ, pos, mylen, deadline, flags,
		    &pb, &pc, &pu);
		zfs_presage_zvol_rele(ds);
		b += pb;
		c += pc;
		u += pu;
		pos += mylen;
		if (err != 0)
			break;
	}
	*bytes = b;
	if (cached != NULL)
		*cached = c;
	if (uncached != NULL)
		*uncached = u;
	return (err);
}

/*
 * The same for a file, on the zthr: the file is resolved, and its
 * filesystem entered, one chunk at a time, so a rollback, receive or
 * unmount waits for at most one chunk of a load or a release walk.
 */
static int
zfs_presage_file_apply(const zfs_presage_res_t *r, uint64_t id,
    uint32_t deadline, uint32_t flags, uint64_t *bytes)
{
	uint64_t end = 0, pos = r->pr_off, b = 0;
	boolean_t first = B_TRUE;
	int err = 0;

	for (;;) {
		znode_t *zp = NULL;
		zfsvfs_t *zfsvfs = NULL;
		uint64_t size, pb = 0, pc = 0, pu = 0, mylen;

		if (id != 0 && zfs_presage_stopped(id))
			break;
		if ((err = zfs_presage_resolve(r, &zp, &zfsvfs)) != 0)
			break;
		size = zp->z_size;
		if (first) {
			first = B_FALSE;
			if (r->pr_off >= size)
				end = r->pr_off;
			else if (r->pr_len == 0 || r->pr_len > size - r->pr_off)
				end = size;
			else
				end = r->pr_off + r->pr_len;
		}
		if (pos >= end || pos >= size) {
			zfs_presage_release(zp, zfsvfs);
			break;
		}
		mylen = MIN(P2ROUNDUP(pos + 1, ZFS_PRESAGE_ZVOL_CHUNK) - pos,
		    MIN(end, size) - pos);
		err = dmu_presage(zfsvfs->z_os, zp->z_id, pos, mylen,
		    deadline, flags, &pb, &pc, &pu);
		zfs_presage_release(zp, zfsvfs);
		b += pb;
		pos += mylen;
		if (err != 0)
			break;
	}
	*bytes = b;
	return (err);
}

/*
 * Cheap change detector: has the object grown or been rewritten since the
 * last sweep?  Reads the dnode's maxblkid and used bytes.
 */
static void
zfs_presage_snapshot_dn(objset_t *os, uint64_t object, uint64_t *maxblkid,
    uint64_t *used)
{
	dnode_t *dn;

	*maxblkid = *used = 0;
	if (dnode_hold(os, object, FTAG, &dn) != 0)
		return;
	*maxblkid = dn->dn_maxblkid;
	*used = DN_USED_BYTES(dn->dn_phys);
	dnode_rele(dn, FTAG);
}

/*
 * A target is what the ioctl front ends hand the core: a held znode
 * (the file form) or the identity of a volume (the dataset form).  The
 * volume is not held across the call; each DMU walk takes its own
 * chunk-bounded hold.
 */
typedef struct zfs_presage_target {
	zfs_presage_kind_t pt_kind;
	znode_t		*pt_zp;		/* PR_FILE: held by the caller */
	uint64_t	pt_spa_guid;
	char		pt_pool[ZFS_MAX_DATASET_NAME_LEN];
	uint64_t	pt_objset;
	uint64_t	pt_object;
	uint64_t	pt_gen;
} zfs_presage_target_t;

static void
zfs_presage_target_file(znode_t *zp, zfs_presage_target_t *t)
{
	zfsvfs_t *zfsvfs = ZTOZSB(zp);
	spa_t *spa = dmu_objset_spa(zfsvfs->z_os);

	memset(t, 0, sizeof (*t));
	t->pt_kind = PR_FILE;
	t->pt_zp = zp;
	t->pt_spa_guid = spa_guid(spa);
	(void) strlcpy(t->pt_pool, spa_name(spa), sizeof (t->pt_pool));
	t->pt_objset = dmu_objset_id(zfsvfs->z_os);
	t->pt_object = zp->z_id;
	(void) sa_lookup(zp->z_sa_hdl, SA_ZPL_GEN(zfsvfs), &t->pt_gen,
	    sizeof (t->pt_gen));
}

/* Fill the identity part of a key from a target. */
static void
zfs_presage_key(const zfs_presage_target_t *t,
    const zfs_presage_args_t *args, zfs_presage_res_t *key)
{
	memset(key, 0, sizeof (*key));
	key->pr_kind = t->pt_kind;
	key->pr_spa_guid = t->pt_spa_guid;
	(void) strlcpy(key->pr_pool, t->pt_pool, sizeof (key->pr_pool));
	key->pr_objset = t->pt_objset;
	key->pr_object = t->pt_object;
	key->pr_gen = t->pt_gen;
	key->pr_off = args->off;
	key->pr_len = args->len;
}

static int
zfs_presage_target_apply(const zfs_presage_target_t *t, uint64_t id,
    uint64_t off, uint64_t len, uint32_t deadline, uint32_t flags,
    uint64_t *bytes,
    uint64_t *cached, uint64_t *uncached)
{
	if (t->pt_kind == PR_FILE) {
		return (zfs_presage_znode_apply(t->pt_zp, id, off, len,
		    deadline, flags, bytes, cached, uncached));
	}
	zfs_presage_res_t key;
	zfs_presage_args_t a = { .off = off, .len = len };
	zfs_presage_key(t, &a, &key);
	return (zfs_presage_zvol_apply(&key, id, off, len, deadline, flags,
	    bytes, cached, uncached));
}

static void
zfs_presage_target_snapshot_dn(const zfs_presage_target_t *t,
    uint64_t *maxblkid, uint64_t *used)
{
	if (t->pt_kind == PR_FILE) {
		znode_t *zp = t->pt_zp;
		zfs_presage_snapshot_dn(ZTOZSB(zp)->z_os, zp->z_id, maxblkid,
		    used);
		return;
	}
	zfs_presage_res_t key;
	zfs_presage_args_t a = { 0 };
	dsl_dataset_t *ds;
	objset_t *os;
	uint64_t size;

	*maxblkid = *used = 0;
	zfs_presage_key(t, &a, &key);
	if (zfs_presage_zvol_hold(&key, &ds, &os, &size) != 0)
		return;
	zfs_presage_snapshot_dn(os, ZVOL_OBJ, maxblkid, used);
	zfs_presage_zvol_rele(ds);
}

/*
 * Demote what a cancelled reservation still covers on the restored
 * dataset, the way an explicit kill does (release mode of the DMU walk:
 * block pointers are read, data is not).  Lock not held.  Returns B_FALSE
 * when the file or volume did not resolve (the file does not exist in the
 * restored state, or the filesystem did not come back mounted), so the
 * caller tries again for a few seconds.  Blocks the restore orphaned are
 * off the dataset and leave the state when their free lands (arc_freed()).
 */
static boolean_t
zfs_presage_cancel_walk(const zfs_presage_res_t *r)
{
	uint64_t bytes = 0;

	if (r->pr_kind == PR_ZVOL) {
		return (zfs_presage_zvol_apply(r, 0, r->pr_off, r->pr_len, 0,
		    ZFS_PRESAGE_RELEASE, &bytes, NULL, NULL) != ENOENT);
	}
	return (zfs_presage_file_apply(r, 0, 0, ZFS_PRESAGE_RELEASE,
	    &bytes) != ENOENT);
}

/*
 * A reservation has reached its deadline.  The ARC reaper demotes the
 * expired headers it can see, which are those on the evictable lists; a
 * header held by a cached dbuf (the indirect blocks the load walked, data
 * someone is reading) is on no list and would stay counted as presaged,
 * against the cap, until something looked at it.  Look now: a walk of the
 * cached indirects that demotes what has expired and reads nothing.  Each
 * header carries its own deadline, so a block another reservation still
 * covers is left alone.  A reservation that was killed while its load
 * was in flight (pr_expire == 0) is walked in release mode instead: the
 * chunk the load was in may have marked blocks after the kill's own
 * release walk had passed them, with a deadline that is still ahead.
 * Lock not held.
 */
static void
zfs_presage_expire_walk(const zfs_presage_res_t *r, uint32_t flags)
{
	uint64_t bytes = 0;

	if (r->pr_kind == PR_ZVOL) {
		(void) zfs_presage_zvol_apply(r, 0, r->pr_off, r->pr_len, 0,
		    flags, &bytes, NULL, NULL);
	} else {
		(void) zfs_presage_file_apply(r, 0, 0, flags, &bytes);
	}
}

/*
 * A release walk over one reservation's range has demoted blocks that
 * other reservations on the same object may still cover.  Have those
 * swept again at once so the blocks get their deadline back (max-wins).
 * Lock held.
 */
static void
zfs_presage_resweep_siblings(const zfs_presage_res_t *k)
{
	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_state == PRS_ACTIVE &&
		    r->pr_spa_guid == k->pr_spa_guid &&
		    r->pr_objset == k->pr_objset &&
		    r->pr_object == k->pr_object) {
			r->pr_force = B_TRUE;
			r->pr_resweep = zfs_presage_now();
		}
	}
}

/*
 * One pass of the zthr: retire expired reservations, release and free
 * cancelled ones, fire due pending ones, re-sweep active ones whose file
 * changed.  Loads and release walks are performed with the lock dropped;
 * the entry is re-found by id afterwards because a kill may have removed
 * it meanwhile.
 */
static void
zfs_presage_tick(void)
{
	mutex_enter(&zfs_presage_lock);
restart:
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		uint64_t now = zfs_presage_now();

		if (r->pr_busy)
			continue;
		if (r->pr_state == PRS_CANCELLED) {
			if (r->pr_resweep > now ||
			    zfs_presage_res_fenced(r))
				continue;
			zfs_presage_res_t snap = *r;
			uint64_t id = r->pr_id;
			r->pr_busy = B_TRUE;
			mutex_exit(&zfs_presage_lock);
			boolean_t done = zfs_presage_cancel_walk(&snap);
			mutex_enter(&zfs_presage_lock);
			cv_broadcast(&zfs_presage_cv);
			for (zfs_presage_res_t *s =
			    avl_first(&zfs_presage_tree); s != NULL;
			    s = AVL_NEXT(&zfs_presage_tree, s)) {
				if (s->pr_id != id)
					continue;
				if (done || s->pr_fire <= zfs_presage_now()) {
					zfs_presage_free(s);
				} else {
					s->pr_busy = B_FALSE;
					s->pr_resweep = zfs_presage_now() + 1;
				}
				break;
			}
			/* A killed range: the others on the file get theirs. */
			zfs_presage_resweep_siblings(&snap);
			goto restart;
		}
		/*
		 * Presage was switched off (zfs_arc_presaged_max_percent =
		 * 0): every reservation ends as if killed, and the release
		 * walk below takes out what the cap reaper cannot see.
		 */
		if (!arc_presage_enabled())
			r->pr_expire = 0;
		if (r->pr_expire <= now) {
			/*
			 * Evictable headers expire on their own in the ARC
			 * reaper; held ones need the look.  The entry goes
			 * first, so a new request for the file is not told
			 * it is busy; a fence on the dataset waits for the
			 * registered walk.  Behind a fence nothing is walked:
			 * a killed entry's release waits for it as a
			 * cancelled entry, an expired one is left to the
			 * reaper.
			 */
			boolean_t killed = (r->pr_expire == 0);
			zfs_presage_walk_t w;

			if (r->pr_state != PRS_ACTIVE && !r->pr_owed) {
				zfs_presage_free(r);
				goto restart;
			}
			if (r->pr_owed)
				killed = B_TRUE;
			if (r->pr_restoring ||
			    zfs_presage_res_fenced(r)) {
				if (killed)
					zfs_presage_cancel_entry(r);
				else
					zfs_presage_free(r);
				goto restart;
			}
			zfs_presage_res_t snap = *r;
			zfs_presage_free(r);
			VERIFY(zfs_presage_walk_begin(&w, snap.pr_spa_guid,
			    snap.pr_objset, snap.pr_kind));
			mutex_exit(&zfs_presage_lock);
			zfs_presage_expire_walk(&snap, killed ?
			    ZFS_PRESAGE_RELEASE : ZFS_PRESAGE_EXPIRE);
			mutex_enter(&zfs_presage_lock);
			zfs_presage_walk_end(&w);
			if (killed)
				zfs_presage_resweep_siblings(&snap);
			goto restart;
		}
		/* Its dataset is mid-restore: neither load it nor judge it. */
		if (r->pr_restoring)
			continue;
		if (r->pr_owed) {
			/*
			 * A replaced reservation's release, deferred by a
			 * fence: walk it before the new one loads, then have
			 * every reservation on the file, this one included,
			 * swept again.
			 */
			zfs_presage_res_t snap = *r;
			uint64_t id = r->pr_id;
			r->pr_busy = B_TRUE;
			r->pr_owed = B_FALSE;
			mutex_exit(&zfs_presage_lock);
			zfs_presage_expire_walk(&snap, ZFS_PRESAGE_RELEASE);
			mutex_enter(&zfs_presage_lock);
			cv_broadcast(&zfs_presage_cv);
			for (zfs_presage_res_t *s =
			    avl_first(&zfs_presage_tree); s != NULL;
			    s = AVL_NEXT(&zfs_presage_tree, s)) {
				if (s->pr_id == id) {
					s->pr_busy = B_FALSE;
					break;
				}
			}
			zfs_presage_resweep_siblings(&snap);
			goto restart;
		}
		boolean_t fire = (r->pr_state == PRS_PENDING &&
		    r->pr_fire <= now);
		boolean_t resweep = (r->pr_state == PRS_ACTIVE &&
		    r->pr_resweep != 0 && r->pr_resweep <= now);
		if (!fire && !resweep)
			continue;

		zfs_presage_res_t snap = *r;
		uint64_t id = r->pr_id;
		r->pr_busy = B_TRUE;
		/* A force set from now on asks for another pass. */
		r->pr_force = B_FALSE;
		mutex_exit(&zfs_presage_lock);

		uint64_t bytes = 0, maxblkid = 0, used = 0;
		boolean_t resolved = B_FALSE;
		int err;
		if (snap.pr_kind == PR_ZVOL) {
			dsl_dataset_t *ds;
			objset_t *os;
			uint64_t size;
			err = zfs_presage_zvol_hold(&snap, &ds, &os, &size);
			if (err == 0) {
				resolved = B_TRUE;
				zfs_presage_snapshot_dn(os, ZVOL_OBJ,
				    &maxblkid, &used);
				zfs_presage_zvol_rele(ds);
				boolean_t changed =
				    (maxblkid != snap.pr_seen_maxblkid ||
				    used != snap.pr_seen_used);
				if (fire || changed || snap.pr_force) {
					err = zfs_presage_zvol_apply(&snap, id,
					    snap.pr_off, snap.pr_len,
					    (uint32_t)snap.pr_expire, 0,
					    &bytes, NULL, NULL);
				} else {
					bytes = snap.pr_bytes;
				}
			}
		} else {
			znode_t *zp = NULL;
			zfsvfs_t *zfsvfs = NULL;
			err = zfs_presage_resolve(&snap, &zp, &zfsvfs);
			if (err == 0) {
				resolved = B_TRUE;
				zfs_presage_snapshot_dn(ZTOZSB(zp)->z_os,
				    zp->z_id, &maxblkid, &used);
				zfs_presage_release(zp, zfsvfs);
				boolean_t changed =
				    (maxblkid != snap.pr_seen_maxblkid ||
				    used != snap.pr_seen_used);
				if (fire || changed || snap.pr_force) {
					err = zfs_presage_file_apply(&snap, id,
					    (uint32_t)snap.pr_expire, 0,
					    &bytes);
				} else {
					bytes = snap.pr_bytes;
				}
			}
		}

		mutex_enter(&zfs_presage_lock);
		cv_broadcast(&zfs_presage_cv);
		/* Re-find: a kill may have removed it while we were out. */
		zfs_presage_res_t *q = NULL;
		for (zfs_presage_res_t *s = avl_first(&zfs_presage_tree);
		    s != NULL; s = AVL_NEXT(&zfs_presage_tree, s)) {
			if (s->pr_id == id) {
				q = s;
				break;
			}
		}
		if (q == NULL)
			goto restart;
		q->pr_busy = B_FALSE;
		if (q->pr_state == PRS_CANCELLED) {
			/* Swapped away while we loaded: next pass releases. */
			goto restart;
		}
		if (q->pr_restoring) {
			/* Stopped for a restore; its end decides what next. */
			if (snap.pr_force)
				q->pr_force = B_TRUE;
			goto restart;
		}
		if (!resolved) {
			/* File, volume or dataset is gone: cancel. */
			zfs_presage_free(q);
			goto restart;
		}
		if (fire)
			q->pr_state = PRS_ACTIVE;
		/* The first load, or the first after a held-off request. */
		if (fire || q->pr_warmed_at == 0)
			q->pr_warmed_at = gethrestime_sec();
		q->pr_seen_maxblkid = maxblkid;
		q->pr_seen_used = used;
		q->pr_bytes = bytes;
		if (q->pr_force) {
			/* A sibling's release walk ran during the load. */
			q->pr_resweep = zfs_presage_now();
		} else {
			q->pr_resweep = zfs_presage_now() +
			    ZFS_PRESAGE_RESWEEP_SECONDS;
		}
		goto restart;
	}
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
}

static boolean_t
zfs_presage_zthr_check(void *arg, zthr_t *zthr)
{
	(void) arg, (void) zthr;
	return (zfs_presage_next_due <= zfs_presage_now() ||
	    (!arc_presage_enabled() && zfs_presage_judgeable != 0));
}

static void
zfs_presage_zthr_func(void *arg, zthr_t *zthr)
{
	(void) arg;
	if (!zthr_iscancelled(zthr))
		zfs_presage_tick();
}

void
zfs_presage_init(void)
{
	mutex_init(&zfs_presage_lock, NULL, MUTEX_DEFAULT, NULL);
	cv_init(&zfs_presage_cv, NULL, CV_DEFAULT, NULL);
	avl_create(&zfs_presage_tree, zfs_presage_compare,
	    sizeof (zfs_presage_res_t), offsetof(zfs_presage_res_t, pr_node));
	list_create(&zfs_presage_fences, sizeof (zfs_presage_fence_t),
	    offsetof(zfs_presage_fence_t, pf_node));
	list_create(&zfs_presage_walks, sizeof (zfs_presage_walk_t),
	    offsetof(zfs_presage_walk_t, pw_node));
	zfs_presage_zthr = zthr_create_timer("zfs_presage",
	    zfs_presage_zthr_check, zfs_presage_zthr_func, NULL, SEC2NSEC(1),
	    defclsyspri);
	zfs_presage_ksp = kstat_create("zfs", 0, "presage", "misc",
	    KSTAT_TYPE_NAMED,
	    sizeof (zfs_presage_stats) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (zfs_presage_ksp != NULL) {
		zfs_presage_ksp->ks_data = &zfs_presage_stats;
		zfs_presage_ksp->ks_update = zfs_presage_kstat_update;
		kstat_install(zfs_presage_ksp);
	}
	zfs_presage_ready = B_TRUE;
}

void
zfs_presage_fini(void)
{
	void *cookie = NULL;
	zfs_presage_res_t *r;

	if (!zfs_presage_ready)
		return;
	zfs_presage_ready = B_FALSE;
	if (zfs_presage_ksp != NULL) {
		kstat_delete(zfs_presage_ksp);
		zfs_presage_ksp = NULL;
	}
	/* zthr_destroy() requires a thread that has been cancelled. */
	(void) zthr_cancel(zfs_presage_zthr);
	zthr_destroy(zfs_presage_zthr);
	zfs_presage_zthr = NULL;
	mutex_enter(&zfs_presage_lock);
	while ((r = avl_destroy_nodes(&zfs_presage_tree, &cookie)) != NULL)
		kmem_free(r, sizeof (*r));
	avl_destroy(&zfs_presage_tree);
	list_destroy(&zfs_presage_fences);
	list_destroy(&zfs_presage_walks);
	mutex_exit(&zfs_presage_lock);
	cv_destroy(&zfs_presage_cv);
	mutex_destroy(&zfs_presage_lock);
}

/*
 * Make or replace a reservation.  args->start is wall-clock seconds
 * (0 = now); args->ttl is seconds and must be > 0 here (0 is a kill,
 * handled by the caller).  With start == now the load runs inline and
 * the call returns when warming is done, so a command that follows it is
 * ordered after the load.  Future starts return at once.
 */
static int
zfs_presage_request_impl(const zfs_presage_target_t *t,
    zfs_presage_args_t *args)
{
	zfs_presage_res_t key, *r, *next;
	zfs_presage_walk_t w;
	avl_index_t where;
	uint64_t now_wall = gethrestime_sec(), now = zfs_presage_now();
	uint64_t delay = 0;
	int err = 0;
	boolean_t replaced = B_FALSE, was_active = B_FALSE;
	boolean_t hold_off, walk = B_FALSE;

	if (!zfs_presage_ready || !arc_presage_enabled())
		return (SET_ERROR(ENOTSUP));
	if (args->ttl == 0 || args->ttl > ZFS_PRESAGE_MAX_SECONDS)
		return (SET_ERROR(EINVAL));
	if (args->start > now_wall) {
		delay = args->start - now_wall;
		if (delay > ZFS_PRESAGE_MAX_SECONDS)
			return (SET_ERROR(EINVAL));
	}

	zfs_presage_key(t, args, &key);
	uint64_t fire = now + delay;
	uint64_t expire = fire + args->ttl;

	mutex_enter(&zfs_presage_lock);
	r = avl_find(&zfs_presage_tree, &key, &where);
	if (r == NULL) {
		if (avl_numnodes(&zfs_presage_tree) >=
		    ZFS_PRESAGE_MAX_RESERVATIONS) {
			mutex_exit(&zfs_presage_lock);
			return (SET_ERROR(EAGAIN));
		}
		r = kmem_zalloc(sizeof (*r), KM_SLEEP);
		*r = key;
		r->pr_id = zfs_presage_next_id++;
		avl_insert(&zfs_presage_tree, r, where);
	} else if (r->pr_busy) {
		mutex_exit(&zfs_presage_lock);
		return (SET_ERROR(EBUSY));
	} else if (r->pr_gen != key.pr_gen) {
		/*
		 * The object number was reused: the entry is for a file or
		 * volume that no longer exists, whose blocks were freed with
		 * it.  Take it over as a new reservation on this one.
		 */
		r->pr_gen = key.pr_gen;
		r->pr_seen_maxblkid = 0;
		r->pr_seen_used = 0;
		r->pr_bytes = 0;
		r->pr_force = B_FALSE;
		r->pr_owed = B_FALSE;
	} else {
		replaced = B_TRUE;
		/* A cancelled one's release has not run yet either. */
		was_active = (r->pr_state == PRS_ACTIVE ||
		    r->pr_state == PRS_CANCELLED);
	}
	/* Replace: the latest request wins. */
	r->pr_fire = fire;
	r->pr_expire = expire;
	r->pr_wall_expire = now_wall + delay + args->ttl;
	r->pr_state = (delay == 0) ? PRS_ACTIVE : PRS_PENDING;
	r->pr_resweep = 0;
	r->pr_warmed_at = 0;
	/* Behind a fence (restore, key unload): no load until it is down. */
	hold_off = zfs_presage_res_fenced(&key);
	if (hold_off)
		r->pr_restoring = B_TRUE;
	/*
	 * A request for later replaces one whose blocks are presaged: they
	 * are released now, or, behind a fence, owed until it comes down.
	 */
	if (delay != 0 && was_active) {
		walk = zfs_presage_walk_begin(&w, key.pr_spa_guid,
		    key.pr_objset, key.pr_kind);
		if (!walk)
			r->pr_owed = B_TRUE;
	}
	uint64_t id = r->pr_id;
	if (delay == 0)
		r->pr_busy = B_TRUE;
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);

	args->pending = (delay == 0) ? 0 : 1;
	args->expires_at = now_wall + delay + args->ttl;
	args->presaged = args->cached = args->uncached = 0;
	args->warmed_at = 0;

	if (delay != 0) {
		/*
		 * A request for later replaced one that was active: that
		 * one has ended, so what it presaged is released now, not
		 * left without a reservation until its old deadline.  Other
		 * reservations on the object get their blocks back.
		 */
		if (walk) {
			uint64_t b = 0;

			(void) zfs_presage_target_apply(t, 0, args->off,
			    args->len, 0, ZFS_PRESAGE_RELEASE, &b, NULL,
			    NULL);
			mutex_enter(&zfs_presage_lock);
			zfs_presage_walk_end(&w);
			zfs_presage_resweep_siblings(&key);
			zfs_presage_recompute_due();
			mutex_exit(&zfs_presage_lock);
		}
		zthr_wakeup(zfs_presage_zthr);
		return (0);
	}

	/*
	 * Inline load, a chunk at a time: a file's znode is held by the
	 * ioctl caller, a volume is held per chunk.  A kill or a restore of
	 * the dataset stops it at the next chunk boundary and the count
	 * returned is what was loaded.  A replaced reservation sets its new
	 * (possibly shorter) deadline on its blocks; other reservations on
	 * the file are then swept again at once so a block they still cover
	 * gets their later deadline back (max-wins).
	 */
	uint64_t bytes = 0, maxblkid = 0, used = 0;
	if (!hold_off) {
		err = zfs_presage_target_apply(t, id, args->off, args->len,
		    (uint32_t)expire, replaced ? ZFS_PRESAGE_RESET : 0, &bytes,
		    &args->cached, &args->uncached);
		zfs_presage_target_snapshot_dn(t, &maxblkid, &used);
	}

	mutex_enter(&zfs_presage_lock);
	cv_broadcast(&zfs_presage_cv);
	for (r = avl_first(&zfs_presage_tree); r != NULL; r = next) {
		next = AVL_NEXT(&zfs_presage_tree, r);
		if (replaced && r->pr_id != id && r->pr_state == PRS_ACTIVE &&
		    r->pr_spa_guid == key.pr_spa_guid &&
		    r->pr_objset == key.pr_objset &&
		    r->pr_object == key.pr_object) {
			r->pr_force = B_TRUE;
			r->pr_resweep = zfs_presage_now();
			continue;
		}
		if (r->pr_id != id)
			continue;
		r->pr_busy = B_FALSE;
		if (r->pr_state == PRS_CANCELLED) {
			/* Swapped away while we loaded: the zthr releases. */
			continue;
		}
		if (err != 0 && err != ENOSPC) {
			zfs_presage_free(r);
			continue;
		}
		if (!hold_off)
			r->pr_warmed_at = gethrestime_sec();
		r->pr_bytes = bytes;
		r->pr_seen_maxblkid = maxblkid;
		r->pr_seen_used = used;
		if (r->pr_restoring) {
			/*
			 * The load may have stopped short for a restore.  If
			 * the restore replaces the dataset this is cancelled;
			 * if it does not, the zthr finishes the load.  A
			 * replacement's new deadline, which only the inline
			 * load sets on blocks already presaged, comes from a
			 * release and a fresh load instead.
			 */
			r->pr_force = B_TRUE;
			r->pr_resweep = zfs_presage_now();
			if (replaced)
				r->pr_owed = B_TRUE;
		} else {
			r->pr_resweep = zfs_presage_now() +
			    ZFS_PRESAGE_RESWEEP_SECONDS;
		}
	}
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);

	args->presaged = bytes;
	args->warmed_at = hold_off ? 0 : gethrestime_sec();
	zthr_wakeup(zfs_presage_zthr);
	return (err);
}

/*
 * Kill.  args->start == 0: remove every reservation on this file (or just
 * the exact range if one was given) and demote its headers now.
 * args->start != 0: cancel only pending reservations whose start is at or
 * after args->start; active ones are left alone.
 * A kill that matches no reservation does nothing and returns ENOENT: the
 * target's blocks are not walked, so a file without a reservation cannot
 * take presaged blocks away from a clone or dedup sibling that shares them.
 */
static int
zfs_presage_kill_impl(const zfs_presage_target_t *t, zfs_presage_args_t *args)
{
	zfs_presage_res_t key, *r, *next;
	zfs_presage_walk_t w;
	uint64_t removed = 0, pending_left = 0;
	boolean_t whole_file = (args->off == 0 && args->len == 0);
	boolean_t fenced, defer, walk;

	if (!zfs_presage_ready)
		return (SET_ERROR(ENOTSUP));
	zfs_presage_key(t, args, &key);

	mutex_enter(&zfs_presage_lock);
	fenced = zfs_presage_res_fenced(&key);
	defer = (fenced || args->start != 0);
	for (r = avl_first(&zfs_presage_tree); r != NULL; r = next) {
		next = AVL_NEXT(&zfs_presage_tree, r);
		if (r->pr_spa_guid != key.pr_spa_guid ||
		    r->pr_objset != key.pr_objset ||
		    r->pr_object != key.pr_object)
			continue;
		if (!whole_file &&
		    (r->pr_off != key.pr_off || r->pr_len != key.pr_len))
			continue;
		if (args->start != 0) {
			if (r->pr_state != PRS_PENDING)
				continue;
			uint64_t now = zfs_presage_now();
			uint64_t fire_wall = gethrestime_sec() +
			    (r->pr_fire > now ? r->pr_fire - now : 0);
			if (fire_wall < args->start) {
				pending_left++;
				continue;
			}
		}
		if (r->pr_busy) {
			/*
			 * The load stops at its next chunk; the zthr then
			 * retires the entry with a release walk.
			 */
			r->pr_expire = 0;
			removed++;
			continue;
		}
		/*
		 * With no release walk here (behind a fence, or a kill of
		 * pending ones) a range that needs one stays, cancelled, and
		 * the zthr releases it once no fence covers it.
		 */
		if ((defer && r->pr_owed) || (fenced &&
		    (r->pr_state == PRS_ACTIVE ||
		    r->pr_state == PRS_CANCELLED)))
			zfs_presage_cancel_entry(r);
		else
			zfs_presage_free(r);
		removed++;
	}
	walk = (removed != 0 && args->start == 0 &&
	    zfs_presage_walk_begin(&w, key.pr_spa_guid, key.pr_objset,
	    key.pr_kind));
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);

	args->pending = pending_left;
	args->presaged = args->cached = args->uncached = 0;
	args->warmed_at = args->expires_at = 0;

	if (removed == 0)
		return (SET_ERROR(ENOENT));
	if (!walk) {
		zthr_wakeup(zfs_presage_zthr);
		return (0);
	}

	/* Demote active headers now (release mode of the DMU walk). */
	uint64_t bytes = 0;
	int err = zfs_presage_target_apply(t, 0, args->off, args->len, 0,
	    ZFS_PRESAGE_RELEASE, &bytes, &args->cached, &args->uncached);
	/* Disabled, or a volume whose key is gone: nothing can be walked. */
	if (err == ENOTSUP || err == EACCES)
		err = 0;
	mutex_enter(&zfs_presage_lock);
	zfs_presage_walk_end(&w);
	/* Reservations that overlap the killed range keep theirs. */
	if (!whole_file)
		zfs_presage_resweep_siblings(&key);
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
	if (!whole_file)
		zthr_wakeup(zfs_presage_zthr);
	return (err);
}

/*
 * Pool export or destroy: forget every reservation on the pool.  The ARC
 * flushes the pool's headers; reservations are RAM state and go with them.
 * A busy entry is marked expired so the in-flight load undoes itself.
 */
void
zfs_presage_drop_pool(uint64_t spa_guid)
{
	zfs_presage_res_t *r, *next;

	if (!zfs_presage_ready)
		return;
	mutex_enter(&zfs_presage_lock);
	for (r = avl_first(&zfs_presage_tree); r != NULL; r = next) {
		next = AVL_NEXT(&zfs_presage_tree, r);
		if (r->pr_spa_guid != spa_guid)
			continue;
		if (r->pr_busy) {
			r->pr_expire = 0;
			continue;
		}
		zfs_presage_free(r);
	}
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
}

/*
 * A restore (rollback, or a receive into an existing dataset) replaced
 * the dataset's contents: what was predicted for the discarded state is
 * not presumed needed, so every reservation on the dataset is cancelled,
 * the same rule as export and destroy; the admin asks again after the
 * restore.  Only the tree is touched here, so this may be called from
 * syncing context (the channel-program rollback does).  The release walk
 * takes dnode holds and reads indirect blocks, so it runs on the zthr,
 * after a busy entry's load has stopped at its next chunk, and the zthr
 * is woken for it now; it is retried once a second for
 * ZFS_PRESAGE_CANCEL_GRACE seconds while the file does not resolve, then
 * the entry is dropped regardless.  Lock held; returns whether any
 * reservation was cancelled.
 */
static boolean_t
zfs_presage_cancel_objset(uint64_t spa_guid, uint64_t objset)
{
	boolean_t any = B_FALSE;

	ASSERT(MUTEX_HELD(&zfs_presage_lock));
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_spa_guid != spa_guid || r->pr_objset != objset)
			continue;
		zfs_presage_cancel_entry(r);
		any = B_TRUE;
	}
	if (any)
		zfs_presage_recompute_due();
	return (any);
}

void
zfs_presage_drop_objset(uint64_t spa_guid, uint64_t objset)
{
	boolean_t any;

	if (!zfs_presage_ready)
		return;
	mutex_enter(&zfs_presage_lock);
	any = zfs_presage_cancel_objset(spa_guid, objset);
	mutex_exit(&zfs_presage_lock);
	if (any)
		zthr_wakeup(zfs_presage_zthr);
}

/* The identity of a dataset by name, held only for the lookup. */
static boolean_t
zfs_presage_ds_identity(const char *dsname, uint64_t *guidp, uint64_t *objp)
{
	dsl_pool_t *dp;
	dsl_dataset_t *ds;

	if (dsl_pool_hold(dsname, FTAG, &dp) != 0)
		return (B_FALSE);
	if (dsl_dataset_hold(dp, dsname, FTAG, &ds) != 0) {
		dsl_pool_rele(dp, FTAG);
		return (B_FALSE);
	}
	*guidp = spa_guid(dp->dp_spa);
	*objp = ds->ds_object;
	dsl_dataset_rele(ds, FTAG);
	dsl_pool_rele(dp, FTAG);
	return (B_TRUE);
}

/*
 * Put up a fence on a dataset: mark what is in its scope so that loads
 * stop at their next chunk and the zthr leaves it alone, then wait,
 * bounded, for loads and walks in flight there to finish.  A volume walk
 * long-holds the dataset, which would fail a restore's check for holders
 * with EBUSY.
 */
static zfs_presage_fence_t *
zfs_presage_fence_begin(uint64_t spa_guid, uint64_t objset)
{
	zfs_presage_fence_t *f = kmem_alloc(sizeof (*f), KM_SLEEP);
	uint64_t giveup = zfs_presage_now() + ZFS_PRESAGE_CANCEL_GRACE;

	f->pf_spa_guid = spa_guid;
	f->pf_objset = objset;
	mutex_enter(&zfs_presage_lock);
	list_insert_tail(&zfs_presage_fences, f);
	for (;;) {
		boolean_t busy = zfs_presage_walking(f);

		for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree);
		    r != NULL; r = AVL_NEXT(&zfs_presage_tree, r)) {
			if (!zfs_presage_in_fence(f, r->pr_spa_guid,
			    r->pr_objset, r->pr_kind))
				continue;
			if (r->pr_state != PRS_CANCELLED)
				r->pr_restoring = B_TRUE;
			if (r->pr_busy)
				busy = B_TRUE;
		}
		if (!busy || zfs_presage_now() >= giveup)
			break;
		(void) cv_timedwait(&zfs_presage_cv, &zfs_presage_lock,
		    ddi_get_lbolt() + hz);
	}
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
	return (f);
}

/*
 * Take a fence down.  With cancel (a restore's), every reservation on its
 * dataset is cancelled.  What it held carries on unless another fence
 * still covers it; a cancelled entry gets its grace period back from now.
 */
static void
zfs_presage_fence_end(zfs_presage_fence_t *f, boolean_t cancel)
{
	boolean_t any = B_FALSE;

	mutex_enter(&zfs_presage_lock);
	list_remove(&zfs_presage_fences, f);
	if (cancel)
		any = zfs_presage_cancel_objset(f->pf_spa_guid, f->pf_objset);
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (!zfs_presage_in_fence(f, r->pr_spa_guid, r->pr_objset,
		    r->pr_kind) || zfs_presage_res_fenced(r))
			continue;
		if (r->pr_state == PRS_CANCELLED) {
			r->pr_fire = MAX(r->pr_fire,
			    zfs_presage_now() + ZFS_PRESAGE_CANCEL_GRACE);
			any = B_TRUE;
		} else if (r->pr_restoring) {
			r->pr_restoring = B_FALSE;
			any = B_TRUE;
		}
	}
	if (any)
		zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
	kmem_free(f, sizeof (*f));
	if (any)
		zthr_wakeup(zfs_presage_zthr);
}

/*
 * The restore ioctls (rollback, receive) bracket their work with these,
 * from open context with nothing held.  _begin, before the filesystem is
 * suspended, puts up a fence on the dataset: its reservations, and any
 * requested until _end, stop loading at their next chunk and are left
 * alone by the zthr, and kills and releases on it are deferred, so
 * nothing is read for the state about to be discarded, none is judged
 * gone while its filesystem is suspended, none re-sweeps the restored
 * file before it is cancelled, and no volume walk holds the dataset when
 * the restore checks for holders.  It returns what _end takes, NULL when
 * the dataset does not exist (yet).  _end, after the filesystem is
 * resumed: restored is whether the contents were in fact replaced; if so
 * the reservations are cancelled and released, as by
 * zfs_presage_drop_objset(); if not, they carry on.
 */
zfs_presage_fence_t *
zfs_presage_restore_begin(const char *dsname)
{
	uint64_t guid, objset;

	if (!zfs_presage_ready ||
	    !zfs_presage_ds_identity(dsname, &guid, &objset))
		return (NULL);
	return (zfs_presage_fence_begin(guid, objset));
}

void
zfs_presage_restore_end(zfs_presage_fence_t *f, boolean_t restored)
{
	if (f != NULL)
		zfs_presage_fence_end(f, restored);
}

/*
 * A filesystem is being unmounted.  Its reservations cannot outlive it
 * (a file is resolved through its mounted filesystem), and their blocks
 * must not: left alone they would stay presaged, against the cap, until
 * their deadlines with nothing able to release them, and for an encrypted
 * dataset that is decrypted data held in memory after its key is
 * unloaded.  So unmount is the same rule as export, destroy and restore:
 * the reservations are cancelled and the blocks released, here and now,
 * while the objset is still there to walk.  A load in flight is told to
 * stop and is waited for, bounded.  Called from zfs_umount() before the
 * teardown, from open context with nothing held.
 */
void
zfs_presage_unmount(objset_t *os)
{
	uint64_t guid = spa_guid(dmu_objset_spa(os));
	uint64_t objset = dmu_objset_id(os);
	zfs_presage_fence_t scope = { .pf_spa_guid = guid,
	    .pf_objset = objset };

	if (!zfs_presage_ready)
		return;
	mutex_enter(&zfs_presage_lock);
	uint64_t giveup = zfs_presage_now() + ZFS_PRESAGE_CANCEL_GRACE;
	for (;;) {
		zfs_presage_res_t *r;
		boolean_t busy = zfs_presage_walking(&scope);

		for (r = avl_first(&zfs_presage_tree); r != NULL;
		    r = AVL_NEXT(&zfs_presage_tree, r)) {
			if (r->pr_spa_guid != guid || r->pr_objset != objset ||
			    r->pr_kind != PR_FILE)
				continue;
			if (!r->pr_busy)
				break;
			r->pr_expire = 0;
			busy = B_TRUE;
		}
		if (r != NULL) {
			zfs_presage_res_t snap = *r;
			dmu_object_info_t doi;
			uint64_t b, c, u;

			zfs_presage_free(r);
			mutex_exit(&zfs_presage_lock);
			if (dmu_object_info(os, snap.pr_object, &doi) == 0 &&
			    snap.pr_off < doi.doi_max_offset) {
				uint64_t len = doi.doi_max_offset - snap.pr_off;
				if (snap.pr_len != 0 && snap.pr_len < len)
					len = snap.pr_len;
				(void) dmu_presage(os, snap.pr_object,
				    snap.pr_off, len, 0, ZFS_PRESAGE_RELEASE,
				    &b, &c, &u);
			}
			mutex_enter(&zfs_presage_lock);
			continue;
		}
		/*
		 * The walk we would wait for can be our own: on Linux the
		 * zthr's release of a file can drop the last reference to
		 * a superblock that is being unmounted and so arrive here.
		 * It stops at its next chunk on its own.
		 */
		if (!busy || zfs_presage_now() >= giveup ||
		    zthr_iscurthread(zfs_presage_zthr))
			break;
		(void) cv_timedwait(&zfs_presage_cv, &zfs_presage_lock,
		    ddi_get_lbolt() + hz);
	}
	zfs_presage_recompute_due();
	mutex_exit(&zfs_presage_lock);
}

/* A volume reservation that a key unload may have to release. */
typedef struct zfs_presage_cand {
	uint64_t	pc_id;
	uint64_t	pc_objset;
	boolean_t	pc_match;
} zfs_presage_cand_t;

/*
 * A key is about to be unloaded from dsname and everything that inherits
 * it.  Filesystems under it are unmounted by then (zfs_presage_unmount()
 * has dealt with them); volumes are not opened by a reservation at all,
 * so theirs are found here.  A fence goes up on every volume of the pool
 * first, so that no request, load or walk starts on one until
 * zfs_presage_unload_key_end(), and those in flight are waited for; then
 * every volume reservation on dsname or below is cancelled and its blocks
 * released while the key can still be used to walk them.  Nothing
 * decrypted stays presaged behind an unloaded key.  From open context
 * with nothing held; NULL when there is nothing to fence.
 */
zfs_presage_fence_t *
zfs_presage_unload_key(const char *dsname)
{
	size_t dlen = strlen(dsname);
	dsl_pool_t *dp;
	zfs_presage_fence_t *f;
	zfs_presage_cand_t *cand;
	uint64_t guid;
	int n, i;

	if (!zfs_presage_ready || dsl_pool_hold(dsname, FTAG, &dp) != 0)
		return (NULL);
	guid = spa_guid(dp->dp_spa);
	dsl_pool_rele(dp, FTAG);
	f = zfs_presage_fence_begin(guid, 0);

	mutex_enter(&zfs_presage_lock);
	n = avl_numnodes(&zfs_presage_tree);
	mutex_exit(&zfs_presage_lock);
	if (n == 0)
		return (f);
	cand = kmem_zalloc(n * sizeof (zfs_presage_cand_t), KM_SLEEP);

	/* Volume reservations on this pool, by id. */
	mutex_enter(&zfs_presage_lock);
	i = 0;
	for (zfs_presage_res_t *r = avl_first(&zfs_presage_tree);
	    r != NULL && i < n; r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_kind != PR_ZVOL || r->pr_spa_guid != guid)
			continue;
		cand[i].pc_id = r->pr_id;
		cand[i].pc_objset = r->pr_objset;
		i++;
	}
	mutex_exit(&zfs_presage_lock);

	/* Which of them are dsname or below it (no presage lock here). */
	if (i != 0 && dsl_pool_hold(dsname, FTAG, &dp) == 0) {
		for (int j = 0; j < i; j++) {
			char name[ZFS_MAX_DATASET_NAME_LEN];
			dsl_dataset_t *ds;

			if (dsl_dataset_hold_obj(dp, cand[j].pc_objset, FTAG,
			    &ds) != 0)
				continue;
			dsl_dataset_name(ds, name);
			dsl_dataset_rele(ds, FTAG);
			cand[j].pc_match = (strncmp(name, dsname, dlen) == 0 &&
			    (name[dlen] == '\0' || name[dlen] == '/'));
		}
		dsl_pool_rele(dp, FTAG);
	}

	for (int j = 0; j < i; j++) {
		zfs_presage_fence_t scope = { .pf_spa_guid = guid,
		    .pf_objset = cand[j].pc_objset };

		if (!cand[j].pc_match)
			continue;
		uint64_t giveup = zfs_presage_now() + ZFS_PRESAGE_CANCEL_GRACE;
		mutex_enter(&zfs_presage_lock);
		for (;;) {
			zfs_presage_res_t *r;

			for (r = avl_first(&zfs_presage_tree); r != NULL;
			    r = AVL_NEXT(&zfs_presage_tree, r)) {
				if (r->pr_id == cand[j].pc_id)
					break;
			}
			if (r == NULL) {
				/* Gone: another unload may be releasing it. */
				if (!zfs_presage_walking(&scope) ||
				    zfs_presage_now() >= giveup)
					break;
			} else if (!r->pr_busy) {
				zfs_presage_res_t snap = *r;
				zfs_presage_walk_t w;
				uint64_t b;

				/* Our own fence does not hold this walk off. */
				zfs_presage_free(r);
				zfs_presage_walk_enter(&w, snap.pr_spa_guid,
				    snap.pr_objset, snap.pr_kind);
				mutex_exit(&zfs_presage_lock);
				(void) zfs_presage_zvol_apply(&snap, 0,
				    snap.pr_off, snap.pr_len, 0,
				    ZFS_PRESAGE_RELEASE, &b, NULL, NULL);
				mutex_enter(&zfs_presage_lock);
				zfs_presage_walk_end(&w);
				break;
			} else {
				/*
				 * Loading past the fence's wait: stop it; it
				 * is then left cancelled for us to release.
				 */
				r->pr_expire = 0;
				if (zfs_presage_now() >= giveup)
					break;
			}
			(void) cv_timedwait(&zfs_presage_cv,
			    &zfs_presage_lock, ddi_get_lbolt() + hz);
		}
		zfs_presage_recompute_due();
		mutex_exit(&zfs_presage_lock);
	}
	kmem_free(cand, n * sizeof (zfs_presage_cand_t));
	return (f);
}

/* The key unload is over: volumes on the pool carry on. */
void
zfs_presage_unload_key_end(zfs_presage_fence_t *f)
{
	if (f != NULL)
		zfs_presage_fence_end(f, B_FALSE);
}

/*
 * Status: reservation facts; the caller has done the residency walk.
 */
static void
zfs_presage_status_impl(const zfs_presage_target_t *t,
    zfs_presage_args_t *args)
{
	zfs_presage_res_t key, *r;
	uint64_t pending = 0, warmed = 0, expires = 0;

	if (!zfs_presage_ready)
		return;
	zfs_presage_key(t, args, &key);
	mutex_enter(&zfs_presage_lock);
	for (r = avl_first(&zfs_presage_tree); r != NULL;
	    r = AVL_NEXT(&zfs_presage_tree, r)) {
		if (r->pr_spa_guid != key.pr_spa_guid ||
		    r->pr_objset != key.pr_objset ||
		    r->pr_object != key.pr_object ||
		    r->pr_state == PRS_CANCELLED)
			continue;
		if (r->pr_state == PRS_PENDING)
			pending++;
		warmed = MAX(warmed, r->pr_warmed_at);
		expires = MAX(expires, r->pr_wall_expire);
	}
	mutex_exit(&zfs_presage_lock);
	args->pending = pending;
	args->warmed_at = warmed;
	args->expires_at = expires;
}

/*
 * The file front ends (zfs_vnops.c): the znode is held and the
 * filesystem entered by the caller.
 */
int
zfs_presage_request(znode_t *zp, zfs_presage_args_t *args)
{
	zfs_presage_target_t t;

	zfs_presage_target_file(zp, &t);
	return (zfs_presage_request_impl(&t, args));
}

int
zfs_presage_kill(znode_t *zp, zfs_presage_args_t *args)
{
	zfs_presage_target_t t;

	zfs_presage_target_file(zp, &t);
	return (zfs_presage_kill_impl(&t, args));
}

void
zfs_presage_status(znode_t *zp, zfs_presage_args_t *args)
{
	zfs_presage_target_t t;

	zfs_presage_target_file(zp, &t);
	zfs_presage_status_impl(&t, args);
}

/*
 * The dataset-named front end (zfs_ioctl.c): a volume by name.  The name
 * is resolved once, briefly, to its identity (objset id, ZVOL_OBJ, dataset
 * guid as the generation); every walk after that holds the dataset a chunk
 * at a time.  Filesystems and snapshots are rejected with EINVAL.
 */
int
zfs_presage_dataset(const char *name, zfs_presage_args_t *args)
{
	zfs_presage_target_t t;
	objset_t *os;
	dsl_dataset_t *ds;
	spa_t *spa;
	int error;

	if ((args->flags & ~ZFS_PRESAGE_STATUS) != 0 ||
	    (args->reserved[0] | args->reserved[1] | args->reserved[2] |
	    args->reserved[3]) != 0)
		return (SET_ERROR(EINVAL));

	if ((error = dmu_objset_hold(name, FTAG, &os)) != 0)
		return (error);
	ds = dmu_objset_ds(os);
	if (dmu_objset_type(os) != DMU_OST_ZVOL || ds->ds_is_snapshot) {
		dmu_objset_rele(os, FTAG);
		return (SET_ERROR(EINVAL));
	}
	spa = dmu_objset_spa(os);
	memset(&t, 0, sizeof (t));
	t.pt_kind = PR_ZVOL;
	t.pt_spa_guid = spa_guid(spa);
	(void) strlcpy(t.pt_pool, spa_name(spa), sizeof (t.pt_pool));
	t.pt_objset = dmu_objset_id(os);
	t.pt_object = ZVOL_OBJ;
	t.pt_gen = dsl_dataset_phys(ds)->ds_guid;
	dmu_objset_rele(os, FTAG);

	args->presaged = args->cached = args->uncached = 0;
	args->pending = args->warmed_at = args->expires_at = 0;

	if (args->flags & ZFS_PRESAGE_STATUS) {
		zfs_presage_walk_t w;
		boolean_t walk;

		/* Behind a fence the residency is not walked: 0 bytes. */
		mutex_enter(&zfs_presage_lock);
		walk = zfs_presage_walk_begin(&w, t.pt_spa_guid, t.pt_objset,
		    t.pt_kind);
		mutex_exit(&zfs_presage_lock);
		if (walk) {
			error = zfs_presage_target_apply(&t, 0, args->off,
			    args->len, 0, ZFS_PRESAGE_STATUS, &args->presaged,
			    &args->cached, &args->uncached);
			mutex_enter(&zfs_presage_lock);
			zfs_presage_walk_end(&w);
			mutex_exit(&zfs_presage_lock);
		}
		zfs_presage_status_impl(&t, args);
	} else if (args->ttl == 0) {
		error = zfs_presage_kill_impl(&t, args);
	} else {
		error = zfs_presage_request_impl(&t, args);
	}
	return (error);
}
