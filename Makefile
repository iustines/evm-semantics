# Common to all versions of K
# ===========================

.PHONY: all clean deps ocaml-deps build defn sphinx split-tests \
		test test-all vm-test vm-test-all bchain-test bchain-test-all proof-test proof-test-all

all: build split-tests

clean:
	rm -r .build
	find tests/proofs/ -name '*.k' -delete

build: .build/ocaml/driver-kompiled/interpreter .build/java/driver-kompiled/timestamp

# Dependencies
# ------------

K_SUBMODULE=$(CURDIR)/.build/k
BUILD_LOCAL=$(CURDIR)/.build/local
PKG_CONFIG_LOCAL=$(BUILD_LOCAL)/lib/pkgconfig

deps: $(K_SUBMODULE)/make.timestamp ocaml-deps

$(K_SUBMODULE)/make.timestamp:
	git submodule update --init -- $(K_SUBMODULE)
	cd $(K_SUBMODULE) \
		&& mvn package -q -DskipTests
	touch $(K_SUBMODULE)/make.timestamp

ocaml-deps: .build/local/lib/pkgconfig/libsecp256k1.pc
	opam init --quiet --no-setup
	opam repository add k "$(K_SUBMODULE)/k-distribution/target/release/k/lib/opam" \
		|| opam repository set-url k "$(K_SUBMODULE)/k-distribution/target/release/k/lib/opam"
	opam update
	opam switch 4.03.0+k
	export PKG_CONFIG_PATH=$(PKG_CONFIG_LOCAL) ; \
	opam install --yes mlgmp zarith uuidm cryptokit secp256k1 bn128

# install secp256k1 from bitcoin-core
.build/local/lib/pkgconfig/libsecp256k1.pc:
	git submodule update --init -- .build/secp256k1/
	cd .build/secp256k1/ \
		&& ./autogen.sh \
		&& ./configure --enable-module-recovery --prefix="$(BUILD_LOCAL)" \
		&& make -s -j4 \
		&& make install

K_BIN=$(K_SUBMODULE)/k-distribution/target/release/k/bin

# Building
# --------

# Tangle definition from *.md files

k_files:=driver.k data.k evm.k analysis.k krypto.k verification.k
ocaml_files:=$(patsubst %,.build/ocaml/%,$(k_files))
java_files:=$(patsubst %,.build/java/%,$(k_files))
defn_files:=$(ocaml_files) $(java_files)

defn: $(defn_files)

.build/java/%.k: %.md
	@echo "==  tangle: $@"
	mkdir -p $(dir $@)
	pandoc --from markdown --to tangle.lua --metadata=code:java $< > $@

.build/ocaml/%.k: %.md
	@echo "==  tangle: $@"
	mkdir -p $(dir $@)
	pandoc --from markdown --to tangle.lua --metadata=code:ocaml $< > $@

# Java Backend

.build/java/driver-kompiled/timestamp: $(java_files) deps
	@echo "== kompile: $@"
	$(K_BIN)/kompile --debug --main-module ETHEREUM-SIMULATION --backend java \
					--syntax-module ETHEREUM-SIMULATION $< --directory .build/java

# OCAML Backend

.build/ocaml/driver-kompiled/interpreter: $(ocaml_files) KRYPTO.ml deps
	@echo "== kompile: $@"
	eval $(shell opam config env) \
	$(K_BIN)/kompile --debug --main-module ETHEREUM-SIMULATION \
					--syntax-module ETHEREUM-SIMULATION $< --directory .build/ocaml \
					--hook-namespaces KRYPTO --gen-ml-only -O3 --non-strict; \
	ocamlfind opt -c .build/ocaml/driver-kompiled/constants.ml -package gmp -package zarith; \
	ocamlfind opt -c -I .build/ocaml/driver-kompiled KRYPTO.ml -package cryptokit -package secp256k1 -package bn128; \
	ocamlfind opt -a -o semantics.cmxa KRYPTO.cmx; \
	ocamlfind remove ethereum-semantics-plugin; \
	ocamlfind install ethereum-semantics-plugin META semantics.cmxa semantics.a KRYPTO.cmi KRYPTO.cmx; \
	$(K_BIN)/kompile --debug --main-module ETHEREUM-SIMULATION \
					--syntax-module ETHEREUM-SIMULATION $< --directory .build/ocaml \
					--hook-namespaces KRYPTO --packages ethereum-semantics-plugin -O3 --non-strict; \
	cd .build/ocaml/driver-kompiled && ocamlfind opt -o interpreter constants.cmx prelude.cmx plugin.cmx parser.cmx lexer.cmx run.cmx interpreter.ml -package gmp -package dynlink -package zarith -package str -package uuidm -package unix -package ethereum-semantics-plugin -linkpkg -inline 20 -nodynlink -O3 -linkall

# Tests
# -----

# Override this with `make TEST=echo` to list tests instead of running
TEST=./kevm test

test-all: vm-test-all bchain-test-all proof-test-all interactive-test-all
test: vm-test bchain-test proof-test interactive-test

