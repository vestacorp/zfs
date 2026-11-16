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
#	A walk of a presaged file that runs while a transaction group is
#	rewriting it does not put the overwritten copies back.  When the
#	write of a block is issued its deadline moves to the new copy; the
#	file's block pointer still names the old copy until the write is
#	ready, and a mark through that pointer would leave the old copy
#	presaged for as long as a snapshot keeps the block.  The walk skips
#	blocks that are being rewritten.
#
# STRATEGY:
#	1. Presage a 64 MiB file; shrink the dbuf cache so rewrites take
#	   the lookup path; snapshot; rewrite the whole file.
#	2. Slow writes with zinject so the sync takes several seconds, start
#	   it, and two seconds in ask for the file again: an inline walk in
#	   the middle of the sync.
#	3. After the sync the whole file is presaged and presaged_size is
#	   where it was before the rewrite, not larger by the blocks that
#	   were still in flight.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsresweep
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024)) rs=131072
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && log_must zfs destroy -r $fs
	restore_tunable DBUF_CACHE_MAX_BYTES
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a walk during a sync does not re-mark overwritten copies"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. presaged file, tiny dbuf cache, snapshot, whole-file rewrite
log_must zfs create -o compression=off $fs
log_must file_write -o create -f $f -b $rs -c 512 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $((64 * mib))
log_must set_tunable64 DBUF_CACHE_MAX_BYTES 65536
sleep 1
typeset -i psize1=$(presaged_size)
log_must zfs snapshot $fs@s1
log_must dd if=/dev/urandom of=$f bs=$rs count=512 conv=notrunc

# 2. 15 ms per write, one at a time: the sync takes about 8 s
log_must zinject -d $DISK -D 15:1 -T write $TESTPOOL
zpool sync $TESTPOOL &
typeset pid=$!
sleep 2
log_must zfs presage -t 300 $f
wait $pid
typeset -i rc=$?
log_must zinject -c all
log_must test $rc -eq 0

# 3. the file, and nothing but the file
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(presaged_bytes $f) -eq $((64 * mib)) ]] && break
	sleep 0.2
done
log_note "after the sync: file $(presaged_bytes $f) presaged," \
    "presaged_size $(presaged_size) (before the rewrite $psize1)"
log_must test "$(presaged_bytes $f)" -eq $((64 * mib))
log_must test "$(presaged_size)" -le $((psize1 + 4 * mib))

log_must zfs presage -t 0 $f
presage_wait_clean $base

log_pass "a walk during a sync does not re-mark overwritten copies"
