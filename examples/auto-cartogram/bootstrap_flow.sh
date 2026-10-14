#!/usr/bin/env bash
# Build the optional AGPL-3.0 flow experiment outside production code.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VENDOR=${1:-"$ROOT/output/auto-cartogram/vendor"}
mkdir -p "$VENDOR"
VENDOR=$(cd "$VENDOR" && pwd)
REVISION=9200b14b983581b78992dd6944cceedf384bb02c
SOURCE="$VENDOR/cartogram-cpp"
if [[ ! -d "$SOURCE" ]]; then
    git clone https://github.com/mgastner/cartogram-cpp.git "$SOURCE"
    git -C "$SOURCE" checkout --detach "$REVISION"
fi
[[ $(git -C "$SOURCE" rev-parse HEAD) == "$REVISION" && -z $(git -C "$SOURCE" status --porcelain) ]] || {
    echo 'The upstream checkout has a different revision or local changes.' >&2; exit 1;
}
[[ -d "$VENDOR/cpp-env" ]] || python3 -m venv "$VENDOR/cpp-env"
"$VENDOR/cpp-env/bin/python" -m pip install 'conan==2.33.0' 'cmake==3.30.0'
export PATH="$VENDOR/cpp-env/bin:$PATH"
export CONAN_HOME="$VENDOR/conan-home"
[[ -f "$CONAN_HOME/profiles/default" ]] || conan profile detect
cd "$SOURCE"
conan install . --build=missing -s build_type=Release -s compiler.cppstd=20
cmake -S . -B build/Release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=build/Release/generators/conan_toolchain.cmake
cmake --build build/Release --parallel "${BUILD_JOBS:-4}"
ctest --test-dir build/Release --output-on-failure -L unit
{
    printf 'revision=%s\nlicense=AGPL-3.0\n' "$REVISION"
    conan --version
    cmake --version
    c++ --version
    sha256sum "$ROOT/examples/auto-cartogram/bootstrap_flow.sh" LICENSE \
        conanfile.txt build/Release/cartogram
} > "$VENDOR/flow-build-info.txt"
printf 'Built the experimental binary: %s/build/Release/cartogram\n' "$SOURCE"
