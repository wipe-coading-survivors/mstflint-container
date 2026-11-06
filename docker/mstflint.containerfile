ARG MSTFLINT_SHA
ARG MSTFLINT_TAG

FROM registry.fedoraproject.org/fedora:44 AS builder

ARG MSTFLINT_SHA
ARG MSTFLINT_TAG

RUN dnf install -y autoconf automake libtool gcc gcc-c++ make \
        openssl-devel zlib-devel libibmad-devel libibumad-devel \
        libibverbs libibmad libibumad infiniband-diags perftest \
        expat-devel xz-devel \
        patchelf curl ca-certificates file patch python3 \
    && dnf clean all

COPY mstflint /src/mstflint
COPY mstflint-data-path-env.patch /src/mstflint-data-path-env.patch
COPY mstflint-secure-read-flag.patch /src/mstflint-secure-read-flag.patch
COPY mft-stage.sh /opt/mft-stage.sh
COPY mstflint-icon.png /opt/mstflint-icon.png

# mstflint-secure-read-flag.patch (-1.3) REPLACES the -1.2 secure-read
# patch: it carries the full -1.2 MCC-read mechanics (ri: FwReadData via
# ReadMccComponent/_bootImgCache; dc: FwGetSection via _createImageOps),
# gated behind the --mcc_read flag, plus the secure-FW slow-path hint.
# The grep gates below pin both the MCC-read wiring and the flag/hint,
# so a silent drop of either fails the build.
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
    && ./autogen.sh \
    && CFLAGS="-O2 -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types" \
        CXXFLAGS="-O2 -Wno-error" \
        MSTFLINT_VERSION_STR="mstflint ${MSTFLINT_TAG#v}" \
        ./configure --prefix=/usr/local --enable-adb-generic-tools \
    && make -j"$(nproc)" \
    && make install \
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

RUN dnf install -y openssl zlib libxml2 libcurl xz-libs expat \
        libibverbs libibmad libibumad infiniband-diags perftest \
    && dnf clean all
