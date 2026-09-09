# Build Tools for OSX

# Use the Apple toolchain by default. Homebrew GCC can still be selected with
# command-line overrides such as `make emu CC=gcc-15 CPP=g++-15`.
CC := clang -fdiagnostics-color
CPP := clang++ -fdiagnostics-color
OBJCOPY := objcopy
OBJDUMP := objdump
ADDR2LINE := addr2line
LD := ld
AR := ar
SIZE := size
STRIP := strip
READELF := readelf
NM := nm
SWIG := swig
PYTHON := python3
ZIP := zip