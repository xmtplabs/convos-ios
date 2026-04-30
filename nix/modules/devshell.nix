_: {
  config.perSystem =
    { pkgs, lib, ... }:
    let
      xcode = pkgs.darwin.xcode_26_3;
      root = ./../..;
      gems = pkgs.bundlerEnv {
        name = "fastlane-gems";
        ruby = pkgs.ruby_3_4;
        gemfile = root + /Gemfile;
        lockfile = root + /Gemfile.lock;
        gemset = root + /nix/gemset.nix;
        extraConfigPaths = [ (root + /fastlane/Pluginfile) ];
      };
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
          gems
          (lib.lowPrio gems.wrappedRuby)
        ];
        DEVELOPER_DIR = "${xcode}";
        LANG = "en_US.UTF-8";
        LC_ALL = "en_US.UTF-8";
        RUBYOPT = "-EUTF-8";
      };
    };
}
