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
#	A presaged block rewritten by a synchronous write that goes to
#	disk ahead of its transaction group (logbias=throughput) stays
#	presaged: the new copy is written in open context, while the file
#	still points at the old one, and takes the old copy's deadline
#	when the transaction group that adopts it is synced.  This is the
#	write pattern of a database that syncs what it rewrites.
# STRATEGY:
#	1. On a dataset with logbias=throughput, presage a 32 MiB file
#	   for 300 s: fully resident.
#	2. Shrink the dbuf cache so the file's dbufs are evicted and each
#	   rewrite gets a fresh buffer, which carries no deadline of its
#	   own.  Rewrite every record with an O_SYNC write and sync the
#	   pool: the file is fully presaged at once, without waiting for a
#	   sweep, and presaged_inherited rose by about the block count.
#	3. Kill the reservation: nothing remains presaged.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsinh
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((32 * mib / rs))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	restore_tunable DBUF_CACHE_MAX_BYTES
	arc_restore
}

log_assert "a presaged block rewritten by a synchronous write stays presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i pdata0=$(kstat arcstats.presaged_data)

# 1. resident
log_must zfs create -o compression=off -o logbias=throughput $fs
log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $size

# 2. synchronous whole-record rewrites from uncached dbufs inherit
log_must set_tunable64 DBUF_CACHE_MAX_BYTES $((64 * 1024))
sleep 2
typeset -i inh0=$(kstat arcstats.presaged_inherited)
log_must dd if=/dev/urandom of=$f bs=$rs count=$blocks conv=notrunc \
    oflag=sync
sync_pool $TESTPOOL
typeset -i i
for ((i = 0; i < 10; i++)); do
	[[ $(presaged_bytes $f) -eq $size ]] && break
	sleep 0.2
done
typeset -i inh1=$(kstat arcstats.presaged_inherited)
log_note "presaged $(presaged_bytes $f) of $size, inherited" \
    "+$((inh1 - inh0)) of $blocks blocks"
log_must test "$(presaged_bytes $f)" -eq $size
log_must test $((inh1 - inh0)) -ge $((blocks * 9 / 10))

# 3. nothing outlives the kill
log_must zfs presage -t 0 $f
presage_wait_clean $base
for ((i = 0; i < 75; i++)); do
	[[ $(kstat arcstats.presaged_data) -le $pdata0 ]] && break
	sleep 0.2
done
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(kstat arcstats.presaged_data)" -le $pdata0

log_pass "a presaged block rewritten by a synchronous write stays presaged"
