// [stol:emu-control-channel]
#include <emu/Control.h>
#include <hal/log.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

namespace emu
{
  static Control theControl;

  Control &controlChannel()
  {
    return theControl;
  }

  Control::~Control()
  {
    if (mOwnsFd && mFd >= 0)
    {
      ::close(mFd);
    }
  }

  static bool setNonBlocking(int fd)
  {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
    {
      return false;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0;
  }

  bool Control::openStdin()
  {
    mFd = STDIN_FILENO;
    mOwnsFd = false;
    if (!setNonBlocking(mFd))
    {
      logError("Control: failed to set stdin non-blocking.");
      mFd = -1;
      return false;
    }
    logInfo("Control channel reading from stdin.");
    return true;
  }

  bool Control::openFifo(const char *path)
  {
    // O_RDWR so the fd keeps a writer alive; a lone reader on a FIFO would see
    // EOF every time the last writer closes.
    mFd = ::open(path, O_RDWR | O_NONBLOCK);
    if (mFd < 0)
    {
      logError("Control: could not open FIFO %s: %s", path, strerror(errno));
      return false;
    }
    mOwnsFd = true;
    logInfo("Control channel reading from FIFO %s.", path);
    return true;
  }

  void Control::poll(std::vector<std::string> &out)
  {
    if (mFd < 0 || mEof)
    {
      return;
    }

    char buf[512];
    for (;;)
    {
      ssize_t n = ::read(mFd, buf, sizeof(buf));
      if (n > 0)
      {
        for (ssize_t i = 0; i < n; i++)
        {
          char c = buf[i];
          if (c == '\n')
          {
            out.push_back(mPartial);
            mPartial.clear();
          }
          else if (c != '\r')
          {
            mPartial.push_back(c);
          }
        }
        // Keep draining until EAGAIN.
        continue;
      }
      else if (n == 0)
      {
        // EOF (writer closed). Only stdin can reach here (FIFO is O_RDWR).
        mEof = true;
        if (!mPartial.empty())
        {
          out.push_back(mPartial);
          mPartial.clear();
        }
        break;
      }
      else
      {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
          break;
        }
        if (errno == EINTR)
        {
          continue;
        }
        logError("Control: read error: %s", strerror(errno));
        mEof = true;
        break;
      }
    }
  }

  void Control::enqueueLua(const char *line)
  {
    char *copy = strdup(line);
    if (!copy)
    {
      return;
    }
    if (!mLuaQ.push(copy))
    {
      logError("Control: lua queue full, dropping command.");
      free(copy);
    }
  }

  bool Control::hasLua()
  {
    return !mLuaQ.empty();
  }

  const char *Control::popLua()
  {
    // Copied into a thread-local buffer so the returned pointer stays valid
    // after we free the queued string. Only the Lua thread calls this, so a
    // single per-thread buffer is safe and leak-free (SWIG copies char* returns
    // into a fresh Lua string immediately).
    static thread_local std::string held;
    char *item = nullptr;
    if (!mLuaQ.pop(&item) || !item)
    {
      return nullptr;
    }
    held = item;
    free(item);
    return held.c_str();
  }

  void Control::pushReply(const char *reply)
  {
    char *copy = strdup(reply ? reply : "");
    if (!copy)
    {
      return;
    }
    if (!mReplyQ.push(copy))
    {
      logError("Control: reply queue full, dropping reply.");
      free(copy);
    }
  }

  bool Control::popReply(std::string &out)
  {
    char *item = nullptr;
    if (!mReplyQ.pop(&item) || !item)
    {
      return false;
    }
    out = item;
    free(item);
    return true;
  }
}
