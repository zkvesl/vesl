# Docker pin-of-record

`NOCKCHAIN_COMMIT` holds the pinned nockchain monorepo SHA that local
`Dockerfile`s must pass as the `NOCKCHAIN_COMMIT` build-arg. The
Dockerfile itself is gitignored (project policy: local dev only, not
shipped), so this file is the authoritative, *tracked* record of what
version of upstream nockchain a container build should use.

`scripts/check-pins.sh` validates that this file agrees with CI's
`NOCK_PIN` (`.github/workflows/jam-determinism.yml`); `scripts/bump-pin.sh`
writes both.

## AUDIT 2026-04-17 M-08

Before this pin existed, Dockerfiles used `git clone --depth 1
--branch main`. Every image rebuild silently picked up whatever
upstream `main` said that day — jet regressions, tx-engine breaks, or
hoonc compiler drift all landed without review. The pin fixes that.

## AUDIT 2026-05-19 H-21

The pin tooling (`check-pins.sh`, `bump-pin.sh`) previously read the
gitignored `Dockerfile`, which is absent in CI — so the gate never ran
there. Both tools now operate on this tracked file, and the clone org
is fixed to `nockchain/nockchain`. The pin is gated for real.

## Bumping the pin

1. Pick a commit on `nockchain/nockchain` to adopt.
2. Run `scripts/bump-pin.sh nock <sha>` — it rewrites every NOCK_PIN
   site atomically (this file and `jam-determinism.yml`) and refuses a
   SHA that does not exist upstream.
3. Rebuild the local container:
   `docker build --build-arg NOCKCHAIN_COMMIT=$(cat docker/NOCKCHAIN_COMMIT) ...`
4. Run the test matrix before merging.

## Dockerfile snippet

```dockerfile
ARG NOCKCHAIN_COMMIT=fe46f4e3a0ce9532288e9cf3a3fb7e94bf9cba1f
RUN git clone https://github.com/nockchain/nockchain.git $WORKSPACE/nockchain \
    && git -C $WORKSPACE/nockchain checkout ${NOCKCHAIN_COMMIT}
```

Keep the default `ARG` value in sync with this file (or always pass
`--build-arg NOCKCHAIN_COMMIT=$(cat docker/NOCKCHAIN_COMMIT)`).
