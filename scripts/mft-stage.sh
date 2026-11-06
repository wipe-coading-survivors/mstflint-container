#!/bin/sh
# mft-stage.sh — staging-дерево (bin/lib/share + manifest), tarball, AppImage
# в /opt/mft-artifacts. Исполняется в builder-стадии docker/mstflint.containerfile.
#
#   mft-stage.sh TAG SHA APPIMAGETOOL RUNTIME_FILE
#
# TAG — mstflint-тег (v4.37.0-1.1); SHA — полный git-SHA тега;
# APPIMAGETOOL — путь к AppRun извлечённого appimagetool;
# RUNTIME_FILE — путь к pinned type2-runtime (для --runtime-file).
set -eu

TAG=${1:?usage: mft-stage.sh TAG SHA APPIMAGETOOL RUNTIME_FILE}
SHA=${2:?usage: mft-stage.sh TAG SHA APPIMAGETOOL RUNTIME_FILE}
APPIMAGETOOL=${3:?usage: mft-stage.sh TAG SHA APPIMAGETOOL RUNTIME_FILE}
RUNTIME_FILE=${4:?usage: mft-stage.sh TAG SHA APPIMAGETOOL RUNTIME_FILE}

VERSION=${TAG#v}
PREFIX=/usr/local
OUT=/opt/mft-artifacts
STAGE=/tmp/mft-staging
APPDIR=/tmp/mft-appdir

mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/mstflint" "$OUT"

cp -a "$PREFIX"/bin/. "$STAGE/bin/"
cp -a "$PREFIX/share/mstflint/." "$STAGE/share/mstflint/"

# Python-тулы (mstfwtrace/mstfwreset/mstresourcedump/mstresourceparse):
# bin-обёртки (common/python_wrapper.sh) ищут <tool>.py сперва в
# $MSTFLINT_PYTHON_TOOLS (= /usr/local/lib/mstflint/python_tools, compile-time),
# fallback — find по $(dirname $0)/../lib/mstflint/python_tools и
# ../lib64/... (python_wrapper.sh:13,45). В AppImage $0 = $APPDIR/bin/<tool>
# → fallback = $APPDIR/lib/mstflint/python_tools. Без стадиации в lib/ тулы
# мертвы: "Couldn't find <tool>.py" (журнал 2026-10-08-mstfwtrace-probe §1.1).
# .so внутри (cmtcr/ccmdif/c_dev_mgt/rreg_access) линкуют только glibc-семейство
# (verified: ldd всех четырёх) — вендинг в lib/ не нужен.
mkdir -p "$STAGE/lib/mstflint"
cp -a "$PREFIX/lib/mstflint/python_tools" "$STAGE/lib/mstflint/"

for pkg in infiniband-diags perftest; do
    for f in $(rpm -ql "$pkg" | grep '^/usr/bin/' || true); do
        cp -a "$f" "$STAGE/bin/"
    done
done

# .so-зависимости ВСЕХ динамических ELF-бинарей в bin/ вендим в lib/;
# RPATH $ORIGIN/../lib. Не только IB-тула: mstlink/mstreg линкуют
# expat/liblzma и могут оказаться динамическими (libtool -static != -all-static).
# Скрипты (.pl/.sh) — не ELF, пропускаем; статичные бинари — без динамических
# зависимостей (ldd без '=> '), пропускаем (patchelf на них упал бы).
# cp -L: в /usr/lib64 soname-файл (libibverbs.so.1) — symlink на версию
# (libibverbs.so.1.15.61.0); без -L в lib/ попадёт болтающийся symlink.
# awk-фильтр $3 ~ /^\//: отбрасывает vdso/vsyscall-строки ldd (там адрес,
# не путь — cp по нему упал бы под set -e).
for b in "$STAGE"/bin/*; do
    if file -b "$b" | grep -q ELF && ldd "$b" 2>/dev/null | grep -q '=> '; then
        ldd "$b" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' | while read -r l; do
            base=${l##*/}
            case $base in
                libc.so*|libstdc++.so*|libm.so*|libgcc_s.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*) continue ;;
            esac
            cp -anL "$l" "$STAGE/lib/"
        done
        patchelf --set-rpath '$ORIGIN/../lib' "$b"
    fi
