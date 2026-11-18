# The local counterpart of CI's `install.sh esp32c6` and `export.sh`.
# Espressif's GCC and ROM ELF tarballs are glibc binaries, so they are
# patchelf'd into the store. The Python set is the slice of ESP-IDF's pip
# requirements this build actually imports.
{
  pkgs,
  toolchainFile,
}:
let
  # ESP-IDF v6.1.1 tools.json, host linux-amd64, "recommended" versions.
  patchPrebuilt = {
    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.patchelf
    ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
      pkgs.glibc
    ];
  };

  prebuilt =
    {
      pname,
      version,
      src,
      stripComponents,
    }:
    pkgs.stdenv.mkDerivation {
      inherit pname version src;
      inherit (patchPrebuilt) nativeBuildInputs buildInputs;
      unpackPhase = ''
        runHook preUnpack
        tar -xf $src --strip-components=${toString stripComponents}
        runHook postUnpack
      '';
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r . $out/
        runHook postInstall
      '';
    };

  riscv32-esp-elf = prebuilt {
    pname = "riscv32-esp-elf";
    version = "esp-15.2.0_20251204";
    src = pkgs.fetchurl {
      url = "https://github.com/espressif/crosstool-NG/releases/download/esp-15.2.0_20251204/riscv32-esp-elf-15.2.0_20251204-x86_64-linux-gnu.tar.xz";
      hash = "sha256-rOWq5q/pj3VJR74EPUAXPi4irOV3VLEaOUtyOO76Ac8=";
    };
    stripComponents = 1;
  };

  espRomElfs = prebuilt {
    pname = "esp-rom-elfs";
    version = "20260528";
    src = pkgs.fetchurl {
      url = "https://github.com/espressif/esp-rom-elfs/releases/download/20260528/esp-rom-elfs-20260528.tar.gz";
      hash = "sha256-yqRj08vvJDClo1hHwdny8VJAOxeoAgUJJ/9gyNpU/kY=";
    };
    stripComponents = 0;
  };

  espIdf = pkgs.fetchgit {
    url = "https://github.com/espressif/esp-idf";
    rev = "v6.1.1";
    hash = "sha256-TpTA8UIAo3aWSkRosozrOepQF6lka2x5/z8NfnHF8Rc=";
    fetchSubmodules = true;
  };

  # kconfgen turns Kconfig into sdkconfig.h and ldgen writes linker fragments.
  # nixpkgs has pyparsing and esptool, but not this package, which also carries
  # the kconfig library those modules import.
  espIdfKconfig = pkgs.python3Packages.buildPythonPackage {
    pname = "esp-idf-kconfig";
    version = "3.14.0";
    format = "pyproject";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/f9/d8/14d43b9f2fe389d8ed9d7279e776779d30a1d00dc5c70b546b343a65f734/esp_idf_kconfig-3.14.0.tar.gz";
      hash = "sha256-Pd3P0s5L5gKxIx2VqNL3mF3QuaYgAtzGgJFkyUpuu8U=";
    };
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies = with pkgs.python3Packages; [
      esp-pylib
      pyparsing
      textual
    ];
    doCheck = false;
  };

  espPython = pkgs.python3.withPackages (
    ps:
    [
      ps.packaging
      espIdfKconfig
      (ps.toPythonModule pkgs.esptool)
    ]
    ++ (with ps; [
      esp-pylib
      pyparsing
      rich
      rich-click
      textual
    ])
  );

  # Same pin as CI. There is no rustup in this shell, so the toolchain file is
  # applied here. `rust-src` is what `-Zbuild-std` compiles for
  # `riscv32imac-esp-espidf`.
  rustToolchain = pkgs.rust-bin.fromRustupToolchainFile toolchainFile;

  # `idf.py` passes -DPYTHON_DEPS_CHECKED=1 after checking its venv. esp-idf-sys
  # calls cmake directly, and the bootloader sub-project inherits the flag.
  # CI wraps the system cmake with scripts/wrap-cmake.sh for the same reason.
  cmake = pkgs.writeShellScriptBin "cmake" ''
    for arg in "$@"; do
      case "$arg" in
        --build|--install|--open|-E)
          exec ${pkgs.cmake}/bin/cmake "$@"
          ;;
      esac
    done
    exec ${pkgs.cmake}/bin/cmake "$@" -DPYTHON_DEPS_CHECKED=1
  '';
in
{
  inherit rustToolchain;

  # Tools a developer shell and `nix build` both expose. Bazel receives a
  # narrower PATH below: it does not need bazel or sccache on that PATH.
  packages = [
    rustToolchain
    riscv32-esp-elf
    espRomElfs
    espIdf
    espPython
    cmake
    pkgs.ninja
    pkgs.ldproxy
    pkgs.git
    pkgs.pkg-config
    pkgs.zlib
    pkgs.llvmPackages.libclang
    pkgs.gcc
  ];

  # esp-idf-sys treats the environment as activated only when `idf.py` is on
  # PATH and resolves to $IDF_PATH/tools/idf.py.
  shellHook = ''
    export PATH=${espIdf}/tools:''${PATH}
  '';

  # Only these paths cross into the Bazel action. `@esp_toolchain` forwards them.
  env = {
    ESP_TOOLCHAIN_IDF = espIdf;
    IDF_PATH = espIdf;
    ESP_ROM_ELF_DIR = espRomElfs;
    ESP_TOOLCHAIN_ROM_ELFS = espRomElfs;
    ESP_TOOLCHAIN_LIBCLANG = "${pkgs.llvmPackages.libclang.lib}/lib";
    LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
    ESP_TOOLCHAIN_PATH =
      "${espIdf}/tools:"
      + pkgs.lib.makeBinPath [
        rustToolchain
        riscv32-esp-elf
        espPython
        cmake
        pkgs.ninja
        pkgs.ldproxy
        pkgs.git
        pkgs.pkg-config
        pkgs.gcc
        pkgs.bash
        pkgs.coreutils
      ];
  };
}
