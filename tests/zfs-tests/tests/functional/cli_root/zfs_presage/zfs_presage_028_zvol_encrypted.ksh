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
#	An encrypted volume is presaged like any other.  The walk holds
#	the dataset without opening the volume, so it has to bring its own
#	key mapping: without one every block is read and none is kept.
#	With the key not loaded the request fails and says so.
#
# STRATEGY:
#	1. Create an encrypted volume with its key in a file, fill 64 MiB
#	   through the device, export the pool.
#	2. Import without loading keys: the request fails.
#	3. Load the key: the request presages the whole 64 MiB, cold, and
#	   a second request finds all of it presaged.
#	4. Unload the key: the reservation is cancelled and its blocks
#	   released before the command returns.
#

verify_runnable "global"

typeset vol=$TESTPOOL/prsencvol
typeset key=$TEST_BASE_DIR/presage_028.key
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 -V $vol >/dev/null 2>&1
	datasetexists $vol && destroy_dataset $vol
	rm -f $key
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "an encrypted volume is presaged in full"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. an encrypted volume with data
log_must eval "echo 'presage-028-passphrase' > $key"
log_must zfs create -V 128m -o volblocksize=16k -o compression=off \
    -o encryption=aes-256-gcm -o keyformat=passphrase \
    -o keylocation=file://$key $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
[[ -n $dev ]] || log_unsupported "no device node for $vol"
log_must dd if=/dev/urandom of=$dev bs=1M count=64 conv=fsync
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL

# 2. key not loaded
log_must zpool import $TESTPOOL
log_mustnot zfs presage -V -t 300 $vol
log_must test "$(kstat presage.reservations)" -eq $base

# 3. key loaded: all of it, from a cold ARC
log_must zfs load-key $vol
typeset out=$(zfs presage -V -t 300 $vol)
log_note "$out"
typeset -i got=$(echo "$out" | awk '{print $3}')
log_must test $got -ge $((64 * mib))
log_must test "$(presaged_bytes $vol)" -eq $got
log_must test "$(kstat presage.holds)" -eq 0

# 4. unloading the key releases it: nothing decrypted stays presaged
log_must zfs unload-key $vol
log_must test "$(kstat presage.reservations)" -eq $base
log_note "presaged_size $(presaged_size) after unload-key (start $psize0)"
log_must test "$(presaged_size)" -le $((psize0 + 131072))
log_must test "$(kstat presage.holds)" -eq 0

log_pass "an encrypted volume is presaged in full"
