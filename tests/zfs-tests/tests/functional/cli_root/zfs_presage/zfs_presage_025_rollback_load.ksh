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
#	A rollback does not wait for a file that "zfs presage" is still
#	loading.  The inline load holds the filesystem, so the rollback
#	cannot suspend it until the command returns; the load therefore
#	stops at its next 64 MiB step when the restore begins, the command
#	reports what it had loaded, and the reservation is cancelled and
#	released with the rest.
#
# STRATEGY:
#	1. Write a 512 MiB file on recordsize=16k, snapshot, and empty the
#	   ARC by export and import.
#	2. Slow reads with zinject so one step takes over a second and the
#	   whole load about ten; start "zfs presage" in the background and
#	   wait until its load is in flight.
#	3. Roll back.  The command must have succeeded with less than the
#	   file presaged: had the rollback waited for the load, it would
#	   report all of it.  The time the rollback took is logged.
#	4. Reservation count at its baseline, no deadline, nothing presaged
#	   on the file, no hold, presaged_size back at its starting value.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsload
typeset f=/$fs/f
typeset out=$TEST_BASE_DIR/presage_025.out
typeset -i mib=$((1024 * 1024))
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && log_must zfs destroy -r $fs
	rm -f $out
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "a rollback stops a zfs presage that is still loading the file"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 75
# room for the whole file, whatever the ARC target happens to be
arc_save
arc_fixed $((1024 * mib))
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a cold 512 MiB file with a snapshot to return to
log_must zfs create -o recordsize=16k -o compression=off $fs
log_must dd if=/dev/urandom of=$f bs=1M count=512
log_must zfs snapshot $fs@s1
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

# 2. 20 ms per read on 64 lanes: a 64 MiB step of 16K blocks takes about
# 1.3 s and the whole load about 10 s
log_must zinject -d $DISK -D 20:64 -T read $TESTPOOL
zfs presage -t 600 $f >$out 2>&1 &
typeset pid=$!
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat presage.loads) -ge 1 ]] && break
	sleep 0.1
done
log_must test "$(kstat presage.loads)" -ge 1
sleep 1

# 3. the rollback interrupts the load
typeset t0=$(date +%s%3N)
log_must zfs rollback $fs@s1
typeset t1=$(date +%s%3N)
wait $pid
typeset -i rc=$?
log_must test $rc -eq 0
log_must zinject -c all
typeset -i got=$(awk '{print $3}' $out)
log_note "rollback returned after $((t1 - t0)) ms; zfs presage had" \
    "loaded $((got / mib)) of 512 MiB: $(cat $out)"
log_must test $got -lt $((512 * mib))

# 4. released like any other reservation on the dataset
presage_wait_clean $base
presage_wait_settled $((psize0 + mib)) 30
log_must test "$(kstat presage.reservations)" -eq $base
log_must test "$(expires_at $f)" -eq 0
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(kstat presage.holds)" -eq 0

log_pass "a rollback stops a zfs presage that is still loading the file"
