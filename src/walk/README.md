# Walkers

Directory walkers traverse files in a directory.

There's two kinds:
- `Walker`: starts at a single root directory. Uses less memory, but you cannot
  have multiple roots. Also roots must be a `fs.Dir`

- `MultiWalker`: supports multiple and heterogenous roots. More flexible than
  `Walker`, but each entry has its own path allocated.
