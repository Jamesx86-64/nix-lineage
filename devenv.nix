# Devenv is a modern development environment manager using nix.
# Upstream URL: https://devenv.sh

{
  pkgs,
  ...
}:

{
  # Formatters
  treefmt = {
    enable = true;
    config.programs = {
      nixfmt.enable = true;
      mdformat = {
        enable = true;
        settings.wrap = 80;
        plugins = plugin: [ plugin.mdformat-gfm ];
      };
      yamlfmt = {
        enable = true;
        settings.formatter.retain_line_breaks_single = true;
      };
    };
  };

  # Enable Nix language support
  languages.nix = {
    enable = true;
    lsp = {
      enable = true;
      package = pkgs.nixd;
    };
  };

  git-hooks.hooks = {

    # Security & safety
    ripsecrets.enable = true;
    check-merge-conflicts.enable = true;

    # Code quality
    deadnix.enable = true;
    statix.enable = true;
    treefmt.enable = true;
    ruff.enable = true;
    typos.enable = true;
    markdownlint = {
      enable = true;
      settings.configuration = {
        MD013 = {
          code_blocks = false;
          tables = false;
          urls = false;
        };
        MD060.style = "any";
        MD041 = false;
      };
    };

    # File consistency
    check-added-large-files.enable = true;
    editorconfig-checker.enable = true;
    trim-trailing-whitespace.enable = true;
    end-of-file-fixer.enable = true;
  };
}
