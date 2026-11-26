# Techo
#
# On a Guix host, run targets through the container:
#   scripts/guix-env make <target>
#
# Dependencies come two ways (ADR-0011):
#
# - The Akku index. Akku.manifest names each one, and Akku.lock pins each
#   one's archive and sha256: `make lock` has Akku 1.2.0 write it, and
#   `make check-akku-lock` fails unless it is what Akku makes of the
#   manifest against today's index. `make fetch` downloads each archive the
#   lock pins, checks its sha256 and unpacks it (scripts/fetch-akku-lock):
#   hashing into vendor/akku, and the others into vendor/akku-trees.
# - The owner's libraries outside the index, circuit, chez-sqlite3,
#   chez-curl, chez-sodium and unique-id, are git submodules under vendor/, each pinned at a commit
#   (SUBMODULE_PINS). A fresh clone runs `make submodules` on the
#   host once, before `make deps`.
# - chez-http-server is both, for now (ADR-0011, amended 2026-11-23): the
#   index has 0.11.0, and Techo needs 0.12.0's await-outside. Akku.manifest
#   and Akku.lock keep ^0.11.0, which brings the libraries the server needs,
#   and the path takes the server's src/ from the submodule
#   vendor/chez-http-server, at v0.12.0. The 0.11.0 tree is still fetched,
#   as the lock pins it, and nothing reads it.
#
# `make check-pins` holds them together: the lock pins exactly what `make
# fetch` gets, each tree is its archive, chez-libuv's copy is its tree and
# its build's products, each submodule's gitlink is its pin, and Akku.manifest
# names every `depends` entry each submodule's own Akku.manifest names. Those
# that download run on the host: the container has no network. `make deps`
# never fetches: it fails unless the lock pins exactly what `make fetch`
# gets and each tree is there; it builds chez-libuv's shim in a copy,
# build/chez-libuv, so that the fetched tree stays its archive, and links
# SRFI-64.

# The Chez binary. In the container, scripts/guix-env-enter exports the
# profile's real `scheme` binary. Elsewhere, scripts/require-chez --find
# takes the first `scheme` or `chez` on PATH that is Chez Scheme 10.4.1 or
# later, threaded, else the first that is Chez at all, else the first on
# PATH, else `scheme`, which check-chez then refuses. A CHEZ given on the
# command line or in the environment stays as given. Exported, so that
# chez-libuv's build, which make runs below, uses this one.
ifeq ($(strip $(CHEZ)),)
CHEZ := $(shell scripts/require-chez --find scheme chez)
endif
export CHEZ

# The C compiler chez-libuv's shim is built with. In the container,
# scripts/guix-env-enter exports the profile's gcc.
CC ?= cc
export CC

# chez-libuv's make, which deps runs in its copy, gets none of this command
# line's variables: it builds the shim under its own $(BUILD_DIR). CHEZ and
# CC reach it through the environment, exported above.
MAKEOVERRIDES =

# The make target to name in a missing-tool hint (scripts/require-tools):
# what the user typed, $(MAKECMDGOALS), or, when that is empty, the
# recipe's own target, $@.
GOAL = $(strip $(if $(MAKECMDGOALS),$(MAKECMDGOALS),$@))

# --- the submodules -----------------------------------------------------------
# NAME:PIN, each vendor/NAME at PIN, a full commit SHA: CI's checkout of a
# submodule is shallow and brings no tags, so a tag would not resolve there.
# Moving a pin is its own commit, with the reason (ADR-0011); `make
# check-pins` fails unless each gitlink is its PIN.
#   circuit           a39346c (no release yet): await-outside, and (circuit worker)
#   chez-sqlite3      v0.1.1
#   chez-curl         v0.1.2
#   chez-http-server  v0.12.0, until the index has it (ADR-0011, amended)
#   chez-sodium       v0.1.0
#   unique-id         v0.1.0
SUBMODULE_PINS := \
  circuit:a39346c31d4242df4a261b6945c411992ee7a504 \
  chez-sqlite3:960d9f0028ce09b51019cd7050d5833af30f98e0 \
  chez-curl:15197e8a699c4b2d6c12e2b62c7dc76be7729780 \
  chez-http-server:bba2ba6fea252996d31bffc6255d8be36e9bdfd2 \
  chez-sodium:981ba2e9e6a41b305d645db8ded4bd49c2c5b341 \
  unique-id:e0ed1284e9262141d87df4144edba114d44eb5e7
