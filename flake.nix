{
  description = "High-level Zig bindings to libhv";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:edolstra/flake-compat";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    zig2nix.url = "github:Cloudef/zig2nix";
    zig2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ nixpkgs, flake-utils, devenv, zig2nix, ... }:
    let
      zig-version = "0.13.0";
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.packageOverrides = pkgs: {
            zig = zig2nix.packages.${system}.zig.${zig-version}.bin;
          };
        };
      in
      rec {
        packages.devenv-up = devShells.${system}.default.config.procfileScript;

        devShells.default = devenv.lib.mkShell {
          inherit pkgs inputs;
          modules = [
            ./devenv.nix
          ];
        };
      }
    );
}
