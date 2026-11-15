#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=stable}
HOST_NAME=${HOST_NAME=openstick-debian}

rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

QEMU_BIN=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
if [ -z "${QEMU_BIN}" ]; then
    echo "Error: qemu-aarch64 binary not found" >&2
    exit 1
fi
cp "${QEMU_BIN}" "${CHROOT}/usr/bin/qemu-aarch64-static"
chmod +x "${CHROOT}/usr/bin/qemu-aarch64-static"

chroot ${CHROOT} qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} qemu-aarch64-static /bin/sh -c /setup.sh

# Установка zram-tools и включение системных сервисов внутри chroot
chroot ${CHROOT} qemu-aarch64-static /bin/bash -c "
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zram-tools && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    systemctl enable serial-getty@ttyGS0.service && \
    systemctl enable zramswap.service && \
    systemctl enable fstrim.timer
"

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services
cp -a configs/system/* ${CHROOT}/etc/systemd/system

# 1. Настройка autologin root на USB Serial (ttyGS0)
mkdir -p ${CHROOT}/etc/systemd/system/serial-getty@ttyGS0.service.d
cat << 'EOF' > ${CHROOT}/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --keep-baud 115200,57600,38400,9600 --autologin root %I $TERM
EOF

# 2. Настройка ZRAM (50% от ОЗУ, сжатие zstd)
cat << 'EOF' > ${CHROOT}/etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

# 3. Настройка аппаратного Watchdog (перезагрузка при зависании ядра/модема)
mkdir -p ${CHROOT}/etc/systemd/system.conf.d
cat << 'EOF' > ${CHROOT}/etc/systemd/system.conf.d/watchdog.conf
[Manager]
RuntimeWatchdogSec=20s
RebootWatchdogSec=2min
EOF

# 4. Продление жизни eMMC: перевод логов journald в ОЗУ (макс. 32 МБ)
mkdir -p ${CHROOT}/etc/systemd/journald.conf.d
cat << 'EOF' > ${CHROOT}/etc/systemd/journald.conf.d/volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
sed -i '/\[main\]/a dns=dnsmasq' ${CHROOT}/etc/NetworkManager/NetworkManager.conf

# enable autoconnect for usb0
cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# install kernel
PMOS_URL="https://mirror.nura.eco/postmarketos/main/aarch64"
KERNEL_PKG=$(wget -qO- "${PMOS_URL}/" \
    | grep -oE 'linux-postmarketos-qcom-msm8916-[0-9][^"]+\.apk' \
    | sort -V | tail -n 1)

wget -O - "${PMOS_URL}/${KERNEL_PKG}" \
    | tar xkzf - -C ${CHROOT} --warning=no-unknown-keyword --exclude=.PKGINFO --exclude=.SIGN*

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# 5. update fstab с опцией noatime для снижения износа eMMC
printf "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults,noatime\t0 2\n" > ${CHROOT}/etc/fstab
printf "/dev/mmcblk0p14\t/\text4\tdefaults,noatime,commit=60\t0 1\n" >> ${CHROOT}/etc/fstab

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
