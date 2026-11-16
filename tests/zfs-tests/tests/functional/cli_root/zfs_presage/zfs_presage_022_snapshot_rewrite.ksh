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
#	Rewriting a presaged file under a snapshot does not grow the
#	presaged state.  The snapshot keeps the overwritten blocks alive, so
#	no free ever takes their headers out; the lookup that carries the
#	deadline to the new copy (zfs_presage_020) moves it off the old one,
#	which is demoted there and then.
#
# STRATEGY:
#	1. Presage a 64 MiB file for 300 s; shrink the dbuf cache so every
#	   rewrite starts from an uncached dbuf.
#	2. Three times: snapshot, rewrite the file whole record by whole
#	   record, sync.  After each pass the file is 1.000 presaged and
#	   presaged_size is within 4 MiB of its value before the first
#	   snapshot (it grew by the file's size per pass before this rule).
#

verify_runnable "global"

typeset fs=$TESTPOOL/prssnaprw
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((64 * mib / rs))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable DBUF_CACHE_MAX_BYTES
	datasetexists $fs && log_must zfs destroy -r $fs
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a rewrite under a snapshot does not grow the presaged state"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

log_must zfs create $fs
log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)

# 1. resident; the dbuf cache lets go of the file
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $size
log_must set_tunable64 DBUF_CACHE_MAX_BYTES $((64 * 1024))
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat dbufstats.cache_size_bytes) -lt $rs ]] && break
	sleep 0.2
done
typeset -i set0=$(presaged_size)

# 2. snapshot, rewrite, three times
typeset -i pass
for pass in 1 2 3; do
	log_must zfs snapshot $fs@s$pass
	log_must dd if=/dev/urandom of=$f bs=$rs count=$blocks conv=notrunc
	sync_pool $TESTPOOL
	for ((i = 0; i < 10; i++)); do
		[[ $(presaged_bytes $f) -eq $size ]] && break
		sleep 0.2
	done
	log_note "pass $pass: file $(presaged_bytes $f) of $size presaged," \
	    "presaged_size $(presaged_size) (before the snapshots $set0)"
	log_must test "$(presaged_bytes $f)" -eq $size
	log_must test "$(presaged_size)" -le $((set0 + 4 * mib))
done

log_must zfs presage -t 0 $f
presage_wait_clean $base
presage_wait_settled $((psize0 + mib))

log_pass "a rewrite under a snapshot does not grow the presaged state"
