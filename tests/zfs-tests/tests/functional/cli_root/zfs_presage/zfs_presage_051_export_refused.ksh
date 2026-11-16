#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#
# Copyright (c) 2026, Vesta Corporation.
# Copyright (c) 2026, Todd Curry.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	An export that is refused leaves the pool's reservations alone.
#	Dropping them before the refusal for an active shared spare
#	would leave the pool imported with its volumes' blocks presaged
#	and no reservation to show or kill.
# STRATEGY:
#	1. Make two pools that share a spare, and a volume on the first;
#	   presage the volume.
#	2. Put the spare in use in the first pool: its export is refused.
#	3. The reservation is still there with the same deadline, and a
#	   kill finds it.
#

verify_runnable "global"

typeset dir=$TEST_BASE_DIR/prsexdev
typeset vol=$TESTPOOL1/vol

function cleanup
{
	zfs presage -t 0 $vol >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	poolexists $TESTPOOL2 && destroy_pool $TESTPOOL2
	rm -rf $dir
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a refused export leaves the pool's reservations alone"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. two pools sharing a spare; a presaged volume on the first
log_must mkdir -p $dir
typeset -i i
for ((i = 0; i < 5; i++)); do
	log_must truncate -s $MINVDEVSIZE $dir/vdev$i
done
log_must zpool create $TESTPOOL1 mirror $dir/vdev0 $dir/vdev1 \
    spare $dir/vdev4
log_must zpool create $TESTPOOL2 mirror $dir/vdev2 $dir/vdev3 \
    spare $dir/vdev4
log_must zfs create -V 32m $vol
log_must zfs presage -t 600 $vol
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
typeset -i exp0=$(expires_at $vol)
log_must test $exp0 -gt 0

# 2. the export is refused
log_must zpool replace $TESTPOOL1 $dir/vdev0 $dir/vdev4
log_mustnot zpool export $TESTPOOL1
log_must poolexists $TESTPOOL1

# 3. the reservation is intact
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
log_must test "$(expires_at $vol)" -eq $exp0
log_must zfs presage -t 0 $vol
presage_wait_clean $base

log_pass "a refused export leaves the pool's reservations alone"
