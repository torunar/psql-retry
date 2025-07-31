{
  description = "psql-retry";
  nixConfig = {
    extra-substituters = "https://kronor.cachix.org";
    extra-trusted-public-keys = "kronor.cachix.org-1:AcZQBZxsK0SSlBoWmD0dNxfmtSoXueMcDBAhxzGb0MU=";
  };
  inputs = {
    git-hooks.url = "github:cachix/git-hooks.nix";
    haskell-nix.url = "github:kronor-io/haskell.nix/wip-nixpkgs-ghc";
    haskell-nix.inputs.hackage.follows = "hackage-nix";
    haskell-nix.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.05";
    hackage-nix.url = "github:kronor-io/hackage.nix";
    hackage-nix.flake = false;
    kronor-haskell-packages.url = "github:kronor-io/kronor-haskell-packages/repo";
    kronor-haskell-packages.flake = false;
    cabal-audit-src.url = "github:kronor-io/cabal-audit";
  };
  outputs =
    { self
    , git-hooks
    , haskell-nix
    , hackage-nix
    , kronor-haskell-packages
    , cabal-audit-src
    , nixpkgs
    }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      mergeAttrs = x: y: x // y;

      foldr = op: nul: list:
        let
          len = builtins.length list;
          fold' = n:
            if n == len
            then nul
            else op (builtins.elemAt list n) (fold' (n + 1));
        in
        fold' 0;

      foldAttrs =
        op:
        nul:
        list_of_attrs:
        foldr
          (n: a:
          foldr
            (name: o:
            o // { ${name} = op n.${name} (a.${name} or nul); }
            )
            a
            (builtins.attrNames n)
          )
          { }
          list_of_attrs;
      eachSystem = f: foldAttrs mergeAttrs { }
        (map (s: builtins.mapAttrs (_: v: { ${s} = v; }) (f s)) supportedSystems);
    in
    eachSystem (system:
    let
      haskellNix = import haskell-nix {
        inherit system;
        sourcesOverride = {
          hackage = hackage-nix;
        };
      };

      pkgs = import nixpkgs (
        {
          inherit system;
          overlays = [ haskellNix.overlay ];
        }
      );
      pristinePkgs = import nixpkgs (
        {
          inherit system;
        }
      );
      compiler-nix-name = "ghc982";
      index-state = "2025-07-29T18:43:35Z";

      psqlRetryProject = pkgs.haskell-nix.project {
        src = ./.;
        inputMap = {
          "https://kronor-io.github.io/kronor-haskell-packages" = kronor-haskell-packages;
        };

        modules = (if system == "x86_64-darwin" || system == "aarch64-darwin" then [{
          packages = {
            streamly = {
              components = {
                library = { libs = [ pkgs.darwin.apple_sdk.frameworks.Cocoa ]; };
              };
            };
          };
        }] else [{
          dontPatchELF = false;
          dontStrip = false;
        }]) ++ [{ doHaddock = false; }];

        inherit compiler-nix-name;
        cabalProjectFreeze = builtins.readFile ./cabal.project.freeze;

        supportHpack = false;
      };

      shell = psqlRetryProject.shellFor {

        withHoogle = false;

        shellHook = ''
          ${self.checks.${system}.pre-commit-check.shellHook}
        '';
      };

    in
    {
      checks = {
        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixpkgs-fmt.enable = true;
            fourmolu.enable = true;
          };
        };
      };
      packages = {
        default = psqlRetryProject.psql-retry.components.exes.psql-retry;
      };
      devShells.default = shell;
    }
    );
}
