// `missing_symbol` is not declared anywhere, so it must show up in the
// symbol table's unresolved references. `later` is a root-level forward
// reference that resolves, so it must not.
const a = missing_symbol;
const b = later;
const later = 1;
