ARG MSTFLINT_SHA
ARG MSTFLINT_TAG

FROM registry.fedoraproject.org/fedora:44 AS builder

ARG MSTFLINT_SHA
ARG MSTFLINT_TAG

RUN dnf install -y autoconf automake libtool gcc gcc-c++ make \
        openssl-devel zlib-devel libibmad-devel libibumad-devel \
        libibverbs libibmad libibumad infiniband-diags perftest \
        expat-devel xz-devel libusb1-devel \
        patchelf curl ca-certificates file patch python3 \
    && dnf clean all

COPY mstflint /src/mstflint
COPY mstflint-data-path-env.patch /src/mstflint-data-path-env.patch
COPY mstflint-secure-read-flag.patch /src/mstflint-secure-read-flag.patch
COPY mstflint-hw-set-nonexternal.patch /src/mstflint-hw-set-nonexternal.patch
COPY mstflint-ch34x-i2c-transport.patch /src/mstflint-ch34x-i2c-transport.patch
COPY mft-stage.sh /opt/mft-stage.sh
COPY mstflint-icon.png /opt/mstflint-icon.png

# mstflint-secure-read-flag.patch (-1.3) REPLACES the -1.2 secure-read
# patch: it carries the full -1.2 MCC-read mechanics (ri: FwReadData via
# ReadMccComponent/_bootImgCache; dc: FwGetSection via _createImageOps),
# gated behind the --mcc_read flag, plus the secure-FW slow-path hint.
# The grep gates below pin both the MCC-read wiring and the flag/hint,
# so a silent drop of either fails the build.
# mstflint-hw-set-nonexternal.patch (-1.4) drops -DEXTERNAL from the flint
# target in flint/Makefile.am: registers hw [query/set], set_vpd and other
# non-EXTERNAL subcommands. Gates: the non-EXTERNAL hw help branch must be
# present in the tree and -DEXTERNAL must be gone from flint/Makefile.am.
# --enable-i2c (mtusb-i2c-re cycle): compile the mtcr i2c backend
# (-DENABLE_MST_DEV_I2C) so /dev/i2c-N devices are supported (configure.ac
# default is no). The grep gate below fails the build if the backend is
# silently dropped: the /dev/i2c literal exists in the tree only inside the
# ENABLE_MST_DEV_I2C ifdef in mtcr_ul/mtcr_ul_com.c (mtcr_parse_name).
# mstflint-ch34x-i2c-transport.patch (-1.5, mtusb-i2c-impl cycle) refactors
# the mtcr i2c core onto bus ops: i2c_transact/i2c_bus_close fn pointers on
# mfile, dev_i2c_transact carries the I2C_RDWR ioctl bodies of the four i2c
# accessors verbatim, and a full ch34x USB transport (libusb-1.0) lives in
# mtcr_ul/ch34x_usb.c: adapter listing/dispatch, per-PID profiles, env knobs
# and the four i2c accessors driven over bulk endpoints. Gates: the USB core
# and its libusb include must be present in the tree and the ch34x parse
# literal must land in the binary.
RUN cd /src/mstflint \
    && patch -p1 < /src/mstflint-data-path-env.patch \
    && grep -q "MSTFLINT_DATA_PATH" mlxconfig/mlxcfg_commander.cpp \
    && grep -q "MSTFLINT_DATA_PATH" tools_layouts/prm_adb_db.cpp \
    && grep -q "MSTFLINT_DATA_PATH" mstdump/crd_lib/crdump.c \
    && grep -q "MSTFLINT_DATA_PATH" efuse/efuse.cpp \
    && patch -p1 < /src/mstflint-secure-read-flag.patch \
    && grep -q "ReadMccComponent(_bootImgCache" mlxfwops/lib/fsctrl_ops.cpp \
    && grep -q "available with --mcc_read" mlxfwops/lib/fsctrl_ops.cpp \
    && grep -q "served via MCC" mlxfwops/lib/fsctrl_ops.cpp \
    && grep -q "mcc_read" flint/cmd_line_parser.cpp \
    && grep -q "_mccRead" mlxfwops/lib/fsctrl_ops.h \
    && patch -p1 < /src/mstflint-hw-set-nonexternal.patch \
    && grep -q "Set/query HW info" flint/subcommands.cpp \
    && ! grep -q -- "-DEXTERNAL" flint/Makefile.am \
    && patch -p1 < /src/mstflint-ch34x-i2c-transport.patch \
    && grep -q "ch34x_transact" mtcr_ul/ch34x_usb.c \
    && grep -q "libusb-1.0/libusb.h" mtcr_ul/ch34x_usb.c \
    && ./autogen.sh \
    && CFLAGS="-O2 -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types" \
        CXXFLAGS="-O2 -Wno-error" \
        MSTFLINT_VERSION_STR="mstflint ${MSTFLINT_TAG#v}" \
        ./configure --prefix=/usr/local --enable-adb-generic-tools --enable-i2c \
    && make -j"$(nproc)" \
    && make install \
    && grep -aq -- '/dev/i2c' /usr/local/bin/mstflint \
    && grep -aq "ch34x" /usr/local/bin/mstflint \
    && test -d /usr/local/share/mstflint/prm_dbs/hca/ext \
    && test "$(/usr/local/bin/mstflint --version | grep -o 'Git SHA Hash: [0-9a-f]\+')" = "Git SHA Hash: ${MSTFLINT_SHA}" \
    && rm -rf /src/mstflint

RUN curl -fsSL -o /tmp/appimagetool.AppImage \
        "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage" \
    && echo "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0  /tmp/appimagetool.AppImage" | sha256sum -c - \
    && curl -fsSL -o /opt/runtime-x86_64 \
        "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64" \
    && echo "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d  /opt/runtime-x86_64" | sha256sum -c - \
    && chmod +x /tmp/appimagetool.AppImage \
    && mkdir -p /opt/appimagetool \
    && cd /opt/appimagetool \
    && /tmp/appimagetool.AppImage --appimage-extract \
    && test -x /opt/appimagetool/squashfs-root/AppRun \
    && rm -f /tmp/appimagetool.AppImage

RUN /opt/mft-stage.sh "$MSTFLINT_TAG" "$MSTFLINT_SHA" \
        /opt/appimagetool/squashfs-root/AppRun /opt/runtime-x86_64

FROM registry.fedoraproject.org/fedora:44

ARG MSTFLINT_SHA
ARG MSTFLINT_TAG

LABEL org.opencontainers.image.revision="${MSTFLINT_SHA}" \
    org.opencontainers.image.version="${MSTFLINT_TAG}" \
    org.opencontainers.image.title="mstflint" \
    org.opencontainers.image.source="https://github.com/Mellanox/mstflint"

COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/mft-artifacts /opt/mft-artifacts

RUN dnf install -y openssl zlib libxml2 libcurl xz-libs expat libusb1 \
        libibverbs libibmad libibumad infiniband-diags perftest \
    && dnf clean all
