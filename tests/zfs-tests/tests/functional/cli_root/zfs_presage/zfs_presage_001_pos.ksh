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
#	A presaged file stays resident while a larger-than-ARC stream passes
#	through the cache, and an unpresaged control file does not.
#
# STRATEGY:
#	1. Enable presage, shrink the ARC to 256M.
#	2. Write a 64M file and a 64M control file; sync; export/import to
#	   start cold.
#	3. Presage the first file for 600s; status reports all of it.
#	4. Stream 1G of other data through the ARC.
#	5. Presaged file: still fully resident. Control: mostly evicted.
#	6. Kill the reservation.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/presaged >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $TESTDIR/presaged $TESTDIR/control $TESTDIR/stream
}

log_assert "zfs presage keeps file data resident under cache pressure"
log_onexit cleanup

save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
arc_small $((256 * 1024 * 1024))

log_must file_write -o create -f $TESTDIR/presaged -b 1048576 -c 64 -d R
log_must file_write -o create -f $TESTDIR/control -b 1048576 -c 64 -d R
log_must file_write -o create -f $TESTDIR/stream -b 1048576 -c 1024 -d R
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

log_must zfs presage -t 600 $TESTDIR/presaged
typeset size=$(stat_size $TESTDIR/presaged)
log_must test "$(presaged_bytes $TESTDIR/presaged)" -eq $size
log_must cat $TESTDIR/control > /dev/null

log_must dd if=$TESTDIR/stream of=/dev/null bs=1M

log_must test "$(presaged_bytes $TESTDIR/presaged)" -eq $size
typeset cached=$(cached_bytes $TESTDIR/control)
log_must test $cached -lt $((size / 2))

log_must zfs presage -t 0 $TESTDIR/presaged
sleep 2
log_must test "$(presaged_bytes $TESTDIR/presaged)" -eq 0
log_pass "zfs presage keeps file data resident under cache pressure"
