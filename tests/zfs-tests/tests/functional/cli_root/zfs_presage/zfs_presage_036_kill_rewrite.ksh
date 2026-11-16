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
#	A kill, and a replacement with an earlier deadline, reach the
#	blocks that are being rewritten at that moment.  Such a block is
#	anonymous in the ARC until its write completes and would carry
#	the old deadline back into the presaged state, where nothing
#	would end it before that deadline.
# STRATEGY:
#	1. Presage a 128 MiB file for ten minutes and rewrite it in
#	   place, over and over, in the background.
#	2. Kill the reservation while the writer runs, and let it run
#	   for a few more transaction groups: once it has stopped and
#	   the pool has synced, the file reports nothing presaged and
#	   presaged_data is back where it started.
#	3. Presage it for ten minutes again with the writer running and
#	   replace that with a 20 s reservation: 10 s after the new
#	   deadline, with the writer still running until then, nothing
#	   is presaged.
#

verify_runnable "global"

typeset f=$TESTDIR/kr
typeset stop=$TESTDIR/kr.stop
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((128 * mib / rs))
typeset -i wpid=0

function writer_stop
{
	touch $stop
	[[ $wpid -ne 0 ]] && wait $wpid 2>/dev/null
	wpid=0
	rm -f $stop
}

function cleanup
{
	writer_stop
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $f
}

# Rewrite the whole file in place, half a record at a time, until told to
# stop: every block is read, dirtied and written through the header that
# holds its deadline.
function writer_start
{
	rm -f $stop
	(
		while [[ ! -e $stop ]]; do
			dd if=/dev/urandom of=$f bs=$((rs / 2)) \
			    count=$((blocks * 2)) conv=notrunc 2>/dev/null
		done
	) &
	wpid=$!
}

# Wait up to $1 s for the file to report nothing presaged, for
# presaged_data to be back at $2 and for the whole state, metadata
# included, to be back at $3.
function wait_gone # seconds data_baseline size_baseline
{
	typeset -i i
	for ((i = 0; i < $1 * 5; i++)); do
		[[ $(presaged_bytes $f) -eq 0 &&
		    $(kstat arcstats.presaged_data) -le $2 &&
		    $(presaged_size) -le $3 ]] && break
		sleep 0.2
	done
	log_note "file presaged $(presaged_bytes $f), presaged_data" \
	    "$(kstat arcstats.presaged_data) (was $2), presaged_size" \
	    "$(presaged_size) (was $3), inherited" \
	    "$(kstat arcstats.presaged_inherited)"
	log_must test "$(presaged_bytes $f)" -eq 0
	log_must test "$(kstat arcstats.presaged_data)" -le $2
	log_must test "$(presaged_size)" -le $3
}

log_assert "a kill and a shorter replacement reach blocks being rewritten"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i pdata0=$(kstat arcstats.presaged_data)
typeset -i psize0=$(presaged_size)

log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)

# 1. presaged and under rewrite
log_must zfs presage -t 600 $f
log_must test "$(presaged_bytes $f)" -eq $size
typeset -i inh0=$(kstat arcstats.presaged_inherited)
writer_start
sleep 6
log_must test "$(kstat arcstats.presaged_inherited)" -gt $inh0

# 2. kill under rewrite
log_must zfs presage -t 0 $f
sleep 12
writer_stop
sync_pool $TESTPOOL
presage_wait_clean $base
wait_gone 15 $pdata0 $psize0

# 3. a shorter replacement under rewrite
log_must zfs presage -t 600 $f
writer_start
sleep 6
log_must zfs presage -t 20 $f
sleep 22
writer_stop
sync_pool $TESTPOOL
wait_gone 10 $pdata0 $psize0

log_pass "a kill and a shorter replacement reach blocks being rewritten"
