{
  description = "AgentObs development and design environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    design-layer.url = "github:lostbean/design-layer";
    design-layer.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      design-layer,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        unstable-packages = final: _prev: {
          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            unstable-packages
          ];
          config.allowUnfree = true;
        };

        isDarwin = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;

        shell = pkgs.mkShell {
          buildInputs =
            with pkgs;
            [
              unstable.beamMinimal29Packages.elixir_1_20
              unstable.beamMinimal29Packages.erlang
              unstable.beamMinimal29Packages.rebar3
              unstable.beamMinimal29Packages.elixir-ls
              # expert-lsp
              unstable.livebook
              rebar3
              lefthook
              actionlint
              nodePackages.prettier
              ast-grep

            ]
            ++ (
              if isDarwin then
                [
                ]
              else
                [ ]
            );
          shellHook = ''
            echo "agent_obs dev environment"
          '';
        };

        designGateApp =
          name: target:
          let
            wrapper = pkgs.writeShellApplication {
              inherit name;
              text = ''
                if [ "$#" -lt 1 ]; then
                  exec ${target.program} "$@"
                fi

                layer_root="$1"
                ${design-layer.apps.${system}.project.program} \
                  ${design-layer.packages.${system}.gate-bundle}/schema/design-schema.json \
                  "$layer_root/.render"
                exec ${target.program} "$@"
              '';
            };
          in
          {
            type = "app";
            program = "${wrapper}/bin/${name}";
          };

      in
      {
        devShells.default = shell;
        apps = {
          design-gate-check =
            designGateApp "design-gate-check" design-layer.apps.${system}.check;
          design-gate-render =
            designGateApp "design-gate-render" design-layer.apps.${system}.render;
        };
      }
    );
}
