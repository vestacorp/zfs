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
#	The cap is enforced on request (ENOSPC, partial residency) and
#	follows the ARC target: lowering zfs_arc_max demotes within seconds.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/big >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $TESTDIR/big
}

log_assert "presage cap is enforced and shrinks with the ARC target"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_small $((512 * 1024 * 1024))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 10

log_must file_write -o create -f $TESTDIR/big -b 1048576 -c 256 -d R
sync_pool $TESTPOOL

log_mustnot zfs presage -t 600 $TESTDIR/big
typeset limit=$(kstat arcstats.presaged_limit)
log_must test "$(presaged_size)" -gt 0
log_must test "$(presaged_size)" -le $((limit + 1048576))

log_must set_tunable64 ARC_MAX $((256 * 1024 * 1024))
sleep 3
limit=$(kstat arcstats.presaged_limit)
log_must test "$(presaged_size)" -le $((limit + 1048576))
log_must test "$(kstat arcstats.presaged_demoted_cap)" -gt 0
log_pass "presage cap is enforced and shrinks with the ARC target"
