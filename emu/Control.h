#pragma once

#include <od/extras/LockFreeQueue.h>
#include <string>
#include <vector>

namespace emu
{
  // Line-oriented control channel for scripted/headless operation.
  //
  // Input side: a non-blocking fd (stdin by default, or a FIFO via
  // --control PATH) read from the emulator loop. Complete newline-delimited
  // lines are handed to the loop for in-order dispatch.
  //
  // Bridge side: two single-producer/single-consumer queues carry `lua`/`cap`
  // work to the Lua interpreter thread and replies back. The loop thread is the
  // sole producer of luaQ / consumer of replyQ; the Lua thread is the sole
  // consumer of luaQ / producer of replyQ. No locking beyond the lock-free
  // queues (matches the DisplayBuffer hand-off pattern in Emulator).
  class Control
  {
  public:
    Control() = default;
    ~Control();

    // Open the input channel. path == nullptr => stdin. Both are set
    // non-blocking; a FIFO is opened O_RDWR so it never sees EOF when a writer
    // transiently closes.
    bool openStdin();
    bool openFifo(const char *path);
    bool isOpen() const { return mFd >= 0; }
    bool atEof() const { return mEof; }

    // Drain whatever is currently readable, appending complete lines to `out`.
    // Non-blocking; safe to call every loop iteration.
    void poll(std::vector<std::string> &out);

    // ---- Lua bridge (loop thread) ----
    void enqueueLua(const char *line); // strdup'd, handed to the Lua thread
    bool popReply(std::string &out);   // reply pushed by the Lua thread

    // ---- Lua bridge (Lua interpreter thread) ----
    bool hasLua();            // is a lua/cap line waiting?
    const char *popLua();     // next line, valid until the next popLua() call
    void pushReply(const char *reply);

  private:
    int mFd = -1;
    bool mOwnsFd = false; // close on destroy (FIFO), never close stdin
    bool mEof = false;
    std::string mPartial;

    od::LockFreeQueue<char *, 256> mLuaQ;   // loop -> lua
    od::LockFreeQueue<char *, 256> mReplyQ; // lua  -> loop
  };

  // Process-wide control channel, shared by Emulator::loop and the emu.* Lua
  // bridge functions in emu.cpp.
  Control &controlChannel();
}
