#!/usr/bin/env bash
# Installs the esp-rs Rust toolchain, the only rustc with a `*-esp-espidf` std,
# and links it into rustup as the `esp` toolchain that rust-toolchain.toml asks
# for. CI uses this where nix would supply the same toolchain from a derivation.
#
# Usage: scripts/install-esp-rust.sh
# Set ESP_RUST_PREFIX to install somewhere other than /opt/esp-rust.
set -euo pipefail

version=1.100.0.0
prefix=${ESP_RUST_PREFIX:-/opt/esp-rust}
release="https://github.com/esp-rs/rust-build/releases/download/v$version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -sSL -o "$tmp/rust.tar.xz" "$release/rust-$version-x86_64-unknown-linux-gnu.tar.xz"
curl -sSL -o "$tmp/rust-src.tar.xz" "$release/rust-src-$version.tar.xz"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xf "$tmp/rust.tar.xz" -C "$prefix" --strip-components=1

# build-std compiles the firmware std from source, which needs the std sources
# at <sysroot>/lib/rustlib/src/rust. The tarball nests them under
# rust-src-nightly/rust-src/lib/rustlib/src/rust, so four levels go.
mkdir -p "$prefix/rustc/lib/rustlib"
tar -xf "$tmp/rust-src.tar.xz" -C "$prefix/rustc/lib/rustlib" --strip-components=4

# Build scripts and proc-macros compile for the host, whose std ships as a
# separate component in this archive.
cp -r "$prefix/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/." \
    "$prefix/rustc/lib/rustlib/x86_64-unknown-linux-gnu/"

# rustup links a toolchain to one prefix and expects every binary under it, but
# this archive splits rustc, cargo and rustc's companion tools across sibling
# directories. Without cargo here, rustup borrows the stable one, whose channel
# rejects `-Zbuild-std`.
for bin in "$prefix"/cargo/bin/* "$prefix"/rustfmt-preview/bin/* "$prefix"/clippy-preview/bin/*; do
    ln -sf "$bin" "$prefix/rustc/bin/$(basename "$bin")"
done

rustup toolchain link esp "$prefix/rustc"
rustup default esp
