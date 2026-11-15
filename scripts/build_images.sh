#!/bin/sh -e

# package rootfs
rm -f rootfs.raw boot.raw
mkdir -p files mnt

# create boot (64 MiB)
truncate -s 67108864 boot.raw
mkfs.ext2 -F boot.raw
mount boot.raw mnt
tar xf rootfs.tgz -C mnt ./boot --exclude='./boot/linux.efi' --strip-components=2
df -h mnt
umount mnt

# create root img (1.5 GiB — match GPT rootfs partition size)
truncate -s 1610612736 rootfs.raw
mkfs.ext4 -F rootfs.raw
mount rootfs.raw mnt
tar xpf rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

# install gt
cp -a dist/* mnt

df -h mnt
umount mnt

# create sparse android images
img2simg rootfs.raw files/rootfs.bin
img2simg boot.raw files/boot.bin
