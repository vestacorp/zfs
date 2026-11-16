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
#	A block rewritten by a synchronous write that goes to disk ahead
#	of its transaction group (logbias=throughput) is written while
#	the file still points at the old copy.  When that transaction
#	group is synced the old copy must leave the presaged state: under
#	a snapshot nothing else would end it before the deadline, and it
#	would outlive a kill of the reservation.  The snapshot's copy of
#	the file names exactly those old blocks.
# STRATEGY:
#	1. On a dataset with logbias=throughput, presage a 32 MiB file
#	   for ten minutes and snapshot: the snapshot's copy reports all
#	   of it presaged.
#	2. Rewrite the file with whole-record O_SYNC writes and sync:
#	   the snapshot's copy reports nothing presaged.
#	3. Kill the reservation: no presaged data remains.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prssync
typeset snap=/$fs/.zfs/snapshot/s1
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((32 * mib / rs))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a block rewritten by a synchronous write leaves the presaged" \
    "state under a snapshot"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i pdata0=$(kstat arcstats.presaged_data)

# 1. a presaged file and a snapshot that keeps its blocks
log_must zfs create -o compression=off -o logbias=throughput $fs
log_must file_write -o create -f /$fs/f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 /$fs/f
log_must zfs snapshot $fs@s1
log_must test "$(presaged_bytes $snap/f)" -eq $((32 * mib))

# 2. rewrite every record with a synchronous write
log_must dd if=/dev/urandom of=/$fs/f bs=$rs count=$blocks conv=notrunc \
    oflag=sync
sync_pool $TESTPOOL
typeset -i i
for ((i = 0; i < 75; i++)); do
	[[ $(presaged_bytes $snap/f) -eq 0 ]] && break
	sleep 0.2
done
log_note "the snapshot's copy: $(presaged_bytes $snap/f) presaged; the" \
    "file: $(presaged_bytes /$fs/f); presaged_data" \
    "$(kstat arcstats.presaged_data), was $pdata0"
log_must test "$(presaged_bytes $snap/f)" -eq 0

# 3. nothing outlives the kill
log_must zfs presage -t 0 /$fs/f
presage_wait_clean $base
for ((i = 0; i < 75; i++)); do
	[[ $(kstat arcstats.presaged_data) -le $pdata0 ]] && break
	sleep 0.2
done
log_must test "$(kstat arcstats.presaged_data)" -le $pdata0

log_pass "a block rewritten by a synchronous write leaves the presaged" \
    "state under a snapshot"
