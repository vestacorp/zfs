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
#	zfs receive -F restores a filesystem to a received state the way a
#	rollback does (the same clone swap), so it cancels the reservations
#	on the filesystem's files: the reservation count returns to its
#	baseline, status reports none and the file's blocks are released.
#	A request made after the receive works as usual.
#
# STRATEGY:
#	1. Send a filesystem with a 16 MiB file to a second one; presage the
#	   received copy: 1.000 resident, one reservation.
#	2. Append to the source, snapshot it, dirty the destination, then
#	   receive the increment with -F.
#	3. Within a few seconds the reservation is gone, status shows no
#	   deadline and 0 presaged, and presage.holds is 0.
#	4. Presage the file again: resident at its new size; kill it.
#

verify_runnable "global"

typeset src=$TESTPOOL/prssrc
typeset dst=$TESTPOOL/prsdst
typeset f=/$dst/f
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $dst && log_must zfs destroy -r $dst
	datasetexists $src && log_must zfs destroy -r $src
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "receive -F cancels the reservations on the filesystem"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a received copy, presaged
log_must zfs create $src
log_must file_write -o create -f /$src/f -b 131072 -c 128 -d R
log_must zfs snapshot $src@s1
log_must eval "zfs send $src@s1 | zfs receive $dst"
sync_pool $TESTPOOL
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $((16 * mib))
log_must test "$(kstat presage.reservations)" -eq $((base + 1))

# 2. the source moves on, the destination diverges, receive -F
log_must file_write -o append -f /$src/f -b 131072 -c 64 -d R
log_must zfs snapshot $src@s2
log_must touch /$dst/diverged
log_must eval "zfs send -i @s1 $src@s2 | zfs receive -F $dst"
sync_pool $TESTPOOL

# 3. cancelled
presage_wait_clean $base
log_must test "$(kstat presage.reservations)" -eq $base
log_must test -f $f
log_mustnot test -e /$dst/diverged
log_must test "$(expires_at $f)" -eq 0
log_must test "$(warmed_at $f)" -eq 0
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(kstat presage.holds)" -eq 0

# 4. asking again after the restore works
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $((24 * mib))
log_must zfs presage -t 0 $f
presage_wait_clean $base
presage_wait_settled $((psize0 + mib))

log_pass "receive -F cancels the reservations on the filesystem"
