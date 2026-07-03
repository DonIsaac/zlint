# Bump Ecoystem Repos

You are bumping git commit SHAs for ecosystem repositories in @test/repos.json to their latest versions.

- get the latest commit hash for each repo and write them to test/repos.json
- run `just submodules` to pull deltas from their remotes (it will take a bit)
- run `just e2e` to update snapshots
