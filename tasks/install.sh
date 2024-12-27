#!/usr/bin/env bash
set -euo pipefail

platform=$(uname -ms)

if [[ ${OS:-} = Windows_NT ]]; then
  if [[ $platform != MINGW64* ]]; then
    # powershell -c "irm zlint.sh/install.ps1|iex"
    # exit $?
    echo "zlint's install does not support Windows yet. Please download a copy of zlint here: https://github.com/DonIsaac/zlint/releases/latest"
    exit 1
  fi
fi

# Reset
Color_Off=''

# Regular Colors
Red=''
Green=''
Dim='' # White

# Bold
Bold_White=''
Bold_Green=''

if [[ -t 1 ]]; then
    # Reset
    Color_Off='\033[0m' # Text Reset

    # Regular Colors
    Red='\033[0;31m'   # Red
    Green='\033[0;32m' # Green
    Dim='\033[0;2m'    # White

    # Bold
    Bold_Green='\033[1;32m' # Bold Green
    Bold_White='\033[1m'    # Bold White
fi

error() {
    echo -e "${Red}error${Color_Off}:" "$@" >&2
    exit 1
}

info() {
    echo -e "${Dim}$@ ${Color_Off}"
}

info_bold() {
    echo -e "${Bold_White}$@ ${Color_Off}"
}

success() {
    echo -e "${Green}$@ ${Color_Off}"
}

case $platform in
'Darwin x86_64')
    target=macos-x86_64
    ;;
'Darwin arm64')
    target=macos-aarch64
    ;;
'Linux aarch64' | 'Linux arm64')
    target=linux-aarch64
    ;;
'MINGW64'*)
    target=windows-x86_64
    ;;
'Linux x86_64' | *)
    target=linux-x86_64
    ;;
esac

if [[ $target = macos-x86_64 ]]; then
    # Is this process running in Rosetta?
    # redirect stderr to devnull to avoid error message when not running in Rosetta
    if [[ $(sysctl -n sysctl.proc_translated 2>/dev/null) = 1 ]]; then
        target=macos-aarch64
        info "Your shell is running in Rosetta 2. Downloading bun for $target instead"
    fi
fi

GITHUB=${GITHUB-"https://github.com"}
github_repo="$GITHUB/DonIsaac/zlint"

if [[ $# = 0 ]]; then
    zlint_uri=$github_repo/releases/latest/download/zlint-$target
else
    zlint_uri=$github_repo/releases/download/$1/zlint-$target
fi

# macos/linux cross-compat mktemp
# https://unix.stackexchange.com/questions/30091/fix-or-alternative-for-mktemp-in-os-x
tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'zlint')
install_dir=/usr/local/bin

curl --fail --location --progress-bar --output "$tmpdir/zlint" "$zlint_uri" ||
    error "Failed to download zlint from \"$zlint_uri\""
chmod +x "$tmpdir/zlint"

# Check if user can write to install directory
if [[ ! -w $install_dir ]]; then
    info "Saving zlint to $install_dir. You will be prompted for your password."
    sudo mv "$tmpdir/zlint" "$install_dir"
    success "zlint installed to $install_dir/zlint" 
else 
    mv "$tmpdir/zlint" "$install_dir"
    success "zlint installed to $install_dir/zlint"
fi
