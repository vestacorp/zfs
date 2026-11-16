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
#	Blocks written into a presaged range during the reservation window
#	become presaged within a few seconds of syncing, with no further
#	request ("zfs presage f && backup > f").
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "blocks written during the window are presaged by the re-sweep"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must touch $TESTDIR/f
log_must zfs presage -t 120 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 64 -d R
sync_pool $TESTPOOL
typeset size=$(stat_size $TESTDIR/f)
typeset i
for i in 1 2 3 4 5 6 7 8; do
	[[ $(presaged_bytes $TESTDIR/f) -eq $size ]] && break
	sleep 2
done
log_must test "$(presaged_bytes $TESTDIR/f)" -eq $size
log_pass "blocks written during the window are presaged by the re-sweep"
