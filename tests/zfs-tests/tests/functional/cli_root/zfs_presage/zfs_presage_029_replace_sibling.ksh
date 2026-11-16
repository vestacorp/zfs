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
#	Overlapping reservations keep a block until the latest of their
#	deadlines, also after one of them is replaced by a shorter request.
#	The replacement sets its own deadline on its blocks; every other
#	reservation on the file is then swept again and raises the blocks
#	it still covers, whichever side of the replaced one it sorts on.
#
# STRATEGY:
#	1. Presage the first 2 MiB and, separately, the first 1 MiB of a
#	   file for 300 s, and bytes 1 MiB to 3 MiB for 300 s.
#	2. Replace the 1 MiB reservation with one of 4 s.
#	3. After it has expired the first MiB is still presaged (the 2 MiB
#	   reservation, which sorts after the replaced one, covers it), and
#	   so are the second and third.
#	4. Kill the third by its range: the megabyte it shared with the
#	   first is presaged again within seconds, the rest of it is not.
#	5. Kill everything.
#

verify_runnable "global"

typeset f=$TESTDIR/prs029
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	rm -f $f
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a replaced reservation does not shorten its siblings' blocks"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
typeset -i base=$(kstat presage.reservations)

log_must file_write -o create -f $f -b 131072 -c 32 -d R
sync_pool $TESTPOOL

# 1. three overlapping reservations
log_must zfs presage -l $((2 * mib)) -t 300 $f
log_must zfs presage -l $mib -t 300 $f
log_must zfs presage -o $mib -l $((2 * mib)) -t 300 $f
log_must test "$(kstat presage.reservations)" -eq $((base + 3))
log_must test "$(presaged_bytes "-l $((3 * mib)) $f")" -eq $((3 * mib))

# 2. replace the middle one in sort order with a short request
log_must zfs presage -l $mib -t 4 $f
sleep 8

# 3. its siblings still hold what they cover
log_must test "$(kstat presage.reservations)" -eq $((base + 2))
log_must test "$(presaged_bytes "-l $mib $f")" -eq $mib
log_must test "$(presaged_bytes "-l $((3 * mib)) $f")" -eq $((3 * mib))

# 4. kill one by its range: the one that overlaps it keeps its blocks
log_must zfs presage -o $mib -l $((2 * mib)) -t 0 $f
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(presaged_bytes "-l $((2 * mib)) $f") -eq $((2 * mib)) ]] && break
	sleep 0.2
done
log_must test "$(presaged_bytes "-l $((2 * mib)) $f")" -eq $((2 * mib))
log_must test "$(presaged_bytes "-o $((2 * mib)) -l $mib $f")" -eq 0

# 5. kill everything
log_must zfs presage -t 0 $f
presage_wait_clean $base
log_must test "$(presaged_bytes $f)" -eq 0

log_pass "a replaced reservation does not shorten its siblings' blocks"
