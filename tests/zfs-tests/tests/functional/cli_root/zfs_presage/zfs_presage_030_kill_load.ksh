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

. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	A kill that arrives while "zfs presage" is still loading the file
#	leaves nothing behind.  The load stops at its next 64 MiB step,
#	but that step may mark its blocks after the kill's own release
#	walk has passed them; the reservation is therefore retired with a
#	second release walk, not left for its deadline.
#
# STRATEGY:
#	1. Write a 512 MiB file on recordsize=16k and empty the ARC by
#	   export and import.
#	2. Slow reads with zinject, start "zfs presage -t 600" in the
#	   background, and kill it one second into the load.
#	3. Both commands succeed; within seconds the reservation is gone,
#	   nothing of the file is presaged and presaged_size is back at
#	   its starting value.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prskill
typeset f=/$fs/f
typeset out=$TEST_BASE_DIR/presage_030.out
typeset -i mib=$((1024 * 1024))
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && destroy_dataset $fs -r
	rm -f $out
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a kill during a load leaves nothing presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 75
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a cold 512 MiB file
log_must zfs create -o recordsize=16k -o compression=off $fs
log_must dd if=/dev/urandom of=$f bs=1M count=512
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

# 2. 20 ms per read on 64 lanes: a 64 MiB step takes about 1.3 s
log_must zinject -d $DISK -D 20:64 -T read $TESTPOOL
zfs presage -t 600 $f >$out 2>&1 &
typeset pid=$!
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat presage.loads) -ge 1 ]] && break
	sleep 0.1
done
log_must test "$(kstat presage.loads)" -ge 1
sleep 1
log_must zfs presage -t 0 $f
wait $pid
typeset -i rc=$?
log_must zinject -c all
log_note "the load returned $rc: $(cat $out)"
log_must test $rc -eq 0

# 3. nothing left
presage_wait_clean $base
presage_wait_settled $((psize0 + mib)) 15
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(expires_at $f)" -eq 0

log_pass "a kill during a load leaves nothing presaged"
