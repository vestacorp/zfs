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
#	The limit bounds the presaged blocks themselves.  Reading presaged
#	data makes copies of it in the dbuf cache; those must not push the
#	set over the limit, cost the file blocks of its own, or get a
#	request refused that fits.
# STRATEGY:
#	1. ARC fixed at 1 GiB, limit 10 % (about 102 MiB).  Presage a
#	   96 MiB file: fully resident.
#	2. Read the file twice, which fills the dbuf cache (up to 1/32 of
#	   the ARC, 32 MiB) with copies of its blocks.  The file is still
#	   fully presaged, nothing was demoted for the cap, and
#	   presaged_counted, which is what the limit is compared with, is
#	   within it.
#	3. Presage a 4 MiB file, which fits under the limit: accepted and
#	   fully resident.
#

verify_runnable "global"

typeset f1=$TESTDIR/cc1
typeset f2=$TESTDIR/cc2
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f1 >/dev/null 2>&1
	zfs presage -t 0 $f2 >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $f1 $f2
}

log_assert "copies in the dbuf cache do not count against the presage limit"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 10
typeset -i base=$(kstat presage.reservations)

log_must file_write -o create -f $f1 -b 131072 -c 768 -d R
log_must file_write -o create -f $f2 -b 131072 -c 32 -d R
sync_pool $TESTPOOL
typeset -i size1=$(stat_size $f1) size2=$(stat_size $f2)

# 1. resident, under the limit
log_must zfs presage -t 600 $f1
log_must test "$(presaged_bytes $f1)" -eq $size1
typeset -i cap=$(kstat arcstats.presaged_limit)
typeset -i demoted0=$(kstat arcstats.presaged_demoted_cap)

# 2. reading it does not cost it its own blocks
log_must dd if=$f1 of=/dev/null bs=1M
log_must dd if=$f1 of=/dev/null bs=1M
sleep 3
log_note "limit $cap: file $(presaged_bytes $f1) of $size1 presaged," \
    "presaged_counted $(kstat arcstats.presaged_counted)," \
    "presaged_size $(presaged_size)," \
    "dbuf cache $(kstat dbufstats.cache_size_bytes)"
log_must test "$(presaged_bytes $f1)" -eq $size1
log_must test "$(kstat arcstats.presaged_demoted_cap)" -eq $demoted0
log_must test "$(kstat arcstats.presaged_counted)" -le $((cap + mib))

# 3. a request that fits is accepted
log_must zfs presage -t 600 $f2
log_must test "$(presaged_bytes $f2)" -eq $size2
log_must test "$(presaged_bytes $f1)" -eq $size1

log_must zfs presage -t 0 $f1
log_must zfs presage -t 0 $f2
presage_wait_clean $base

log_pass "copies in the dbuf cache do not count against the presage limit"
