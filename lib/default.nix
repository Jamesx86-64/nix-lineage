let

  # Gets all of the lineage API versions for backwards compatibility
  versionsData = import ./versions.nix;

  inherit (versionsData) versions;

  latest = versions.${versionsData.latest};
in
{

  # Allows setting specific API versions, the latest version or not specifying will use the latest too
  inherit versions latest;
  inherit (latest) buildDB buildHost;
}
