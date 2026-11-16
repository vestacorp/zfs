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
#	Export drops every presaged header of the pool and cancels its
#	pending reservations, also when the blocks were reloaded by a second
#	request just before the export (the reload is a prefetch hit, and a
#	prefetch buffer's minimum lifespan must not hide a presaged header
#	from the flush).  A rewrite (zfs rewrite, in place) keeps the file
#	presaged: the rewritten blocks inherit the deadline.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL || log_must zpool import $TESTPOOL
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "export releases presaged blocks; a rewrite keeps them"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 64 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 $TESTDIR/f
log_must zfs presage -s +120s -t 60 -o 0 -l 131072 $TESTDIR/f
log_must test "$(presaged_size)" -gt 0
log_must zpool export $TESTPOOL
log_must test "$(presaged_size)" -eq 0
log_must zpool import $TESTPOOL
log_must test "$(pending_count $TESTDIR/f)" -eq 0
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0

# A second request reloads blocks already presaged; export at once.
log_must zfs presage -t 600 $TESTDIR/f
log_must zfs presage -t 600 $TESTDIR/f
log_must zpool export $TESTPOOL
typeset i
for i in 1 2 3 4 5; do
	[[ $(presaged_size) -eq 0 ]] && break
	sleep 1
done
log_must test "$(presaged_size)" -eq 0
log_must zpool import $TESTPOOL

log_must zfs presage -t 600 $TESTDIR/f
typeset -i size=$(stat_size $TESTDIR/f)
log_must test "$(presaged_bytes $TESTDIR/f)" -eq $size
typeset -i inherited=$(kstat arcstats.presaged_inherited)
log_must zfs rewrite $TESTDIR/f
sync_pool $TESTPOOL
log_must test "$(presaged_bytes $TESTDIR/f)" -eq $size
log_must test "$(kstat arcstats.presaged_inherited)" -ge $((inherited + 64))
log_pass "export releases presaged blocks; a rewrite keeps them"
