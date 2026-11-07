PREFIX ?= $(shell [ -w /usr/local/bin ] && echo /usr/local || echo $(HOME)/.local)

.PHONY: build test e2e install template dist-binary dist-tarball release formula

build:
	swift build -c release

test:
	swift test

# Opt-in end-to-end tests (v0.5): real xcodebuild on scratch copies of fixtures/projects/AcmeWhy and AcmeApp into
# scratch DerivedData; DeepE2ETests resolves swift-syntax over the network (XCBLAME_E2E_PACKAGES=<dir> reuses clones).
e2e:
	XCBLAME_E2E=1 swift test --filter 'WhyE2ETests|DeepE2ETests'

install: build
	mkdir -p $(PREFIX)/bin
	cp .build/release/xcblame $(PREFIX)/bin/xcblame
	@echo "installed $(PREFIX)/bin/xcblame"

# Re-embed Sources/XcblameKit/Resources/report.html after editing it (HTMLTemplateTests catches drift).
template:
	Scripts/embed-report-template.sh

# Release artifacts (docs/DESIGN.md §11 v0.4). The release workflow runs the same steps; nothing here publishes.
VERSION ?= $(shell sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/XcblameKit/Analyzers/XcblameError.swift)
DIST ?= dist
TARBALL ?= $(DIST)/xcblame-$(VERSION)-macos-universal.tar.gz
URL ?=

# A universal (arm64 + x86_64) release binary at dist/xcblame.
dist-binary:
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p $(DIST)
	cp "$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/xcblame" $(DIST)/xcblame
	lipo -info $(DIST)/xcblame

# The tarball of dist/xcblame (sign it first when releasing) and its sha256 file.
dist-tarball:
	test -f $(DIST)/xcblame || { echo "run 'make dist-binary' first"; exit 1; }
	tar -czf $(TARBALL) -C $(DIST) xcblame
	cd $(dir $(TARBALL)) && shasum -a 256 $(notdir $(TARBALL)) > $(notdir $(TARBALL)).sha256
	@cat $(TARBALL).sha256

release: dist-binary dist-tarball

# Fills Formula/xcblame.rb from a built tarball into $(DIST)/xcblame.rb and prints it:
#   make formula TARBALL=dist/xcblame-0.4.0-macos-universal.tar.gz URL=https://github.com/<owner>/xcblame/releases/download/v0.4.0/xcblame-0.4.0-macos-universal.tar.gz
formula:
	Scripts/make-formula.sh "$(TARBALL)" "$(URL)" "$(VERSION)" "$(DIST)/xcblame.rb"
