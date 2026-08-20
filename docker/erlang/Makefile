SHELL := /bin/bash

OTP_VERSION  ?= 29.0.5
LAMBDA_IMAGE ?= public.ecr.aws/lambda/provided:al2023

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

BASE_TAG  := ghcr.io/groguelon/lambda-layer-erlang:$(OTP_VERSION)
IMAGE_TAG := $(BASE_TAG)-$(PLATFORM)
OUT_DIR   := $(shell echo "$(realpath ../..)/out")
ZIP_FILE  := lambda-layer-erlang-$(OTP_VERSION)-$(PLATFORM).zip

# Only colourise when stdout is a terminal (keeps CI logs clean)
ifneq (,$(findstring xterm,$(TERM))$(MAKE_TERMOUT))
  CYAN  := \033[36m
  GREEN := \033[32m
  RESET := \033[0m
endif

log = @printf '$(CYAN)==>$(RESET) %s\n' "$(1)"
ok  = @printf '$(GREEN) \xe2\x9c\x93 $(RESET) %s\n' "$(1)"

.PHONY: help all build push extract merge-images

# Docker builds here are sequential by nature; -j would interleave the logs
# into an unreadable mess without buying much.
.NOTPARALLEL:

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------

help:  ## Show this help
	@printf '$(CYAN)Targets$(RESET)\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@printf '\n$(CYAN)Config$(RESET) (override on the command line)\n'
	@printf '  %-14s %s\n' \
	  PLATFORM        "$(PLATFORM) (--platform $(DOCKER_PLATFORM))" \
	  OTP_VERSION     "$(OTP_VERSION)" \
	  LAMBDA_IMAGE    "$(LAMBDA_IMAGE)" \
	  BASE_TAG        "$(BASE_TAG)" \
	  IMAGE_TAG       "$(IMAGE_TAG)" \
	  LAYER_PATH      "$(OUT_DIR)/$(ZIP_FILE)"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

all:  ## Build, Push and Package Docker image and AWS Lambda Layer (required: OTP_VERSION, optional: PLATFORM)
	@$(MAKE) build PLATFORM=arm64
	@$(MAKE) push PLATFORM=arm64
	@$(MAKE) extract PLATFORM=arm64
	@$(MAKE) build PLATFORM=amd64
	@$(MAKE) push PLATFORM=amd64
	@$(MAKE) extract PLATFORM=amd64
	@$(MAKE) merge-images

build:  ## Build the Docker image (required: OTP_VERSION, optional: PLATFORM)
	$(call log,Build Docker image for Erlang $(OTP_VERSION) on $(PLATFORM))
	@docker buildx build \
		--platform $(DOCKER_PLATFORM) \
		--build-arg OTP_VERSION=$(OTP_VERSION) \
		--build-arg LAMBDA_IMAGE=$(LAMBDA_IMAGE) \
		--load \
		-t $(IMAGE_TAG) \
		.
	$(call ok,Image built: $(IMAGE_TAG))

push:  ## Push the Docker image on Container Registry (required: OTP_VERSION, optional: PLATFORM)
	@docker push $(IMAGE_TAG)

extract:  ## Extract the AWS Lambda layer from the Docker image (required: OTP_VERSION, optional: PLATFORM)
	$(call log,Generating the AWS Lambda layer for Erlang $(OTP_VERSION) on $(PLATFORM))
	@rm -rf "$(OUT_DIR)/tmp"
	@mkdir -p $(OUT_DIR) "$(OUT_DIR)/tmp"
	@container_id=$$(docker create --platform $(DOCKER_PLATFORM) $(IMAGE_TAG)); \
	docker cp "$$container_id:/opt/otp" $(OUT_DIR)/tmp/otp; \
	docker cp "$$container_id:/opt/lib" $(OUT_DIR)/tmp/lib; \
	docker rm "$$container_id" > /dev/null
	@cd $(OUT_DIR)/tmp && zip -r -y -q "$(OUT_DIR)/$(ZIP_FILE)" otp lib
	@rm -rf "$(OUT_DIR)/tmp"
	$(call ok,AWS Lambda layer: $(OUT_DIR)/$(ZIP_FILE))

merge-images:  ## Merge the Docker images (arm64 and amd64) into a single image (required: OTP_VERSION)
	$(call log,Merging Docker images for Erlang $(OTP_VERSION))
	@docker buildx imagetools create -t $(BASE_TAG) $(BASE_TAG)-arm64 $(BASE_TAG)-amd64
	$(call ok,Docker image: $(BASE_TAG))
