include scripts/env.mk

MODNAME := txo
src_dir = $(mods_dir)/$(MODNAME)
includes += $(mods_dir) $(lua_dir)

include scripts/mod-builder.mk
