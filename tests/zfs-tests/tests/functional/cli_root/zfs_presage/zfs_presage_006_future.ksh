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
#	A reservation with a future start loads at that time, not before,
#	and status reports pending, warmed and expiry.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "a future start time loads at the right time and not before"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 64 -d R
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
typeset size=$(stat_size $TESTDIR/f)

typeset t0=$(date +%s)
log_must zfs presage -s +6s -t 60 $TESTDIR/f
log_must test "$(pending_count $TESTDIR/f)" -eq 1
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_must test "$(warmed_at $TESTDIR/f)" -eq 0
sleep 3
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
sleep 6
log_must test "$(pending_count $TESTDIR/f)" -eq 0
log_must test "$(presaged_bytes $TESTDIR/f)" -eq $size
typeset w=$(warmed_at $TESTDIR/f)
log_must test $((w - t0)) -ge 5
log_must test $((w - t0)) -le 9
log_must test $(($(expires_at $TESTDIR/f) - t0)) -ge 64
log_pass "a future start time loads at the right time and not before"
