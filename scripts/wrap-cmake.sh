#!/usr/bin/env bash
# Wraps cmake so ESP-IDF skips its Python dependency check.
#
# `idf.py` passes -DPYTHON_DEPS_CHECKED=1 after checking the environment itself,
# and the bootloader sub-project inherits the flag. esp-idf-sys calls cmake
# directly, so a plain cmake fails on dependency checks that only matter to
# idf.py's tooling. nix solves this with a cmake wrapper in flake.nix; CI runs
# this script at the same point in its setup.
#
# Usage: sudo scripts/wrap-cmake.sh /usr/bin/cmake
set -euo pipefail

real=$1
mv "$real" "$real.real"

cat > "$real" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  case "\$arg" in
    --build|--install|--open|-E) exec $real.real "\$@";;
  esac
done
exec $real.real "\$@" -DPYTHON_DEPS_CHECKED=1
EOF
chmod +x "$real"
