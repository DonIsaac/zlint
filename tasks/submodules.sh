#!/bin/bash
# Run this with `just submodules`
mkdir -p zig-out/repos
repos=$(cat test/repos.json)

while read repository
do
    name=$(echo "$repository" | jq -r .name)
    repo_url=$(echo "$repository" | jq -r .repo_url)
    hash=$(echo "$repository" | jq -r .hash)

    just clone-submodule "zig-out/repos/$name" $repo_url $hash

done < <(echo "$repos" | jq -c '.[]')
