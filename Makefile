## This is a self-documented Makefile. For usage information, run `make help`:
##
## For more information, refer to https://www.thapaliya.com/en/writings/well-documented-makefiles/

ROOTDIR       := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
DISTDIR       := $(abspath $(ROOTDIR)/dist)
HOST_OS       := $(shell go env GOOS)
HOST_ARCH     := $(shell go env GOARCH)
WANTED_OSES   := $(sort $(HOST_OS) linux)
WANTED_ARCHES := $(sort $(HOST_ARCH) amd64 arm arm64)

BUILD_VERSION := $(shell $(ROOTDIR)/scripts/version)
BUILD_COMMIT  := $(shell git rev-parse HEAD^{commit})
BUILD_STAMP   := $(shell date -u '+%Y-%m-%d %H:%M:%S+00:00')

include config.mk

-include local/Makefile

S := @
V :=

GO := GO111MODULE=on CGO_ENABLED=0 go
GO_VENDOR := $(if $(realpath $(ROOTDIR)/vendor/modules.txt),true,false)
GO_BUILD_COMMON_FLAGS := -trimpath
ifeq ($(GO_VENDOR),true)
	GO_BUILD_MOD_FLAGS := -mod=vendor
	GOLANGCI_LINT_MOD_FLAGS := --modules-download-mode=vendor
else
	GO_BUILD_MOD_FLAGS := -mod=readonly
	GOLANGCI_LINT_MOD_FLAGS := --modules-download-mode=readonly
endif
GO_BUILD_FLAGS := $(GO_BUILD_MOD_FLAGS) $(GO_BUILD_COMMON_FLAGS)

GO_PKGS ?= ./...
SH_FILES ?= $(shell find ./scripts -name *.sh)

GO_TEST_ARGS ?= $(GO_PKGS)

COMMANDS := $(shell $(GO) list $(GO_BUILD_MOD_FLAGS) ./cmd/...)

VERSION_PKG := $(shell $(GO) list $(GO_BUILD_MOD_FLAGS) ./internal/version)

ifeq ($(origin GOLANGCI_LINT),undefined)
GOLANGCI_LINT ?= $(ROOTDIR)/scripts/go/bin/golangci-lint
LOCAL_GOLANGCI_LINT = yes
endif

ifeq ($(origin GOTESTSUM),undefined)
GOTESTSUM ?= $(ROOTDIR)/scripts/go/bin/gotestsum
LOCAL_GOTESTSUM = yes
endif

TEST_OUTPUT := $(DISTDIR)/test

.DEFAULT_GOAL := all

.PHONY: all
all: deps build

##@ Dependencies

.PHONY: deps-go
deps-go: ## Install Go dependencies.
ifeq ($(GO_VENDOR),true)
	$(GO) mod vendor
else
	$(GO) mod download
endif
	$(GO) mod verify
	$(GO) mod tidy -compat=1.17

.PHONY: deps
deps: deps-go ## Install all dependencies.

##@ Building

define build_go_template
BUILD_GO_TARGETS += build-go-$(1)-$(2)-$(3)

build-go-$(1)-$(2)-$(3) : GOOS := $(1)
build-go-$(1)-$(2)-$(3) : GOARCH := $(2)
build-go-$(1)-$(2)-$(3) : GOPKG := $(3)

endef

$(foreach BUILD_OS,$(WANTED_OSES), \
	$(foreach BUILD_ARCH,$(WANTED_ARCHES), \
		$(foreach CMD,$(COMMANDS), \
			$(eval $(call build_go_template,$(BUILD_OS),$(BUILD_ARCH),$(CMD))))))

BUILD_GO_NATIVE_TARGETS := $(filter build-go-$(HOST_OS)-$(HOST_ARCH)-%, $(BUILD_GO_TARGETS))

.PHONY: $(BUILD_GO_TARGETS)
$(BUILD_GO_TARGETS) : build-go-% :
	$(call build_go_command,$(GOPKG))

.PHONY: build-go
build-go: $(BUILD_GO_TARGETS) ## Build all Go binaries.
	$(S) echo Done.

.PHONY: build
build: build-go ## Build everything.

.PHONY: bn
bn: $(BUILD_GO_NATIVE_TARGETS) ## Build only native Go binaries
	$(S) echo Done.

scripts/go/bin/bra: scripts/go/go.mod
	$(S) cd scripts/go && \
		$(GO) mod download && \
		$(GO) build -o ./bin/bra github.com/unknwon/bra

.PHONY: run
run: scripts/go/bin/bra ## Build and run web server on filesystem changes.
	$(S) GO111MODULE=on scripts/go/bin/bra run

##@ Testing

ifeq ($(LOCAL_GOTESTSUM),yes)
$(GOTESTSUM): scripts/go/go.mod
	$(S) cd scripts/go && \
		$(GO) mod download && \
		$(GO) build -o $(GOTESTSUM) gotest.tools/gotestsum
endif

.PHONY: test-go
test-go: $(GOTESTSUM) ## Run Go tests.
	$(S) echo "test backend"
	$(GOTESTSUM) \
		--format standard-verbose \
		--jsonfile $(TEST_OUTPUT).json \
		--junitfile $(TEST_OUTPUT).xml \
		-- \
		$(GO_BUILD_MOD_FLAGS) \
		-cover \
		-coverprofile=$(TEST_OUTPUT).cov \
		-race \
		$(GO_TEST_ARGS)
	$(S) $(ROOTDIR)/scripts/report-test-coverage $(TEST_OUTPUT).cov

