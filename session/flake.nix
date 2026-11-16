{
  # Example home-manager configuration for the native /nix session (the app's
  # terminal runs this profile's bash directly — no proot). Put your own
  # packages in home.nix. Applied on the phone with
  #   home-manager switch --flake ~/.config/nix-native#native
  # (native-setup.sh bootstraps it the first time).
  description = "android-native-nix: home-manager profile for the native /nix session";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }:
    let pkgs = import nixpkgs { system = "aarch64-linux"; };
    in {
      homeConfigurations.native = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          ({ pkgs, ... }:
          let
            # Android has no passwd entry for the app's UID and OpenSSH refuses to run
            # without one ("No user exists for uid …"). nss_wrapper supplies it for the
            # ssh tools only; native-login.sh writes ~/.config/nss/passwd at every start.
            sshNss = pkgs.symlinkJoin {
              name = "openssh-nss-wrapper";
              paths = [ pkgs.openssh ];
              nativeBuildInputs = [ pkgs.makeWrapper ];
              postBuild = ''
                for b in ssh scp sftp ssh-keygen ssh-add ssh-agent; do
                  wrapProgram $out/bin/$b \
                    --set LD_PRELOAD ${pkgs.nss_wrapper}/lib/libnss_wrapper.so \
                    --run 'export NSS_WRAPPER_PASSWD=$HOME/.config/nss/passwd NSS_WRAPPER_GROUP=$HOME/.config/nss/group'
                done
              '';
            };
          in {
            home.username = "nix-on-droid";
            home.homeDirectory = "/data/data/com.termux.nix/files/home";
            home.stateVersion = "26.05";
            home.packages = [ pkgs.bashInteractive pkgs.coreutils pkgs.cacert pkgs.nix sshNss ];
            # home-manager's own man page is built with Python multiprocessing; not needed
            manual.manpages.enable = false;
            # single-user Nix: no user namespaces on Android → no sandbox, no build users.
            # Hard links work with the nix_app domain (ROM patch); set
            # auto-optimise-store = true only on such a ROM.
            nix.package = pkgs.nix;
            nix.settings = {
              experimental-features = [ "nix-command" "flakes" ];
              sandbox = false;
              build-users-group = "";
              auto-optimise-store = false;
            };
            programs.home-manager.enable = true;
            programs.bash.enable = true;
            home.sessionVariables = {
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              # Android has no /run and the app can't write /tmp: runtime dir in the app
              # cache (native-login.sh creates it, 0700)
              XDG_RUNTIME_DIR = "/data/data/com.termux.nix/cache/run";
              TMUX_TMPDIR = "/data/data/com.termux.nix/cache/run";
              # Boehm GC (in Nix) counts CPUs via /proc/stat, which apps may not read
              # → set your phone's core count to silence "GC Warning: Could not open /proc/stat"
              GC_NPROCS = "8";
            };
          })
        ];
      };
    };
}
