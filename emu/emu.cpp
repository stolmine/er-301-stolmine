#include <emu/emu.h>
#include <emu/Emulator.h>
#include <emu/Control.h>

namespace emu
{
  static Emulator emulator;

  // [stol:emu-lua-eval] Lua-thread side of the control bridge.
  bool hasControlInput()
  {
    return controlChannel().hasLua();
  }

  const char *popControlLine()
  {
    return controlChannel().popLua();
  }

  void pushControlReply(const char *reply)
  {
    controlChannel().pushReply(reply);
  }

  DisplayBuffer *getDisplayBuffer()
  {
    return emulator.getDisplayBuffer();
  }

  void putDisplayBuffer(DisplayBuffer *buffer)
  {
    emulator.putDisplayBuffer(buffer);
  }

  int getEncoderValue()
  {
    return emulator.getEncoderValue();
  }

  bool isRearCardPresent()
  {
    return emulator.isRearCardPresent();
  }

  bool isFrontCardPresent()
  {
    return emulator.isFrontCardPresent();
  }
}

int main(int argc, char **argv)
{
  return emu::emulator.run(argc, argv);
}
