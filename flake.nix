{
  description = "roc-zip";

  nixConfig = {
    extra-substituters = [ "https://niclas-ahden.cachix.org" ];
    extra-trusted-public-keys = [ "niclas-ahden.cachix.org-1:FdGli1vBk0cTuVJV27Tau/JvlbW+Ly3pRwFByyqdke0=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Temporary: the prebuilt nightly instead of roc-nix, which cannot
        # build a520eed (a Zig compile error in src/unbundle/download.zig).
        # Keep `nightly` equal to the `roc:` the workflows pin.
        nightly = "nightly-2026-11-18-a520eed";
        asset = {
          x86_64-linux = { name = "linux_x86_64"; hash = "sha256-2TlUlfndB8OWKcM/FW9/7mjo0i+KdkUi5c3RzDCHm1E="; };
          aarch64-linux = { name = "linux_arm64"; hash = "sha256-Fvsr1azozXjjSFQ2OYBk0svl4o08hOFVskYNMhAXIsM="; };
          aarch64-darwin = { name = "macos_apple_silicon"; hash = "sha256-O5ujzHNX5HkW8DaJl5vmw1wZhqH9WlS/DQbqYJ/gZI0="; };
        }.${system};
        roc = pkgs.stdenvNoCC.mkDerivation {
          pname = "roc";
          version = nightly;
          src = pkgs.fetchurl {
            url = "https://github.com/roc-lang/nightlies/releases/download/${nightly}/roc_nightly-${asset.name}-${pkgs.lib.removePrefix "nightly-" nightly}.tar.gz";
            inherit (asset) hash;
          };
          # The Linux binary is static, and the macOS one finds its darwin/
          # directory beside it, so the archive is installed as it is.
          dontFixup = true;
          installPhase = ''
            mkdir -p $out/bin
            cp -R . $out/bin/
          '';
        };
      in
      {
        formatter = pkgs.nixpkgs-fmt;

        packages = {
          inherit roc;
          default = roc;
        };

        devShells = {
          default = pkgs.mkShell {
            # tests.roc hands the archives we write to unzip, bsdtar (libarchive)
            # and 7z and compares the bytes they hand back, and reads what
            # Info-ZIP's zip and bsdtar write. Providing them here means the
            # script never assumes host tools.
            buildInputs = [
              roc
              pkgs.watchexec
              pkgs.unzip
              pkgs.zip
              pkgs.libarchive
              pkgs.p7zip
            ];

            shellHook = ''
              export ROC_LANGUAGE_SERVER_PATH=${roc}/bin/roc
            '';
          };
        };
      });
}