SUBMODULE_NAMES := $(foreach p,$(SUBMODULE_PINS),$(firstword $(subst :, ,$(p))))
CIRCUIT_DIR := vendor/circuit
SQLITE3_DIR := vendor/chez-sqlite3
CURL_DIR    := vendor/chez-curl
SODIUM_DIR  := vendor/chez-sodium
UNIQUE_ID_DIR := vendor/unique-id
# The server the path uses: the submodule, 0.12.0, not Akku's 0.11.0 tree.
SERVER_DIR  := vendor/chez-http-server
SERVER_VERSION := 0.12.0

# --- the trees ----------------------------------------------------------------
# Every package `make fetch` unpacks into vendor/akku-trees, as NAME:FILE,
# FILE a path under its tree that deps looks for. fetch, deps and
# check-pins each take every one. hashing goes into vendor/akku on its own.
# deps and check-pins fail unless Akku.lock pins exactly those projects,
# each once (CHECK_LOCKED, below).
AKKU_LOCK_FILE := Akku.lock
AKKU_DIR := vendor/akku
AKKU_TREES_DIR := vendor/akku-trees
AKKU_TREES := chez-http-server:src/http-server.sls \
  chez-websocket:src/websocket.sls \
  chez-libuv:Makefile \
  chez-httparse:src \
  byte-machine:src \
  chez-uri:src \
  jsonparse:src/jsonparse/easy.sls \
  threading:src \
  chez-srfi:%3a64.sls
AKKU_TREE_NAMES := $(foreach t,$(AKKU_TREES),$(firstword $(subst :, ,$(t))))

