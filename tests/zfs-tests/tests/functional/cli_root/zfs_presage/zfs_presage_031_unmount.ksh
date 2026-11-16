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
#	Unmounting a filesystem releases its presaged files, at once: the
#	reservations are cancelled and nothing of them stays in the
#	presaged state.  On an encrypted filesystem that means no decrypted
#	data is held in memory once the key has been unloaded.
#
# STRATEGY:
#	1. On an encrypted filesystem, presage two files for ten minutes,
#	   one of them only in part.
#	2. Unmount.  When the command returns the reservations are gone
#	   and presaged_size is back at its starting value.
#	3. Unload the key, load it again, mount: the files report nothing
#	   presaged and no deadline; a new request works.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsumount
typeset key=$TEST_BASE_DIR/presage_031.key
typeset -i mib=$((1024 * 1024))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	rm -f $key
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "unmount releases a filesystem's presaged files"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. two presaged files on an encrypted filesystem
log_must eval "echo 'presage-031-passphrase' > $key"
log_must zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
    -o keylocation=file://$key -o compression=off $fs
log_must file_write -o create -f /$fs/a -b 131072 -c 256 -d R
log_must file_write -o create -f /$fs/b -b 131072 -c 256 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 /$fs/a
log_must zfs presage -o $((8 * mib)) -l $((16 * mib)) -t 600 /$fs/b
log_must test "$(presaged_bytes /$fs/a)" -eq $((32 * mib))
log_must test "$(kstat presage.reservations)" -eq $((base + 2))
log_must test "$(presaged_size)" -ge $((psize0 + 48 * mib))

# 2. unmount: gone when the command returns
log_must zfs unmount $fs
log_must test "$(kstat presage.reservations)" -eq $base
log_must test "$(kstat presage.holds)" -eq 0
log_note "presaged_size $(presaged_size) after the unmount (start $psize0)"
log_must test "$(presaged_size)" -le $((psize0 + 131072))

# 3. key out, key in, mount: a clean slate
log_must zfs unload-key $fs
log_must zfs load-key $fs
log_must zfs mount $fs
log_must test "$(presaged_bytes /$fs/a)" -eq 0
log_must test "$(expires_at /$fs/a)" -eq 0
log_must zfs presage -t 600 /$fs/a
log_must test "$(presaged_bytes /$fs/a)" -eq $((32 * mib))
log_must zfs presage -t 0 /$fs/a
presage_wait_clean $base

log_pass "unmount releases a filesystem's presaged files"
