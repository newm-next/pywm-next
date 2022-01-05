{
  description = "pywm - Wayland compositor core";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.pywm = (
        let
          my-python = pkgs.python3;
          python-with-my-packages = my-python.withPackages (p: with p; [
            imageio
            numpy
            pycairo
            evdev
            matplotlib
          ]);
        in (
          pkgs.python3.pkgs.buildPythonPackage rec {
            pname = "pywm";
            version = "0.2";

            # BEGIN Fucking suubprojects bug workaround for 'src = ./.'
            srcs = [
              ./.
              (builtins.fetchGit {
                url = "https://github.com/swaywm/wlroots";
                rev = "3d6ca9942db43ca182d91b115597a4ca7f367eef";
                submodules = true;
              })
            ];

            setSourceRoot = ''
              for i in ./*; do
                if [ -f "$i/wlroots.syms" ]; then
                  wlrootsDir=$i
                fi
                if [ -f "$i/pywm/pywm.py" ]; then
                  sourceRoot=$i
                fi
              done
            '';

            preConfigure = ''
              cp -r ../$wlrootsDir ./subprojects/wlroots
              ls -al ../$wlrootsDir
              ls -al ./subprojects/wlroots
            '';
            # END Fucking suubprojects bug workaround

            nativeBuildInputs = with pkgs; [
              meson_0_60
              ninja
              pkg-config
              wayland-scanner
              glslang
            ];

            preBuild = "cd ..";

            buildInputs = with pkgs; [
              libGL
              wayland
              wayland-protocols
              libinput
              libxkbcommon
              pixman
              xorg.xcbutilwm
              xorg.xcbutilrenderutil
              xorg.xcbutilerrors
              xorg.xcbutilimage
              xorg.libX11
              seatd
              xwayland
              vulkan-loader
              mesa

              libpng
              ffmpeg
              libcap

              python-with-my-packages
            ];
          }
        )
      );
    }
  );
}