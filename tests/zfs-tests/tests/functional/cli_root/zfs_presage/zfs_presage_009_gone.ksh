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
#	A pending reservation on a file that is deleted, or replaced by a new
#	file with the same name, before its start time is cancelled quietly.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "pending reservations on deleted or replaced files cancel"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 16 -d R
sync_pool $TESTPOOL
log_must zfs presage -s +4s -t 60 $TESTDIR/f
log_must rm $TESTDIR/f
sync_pool $TESTPOOL
sleep 7

# a new file under the same name is unaffected
log_must file_write -o create -f $TESTDIR/f -b 131072 -c 16 -d R
sync_pool $TESTPOOL
log_must test "$(pending_count $TESTDIR/f)" -eq 0
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_must zfs presage -t 30 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -gt 0
log_pass "pending reservations on deleted or replaced files cancel"
