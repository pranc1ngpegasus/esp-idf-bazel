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
          toolchain = import ./nix/toolchain.nix {
            inherit pkgs;
            toolchainFile = ./rust-toolchain.toml;
          };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };

          devShells.default = pkgs.mkShell (
            toolchain.env
            // {
              packages = [
                pkgs.bazel_9
                pkgs.sccache
              ]
              ++ toolchain.packages;
              inherit (toolchain) shellHook;
            }
          );

          packages.default = pkgs.symlinkJoin {
            name = "esp-idf-toolchain";
            paths = toolchain.packages;
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
              buildifier.enable = true;
              nixfmt.enable = true;
              rustfmt.enable = true;
              rustfmt.package = toolchain.rustToolchain;
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
