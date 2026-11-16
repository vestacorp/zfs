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
#	While a restore of its dataset is in flight, a reservation is left
#	alone by the presage thread, and the thread sleeps: a re-sweep
#	time that passes during the restore must not keep it running
#	without a pause until the restore ends.
# STRATEGY:
#	1. Presage a file; snapshot the dataset and change it.
#	2. Delay every write to the pool by one second and roll back in
#	   the background, so the restore lasts well past the
#	   reservation's next re-sweep time (five seconds).
#	3. From six to nine seconds after the presage, while the rollback
#	   is still in flight, the zfs_presage thread uses less than half
#	   a second of CPU time.
#	4. Clear the delay: the rollback succeeds and the reservation is
#	   released.
#

verify_runnable "global"

is_linux || log_unsupported "reads the presage thread's CPU time from /proc"

typeset fs=$TESTPOOL/prsidle
typeset f=/$fs/f
typeset rbpid=""
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	[[ -n $rbpid ]] && wait $rbpid
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

# utime + stime of a thread, in clock ticks
function cpu_ticks # pid
{
	awk '{print $14 + $15}' /proc/$1/stat
}

log_assert "the presage thread sleeps while a restore holds a reservation"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i hz=$(getconf CLK_TCK)
typeset zpid=$(pgrep -x zfs_presage | head -1)
[[ -n $zpid ]] || log_fail "no zfs_presage thread"

# 1. a presaged file on a dataset with something to roll back
log_must zfs create $fs
log_must file_write -o create -f $f -b 131072 -c 64 -d R
log_must zfs snapshot $fs@s
log_must file_write -o create -f /$fs/g -b 131072 -c 8 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 $f
typeset -i t0=$SECONDS

# 2. a slow rollback
log_must zinject -d $DISK -D 1000:1 -T write $TESTPOOL
zfs rollback $fs@s &
rbpid=$!

# 3. CPU time of the presage thread past the re-sweep time
while ((SECONDS - t0 < 6)); do
	sleep 0.2
done
typeset -i c0=$(cpu_ticks $zpid)
sleep 3
typeset -i c1=$(cpu_ticks $zpid)
kill -0 $rbpid 2>/dev/null || \
    log_unsupported "the rollback ended before the measurement did"
log_note "zfs_presage used $((c1 - c0)) ticks in 3 s (hz $hz)"
log_must test $((c1 - c0)) -lt $((hz / 2))

# 4. the rollback completes and releases the reservation
log_must zinject -c all
wait $rbpid
typeset -i rc=$?
rbpid=""
log_must test $rc -eq 0
presage_wait_clean $base

log_pass "the presage thread sleeps while a restore holds a reservation"
