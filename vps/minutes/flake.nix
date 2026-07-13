{
  # Self-contained dev/run environment for the minutes-generation service.
  # Everything (python3 + requests, ffmpeg) is provided INSIDE this flake, so
  # nothing is installed globally on the shared AI-OCR VPS.
  #
  # Usage on the VPS (in ~/projects/minutes):
  #   nix develop                      # enter a shell with python + ffmpeg
  #   python -m src.main draft <audio.mp4> --vtt <teams.vtt>
  # or one-shot:
  #   nix develop -c python -m src.main draft <audio.mp4> --vtt <teams.vtt>
  description = "minutes: Teams recording -> transcript (Sakura Whisper) -> draft (Sakura Chat)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      py = pkgs.python3.withPackages (ps: [ ps.requests ]);
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ py pkgs.ffmpeg ];
        shellHook = ''
          echo "minutes devshell: python=$(python --version 2>&1), ffmpeg=$(ffmpeg -version | head -n1)"
          echo "run: python -m src.main draft <audio> [--vtt <vtt>]"
        '';
      };

      # `nix run .#minutes -- draft <audio> --vtt <vtt>`
      # MUST be invoked from the project dir (~/projects/minutes): it imports
      # `src/` from the current directory and writes outputs to `out/` there.
      apps.${system}.minutes = {
        type = "app";
        program = toString (pkgs.writeShellScript "minutes" ''
          export PATH=${pkgs.lib.makeBinPath [ py pkgs.ffmpeg ]}:$PATH
          if [ ! -d src ]; then
            echo "error: run from the project dir (~/projects/minutes); src/ not found in $PWD" >&2
            exit 1
          fi
          exec ${py}/bin/python -m src.main "$@"
        '');
      };
    };
}
