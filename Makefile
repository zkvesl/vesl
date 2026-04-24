# Vesl — Makefile
#
# Quick start:
#   cp vesl.toml.example vesl.toml   (edit nock_home if needed)
#   make setup                        (create hoon symlinks)
#   make build                        (compile hull)

.PHONY: help setup build test test-unit clean

# ---------------------------------------------------------------------------
# Config: vesl.toml → env var fallback → empty
# ---------------------------------------------------------------------------

NOCK_HOME ?= $(shell grep -s '^nock_home' vesl.toml 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' | head -1)

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------

help:
	@echo "Vesl — verifiable computation on Nockchain"
	@echo ""
	@echo "Quick start:"
	@echo "  cp vesl.toml.example vesl.toml   # edit nock_home if needed"
	@echo "  make setup                        # create hoon symlinks"
	@echo "  make build                        # compile the workspace"
	@echo ""
	@echo "Targets:"
	@echo "  setup       Create hoon/ symlinks to nockchain monorepo"
	@echo "  build       Compile the workspace (cargo build --workspace --release)"
	@echo "  test        Run all workspace tests"
	@echo "  test-unit   Run unit tests only (workspace libraries)"
	@echo "  clean       Remove build artifacts"
	@echo ""
	@echo "For the LLM/RAG reference implementation, see zkvesl/hull-llm."
	@echo ""
	@echo "Config: set values in vesl.toml or via environment variables."
	@echo "  NOCK_HOME = $(or $(NOCK_HOME),(not set))"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check-cargo:
	@command -v cargo >/dev/null 2>&1 || { \
		echo "Error: cargo not found."; \
		echo "Install Rust: https://rustup.rs"; \
		echo "Required nightly: $$(grep channel rust-toolchain.toml 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || echo 'see rust-toolchain.toml')"; \
		exit 1; \
	}

check-nock-home:
	@if [ -z "$(NOCK_HOME)" ]; then \
		echo "Error: NOCK_HOME is not set."; \
		echo ""; \
		echo "Option 1: Create vesl.toml from the template:"; \
		echo "  cp vesl.toml.example vesl.toml"; \
		echo ""; \
		echo "Option 2: Set the environment variable:"; \
		echo "  export NOCK_HOME=~/projects/nockchain/nockchain"; \
		exit 1; \
	fi
	@if [ ! -d "$(NOCK_HOME)/hoon/common" ]; then \
		echo "Error: $(NOCK_HOME)/hoon/common not found."; \
		echo "Is NOCK_HOME pointing to the nockchain monorepo root?"; \
		echo "  Current value: $(NOCK_HOME)"; \
		exit 1; \
	fi

check-hoonc:
	@command -v hoonc >/dev/null 2>&1 || { \
		echo "Error: hoonc not found."; \
		echo "Build it from the nockchain monorepo:"; \
		echo "  cd $(or $(NOCK_HOME),\$$NOCK_HOME) && make install-hoonc"; \
		exit 1; \
	}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

setup: check-cargo check-nock-home
	@NOCK_HOME="$(NOCK_HOME)" ./scripts/setup-hoon-tree.sh

build: check-cargo
	cargo build --workspace --release

test: check-cargo
	cargo test --workspace

test-unit: check-cargo
	cargo test --workspace --lib

clean:
	cargo clean 2>/dev/null || true
	rm -rf hull/.data.vesl/ out.jam
	@echo "Clean."
