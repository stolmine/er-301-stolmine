#pragma once

#include <hal/display.h>

namespace emu
{
  // Thread-safe.
  void putDisplayBuffer(DisplayBuffer *buffer);
  DisplayBuffer *getDisplayBuffer();
  int getEncoderValue();
  bool isRearCardPresent();
  bool isFrontCardPresent();

  // Control-channel bridge (see emu/Control.h). Drained by Application.lua on
  // the Lua interpreter thread, under app.EMULATION. C strings only (SWIG
  // maps char* <-> Lua string): the reply carries the pcall result as text.
  bool hasControlInput();
  const char *popControlLine();
  void pushControlReply(const char *reply);
}