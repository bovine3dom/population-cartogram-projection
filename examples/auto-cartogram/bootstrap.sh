#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VENDOR=${1:-"$ROOT/output/auto-cartogram/vendor"}
mkdir -p "$VENDOR"
VENDOR=$(cd "$VENDOR" && pwd)

checkout() {
    local name=$1 revision=$2
    if [[ ! -d "$VENDOR/$name" ]]; then
        git clone "https://github.com/tue-alga/$name.git" "$VENDOR/$name"
        git -C "$VENDOR/$name" checkout --detach "$revision"
    fi
    [[ $(git -C "$VENDOR/$name" rev-parse HEAD) == "$revision" ]] || {
        echo "Unexpected revision in $VENDOR/$name" >&2; exit 1;
    }
    [[ -z $(git -C "$VENDOR/$name" status --porcelain) ]] || {
        echo "Modified upstream checkout: $name" >&2; exit 1;
    }
}
checkout GridMapPipeline f1c18c0a938bd526e42d531e3728a85f3f0a0305
checkout GeometryCore c4f7faa617be73243d658bf8cd671aa6482ab950

# A caller-supplied JDK avoids downloading a binary. The bundled choice is
# pinned to the package and checksum published by the Adoptium assets API.
if [[ -z ${JAVA_HOME:-} ]]; then
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
        echo 'Set JAVA_HOME to a JDK 21 installation on this platform.' >&2; exit 1;
    }
    archive="$VENDOR/temurin-21.0.12.1.tar.gz"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 3 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz' -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    printf '%s  %s\n' ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94 "$archive" | sha256sum -c -
    JAVA_HOME="$VENDOR/jdk-21.0.12.1"
    if [[ ! -x "$JAVA_HOME/bin/javac" ]]; then
        mkdir -p "$JAVA_HOME"
        tar -xzf "$archive" --strip-components=1 -C "$JAVA_HOME"
    fi
fi

mkdir -p "$VENDOR/classes"
patched=(arrange/DeformAlgorithm.java arrange/algorithms/GuideConstructor.java arrange/algorithms/MoveAndReshape.java
    arrange/algorithms/sub/Polisher.java common/gridmath/util/CoordinateSet.java
    common/mcf/SuccessiveShortestPathMininumCostFlow.java)
exclusions=(); patched_sources=()
for path in "${patched[@]}"; do
    destination="$VENDOR/patched-source/$path"
    mkdir -p "$(dirname "$destination")"
    cp "$VENDOR/GridMapPipeline/GridmapPipeline/src/$path" "$destination"
    exclusions+=(--exclude "${path##*/}")
    patched_sources+=("$destination")
done
patch --batch -p1 -d "$VENDOR/patched-source" < "$ROOT/examples/auto-cartogram/upstream-fixes.patch"
mapfile -d '' sources < <(fd -0 --extension java "${exclusions[@]}" . \
    "$VENDOR/GeometryCore/src" "$VENDOR/GridMapPipeline/GridmapPipeline/src")
"$JAVA_HOME/bin/javac" --release 21 -encoding UTF-8 -d "$VENDOR/classes" \
    "${sources[@]}" "${patched_sources[@]}" \
    "$ROOT/examples/auto-cartogram/MosaicAdapter.java" \
    "$ROOT/examples/auto-cartogram/DirectionalPlacement.java" \
    "$ROOT/examples/auto-cartogram/GeographicOrientation.java"
printf '%s\n' "$JAVA_HOME/bin/java" > "$VENDOR/java-path.txt"
"$JAVA_HOME/bin/java" -version
printf 'Built headless adapter in %s/classes\n' "$VENDOR"
