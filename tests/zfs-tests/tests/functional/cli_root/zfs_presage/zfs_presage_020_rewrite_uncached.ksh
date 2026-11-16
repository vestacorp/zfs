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
#	A presaged block rewritten whole after its dbuf left the dbuf cache
#	stays presaged.  The fresh buffer has no header of its own to carry
#	the deadline, so dbuf_write() looks the old block up in the ARC
#	(presaged_lookups) and carries its deadline over before the write
#	(presaged_inherited_lookup); arc_write_done() then admits the new
#	copy exactly as for a cached-dbuf rewrite (presaged_inherited).
#	A block demoted for the cap is not found presaged and does not come
#	back.
#
# STRATEGY:
#	1. Presage a 64 MiB file for 300 s: 1.000 resident.
#	2. Shrink the dbuf cache to 64 KiB so the file's dbufs are evicted
#	   (the evict thread drains it within a second) and every rewrite
#	   below starts from an uncached dbuf.  Rewrite the file in place
#	   three times with whole-record writes (dd bs=recordsize
#	   conv=notrunc, so dbuf_noread() allocates a fresh buffer), sync
#	   after each: the file is back at full size at once,
#	   presaged_lookups and presaged_inherited_lookup each rose by about
#	   the block count, presaged_inherited by at least that.
#	3. Lower the cap below the file (256 MiB ARC, 1 %): the reaper
#	   demotes down to the cap.  Rewrite again: the lookups find the
#	   demoted headers in MFU, not presaged, so the file's presaged
#	   bytes do not rise and presaged_inherited_lookup rises by at most
#	   the blocks that were still presaged.
#

verify_runnable "global"

typeset f=$TESTDIR/rwu
typeset -i mib=$((1024 * 1024)) rs=131072
typeset -i blocks=$((64 * mib / rs))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	restore_tunable DBUF_CACHE_MAX_BYTES
	arc_restore
	rm -f $f
}

function inherited
{
	kstat arcstats.presaged_inherited
}
function lookups
{
	kstat arcstats.presaged_lookups
}
function inherited_lookup
{
	kstat arcstats.presaged_inherited_lookup
}

# Rewrite the whole file in place, one whole record per write, and sync.
function rewrite_whole_records
{
	log_must dd if=/dev/urandom of=$f bs=$rs count=$blocks conv=notrunc
	sync_pool $TESTPOOL
}

log_assert "a presaged block rewritten whole from an uncached dbuf stays presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
save_tunable DBUF_CACHE_MAX_BYTES
arc_save
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50

log_must file_write -o create -f $f -b $rs -c $blocks -d R
sync_pool $TESTPOOL
typeset -i size=$(stat_size $f)
log_must test $size -eq $((64 * mib))

# 1. resident
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $size

# 2. the dbuf cache lets go of the file; whole-record rewrites inherit by lookup
log_must set_tunable64 DBUF_CACHE_MAX_BYTES $((64 * 1024))
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat dbufstats.cache_size_bytes) -lt $rs ]] && break
	sleep 0.2
done
log_note "dbuf cache $(kstat dbufstats.cache_size_bytes) bytes after the shrink"
log_must test "$(kstat dbufstats.cache_size_bytes)" -lt $((4 * rs))

typeset -i pass inh0 inh1 lk0 lk1 il0 il1
for pass in 1 2 3; do
	inh0=$(inherited); lk0=$(lookups); il0=$(inherited_lookup)
	rewrite_whole_records
	for ((i = 0; i < 10; i++)); do
		[[ $(presaged_bytes $f) -eq $size ]] && break
		sleep 0.2
	done
	inh1=$(inherited); lk1=$(lookups); il1=$(inherited_lookup)
	log_note "pass $pass: presaged $(presaged_bytes $f) of $size," \
	    "lookups +$((lk1 - lk0)), inherited by lookup +$((il1 - il0))," \
	    "inherited +$((inh1 - inh0)) of $blocks blocks"
	log_must test "$(presaged_bytes $f)" -eq $size
	log_must test $((lk1 - lk0)) -ge $((blocks * 9 / 10))
	log_must test $((il1 - il0)) -ge $((blocks * 9 / 10))
	log_must test $((il1 - il0)) -le $blocks
	log_must test $((inh1 - inh0)) -ge $((il1 - il0))
done

# 3. a cap-demoted block is not found presaged and does not come back
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
il0=$(inherited_lookup)
rewrite_whole_records
sleep 1
il1=$(inherited_lookup)
log_note "cap $(($(kstat arcstats.c) / 100)): $left presaged before the" \
    "rewrite, $(presaged_bytes $f) after, inherited by lookup +$((il1 - il0))"
log_must test "$(presaged_bytes $f)" -le $left
log_must test $((il1 - il0)) -le $((left / rs + 1))

log_pass "a presaged block rewritten whole from an uncached dbuf stays presaged"
