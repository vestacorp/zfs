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
#	A request for a volume made while a rollback of it is in flight
#	loads nothing until the rollback ends.  Loading at once would
#	be for the state about to be discarded, and would hold the
#	dataset chunk by chunk, which can make the rollback fail with
#	EBUSY.
# STRATEGY:
#	1. Write 32 MiB to a volume, snapshot it, change it.
#	2. Delay every write to the pool by one second and roll the
#	   volume back in the background.
#	3. While the rollback is in flight, presage the volume: the
#	   request succeeds and reports 0 bytes presaged.
#	4. Clear the delay: the rollback succeeds and the reservation,
#	   made for the discarded state, is released.
#

verify_runnable "global"

typeset vol=$TESTPOOL/prsrbvol
typeset rbpid=""
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	[[ -n $rbpid ]] && wait $rbpid
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && destroy_dataset $vol -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a request made during a rollback waits for the rollback"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. a volume with data and something to roll back
log_must zfs create -V 64m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
[[ -n $dev ]] || log_unsupported "no block device for $vol (no udev rules)"
log_must dd if=/dev/urandom of=$dev bs=1M count=32 conv=fsync
sync_pool $TESTPOOL
log_must zfs snapshot $vol@s
log_must dd if=/dev/urandom of=$dev bs=1M count=1 seek=40 conv=fsync
sync_pool $TESTPOOL

# 2. a slow rollback
log_must zinject -d $DISK -D 1000:1 -T write $TESTPOOL
zfs rollback $vol@s &
rbpid=$!
sleep 2
kill -0 $rbpid 2>/dev/null || \
    log_unsupported "the rollback ended before the request was made"

# 3. the request loads nothing yet
typeset out
out=$(zfs presage -p -t 600 $vol)
typeset -i rc=$?
typeset -i bytes=$(echo "$out" | awk '{print $3}')
kill -0 $rbpid 2>/dev/null || \
    log_unsupported "the rollback ended before the request returned"
log_note "request during the rollback: rc $rc, presaged $bytes"
log_must test $rc -eq 0
log_must test $bytes -eq 0

# 4. the rollback succeeds; the reservation is released
log_must zinject -c all
wait $rbpid
rc=$?
rbpid=""
log_must test $rc -eq 0
presage_wait_clean $base

log_pass "a request made during a rollback waits for the rollback"