# tree NAME: NAME's tree under vendor/akku-trees. make stops at once, before
# any target runs, unless AKKU_TREES names NAME.
tree = $(if $(filter $(1),$(AKKU_TREE_NAMES)),$(AKKU_TREES_DIR)/$(1),$(error AKKU_TREES names no $(1), which a directory of the Makefile's is in))

WEBSOCKET_DIR    := $(call tree,chez-websocket)
LIBUV_TREE       := $(call tree,chez-libuv)
HTTPARSE_DIR     := $(call tree,chez-httparse)
BYTE_MACHINE_DIR := $(call tree,byte-machine)
URI_DIR          := $(call tree,chez-uri)
JSONPARSE_DIR    := $(call tree,jsonparse)
THREADING_DIR    := $(call tree,threading)
SRFI_DIR         := $(call tree,chez-srfi)

# chez-libuv's copy, where deps builds its shim. `make clean` removes it
# with build/.
LIBUV_DIR := build/chez-libuv

# --- the library path ---------------------------------------------------------
# LIBDIRS is the path `make dev`, `make libdirs` and the suites use: Techo's
# src/, then tests/, which holds (techo-testing), then the submodules' src/
# directories, the server's among them, then the Akku trees as circuit
# orders them: chez-websocket's, chez-libuv's copy's and those of the other libraries the
# server brings, then jsonparse's, then threading's, then build/scheme-libs,
# which carries (srfi :64), then vendor/akku, which holds hashing.
# chez-libuv locates its C shim by an absolute path baked into the
# config.sls its build generates in the copy, so only the copy's src/ is
# needed. vendor/akku comes last, so it can stand in for none of the
# others' libraries.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
LIBDIR_LIST := src \
  tests \
  $(CIRCUIT_DIR)/src \
  $(SQLITE3_DIR)/src \
  $(CURL_DIR)/src \
  $(SODIUM_DIR)/src \
  $(UNIQUE_ID_DIR)/src \
  $(SERVER_DIR)/src \
  $(WEBSOCKET_DIR)/src \
  $(LIBUV_DIR)/src \
  $(HTTPARSE_DIR)/src $(BYTE_MACHINE_DIR)/src \
  $(URI_DIR)/src \
  $(JSONPARSE_DIR)/src \
  $(THREADING_DIR)/src \
  $(SRFI_LIBS) \
  $(AKKU_DIR)
LIBDIRS := $(subst $(SPACE),:,$(strip $(LIBDIR_LIST)))

# make stops at once, before any target runs, on an entry of LIBDIR_LIST
# under vendor/akku-trees but a tree's src/ that AKKU_TREES names.
LIBDIR_STRAYS := $(filter-out $(foreach n,$(AKKU_TREE_NAMES),$(AKKU_TREES_DIR)/$(n)/src),$(filter $(AKKU_TREES_DIR)/%,$(LIBDIR_LIST)))
$(if $(LIBDIR_STRAYS),$(error LIBDIR_LIST holds $(LIBDIR_STRAYS), which no tree AKKU_TREES names gives))

# Every suite, in one order everywhere: make 3.82 to 4.2 leave $(wildcard)
# unsorted. `make test SUITES="tests/test-a.sps tests/test-b.sps"` runs only
# those.
SUITES := $(sort $(wildcard tests/test-*.sps))

# Seconds a suite may run before timeout kills it and make test names it
# HUNG.
TEST_TIMEOUT ?= 300

# GNU timeout.
TIMEOUT ?= $(or $(shell command -v timeout 2>/dev/null),$(shell command -v gtimeout 2>/dev/null),timeout)

# One physical line: check-help reads it with awk, and fails if it ends in
# a backslash.
.PHONY: help submodules check-help check-makefile check-guix check-guix-inside akku-deps lock check-akku-lock fetch check-pins check-chez deps dev libdirs test check-suites check-test-fails check-ci run machines clean

.DEFAULT_GOAL := help

# The name column is as wide as the longest target's name.
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / \
	  { n++; name[n] = $$1; text[n] = $$2; if (length($$1) > width) width = length($$1) } \
	  END { format = "  \033[36m%-" width "s\033[0m %s\n"; \
	        for (i = 1; i <= n; i++) printf format, name[i], text[i] }' $(MAKEFILE_LIST)

# Reads what `make help` prints, colour codes stripped, so it checks the
# listing itself. Both directions: every .PHONY target is listed, and every
# listed target is in .PHONY. A listed target left out of .PHONY silently
# stops running once a file of its name exists.
check-help: ## Fail unless `make help` lists exactly the .PHONY targets
	@status=0; \
	if grep -qE '^\.PHONY:.*\\$$' Makefile; then \
	  echo "check-help: the .PHONY line ends in a backslash; keep it on one line" >&2; \
	  status=1; \
	fi; \
	help=$$($(MAKE) --no-print-directory help) || { \
	  echo "check-help: make help failed" >&2; \
	  exit 1; \
	}; \
	esc=$$(printf '\033'); \
	listed=$$(printf '%s\n' "$$help" | sed "s/$$esc\[[0-9;]*m//g" | awk '{ print $$1 }'); \
	phony=$$(awk '/^\.PHONY:/ { $$1 = ""; print }' Makefile); \
	for t in $$phony; do \
	  printf '%s\n' $$listed | grep -qxF "$$t" || { \
	    echo "check-help: make help does not list .PHONY target '$$t'; give it a '## ' description on its target line" >&2; \
	    status=1; \
	  }; \
	done; \
	for t in $$listed; do \
	  printf '%s\n' $$phony | grep -qxF "$$t" || { \
	    echo "check-help: make help lists '$$t', which is not in .PHONY" >&2; \
	    status=1; \
	  }; \
	done; \
	exit $$status

check-guix: ## (host) Test scripts/guix-env on the host, then the toolchain inside the container
	@scripts/require-tools "$(GOAL)" guix
	@sh tests/guix-env-launcher.sh
	@scripts/guix-env make check-guix-inside

check-guix-inside: ## (inside the container) Assert the pinned toolchain, isolation and loopback-only network
	@CHEZ='$(CHEZ)' CC='$(CC)' sh scripts/guix-env-selftest

# Each package as Akku.lock pins it, downloaded, its sha256 checked, and
# unpacked by scripts/fetch-akku-lock: hashing into vendor/akku, and every
# one AKKU_TREES names into vendor/akku-trees. It needs curl or wget, tar,
# sha256sum or shasum, and diff, and xz with GNU tar, which reads the
# archive through it. A tree that already records the lock's sha256 is held
# to its archive under its directory's dl/, the archive downloaded again
# first if dl/ lacks it or holds another, and the tree unpacked again if it
# differs. So with every archive in dl/ it needs no network.
FETCH_TOOL = $(if $(shell command -v curl 2>/dev/null),curl,$(if $(shell command -v wget 2>/dev/null),wget,"curl or wget"))
SHA256_TOOL = $(if $(shell command -v sha256sum 2>/dev/null),sha256sum,$(if $(shell command -v shasum 2>/dev/null),shasum,"sha256sum or shasum"))
XZ_TOOL = $(if $(findstring GNU,$(shell tar --version 2>/dev/null)),xz)

fetch: ## (host) Fetch every Akku dependency as Akku.lock pins it, each sha256 checked: hashing into vendor/akku, the others into vendor/akku-trees
	@scripts/require-tools "$(GOAL)" $(FETCH_TOOL) tar $(XZ_TOOL) $(SHA256_TOOL) diff
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock hashing
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock $(AKKU_TREE_NAMES)

# The two checks deps and check-pins share, each in one place.
# CHECK_LOCKED fails unless Akku.lock pins exactly hashing and every tree
# AKKU_TREES names, each once, naming a project nothing fetches and a tree
# the lock doesn't pin (scripts/check-lock-projects). CHECK_LIBUV_COPY
# fails unless chez-libuv's copy is its tree plus its build's two products,
# build/ and src/libuv/private/config.sls, naming every other line `diff
# -rq` gives; a copy not made yet passes it (scripts/check-libuv-copy).
CHECK_LOCKED = AKKU_LOCK=$(AKKU_LOCK_FILE) sh scripts/check-lock-projects hashing $(AKKU_TREE_NAMES)
CHECK_LIBUV_COPY = sh scripts/check-libuv-copy $(LIBUV_TREE) $(LIBUV_DIR)

# CHECK_LOCKED, then scripts/fetch-akku-lock --check, which downloads
# nothing: each tree must record Akku.lock's sha256 and be the archive
# under its directory's dl/, with that sha256, unpacked, and it names each
# file that differs. Then CHECK_LIBUV_COPY; then the submodules, each
# gitlink at its pin (scripts/check-submodules, which needs git); then
# Akku.manifest against circuit's own (scripts/check-manifest-deps). It goes
# on past a check that fails, so one run names every fault.
check-pins: ## (host) Fail unless Akku.lock, the fetched trees, chez-libuv's copy and the submodules' gitlinks agree, and Akku.manifest names every depends entry circuit's does
	@scripts/require-tools "$(GOAL)" git awk sort uniq grep tar $(XZ_TOOL) $(SHA256_TOOL) diff
	@fail=0; \
	if ! $(CHECK_LOCKED); then \
	  echo "PIN MISMATCH: Akku.lock and the Makefile's AKKU_TREES name different packages. A lock move that adds or drops a package changes both, on one commit." >&2; fail=1; \
	fi; \
	trees=0; \
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock --check hashing || trees=1; \
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock --check $(AKKU_TREE_NAMES) || trees=1; \
	if [ $$trees -ne 0 ]; then \
	  echo "PIN MISMATCH: a tree above isn't the one Akku.lock pins. Run 'make fetch' on the host, which unpacks it again: an edit there is lost." >&2; fail=1; \
	fi; \
	if ! $(CHECK_LIBUV_COPY); then \
	  echo "PIN MISMATCH: $(LIBUV_DIR) isn't chez-libuv's tree and its build's products. Run 'make deps', which copies it again: an edit there is lost." >&2; fail=1; \
	fi; \
	if ! sh scripts/check-submodules $(SUBMODULE_PINS); then \
	  echo "PIN MISMATCH: a submodule above isn't at its pin. Move a pin in SUBMODULE_PINS and the gitlink together, in one commit (ADR-0011)." >&2; fail=1; \
	fi; \
	for n in $(SUBMODULE_NAMES); do \
	  if ! sh scripts/check-manifest-deps vendor/$$n/Akku.manifest Akku.manifest; then \
	    echo "PIN MISMATCH: Akku.manifest misses a depends entry vendor/$$n/Akku.manifest names (ADR-0011). Add it, then 'make lock'." >&2; fail=1; \
	  fi; \
	done; \
	exit $$fail

# --- Akku itself --------------------------------------------------------------
# Akku 1.2.0, the release for Chez Scheme, as scripts/akku-tool.lock pins
# it, unpacked into build/akku-tool, where scripts/akku runs it from: the
# path is written out, as scripts/akku names it. Guix's Akku is 1.1.0,
# which knows only the archive's old signing key. `make clean` removes it,
# so akku-deps runs again after it.
AKKU := scripts/akku

akku-deps: ## (host, and after make clean) Fetch Akku 1.2.0 into build/akku-tool, as scripts/akku-tool.lock pins it, its sha256 checked
	@scripts/require-tools "$(GOAL)" $(FETCH_TOOL) tar $(XZ_TOOL) $(SHA256_TOOL) diff
	@AKKU_LOCK=scripts/akku-tool.lock AKKU_DEST=build/akku-tool sh scripts/fetch-akku-lock akku

# `akku update`, so that Akku reads today's index, then `akku lock`, which
# writes Akku.lock from Akku.manifest. Akku downloads the index with curl,
# and checks its signature itself.
lock: ## (host) Write Akku.lock from Akku.manifest with Akku 1.2.0, against today's index
	@scripts/require-tools "$(GOAL)" curl $(CHEZ)
	$(AKKU) update
	$(AKKU) lock

# scripts/check-akku-lock: `akku update`, then `akku lock` on a copy of
# Akku.manifest in a scratch directory, and it fails unless every token
# `akku lock` writes for each project, in order, is Akku.lock's; layout,
# comments and the projects' order aside. So a release on the index that a
# range in the manifest admits fails it until `make lock` moves the lock.
# It never skips: where Akku isn't there, it fails naming `make akku-deps`,
# and where the index can't be fetched, the network.
check-akku-lock: ## (host) Fail unless Akku.lock is what Akku 1.2.0 makes of Akku.manifest against today's index
	@scripts/require-tools "$(GOAL)" curl $(CHEZ) awk sort cmp diff
	@AKKU=$(AKKU) AKKU_LOCK=$(AKKU_LOCK_FILE) sh scripts/check-akku-lock

# Runs $(CHEZ) once, asking its version and build, and refuses one that is
# not Chez Scheme 10.4.1 or later, threaded, chez-http-server's floor,
# naming what it found and what it needs (scripts/require-chez). A CHEZ
# that is empty or not on PATH it refuses itself, so require-tools doesn't
# ask first. deps takes it first, so every target that runs Chez on the
# libraries holds it before Chez runs.
check-chez: ## Fail unless CHEZ is Chez Scheme 10.4.1 or later, threaded, naming what it found
	@scripts/require-chez "$(GOAL)" "$(CHEZ)"

# git submodule update --init: a fresh clone's submodules, each at its
# pin. It needs git, so it runs on the host: the container has none.
submodules: ## (host) Check out each submodule at its pin (git submodule update --init)
	@scripts/require-tools "$(GOAL)" git
	git submodule update --init

# Never fetches: the container has no network, so a missing tree is
# fetched on the host. chez-srfi ships Akku's percent-encoded filenames
# (%3a64.sls) and Chez resolves (srfi :64) only from the decoded spelling
# (:64.sls), so every entry is linked under both and the tree itself is left
# alone. Two runs may link at once, so nothing is cleared first: a link
# that is already right is kept, a new one is made beside its place and
# renamed onto it, and a link whose file has gone is unlinked last. The
# name beside its place comes from mktemp, not the shell's PID: every
# container counts PIDs from 1, so two runs share them. `ln -sn`, and
# the rename with the flag scripts/mv-no-follow-flag finds (GNU mv -T, BSD
# mv -h), never follow a link that is already there into the fetched tree. A name a
# killed run left behind is removed once it is an hour old.
define link-srfi
	@mkdir -p $(SRFI_LIBS)/srfi
	@set -e; \
	src="$(abspath $(SRFI_DIR))"; dst="$(abspath $(SRFI_LIBS))/srfi"; \
	tok=$$(mktemp -u XXXXXXXXXXXX); \
	mvf=$$(sh scripts/mv-no-follow-flag) || { echo "deps: this mv has neither -T nor -h" >&2; exit 1; }; \
	find "$$dst" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete; \
	link() { \
	  [ "$$(readlink "$$dst/$$2" 2>/dev/null)" = "$$1" ] && return 0; \
	  ln -sn "$$1" "$$dst/.tmp.$$tok.$$2" && mv $$mvf "$$dst/.tmp.$$tok.$$2" "$$dst/$$2"; \
	}; \
	for f in "$$src"/*; do \
	  b=$$(basename "$$f"); \
	  link "$$f" "$$b"; \
	  d=$$(printf '%s' "$$b" | sed 's/%3a/:/g'); \
	  [ "$$d" = "$$b" ] || link "$$f" "$$d"; \
	done; \
	for l in "$$dst"/*; do \
	  [ -e "$$l" ] || unlink "$$l"; \
	done
endef

# CHECK_LOCKED first. Then each submodule's src/ must be there and its
# checkout at its pin: scripts/submodule-head reads the commit from git's
# own files, since the container has no git, and a checkout it cannot read
# is let through (check-pins, on the host, holds the gitlinks). A pull that
# moves a pin leaves the files behind until `make submodules`, and this is
# what says so. The server's submodule must also be the release
# SERVER_VERSION names, by its own Akku.manifest.
# Each
# tree must be there, by the file AKKU_TREES names under it, and record the
# sha256 Akku.lock pins (scripts/fetch-akku-lock --check-record), as
# hashing must under vendor/akku. chez-libuv's tree is copied to
# build/chez-libuv again whenever CHECK_LIBUV_COPY fails, a copy not made
# yet aside, and chez-libuv's own `make build` builds the shim and its
# config.sls in the copy: the fetched tree stays its archive, which
# check-pins holds.
deps: check-chez ## Copy chez-libuv to build/chez-libuv and build its shim there, and link SRFI-64 into build/scheme-libs; never fetches
	@scripts/require-tools "$(GOAL)" $(CHEZ) $(CC) pkg-config
	@for d in $(CIRCUIT_DIR) $(SQLITE3_DIR) $(CURL_DIR) $(SERVER_DIR) $(SODIUM_DIR) $(UNIQUE_ID_DIR); do \
	  if [ ! -d $$d/src ]; then \
	    echo "deps: $$d/src not found, so the submodule isn't checked out. Run 'make submodules' on the host: the container has no git." >&2; \
	    exit 1; \
	  fi; \
	done
	@for p in $(SUBMODULE_PINS); do \
	  n=$${p%%:*}; want=$${p#*:}; \
	  got=$$(sh scripts/submodule-head vendor/$$n); \
	  if [ -n "$$got" ] && [ "$$got" != "$$want" ]; then \
	    echo "deps: vendor/$$n is at $$(printf %.7s "$$got"), not its pin $$(printf %.7s "$$want"). Run 'make submodules' on the host: the container has no git." >&2; \
	    exit 1; \
	  fi; \
	done
	@if ! grep -qF '("chez-http-server" "$(SERVER_VERSION)")' $(SERVER_DIR)/Akku.manifest; then \
	  echo "deps: $(SERVER_DIR) isn't chez-http-server $(SERVER_VERSION). Run 'make submodules' on the host: the container has no git." >&2; \
	  exit 1; \
	fi
	@if ! $(CHECK_LOCKED) > /dev/null; then \
	  echo "deps: so Akku.lock and the Makefile's AKKU_TREES name different packages. A lock move that adds or drops a package changes both, on one commit." >&2; \
	  exit 1; \
	fi
	@if [ ! -e $(AKKU_DIR)/hashing/sha-2.scm ]; then \
	  echo "deps: $(AKKU_DIR)/hashing/sha-2.scm not found, so hashing, which Akku.lock pins, isn't fetched. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@if ! AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock --check-record hashing > /dev/null; then \
	  echo "deps: so $(AKKU_DIR) holds another hashing than the one Akku.lock pins. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@for t in $(AKKU_TREES); do \
	  name=$${t%%:*}; f=$(AKKU_TREES_DIR)/$$name/$${t#*:}; \
	  if [ ! -e "$$f" ]; then \
	    echo "deps: $$f not found, so $$name, which Akku.lock pins, isn't fetched. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	    exit 1; \
	  fi; \
	done
	@if ! AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock --check-record $(AKKU_TREE_NAMES) > /dev/null; then \
	  echo "deps: so $(AKKU_TREES_DIR) holds another tree than one Akku.lock pins. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@if [ ! -e $(LIBUV_DIR) ] || ! $(CHECK_LIBUV_COPY) > /dev/null; then \
	  mkdir -p $(dir $(LIBUV_DIR)) && \
	  mvf=$$(sh scripts/mv-no-follow-flag) && \
	  tmp=$$(mktemp -d $(LIBUV_DIR).tmp.XXXXXXXX) && \
	  cp -R $(LIBUV_TREE)/. $$tmp && \
	  rm -rf $(LIBUV_DIR) && \
	  mv $$mvf $$tmp $(LIBUV_DIR) && \
	  echo "deps: $(LIBUV_TREE) copied to $(LIBUV_DIR)" || exit 1; \
	fi
	@$(MAKE) --no-print-directory -C $(LIBUV_DIR) build
	$(link-srfi)
	@echo "deps: chez-libuv's shim built in $(LIBUV_DIR); $(SRFI_DIR) linked into $(SRFI_LIBS)/srfi"

dev: deps ## Start a REPL on the library path
	$(CHEZ) --libdirs $(LIBDIRS)

# One line, the path and nothing else, so a service or a container can take
# it: scheme --libdirs "$(make libdirs)" --program app.sps, from the
# checkout, where its relative directories resolve. It builds nothing: run
# make deps first.
libdirs: ## Print the library path a program needs, LIBDIRS, on one line: for running it without make
	@printf '%s\n' '$(LIBDIRS)'

# Runs each suite as its own process under GNU timeout and reports its exit
# status, or HUNG when timeout killed it (exit 124). It fails if any suite
# failed or hung, or if none matched. At a terminal, --foreground keeps a
# suite in make's process group, so Ctrl-C reaches it at once; but then
# timeout kills the suite alone, and a child it started (curl, a server)
# lives on, holding its port. Anywhere else, CI and pipes included, timeout
# kills the suite's whole process group. The checks come first: check-chez,
# through deps, check-help and check-suites each stop it.
test: deps check-help check-suites ## Run every tests/test-*.sps under timeout (or SUITES="a.sps b.sps"); fail if one fails or hangs, or none exists
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ)
	@if [ -z "$(SUITES)" ]; then \
	  echo "test: no suites: nothing matches tests/test-*.sps" >&2; \
	  exit 1; \
	fi; \
	passed=0; failed=0; hung=0; fg=; \
	if [ -t 0 ]; then fg=--foreground; fi; \
	for t in $(SUITES); do \
	  echo "=== $$t"; \
	  $(TIMEOUT) $$fg $(TEST_TIMEOUT) $(CHEZ) --libdirs $(LIBDIRS) --program $$t; \
	  rc=$$?; \
	  if [ $$rc -eq 0 ]; then \
	    echo "test: pass $$t"; passed=$$((passed + 1)); \
	  elif [ $$rc -eq 124 ]; then \
	    echo "test: HUNG $$t (no exit within $(TEST_TIMEOUT)s)"; hung=$$((hung + 1)); \
	  else \
	    echo "test: FAIL $$t (exit $$rc)"; failed=$$((failed + 1)); \
	  fi; \
	done; \
	echo "test: ran $$((passed + failed + hung)), passed $$passed, failed $$failed, hung $$hung"; \
	[ $$failed -eq 0 ] && [ $$hung -eq 0 ]

# Reads every suite as data and fails unless each one's last datum is the
# shared exit form, (techo-testing)'s suite-exit-form, and no datum before
# it holds an exit form but (exit 1), naming each suite that breaks either
# rule (tests/check-suites.sps). With no suite it passes: make test fails
# that case itself.
check-suites: deps ## Fail unless every tests/test-*.sps ends with the shared exit form
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(LIBDIRS) --program tests/check-suites.sps $(SUITES)

# The program, on the library path: make run ARGS="serve".
run: deps ## Run techo on the library path: make run ARGS="serve" (ARGS="help" lists the commands)
	@$(CHEZ) --libdirs $(LIBDIRS) --program techo.sps $(ARGS)

# Renders the machines' diagrams from their tables into
# .plans/machines/migrate.md, doorway.md, key.md, login.md, write.md and
# lifecycle.md (scripts/render-machines.sps prints the text of the one it
# is named, the migrate one by default). tests/test-migrations.sps,
# tests/test-transaction.sps, tests/test-keys.sps, tests/test-login.sps and
# tests/test-nodes.sps fail when a file differs.
machines: deps ## Write .plans/machines/migrate.md, doorway.md, key.md, login.md, write.md and lifecycle.md from the tables
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@mkdir -p .plans/machines
	@for m in migrate doorway key login write lifecycle; do \
	  $(CHEZ) --libdirs $(LIBDIRS) --program scripts/render-machines.sps $$m > .plans/machines/$$m.md.tmp || exit 1; \
	  mv .plans/machines/$$m.md.tmp .plans/machines/$$m.md; \
	done

# Every action a workflow uses is pinned to a full commit SHA, with its tag in
# a comment (scripts/ci/check-action-pins.sh).
check-ci: ## Fail unless every action in .github/workflows is pinned to a full commit SHA
	@sh scripts/ci/check-action-pins.sh .github/workflows

# In a copy of the tree, plants a failing suite, a suite with no test, a
# hanging suite, a suite without the exit form, and no suite at all, and
# requires make test to fail on each, naming it (tests/check-test-fails.sh).
check-test-fails: ## Plant a failing suite, a hanging one and others in a copy; make test must fail on each, by name
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ) tar
	@MAKE='$(MAKE)' TIMEOUT='$(TIMEOUT)' CHEZ='$(CHEZ)' sh tests/check-test-fails.sh

# Holds make submodules, deps' two hints (a submodule missing, and one off
# its pin), scripts/submodule-head, the absence of GNU-only mv and ln
# flags, scripts/mv-no-follow-flag and make clean on a read-only directory,
# in scratch directories (tests/check-makefile.sh).
check-makefile: ## Check make submodules, deps' hints, the mv flag and make clean on a read-only directory
	@MAKE='$(MAKE)' CHEZ='$(CHEZ)' sh tests/check-makefile.sh

# Removes build/ (BUILD_DIR), and with it chez-libuv's copy and its shim, and Akku
# 1.2.0 (akku-deps). vendor/akku and vendor/akku-trees stay: `make fetch`
# got them, and the container can't. A read-only directory in it would stop
# the removal, so write permission comes back first (chmod -R u+w is BSD's
# too).
clean: ## Remove build/, chez-libuv's copy and its shim with it
	@if [ -e $(BUILD_DIR) ]; then chmod -R u+w $(BUILD_DIR); fi
	rm -rf $(BUILD_DIR)
