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
#	-t 0 cancels pending reservations; with -s it cancels only those
#	starting at or after the given time and leaves active ones alone.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "kill cancels pending reservations"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 16 -d R
sync_pool $TESTPOOL

log_must zfs presage -s +300s -t 60 $TESTDIR/f
log_must test "$(pending_count $TESTDIR/f)" -eq 1
log_must zfs presage -t 0 $TESTDIR/f
log_must test "$(pending_count $TESTDIR/f)" -eq 0

# active now + pending later; a timed kill removes only the pending one
log_must zfs presage -t 120 $TESTDIR/f
log_must zfs presage -s +300s -t 60 -o 0 -l 131072 $TESTDIR/f
log_must test "$(pending_count $TESTDIR/f)" -eq 1
log_must zfs presage -s +200s -t 0 $TESTDIR/f
log_must test "$(pending_count $TESTDIR/f)" -eq 0
log_must test "$(presaged_bytes $TESTDIR/f)" -gt 0
log_must zfs presage -t 0 $TESTDIR/f
log_pass "kill cancels pending reservations"
