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
#	A presage of a mostly empty object costs time proportional to its
#	data, not its size: a 1 TiB sparse file with 2 MiB of data at its
#	end is presaged in seconds, and only the data is counted.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/sparse >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/sparse
}

log_assert "presage of a sparse file skips holes"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

# 2 MiB of data at offset 1 TiB; everything before it is a hole
log_must dd if=/dev/urandom of=$TESTDIR/sparse bs=1M count=2 \
    seek=$((1024 * 1024)) status=none
sync_pool $TESTPOOL
log_must test "$(stat_size $TESTDIR/sparse)" -gt $((1 << 40))

typeset -i t0=$(date +%s)
log_must zfs presage -t 60 $TESTDIR/sparse
typeset -i t1=$(date +%s)
log_must test $((t1 - t0)) -le 10
typeset -i p=$(presaged_bytes $TESTDIR/sparse)
log_must test $p -ge $((2 << 20))
log_must test $p -le $((3 << 20))
log_pass "presage of a sparse file skips holes"
