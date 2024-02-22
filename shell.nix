let
  pkgs = import <nixpkgs> {};

  inherit (pkgs)
    writeScript
    stdenv;

  shellWrapper = writeScript "shell-wrapper" ''
    #! ${stdenv.shell}
    set -e

    exec -a shell ${pkgs.fish}/bin/fish --login --interactive "$@"
  '';
in with pkgs; stdenv.mkDerivation {
  name = "playground";
  buildInputs = [
    pkg-config
    coreutils
    curl
    chicken
    zig
    openssl
    zlib
    readline
  ];
  shellHook = ''
    export LANG=en_US.UTF-8

    local_repo=$(pwd)/repo
    system_repository=$(chicken-install -repository)
    binary_version=${"$"}{system_repository##*/}

    local_repository=$local_repo/lib/chicken/$binary_version

    CHICKEN_REPOSITORY_PATH=$system_repository
    CHICKEN_REPOSITORY_PATH+=:$local_repository
    PATH+=:$local_repo/bin

    export CHICKEN_REPOSITORY_PATH
    export CHICKEN_INSTALL_REPOSITORY=$local_repository
    export CHICKEN_INSTALL_PREFIX=$local_repo
    export PATH

    export CC="zig cc"
    export CFLAGS="$NIX_CFLAGS_COMPILE"
    # NOTE: stop complaining about impure paths by default
    export NIX_ENFORCE_PURITY=0

    chicken_home="$(csi -R chicken.platform -p '(chicken-home)')"
    if [ ! -d "$chicken_home" ]
    then
        echo
        echo Will install dependencies because chicken home $chicken_home does not exists yet
        echo This is required to make Emacs Geiser work
        echo
        chicken-install apropos chicken-doc srfi-18
        echo
        echo Downloading doc repo and unpacking to $chicken_home
        echo
        mkdir -p "$chicken_home"
        cd "$chicken_home"
        curl https://3e8.org/pub/chicken-doc/chicken-doc-repo-5.tgz | tar zx
        cd -
    fi

    if [ ! -z "$PS1" ]
    then
      export SHELL="${shellWrapper}"
      exec "$SHELL"
    fi
  '';
}
