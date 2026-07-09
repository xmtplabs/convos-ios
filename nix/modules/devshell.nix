_: {
  config.perSystem =
    { pkgs, inputs', ... }:
    let
      xcode = pkgs.darwin.xcode_26_3;
      # mkShellNoCC keeps nix's clang/ld off PATH so xcodebuild uses Xcode's
      # We also override stdenv to drop the apple-sdk setup hook, which would
      # otherwise re-export SDKROOT/DEVELOPER_DIR after we set them.
      # See https://github.com/cachix/devenv/blob/main/src/modules/top-level.nix
      stdenvNoAppleSdk =
        if pkgs.stdenvNoCC.isDarwin then
          pkgs.stdenvNoCC.override (prev: {
            extraBuildInputs = builtins.filter (x: !(x ? sdkroot)) prev.extraBuildInputs;
          })
        else
          pkgs.stdenvNoCC;
    in
    {
      devShells.default = (pkgs.mkShellNoCC.override { stdenv = stdenvNoAppleSdk; }) {
        packages = [
          # fastlane + lanes from convos-releases; the wrapper exports
          # CONVOS_LANES for the stub Fastfile.
          inputs'.convos-releases.packages.fastlane
          # dSYM upload to Sentry in the prod TestFlight workflow
          pkgs.sentry-cli
        ];
        DEVELOPER_DIR = "${xcode}";
        LANG = "en_US.UTF-8";
        LC_ALL = "en_US.UTF-8";
        RUBYOPT = "-EUTF-8";
      };
    };
}
