PROFILE ?= release
ARCH = am335x
include scripts/env.mk

firmware_archive = $(build_dir)/er-301-v$(FIRMWARE_VERSION).zip

# [stol] `all` must stay the FIRST target: the top-level `make firmware` invokes
# this file with no target, so whatever comes first is what runs.
.PHONY: all deploy-hint app-libs clean
all: $(firmware_archive) deploy-hint

firmware_contents = $(build_dir)/app/kernel.bin
firmware_contents += $(build_dir)/sbl/SBL
firmware_contents += $(build_dir)/pbl/MLO
firmware_contents += $(build_dir)/mods/core-$(FIRMWARE_VERSION).pkg
firmware_contents += $(build_dir)/mods/teletype-$(FIRMWARE_VERSION).pkg
firmware_contents += $(build_dir)/mods/txo-$(FIRMWARE_VERSION).pkg
firmware_contents += $(build_dir)/install.lua

$(firmware_archive): $(firmware_contents)
	@echo $(describe_env) ZIP $(describe_target)
	@rm -rf $(firmware_archive)
	@$(ZIP) -j $(firmware_archive) $(firmware_contents)	

# [stol] Deploy hint, printed on EVERY firmware build rather than only the ones
# that actually rebuild the archive. The step after a build is always the same,
# and the failure it guards against is real: three differently-versioned zips can
# sit in this directory at once, and retyping a version by hand is how the wrong
# image ends up on a card.
#
# Override the mount point with `make firmware SD_ROOT=/run/media/you/ER-301`.
SD_ROOT ?= /mnt

deploy-hint: $(firmware_archive)
	@echo ""
	@echo "  firmware $(FIRMWARE_VERSION)"
	@echo "  $(firmware_archive)"
	@echo ""
	@echo "  Copy to the FRONT card:"
	@echo ""
	@echo "    sudo cp $(firmware_archive) $(SD_ROOT)/ER-301/firmware/"
	@echo "    sudo rm -f $(SD_ROOT)/ER-301/packages/core-*.pkg $(SD_ROOT)/ER-301/packages/teletype-*.pkg $(SD_ROOT)/ER-301/packages/txo-*.pkg"
	@echo "    sync"
	@echo ""
	@echo "  Deleting the old packages is not housekeeping: the installer skips a"
	@echo "  package whose version already matches, so stale .pkg files leave you"
	@echo "  running old package code against a new kernel."
	@if [ -d "$(SD_ROOT)/ER-301" ]; then \
	  echo ""; \
	  echo "  Card is mounted at $(SD_ROOT)/ER-301."; \
	else \
	  echo ""; \
	  echo "  No card at $(SD_ROOT)/ER-301 right now."; \
	fi
	@echo ""

$(build_dir)/install.lua: scripts/install.lua scripts/env.mk
	@echo $(describe_env) SED $(describe_target)
	@sed 's/FIRMWARE_VERSION/$(FIRMWARE_VERSION)/g' $< > $@

app-libs:
	+$(MAKE) -f scripts/lua.mk PROFILE=$(PROFILE) ARCH=$(ARCH)
	+$(MAKE) -f scripts/miniz.mk PROFILE=$(PROFILE) ARCH=$(ARCH)
	+$(MAKE) -f scripts/lodepng.mk PROFILE=$(PROFILE) ARCH=$(ARCH)
	+$(MAKE) -f scripts/ne10.mk PROFILE=$(PROFILE) ARCH=$(ARCH)	

$(build_dir)/app/kernel.bin: app-libs
	+$(MAKE) -f scripts/app.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

$(build_dir)/mods/core-$(FIRMWARE_VERSION).pkg:
	+$(MAKE) -f scripts/core.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

$(build_dir)/mods/teletype-$(FIRMWARE_VERSION).pkg:
	+$(MAKE) -f scripts/teletype.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

$(build_dir)/mods/txo-$(FIRMWARE_VERSION).pkg:
	+$(MAKE) -f scripts/txo.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

$(build_dir)/sbl/SBL:
	+$(MAKE) -f scripts/sbl.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

$(build_dir)/pbl/MLO:
	+$(MAKE) -f scripts/pbl.mk PROFILE=$(PROFILE) ARCH=$(ARCH)

clean:
	rm -rf $(firmware_archive) $(build_dir)/install.lua
	+$(MAKE) -f scripts/lua.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/miniz.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/lodepng.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/ne10.mk PROFILE=$(PROFILE) ARCH=$(ARCH)	clean
	+$(MAKE) -f scripts/core.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/teletype.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/txo.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/app.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/sbl.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
	+$(MAKE) -f scripts/pbl.mk PROFILE=$(PROFILE) ARCH=$(ARCH) clean
