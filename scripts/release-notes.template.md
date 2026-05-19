# vesl-core <TAG>

<one-line summary>

## Catalog

| crate                 | version |
| --------------------- | ------- |
<CRATE_TABLE>

## Nockchain pin

NOCK_PIN: `<NOCK_PIN>`

## Kernel JAM checksums

```
<JAM_SUMS>
```

## Highlights

- ...

## Breaking changes

- ...

## Bug fixes

- ...

## Known issues

- ...

## Verifying this release

- `scripts/check-jam.sh` reproduces all three JAMs from source
- `cargo test -p vesl-core` passes against sibling nockchain @ NOCK_PIN
- `cargo clippy --workspace -- -D warnings` clean
