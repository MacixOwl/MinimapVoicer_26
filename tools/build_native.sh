#!/usr/bin/env bash
# Build the same SmartServe service for an API9 HAP or a Linux inference peer.
set -euo pipefail
demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target=host
sdk_root=""
build_root="$demo_root/build/native"
smartserve_source="$(cd "$demo_root/../smartserve" && pwd)"
jobs=8
while (($#)); do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --sdk) sdk_root="$2"; shift 2 ;;
    --build-root) build_root="$2"; shift 2 ;;
    --smartserve) smartserve_source="$2"; shift 2 ;;
    -j) jobs="$2"; shift 2 ;;
    *) echo "Usage: bash tools/build_native.sh [--target host|ohos] [--sdk SDK_API_DIR] [--build-root DIR] [--smartserve DIR] [-j N]" >&2; exit 2 ;;
  esac
done
smartserve_source="$(cd "$smartserve_source" && pwd)"
mkdir -p "$build_root"
build_root="$(cd "$build_root" && pwd)"
espeak_source="$build_root/espeak-ng-1.52.0"
if [[ ! -f "$espeak_source/src/libespeak-ng/CMakeLists.txt" ]]; then
  curl --fail --location --retry 2 \
    https://codeload.github.com/espeak-ng/espeak-ng/tar.gz/refs/tags/1.52.0 \
    --output "$build_root/espeak-ng-1.52.0.tar.gz"
  tar -xzf "$build_root/espeak-ng-1.52.0.tar.gz" -C "$build_root"
fi
platform_options=()
extra_options=()
if [[ "$target" == ohos ]]; then
  if [[ ! -f "$sdk_root/native/build/cmake/ohos.toolchain.cmake" ]]; then
    echo "--sdk must name the API9 directory containing native/, ets/, and toolchains/." >&2
    exit 2
  fi
  sdk_root="$(cd "$sdk_root" && pwd)"
  platform_options+=("-DCMAKE_TOOLCHAIN_FILE=$sdk_root/native/build/cmake/ohos.toolchain.cmake"
    -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_static)
  deps="$build_root/deps"
  if [[ ! -f "$deps/lib/libssl.a" ]]; then
    # API9 ships clang without the newer aarch64-unknown-linux-ohos-clang wrapper.
    mkdir -p "$build_root/openssl"
    (
      cd "$build_root/openssl"
      export CC="$sdk_root/native/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$sdk_root/native/sysroot -fPIC"
      export AR="$sdk_root/native/llvm/bin/llvm-ar"
      export RANLIB="$sdk_root/native/llvm/bin/llvm-ranlib"
      "$smartserve_source/third-party/openssl/Configure" linux-aarch64 no-shared no-tests --prefix="$deps"
      make -j "$jobs"
      make install_sw
    )
  fi
  bash "$smartserve_source/scripts/harmonyos/build_sdk.sh" --sdk "$sdk_root" --platform-level 9 \
    --no-mnn --no-gewu --deps-dir "$deps" --build-dir "$build_root/smartserve" \
    --output-dir "$build_root/install" -j "$jobs"
  extra_options+=("-DSMARTSERVE_DEPS=$deps")
elif [[ "$target" == host ]]; then
  cmake -S "$smartserve_source" -B "$build_root/smartserve" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DENABLE_LLAMACPP_PLUGIN=OFF -DENABLE_MNN_PLUGIN=OFF \
    -DENABLE_GEWU_PLUGIN=OFF -DENABLE_EXECUTORCH_PLUGIN=OFF -DENABLE_DUMMY_PLUGIN=OFF \
    -DSMARTSERVE_BUILD_SDK=ON -DSMARTSERVE_BUILD_APPLICATIONS=OFF -DSMARTSERVE_BUILD_TESTS=OFF
  cmake --build "$build_root/smartserve" --target smartserve_sdk -j "$jobs"
  extra_options+=(-DGAMEVOICE_HOST=ON)
else
  echo "Unsupported target: $target" >&2
  exit 2
fi
cmake -S "$smartserve_source/third-party/llama.cpp" -B "$build_root/llama" -G Ninja \
  "${platform_options[@]}" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CPU_KLEIDIAI=OFF -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF
cmake --build "$build_root/llama" --target llama mtmd llama-common -j "$jobs"
cmake -S "$demo_root/native" -B "$build_root/app" -G Ninja "${platform_options[@]}" \
  "${extra_options[@]}" -DCMAKE_BUILD_TYPE=Release "-DSMARTSERVE_SOURCE=$smartserve_source" \
  "-DSMARTSERVE_BUILD=$build_root/smartserve" "-DLLAMA_BUILD=$build_root/llama" \
  "-DESPEAK_SOURCE=$espeak_source"
cmake --build "$build_root/app" -j "$jobs"
if [[ "$target" == ohos ]]; then
  mkdir -p "$demo_root/entry/libs/arm64-v8a"
  cp "$build_root/app/libgamevoice.so" "$demo_root/entry/libs/arm64-v8a/libgamevoice.so"
  "$sdk_root/native/llvm/bin/llvm-strip" --strip-unneeded "$demo_root/entry/libs/arm64-v8a/libgamevoice.so"
  echo "HAP native library: $demo_root/entry/libs/arm64-v8a/libgamevoice.so"
else
  echo "Linux peer: $build_root/app/gamevoice"
fi
