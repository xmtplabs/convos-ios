{ inputs, ... }:
{
  config.perSystem =
    { system, ... }:
    {
      # Override flake-parts' default pkgs so allowUnfree is on everywhere.
      # Xcode + apple-sdk derivations need it; leaving it global keeps
      # individual modules from each having to opt in.
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    };
}
