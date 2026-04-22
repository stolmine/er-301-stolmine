include scripts/env.mk

MODNAME := multiout
src_dir = $(mods_dir)/$(MODNAME)
includes += $(mods_dir) $(lua_dir)

include scripts/mod-builder.mk
