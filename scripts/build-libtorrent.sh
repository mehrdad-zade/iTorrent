#!/bin/zsh
# Generates the libtorrent Xcode project that LibTorrent-Swift links against.
# Same as Submodules/LibTorrent-Swift/make.sh, but with deployment targets
# raised to what current Xcode supports. Requires: brew install cmake boost
set -e
ROOT="$(cd "$(dirname $0)/.." && pwd)"
cd "$ROOT/Submodules/LibTorrent-Swift"

# Local fixes to the wrapper (skipped if already applied).
for patch in "$ROOT"/patches/LibTorrent-Swift-*.patch; do
    git apply --reverse --check "$patch" 2>/dev/null || git apply "$patch"
done

rm -rf ./libtorrent-build

cmake ./Thirdparty/libtorrent \
    -B./libtorrent-build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -G Xcode \
    -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_CXX_FLAGS="-DTORRENT_HAVE_MMAP=0 -DNDEBUG" \
    -Ddeprecated-functions=OFF \
    -Dwebtorrent=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_XCODE_ATTRIBUTE_ARCHS="\$(ARCHS_STANDARD)" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="macosx iphonesimulator iphoneos"

# CMake turns on TORRENT_USE_ASSERTS for the Debug config, which changes libtorrent's
# struct layouts. LibTorrent-Swift compiles its headers without it (and always links the
# Debug output), so strip it to keep both sides ABI-compatible.
sed -i '' 's/TORRENT_USE_ASSERTS,//g' ./libtorrent-build/libtorrent.xcodeproj/project.pbxproj

# libtorrent's CMakeLists builds with -Weverything, which floods Xcode with hundreds of
# warnings in third-party code (and CMake adds include dirs that don't exist). Silence them.
sed -i '' 's/ -Weverything / -w /g' ./libtorrent-build/libtorrent.xcodeproj/project.pbxproj

# The wrapper targets iOS 15, but libtorrent is built for 26, so ld warns on every object
# file. Match the app's deployment target and quiet the wrapper's one implicit-self warning.
sed -i '' -e 's/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/IPHONEOS_DEPLOYMENT_TARGET = 26.0;/' \
    -e 's/CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;/CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = NO;/' \
    ./LibTorrent.xcodeproj/project.pbxproj
