#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
SRCDIR=$(pwd)/src

# install gt dependencies inside chroot and clean apt cache afterwards
chroot ${CHROOT} qemu-aarch64-static /bin/sh \
    -c "apt-get update && apt-get install -y --no-install-recommends libconfig-dev && apt-get clean && rm -rf /var/lib/apt/lists/*"

# build and install libusbgx
(
    cd "${SRCDIR}/libusbgx"
    autoreconf -i
)

rm -rf build dist
mkdir -p build dist

(
    cd build
    PKG_CONFIG_PATH="${CHROOT}/usr/lib/aarch64-linux-gnu/pkgconfig" \
        "${SRCDIR}/libusbgx/configure" \
            --host=aarch64-linux-gnu \
            --prefix=/usr \
            --with-sysroot="${CHROOT}"
)

make -C build DESTDIR="$(pwd)/dist" CFLAGS="--sysroot=${CHROOT}" install
make -C build DESTDIR="${CHROOT}" CFLAGS="--sysroot=${CHROOT}" install

# build and install gt
rm -rf build/*
PKG_CONFIG_PATH="${CHROOT}/usr/lib/pkgconfig:${CHROOT}/usr/lib/aarch64-linux-gnu/pkgconfig" \
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_C_FLAGS="-I$(pwd)/dist/usr/include" \
        -DCMAKE_EXE_LINKER_FLAGS="-L$(pwd)/dist/usr/lib -Wl,-rpath-link,$(pwd)/dist/usr/lib" \
        -DCMAKE_FIND_ROOT_PATH="${CHROOT};$(pwd)/dist" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_SYSROOT="${CHROOT}" \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -S "${SRCDIR}/gt/source" \
        -B build

make -C build DESTDIR="$(pwd)/dist" install

rm -rf dist/usr/share dist/usr/lib/cmake dist/usr/lib/pkgconfig \
    dist/usr/lib/*a dist/usr/bin/ga* dist/usr/bin/s* dist/usr/include

mkdir -p dist/etc
cp -a configs/templates dist/etc/gt
