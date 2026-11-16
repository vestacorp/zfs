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
#	A flush of the ARC evicts presaged headers to a ghost list.  The
#	ghost must not keep the deadline: read back and rewritten, the
#	block would return to the presaged state with nobody asking.
# STRATEGY:
#	1. Presage a 16 MiB file for 600 s, shrink the dbuf cache so that
#	   nothing holds its headers, flush the ARC (zinject -a): nothing
#	   of the file is presaged.  Kill the reservation.
#	2. Read the file (ghost hits) and rewrite it in place, then sync:
#	   nothing of it is presaged and presaged_data is where it began.
#

verify_runnable "global"

typeset f=$TESTDIR/fg
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((16 * mib / rs))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	restore_tunable DBUF_CACHE_MAX_BYTES
	arc_restore
	rm -f $f
}

log_assert "a presaged header evicted by a flush forgets its deadline"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i pdata0=$(kstat arcstats.presaged_data)

log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)
log_must zfs presage -t 600 $f
log_must test "$(presaged_bytes $f)" -eq $size

# 1. flush, then end the reservation
log_must set_tunable64 DBUF_CACHE_MAX_BYTES $((64 * 1024))
sleep 2
log_must zinject -a
log_note "after the flush: $(presaged_bytes $f) presaged"
log_must test "$(presaged_bytes $f)" -eq 0
zfs presage -t 0 $f
presage_wait_clean $base
log_must restore_tunable DBUF_CACHE_MAX_BYTES

# 2. bring the blocks back and rewrite them through their headers
log_must dd if=$f of=/dev/null bs=1M
log_must dd if=/dev/urandom of=$f bs=$((rs / 2)) count=$((blocks * 2)) \
    conv=notrunc
sync_pool $TESTPOOL
sleep 2
log_note "after the rewrite: $(presaged_bytes $f) presaged, presaged_data" \
    "$(kstat arcstats.presaged_data) (was $pdata0)"
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(kstat arcstats.presaged_data)" -le $pdata0

log_pass "a presaged header evicted by a flush forgets its deadline"
