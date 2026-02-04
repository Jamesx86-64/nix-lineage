{
  description = "Nix Lineage Framework";

  # Flake outputs are required to be functions hence the `_:`
  # Exports the public Lineage API as the flake output
  outputs = _: {

    # For direct use within a flake
    lib = import ./lib/default.nix;
  };
}
