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
#	A presaged block rewritten in place stays presaged: the new copy
#	inherits the old one's deadline when its write completes, without
#	waiting for a re-sweep (which does not notice a same-size rewrite).
#	A block demoted for the cap does not come back by being rewritten.
#
# STRATEGY:
#	1. Presage a 64 MiB file for 300 s: 1.000 resident.
#	2. Rewrite it in place three times (dd conv=notrunc with half-record
#	   writes, so each block is read, dirtied and written through the
#	   header that holds its deadline), sync after each pass: the file
#	   is back at the full size at once and presaged_inherited rose by
#	   about the block count each pass.
#	3. Lower the cap below the file (256 MiB ARC, 1 %): the reaper
#	   demotes the evictable headers down to the cap (ones still held
#	   by cached dbufs are demoted when their holds drop).  Rewrite
#	   again: the file's presaged bytes do not rise and
#	   presaged_inherited rises by at most the blocks that were still
#	   presaged (the demoted ones have no deadline to inherit).
#

verify_runnable "global"

typeset f=$TESTDIR/rw
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((64 * mib / rs))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $f
}

function inherited
{
	kstat arcstats.presaged_inherited
}

# Rewrite the whole file in place, half a record at a time, and sync.
function rewrite_in_place
{
	log_must dd if=/dev/urandom of=$f bs=$((rs / 2)) \
	    count=$((blocks * 2)) conv=notrunc
	sync_pool $TESTPOOL
}

log_assert "a presaged block rewritten in place stays presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50

log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)
log_must test $size -eq $((64 * mib))

# 1. resident
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $size

# 2. rewrites inherit
typeset -i pass before after i
for pass in 1 2 3; do
	before=$(inherited)
	rewrite_in_place
	for ((i = 0; i < 10; i++)); do
		[[ $(presaged_bytes $f) -eq $size ]] && break
		sleep 0.2
	done
	after=$(inherited)
	log_note "pass $pass: presaged $(presaged_bytes $f) of $size," \
	    "inherited +$((after - before)) of $blocks blocks"
	log_must test "$(presaged_bytes $f)" -eq $size
	log_must test $((after - before)) -ge $((blocks * 9 / 10))
done

# 3. a cap-demoted block does not come back
typeset -i demoted0=$(kstat arcstats.presaged_demoted_cap)
arc_small $((256 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 1
typeset -i left prev=-1
for ((i = 0; i < 30; i++)); do
	left=$(presaged_bytes $f)
	[[ $left -lt $size && $left -eq $prev ]] && break
	prev=$left
	sleep 1
done
log_must test "$(kstat arcstats.presaged_demoted_cap)" -gt $demoted0
log_must test $left -lt $((size / 2))
before=$(inherited)
rewrite_in_place
sleep 1
after=$(inherited)
log_note "cap $(($(kstat arcstats.c) / 100)): $left presaged before the" \
    "rewrite, $(presaged_bytes $f) after, inherited +$((after - before))"
log_must test "$(presaged_bytes $f)" -le $left
log_must test $((after - before)) -le $((left / rs + 1))

log_pass "a presaged block rewritten in place stays presaged"
