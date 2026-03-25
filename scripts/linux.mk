# Build Tools for Linux
CC := gcc -fdiagnostics-color -fmax-errors=5
CPP := g++ -fdiagnostics-color -fmax-errors=5
OBJCOPY := objcopy
OBJDUMP := objdump
ADDR2LINE := addr2line
LD := gcc -fdiagnostics-color
AR := gcc-ar
SIZE := size
STRIP := strip
READELF := readelf
NM := nm
SWIG := $(HOME)/.local/swig-4.2.1/bin/swig
PYTHON := python3
ZIP := zip