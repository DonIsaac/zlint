#!/usr/bin/env bash

set -e # Exit on error

function try_install() {
    package_manager=$1
    package_name=$2
    binary_name=${3:-$2}
    
    if ! which $binary_name > /dev/null; then
        echo "Installing $package_name"
        brew install $package_name
    else
        echo "$package_name is already installed, skipping"
    fi
}


if which brew > /dev/null; then
    try_install brew entr
    try_install brew typos-cli typos
    try_install brew kcov
    try_install brew bun
    elif which apt-get > /dev/null; then
    try_install apt-get entr
    try_install apt-get typos-cli typos
    try_install apt-get kcov
    if ! which bun > /dev/null; then
        echo "Bun is not installed. Please follow steps on https://bun.sh"
    fi
else
    echo "No supported package manager found. Please install dependencies manually and/or update this script to support your package manager."
    exit 1
fi