done

# Гейт: ни один бинарь не должен иметь неразрешённых зависимостей.
for b in "$STAGE"/bin/*; do
    if ldd "$b" 2>/dev/null | grep -q 'not found'; then
        echo "mft-stage: unresolved libraries in $b:" >&2
        ldd "$b" 2>/dev/null | grep 'not found' >&2
        exit 1
    fi
done

# Гейт: python-тулы на месте (регрессия — AppImage с мёртвыми python-тулами,
# журнал 2026-10-08-mstfwtrace-probe §1.1). find, а не test -f: resourcetools
# лежит в python_tools/resourcetools/<tool>.py, не python_tools/<tool>/<tool>.py.
for t in mstfwtrace mstfwreset mstresourcedump mstresourceparse; do
    test -n "$(find "$STAGE/lib/mstflint/python_tools" -name "$t.py" | head -n1)"
done
# Smoke: module-level imports (mtcr→cmtcr.so, cmdif→ccmdif.so, tools_version)
# резолвятся из python_tools; --version не трогает железо.
PYTHONPATH="$STAGE/lib/mstflint/python_tools" \
    python3 "$STAGE/lib/mstflint/python_tools/mstfwtrace/mstfwtrace.py" --version

{
    echo "tag=$TAG"
    echo "sha=$SHA"
    echo "version=$VERSION"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mstflint-version=$("$STAGE/bin/mstflint" --version 2>&1 | head -1)"
    for b in "$STAGE"/bin/*; do
        echo "BIN=${b##*/}"
    done
    echo ""
    echo "--- files ---"
    (cd "$STAGE" && find . -type f | sort)
} > "$STAGE/manifest.txt"
cp "$STAGE/manifest.txt" "$OUT/manifest.txt"

tar -czf "$OUT/mstflint-$VERSION.tar.gz" -C "$STAGE" .

mkdir -p "$APPDIR"
cp -a "$STAGE/." "$APPDIR/"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
set -eu
name=$(basename "${ARGV0:-$0}")
case "$name" in
    AppRun|*.AppImage) name=mstflint ;;
esac
APPDIR="${APPDIR:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}"
# Данные (DB/CSV/ADB/efuse-конфиг): вендор-патч резолвит путь из env
# MSTFLINT_DATA_PATH (корень = share/mstflint), а не из compile-time
# /usr/local/share/mstflint — AppImage самодостаточен по данным.
export MSTFLINT_DATA_PATH="${APPDIR}/share/mstflint"
# Обёртки infiniband-diags (ibnodes/ibhosts/ibswitches/ibnetdiscover)
# резолвят сородичей через env IBPATH (по умолчанию /usr/bin) —
# указываем bin/ AppImage'а, свита самодостаточна.
export IBPATH="${APPDIR}/bin"
if [ ! -x "${APPDIR}/bin/${name}" ]; then
    echo "mstflint AppImage: unknown tool '${name}'" >&2
    echo "available: $(cd "${APPDIR}/bin" && ls | tr '\n' ' ')" >&2
    exit 2
fi
export LD_LIBRARY_PATH="${APPDIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "${APPDIR}/bin/${name}" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"
cat > "$APPDIR/mstflint.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=mstflint $VERSION
Exec=AppRun
Icon=mstflint
Terminal=true
Categories=System;Monitor;
EOF
cp /opt/mstflint-icon.png "$APPDIR/mstflint.png"

ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT/mstflint-$VERSION-x86_64.AppImage" --runtime-file "$RUNTIME_FILE"

test -f "$OUT/mstflint-$VERSION.tar.gz"
test -f "$OUT/mstflint-$VERSION-x86_64.AppImage"
test -f "$OUT/manifest.txt"
echo "mft-stage: done version=$VERSION bins=$(ls "$STAGE"/bin | wc -l) libs=$(ls "$STAGE"/lib | wc -l)"
