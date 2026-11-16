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
#	An indirect block of a presaged file that is rewritten gives its
#	deadline to the new copy, also when a snapshot keeps the old copy
#	and a reader of the snapshot holds a buffer on its ARC header.
#	arc_release() then leaves the old header in place instead of
#	reusing it, and without the move the old copy would stay presaged
#	until its deadline, out of reach of a kill, counted against the
#	cap.
#
# STRATEGY:
#	1. Presage a 64 MiB file of 4k records (16 indirect blocks) for
#	   ten minutes and snapshot it.
#	2. Ask for the status of the snapshot's copy, which reads the 16
#	   indirect blocks through the snapshot and leaves them cached.
#	3. Rewrite the file in place and sync: every indirect block is
#	   rewritten; the file is still presaged in full.
#	4. Kill the reservation: no presaged data remains, and less
#	   presaged metadata than two of the old indirect blocks would be.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsind
typeset f=/$fs/file
typeset snap=/$fs/.zfs/snapshot/s1
typeset -i mib=$((1024 * 1024))
typeset -i size=$((64 * mib))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a rewritten indirect block does not stay presaged in a snapshot"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i pdata0=$(kstat arcstats.presaged_data)
typeset -i pmeta0=$(kstat arcstats.presaged_metadata)

# 1. a presaged file with 16 indirect blocks, and a snapshot
log_must zfs create -o compression=off -o recordsize=4k $fs
log_must file_write -o create -f $f -b 4096 -c 16384 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 $f
log_must test "$(presaged_bytes $f)" -eq $size
log_must zfs snapshot $fs@s1

# 2. the snapshot's indirect blocks are read and stay cached
log_must test "$(presaged_bytes $snap/file)" -eq $size
typeset -i pmeta1=$(kstat arcstats.presaged_metadata)

# 3. rewrite every block in place
log_must dd if=/dev/urandom of=$f bs=4096 count=16384 conv=notrunc
sync_pool $TESTPOOL
typeset -i i
for ((i = 0; i < 25; i++)); do
	[[ $(presaged_bytes $f) -eq $size ]] && break
	sleep 0.2
done
log_must test "$(presaged_bytes $f)" -eq $size
log_note "presaged_metadata $pmeta0 at the start, $pmeta1 before the" \
    "rewrite, $(kstat arcstats.presaged_metadata) after it"

# 4. nothing of the file is left once its reservation is killed
log_must zfs presage -t 0 $f
presage_wait_clean $base
for ((i = 0; i < 75; i++)); do
	[[ $(kstat arcstats.presaged_data) -le $pdata0 &&
	    $(kstat arcstats.presaged_metadata) -le $((pmeta0 + 65536)) ]] &&
	    break
	sleep 0.2
done
log_note "after the kill: presaged_data $(kstat arcstats.presaged_data)" \
    "(was $pdata0), presaged_metadata" \
    "$(kstat arcstats.presaged_metadata) (was $pmeta0)"
log_must test "$(kstat arcstats.presaged_data)" -le $pdata0
log_must test "$(kstat arcstats.presaged_metadata)" -le $((pmeta0 + 65536))

log_pass "a rewritten indirect block does not stay presaged in a snapshot"
