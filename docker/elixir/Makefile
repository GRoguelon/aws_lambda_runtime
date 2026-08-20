SHELL := /bin/bash

OTP_VERSION    ?= 29.0.5
ELIXIR_VERSION ?= 1.20.3
ERLANG_IMAGE   ?= ghcr.io/groguelon/lambda-layer-erlang:$(OTP_VERSION)

# x86_64 or arm64 (Lambda's own architecture names)
PLATFORM ?= $(shell uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')

VALID_PLATFORMS := amd64 arm64
ifeq ($(filter $(PLATFORM),$(VALID_PLATFORMS)),)
$(error PLATFORM must be one of $(VALID_PLATFORMS), got "$(PLATFORM)")
endif

ifeq ($(PLATFORM),amd64)
DOCKER_PLATFORM := linux/amd64
else
DOCKER_PLATFORM := linux/arm64
endif

BASE_TAG  := ghcr.io/groguelon/lambda-layer-elixir:$(ELIXIR_VERSION)-erlang-$(OTP_VERSION)
IMAGE_TAG := $(BASE_TAG)-$(PLATFORM)

# Only colourise when stdout is a terminal (keeps CI logs clean)
ifneq (,$(findstring xterm,$(TERM))$(MAKE_TERMOUT))
  CYAN  := \033[36m
  GREEN := \033[32m
  RESET := \033[0m
endif

log = @printf '$(CYAN)==>$(RESET) %s\n' "$(1)"
ok  = @printf '$(GREEN) \xe2\x9c\x93 $(RESET) %s\n' "$(1)"

.PHONY: help all build push merge-images

# Docker builds here are sequential by nature; -j would interleave the logs
# into an unreadable mess without buying much.
.NOTPARALLEL:

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------

.PHONY: help
help:  ## Show this help
	@printf '$(CYAN)Targets$(RESET)\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@printf '\n$(CYAN)Config$(RESET) (override on the command line)\n'
	@printf '  %-14s %s\n' \
	  PLATFORM        "$(PLATFORM) (--platform $(DOCKER_PLATFORM))" \
	  OTP_VERSION     "$(OTP_VERSION)" \
	  ELIXIR_VERSION  "$(ELIXIR_VERSION)" \
	  ERLANG_IMAGE    "$(ERLANG_IMAGE)" \
	  BASE_TAG        "$(BASE_TAG)" \
	  IMAGE_TAG       "$(IMAGE_TAG)"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

all:  ## Build and Push Docker image (required: ELIXIR_VERSION,OTP_VERSION, optional: PLATFORM)
	@$(MAKE) build PLATFORM=arm64
	@$(MAKE) push PLATFORM=arm64
	@$(MAKE) build PLATFORM=amd64
	@$(MAKE) push PLATFORM=amd64
	@$(MAKE) merge-images

build:  ## Build the Docker image (required: ELIXIR_VERSION,OTP_VERSION, optional: PLATFORM)
	$(call log,Build Docker image for Elixir $(ELIXIR_VERSION) - OTP: $(OTP_VERSION) on $(PLATFORM))
	@docker buildx build \
		--platform $(DOCKER_PLATFORM) \
		--build-arg OTP_VERSION=$(OTP_VERSION) \
		--build-arg LAMBDA_IMAGE=$(LAMBDA_IMAGE) \
		--load \
		-t $(IMAGE_TAG) \
		.
	$(call ok,Image built: $(IMAGE_TAG))

push:  ## Push the Docker image on Container Registry (required: ELIXIR_VERSION,OTP_VERSION, optional: PLATFORM)
	@docker push $(IMAGE_TAG)

merge-images:  ## Merge the Docker images (arm64 and amd64) into a single image (required: ELIXIR_VERSION,OTP_VERSION)
	$(call log,Merging Docker images for Elixir $(ELIXIR_VERSION) - OTP: $(OTP_VERSION))
	@docker buildx imagetools create -t $(BASE_TAG) $(BASE_TAG)-arm64 $(BASE_TAG)-amd64
	$(call ok,Docker image: $(BASE_TAG))
