# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Test tooling for the Watcom compiler container collection";

  # Use the host's registry `nixpkgs` so entering the shell reuses the
  # already-cached nixpkgs instead of fetching a fresh tree.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/4bd9165a9165d7b5e33ae57f3eecbcb28fb231c9";

  # TEMPORARY: fresh nixpkgs just to get an up-to-date codex (remove before commit)
  inputs.nixpkgs-codex.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, nixpkgs-codex }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # bats with the standard assertion + support helper libraries.
      batsWith = pkgs: pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]);
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          # The only tool the shell needs is the test harness.  bats is
          # language-agnostic (it just runs commands and asserts on their
          # output/exit) and is the one runner that can express our matrix:
          # bind-mount a source into the compile, run the produced exe in a
          # *different* image (wibo output under dosemu2), and use per-release
          # run commands.  podman comes from the host (rootless-configured
          # there); the shell deliberately does not bundle a second copy.
          packages = [
            (batsWith pkgs)
            nixpkgs-codex.legacyPackages.${pkgs.stdenv.hostPlatform.system}.codex  # TEMPORARY: coding agent for local dev (remove before commit)
            pkgs.file   # the targets check confirms the emitted binary format
            pkgs.internetarchive  # `ia` CLI for the archive-org/ upload scripts
            pkgs.mtools           # floppy .img extraction for the derived ZIP (stage.sh)
            pkgs.zip              # derived floppy-contents ZIP (stage.sh)
          ];
          shellHook = ''
            echo "watcom test devshell"
            echo "  bats -r tests          # full image verification matrix"
            echo "  bats -F tap -r tests   # TAP output (CI)"
            echo "  bats -f 8.5 -r tests   # filter to one release"
            echo "  ia configure           # one-time archive.org login (archive-org/)"
          '';
        };
      });

      # `nix run .#test [-- <bats args>]` from the repo root.
      apps = forAll (pkgs: {
        test = {
          type = "app";
          program = "${pkgs.writeShellScript "wc-test" ''
            exec ${batsWith pkgs}/bin/bats -r tests "$@"
          ''}";
        };
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.test;
      });
    };
}
