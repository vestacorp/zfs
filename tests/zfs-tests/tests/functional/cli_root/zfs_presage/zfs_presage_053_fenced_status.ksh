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
#	While a rollback of a volume is in flight, status on the volume
#	does not walk it (a walk holds the dataset, which can make the
#	rollback fail with EBUSY): it reports the reservation and 0
#	presaged bytes.  A request held off by the rollback reports no
#	warm time, since it loaded nothing.
# STRATEGY:
#	1. Write 32 MiB to a volume, presage it, snapshot it, change it.
#	2. Delay every write to the pool by one second and roll the
#	   volume back in the background.
#	3. While the rollback is in flight: status shows the reservation's
#	   deadline and 0 presaged bytes; a request for a sub-range
#	   reports 0 presaged and warm time 0.
#	4. Clear the delay: the rollback succeeds and both reservations
#	   are released.
#

verify_runnable "global"

typeset vol=$TESTPOOL/prsfence
typeset rbpid=""
typeset -i mib=$((1024 * 1024))
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	[[ -n $rbpid ]] && wait $rbpid
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && destroy_dataset $vol -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "status and requests during a rollback walk nothing"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. a presaged volume with something to roll back
log_must zfs create -V 64m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
[[ -n $dev ]] || log_unsupported "no block device for $vol (no udev rules)"
log_must dd if=/dev/urandom of=$dev bs=1M count=32 conv=fsync
sync_pool $TESTPOOL
log_must zfs presage -t 600 $vol
log_must test "$(presaged_bytes $vol)" -eq $((32 * mib))
log_must zfs snapshot $vol@s
log_must dd if=/dev/urandom of=$dev bs=1M count=1 seek=40 conv=fsync
sync_pool $TESTPOOL

# 2. a slow rollback
log_must zinject -d $DISK -D 1000:1 -T write $TESTPOOL
zfs rollback $vol@s &
rbpid=$!
sleep 2
kill -0 $rbpid 2>/dev/null || \
    log_unsupported "the rollback ended before the checks were made"

# 3. status and a request during the rollback
typeset st req
st=$(zfs presage status -p $vol)
req=$(zfs presage -p -t 600 -o 0 -l $((16 * mib)) $vol)
typeset -i rc=$?
kill -0 $rbpid 2>/dev/null || \
    log_unsupported "the rollback ended before the checks were done"
log_note "status during the rollback: $st"
log_note "request during the rollback: rc $rc, $req"
log_must test "$(echo "$st" | awk '{print $3}')" -eq 0
log_must test "$(echo "$st" | awk '{print $13}')" -gt 0
log_must test $rc -eq 0
log_must test "$(echo "$req" | awk '{print $3}')" -eq 0
log_must test "$(echo "$req" | awk '{print $11}')" -eq 0

# 4. the rollback succeeds; the reservations are released
log_must zinject -c all
wait $rbpid
rc=$?
rbpid=""
log_must test $rc -eq 0
presage_wait_clean $base

log_pass "status and requests during a rollback walk nothing"
