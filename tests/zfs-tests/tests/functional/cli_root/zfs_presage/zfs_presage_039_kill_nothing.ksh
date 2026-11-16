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
#	A kill that matches no reservation does nothing.  Walking the
#	file and releasing its blocks all the same would take presaged
#	blocks away from another file that shares them: here, a clone's
#	copy of the file.
# STRATEGY:
#	1. Make a file, snapshot the dataset and clone it; presage the
#	   clone's copy of the file for ten minutes.
#	2. Kill on the origin's file, which has no reservation: the
#	   command fails ("nothing to kill") and the clone's copy stays
#	   fully presaged.
#	3. Kill a range of the clone's copy that no reservation was made
#	   for: fails the same way, nothing is released.
#	4. Kill the clone's copy: released.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prskn
typeset clone=$TESTPOOL/prskn_clone
typeset -i mib=$((1024 * 1024))

function cleanup
{
	datasetexists $clone && destroy_dataset $clone
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a kill that matches no reservation releases nothing"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. a presaged file whose blocks an unreserved file shares
log_must zfs create -o compression=off $fs
log_must file_write -o create -f /$fs/f -b 131072 -c 256 -d R
sync_pool $TESTPOOL
log_must zfs snapshot $fs@s
log_must zfs clone $fs@s $clone
typeset -i size=$(stat_size /$clone/f)
log_must zfs presage -t 600 /$clone/f
log_must test "$(presaged_bytes /$clone/f)" -eq $size

# 2. a kill on the file that has no reservation
log_mustnot zfs presage -t 0 /$fs/f
sleep 3
log_note "after the kill on the origin: clone's copy" \
    "$(presaged_bytes /$clone/f) of $size presaged"
log_must test "$(presaged_bytes /$clone/f)" -eq $size
log_must test "$(kstat presage.reservations)" -eq $((base + 1))

# 3. a kill on a range nobody reserved
log_mustnot zfs presage -t 0 -o 0 -l $((8 * mib)) /$clone/f
sleep 3
log_must test "$(presaged_bytes /$clone/f)" -eq $size

# 4. the kill that does match
log_must zfs presage -t 0 /$clone/f
presage_wait_clean $base
log_must test "$(presaged_bytes /$clone/f)" -eq 0

log_pass "a kill that matches no reservation releases nothing"
