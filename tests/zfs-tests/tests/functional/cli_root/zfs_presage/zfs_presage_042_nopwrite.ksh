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
#	A presaged block rewritten with the same contents on a dataset
#	where that is a nopwrite keeps its presage.  The write completes
#	with the block's old header still in place; the deadline the new
#	buffer took from it has to go back.
# STRATEGY:
#	1. On a dataset with checksum=sha256 and compression=lz4, write a
#	   32 MiB file of compressible data and keep a copy of it
#	   elsewhere; presage the file for 300 s.
#	2. Shrink the dbuf cache so each rewrite starts from a fresh
#	   buffer, write the same data over the file with whole-record
#	   writes and sync: the writes are nopwrites and the file is still
#	   fully presaged.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsnop
typeset f=/$fs/f
typeset copy=$TESTDIR/prsnop.copy
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((32 * mib / rs))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	restore_tunable DBUF_CACHE_MAX_BYTES
	arc_restore
	rm -f $copy
}

log_assert "a nopwrite of a presaged block keeps it presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

log_must zfs create -o checksum=sha256 -o compression=lz4 $fs
# compressible, and different in every record
log_must eval "seq 1 5000000 | head -c $((32 * mib)) > $copy"
log_must dd if=$copy of=$f bs=$rs
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $size

log_must set_tunable64 DBUF_CACHE_MAX_BYTES $((64 * 1024))
sleep 2
typeset -i used0=$(get_prop used $fs)
log_must dd if=$copy of=$f bs=$rs conv=notrunc
sync_pool $TESTPOOL
sleep 1
log_note "after the rewrite: $(presaged_bytes $f) of $size presaged," \
    "used $(get_prop used $fs) (was $used0)"
log_must test "$(presaged_bytes $f)" -eq $size

log_must zfs presage -t 0 $f
presage_wait_clean $base
log_pass "a nopwrite of a presaged block keeps it presaged"