split-tests: tests/ethereum-tests/make.timestamp split-proof-tests

tests/ethereum-tests/make.timestamp:
	@echo "==  git submodule: cloning upstreams test repository"
	git submodule update --init -- tests/ethereum-tests
	touch $@

tests/ethereum-tests/%.json: tests/ethereum-tests/make.timestamp

# VMTests

vm_tests=$(wildcard tests/ethereum-tests/VMTests/*/*.json)
slow_vm_tests=$(wildcard tests/ethereum-tests/VMTests/vmPerformance/*.json)
quick_vm_tests=$(filter-out $(slow_vm_tests), $(vm_tests))

vm-test-all: $(vm_tests:=.test)
vm-test: $(quick_vm_tests:=.test)

tests/ethereum-tests/VMTests/%.test: tests/ethereum-tests/VMTests/% build
	$(TEST) $<

# BlockchainTests

bchain_tests=$(wildcard tests/ethereum-tests/BlockchainTests/GeneralStateTests/*/*.json)
slow_bchain_tests=$(wildcard tests/ethereum-tests/BlockchainTests/GeneralStateTests/stQuadraticComplexityTest/*.json) \
                  $(wildcard tests/ethereum-tests/BlockchainTests/GeneralStateTests/stStaticCall/static_Call50000*.json) \
                  $(wildcard tests/ethereum-tests/BlockchainTests/GeneralStateTests/stStaticCall/static_Return50000*.json) \
                  $(wildcard tests/ethereum-tests/BlockchainTests/GeneralStateTests/stStaticCall/static_Call1MB1024Calldepth_d1g0v0.json)
                  # $(wildcard tests/BlockchainTests/GeneralStateTests/*/*/*_Constantinople.json)
quick_bchain_tests=$(filter-out $(slow_bchain_tests), $(bchain_tests))

bchain-test-all: $(bchain_tests:=.test)
bchain-test: $(quick_bchain_tests:=.test)

tests/ethereum-tests/BlockchainTests/%.test: tests/ethereum-tests/BlockchainTests/% build
	$(TEST) $<

# ProofTests

proof_dir=tests/proofs
proof_tests=$(proof_dir)/sum-to-n-spec.k \
            $(proof_dir)/hkg/allowance-spec.k \
            $(proof_dir)/hkg/approve-spec.k \
            $(proof_dir)/hkg/balanceOf-spec.k \
            $(proof_dir)/hkg/transfer-else-spec.k $(proof_dir)/hkg/transfer-then-spec.k \
            $(proof_dir)/hkg/transferFrom-else-spec.k $(proof_dir)/hkg/transferFrom-then-spec.k

proof-test-all: proof-test
proof-test: $(proof_tests:=.test)

tests/proofs/%.test: tests/proofs/% build
	$(TEST) $<

split-proof-tests: $(proof_tests)

tests/proofs/sum-to-n-spec.k: proofs/sum-to-n.md
	@echo "==  tangle: $@"
	mkdir -p $(dir $@)
	pandoc --from markdown --to tangle.lua --metadata=code:sum-to-n $< > $@

tests/proofs/hkg/%-spec.k: proofs/hkg.md
	@echo "==  tangle: $@"
	mkdir -p $(dir $@)
	pandoc --from markdown --to tangle.lua --metadata=code:$* $< > $@

# InteractiveTests

interactive-test-all: interactive-test
interactive-test: \
	tests/interactive/gas-analysis/sumTo10.evm.test \
	tests/interactive/add0.json.test \
	tests/interactive/log3_MaxTopic_d0g0v0.json.test

tests/interactive/%.test: tests/interactive/% tests/interactive/%.out build
	$(TEST) $<

# Sphinx HTML Documentation
# -------------------------

# You can set these variables from the command line.
SPHINXOPTS     =
SPHINXBUILD    = sphinx-build
PAPER          =
SPHINXBUILDDIR = .build/sphinx-docs

# Internal variables.
PAPEROPT_a4     = -D latex_paper_size=a4
PAPEROPT_letter = -D latex_paper_size=letter
ALLSPHINXOPTS   = -d ../$(SPHINXBUILDDIR)/doctrees $(PAPEROPT_$(PAPER)) $(SPHINXOPTS) .
# the i18n builder cannot share the environment and doctrees with the others
I18NSPHINXOPTS  = $(PAPEROPT_$(PAPER)) $(SPHINXOPTS) .

sphinx:
	mkdir $(SPHINXBUILDDIR); \
	cp -r *.md proofs $(SPHINXBUILDDIR)/.; \
	cd $(SPHINXBUILDDIR); \
	pandoc --from markdown --to rst README.md --output index.rst; \
	sed -i 's/{.k[ a-zA-Z.-]*}/k/g' *.md proofs/*.md; \
	$(SPHINXBUILD) -b dirhtml $(ALLSPHINXOPTS) html; \
	$(SPHINXBUILD) -b text $(ALLSPHINXOPTS) html/text; \
	echo "[+] HTML generated in $(SPHINXBUILDDIR)/html, text in $(SPHINXBUILDDIR)/html/text"
