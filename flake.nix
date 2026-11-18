{
  description = "ESP-IDF firmware: nix supplies the toolchain, Bazel orchestrates the build";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        { pkgs, system, ... }:
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

          # ESP-IDF drives its build through its own Python modules: kconfgen
          # turns Kconfig into sdkconfig.h, ldgen into linker fragments, and
          # esptool makes the images. nixpkgs has pyparsing and esptool but not
          # esp-idf-kconfig, which also carries the kconfig library those
          # modules import.
          espIdfKconfig = pkgs.python3Packages.buildPythonPackage rec {
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

          # Same pin as CI. `rust-src` is what `-Zbuild-std` compiles the
          # `riscv32imac-esp-espidf` std from. This shell has no rustup, so the
          # file is applied here instead of by a rustup proxy.
          rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

          # ESP-IDF's configure step re-checks a pip virtualenv under
          # IDF_TOOLS_PATH against its full "core" requirement list, most of
          # which is idf.py tooling (monitor, coredump, sbom) this build never
          # runs. `idf.py` passes -DPYTHON_DEPS_CHECKED=1 after doing that check
          # itself, and the bootloader sub-project passes it too; esp-idf-sys
          # calls cmake directly, so supply the flag the same way.
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
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };

          packages.default = pkgs.symlinkJoin {
            name = "esp-idf-toolchain";
            paths = [
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
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.bazel_9
              rustToolchain
              pkgs.sccache
            ]
            ++ (with pkgs; [
              riscv32-esp-elf
              espRomElfs
              espIdf
              espPython
              cmake
              ninja
              git
              pkg-config
              zlib
              llvmPackages.libclang
              ldproxy
              gcc
            ]);

            # ESP-IDF's `tools` goes ahead of the nightly cargo because
            # esp-idf-sys checks for `idf.py` there. The nightly itself is
            # already on PATH via `rustToolchain`.
            shellHook = ''
              export PATH=${espIdf}/tools:''${PATH}
            '';

            # Espressif's prebuilt toolchains are patched to run natively, so
            # the Bazel action uses plain store paths. Only paths cross the
            # nix/Bazel boundary; @esp_toolchain forwards them into the build.
            ESP_TOOLCHAIN_IDF = "${espIdf}";
            # A plain `cargo build` in the dev shell resolves the same ESP-IDF
            # that the Bazel action uses, so both compile the crate identically.
            IDF_PATH = "${espIdf}";
            ESP_ROM_ELF_DIR = "${espRomElfs}";
            ESP_TOOLCHAIN_ROM_ELFS = "${espRomElfs}";
            ESP_TOOLCHAIN_LIBCLANG = "${pkgs.llvmPackages.libclang.lib}/lib";
            # bindgen reads LIBCLANG_PATH directly when the crate builds outside
            # Bazel, so the dev shell exports the same value.
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            # esp-idf-sys treats the environment as "activated" only when
            # `idf.py` is on PATH and resolves to $IDF_PATH/tools/idf.py, so
            # that directory goes first, and `python` must satisfy its shebang.
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

          pre-commit.settings = {
            hooks = {
              deadnix.enable = true;
              statix.enable = true;
            };
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              rustfmt.enable = true;
              rustfmt.package = rustToolchain;
              taplo.enable = true;
            };
          };
        };

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
}
