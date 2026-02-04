let
  core = import ./core.nix;
in
{

  # All versions are kept here
  # New versions will be added if/when API changes cause regressions
  # This allows backwards compatibility with little overhead
  versions = {
    "0.9" = {
      inherit (core) buildDB buildHost;
    };
  };

  latest = "0.9";
}