.PHONY: test
test: test-go ## Run all tests.

##@ Linting

ifeq ($(LOCAL_GOLANGCI_LINT),yes)
$(GOLANGCI_LINT): scripts/go/go.mod
	$(S) cd scripts/go && \
		$(GO) mod download && \
		$(GO) build -o $(GOLANGCI_LINT) github.com/golangci/golangci-lint/cmd/golangci-lint
endif

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT)
	$(S) echo "lint via golangci-lint"
	$(S) $(GOLANGCI_LINT) run \
		$(GOLANGCI_LINT_MOD_FLAGS) \
		--config ./scripts/go/configs/golangci.yml \
		$(GO_PKGS)

scripts/go/bin/gosec: scripts/go/go.mod
	$(S) cd scripts/go && \
		$(GO) mod download && \
		$(GO) build -o ./bin/gosec github.com/securego/gosec/cmd/gosec

# TODO recheck the rules and leave only necessary exclusions
.PHONY: gosec
gosec: scripts/go/bin/gosec
	$(S) echo "lint via gosec"
	$(S) scripts/go/bin/gosec -quiet \
		-exclude= \
		-conf=./scripts/go/configs/gosec.json \
		$(GO_PKGS)

.PHONY: go-vet
go-vet:
	$(S) echo "lint via go vet"
	$(S) $(GO) vet $(GO_BUILD_MOD_FLAGS) $(GO_PKGS)

.PHONY: lint-go
lint-go: go-vet golangci-lint gosec ## Run all Go code checks.

.PHONY: lint
lint: lint-go ## Run all code checks.

##@ Packaging
.PHONY: package
package: build ## Build Debian and RPM packages.
	$(S) echo "Building Debian and RPM packages..."		
	$(S) sh scripts/package/package.sh

.PHONY: publish-packages
publish-packages: package ## Publish Debian and RPM packages to the repository.
	$(S) echo "Publishing Debian and RPM packages...."
	$(S) sh scripts/package/publish.sh
	
##@ Helpers

.PHONY: clean
clean: ## Clean up intermediate build artifacts.
	$(S) echo "Cleaning intermediate build artifacts..."
	$(V) rm -rf node_modules
	$(V) rm -rf public/build
	$(V) rm -rf dist/build
	$(V) rm -rf dist/publish

.PHONY: distclean
distclean: clean ## Clean up all build artifacts.
	$(S) echo "Cleaning all build artifacts..."
	$(V) git clean -Xf

.PHONY: help
help: ## Display this help.
	$(S) awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: docker
docker: build
	$(S) docker build -t $(DOCKER_TAG) ./

.PHONY: docker-push
docker-push:  docker
	$(S) docker push $(DOCKER_TAG)
	$(S) docker tag $(DOCKER_TAG) $(DOCKER_TAG):$(BUILD_VERSION)
	$(S) docker push $(DOCKER_TAG):$(BUILD_VERSION)

.PHONY: generate
generate: $(ROOTDIR)/pkg/accounting/data.go $(ROOTDIR) $(ROOTDIR)/pkg/pb/synthetic_monitoring/checks.pb.go
	$(S) true

$(ROOTDIR)/pkg/accounting/data.go : $(ROOTDIR)/pkg/accounting/data.go.tmpl $(wildcard $(ROOTDIR)/internal/scraper/testdata/*.txt)
	$(S) echo "Generating $@ ..."
	$(GO) generate -v "$(@D)"

$(ROOTDIR)/pkg/pb/synthetic_monitoring/%.pb.go : $(ROOTDIR)/pkg/pb/synthetic_monitoring/%.proto
	$(S) echo "Generating $@ ..."
	$(V) $(ROOTDIR)/scripts/genproto.sh

.PHONY: testdata
testdata: ## Update golden files for tests.
	# update scraper golden files
	$(V) $(GO) test -v -run TestValidateMetrics ./internal/scraper -args -update-golden

.PHONY: drone
drone:
	drone jsonnet --stream --source .drone/drone.jsonnet --target .drone/drone.yml --format
	drone lint .drone/drone.yml
	drone sign --save grafana/synthetic-monitoring-agent .drone/drone.yml

define build_go_command
	$(S) echo 'Building $(1)'
	$(S) mkdir -p $(DISTDIR)/$(GOOS)-$(GOARCH)
	$(V) GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build \
		$(GO_BUILD_FLAGS) \
		-o '$(DISTDIR)/$(GOOS)-$(GOARCH)/$(notdir $(1))' \
		-ldflags '-X "$(VERSION_PKG).commit=$(BUILD_COMMIT)" -X "$(VERSION_PKG).version=$(BUILD_VERSION)" -X "$(VERSION_PKG).buildstamp=$(BUILD_STAMP)"' \
		'$(1)'
	$(S) test '$(GOOS)' = '$(HOST_OS)' -a '$(GOARCH)' = '$(HOST_ARCH)' && \
		cp -a '$(DISTDIR)/$(GOOS)-$(GOARCH)/$(notdir $(1))' '$(DISTDIR)/$(notdir $(1))' || \
		true
endef
