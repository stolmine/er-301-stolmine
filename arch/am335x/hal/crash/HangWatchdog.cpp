// [stol:infra-crash-diag-hang-watchdog]
//
// HARDWARE hang capture for am335x (phase 1). See hal/crash.h + section 8 of
// planning/crash-diagnostics-plan.md for the design.
//
// The trap path (arch/am335x/hal/crash/PanicBuffer.cpp) catches faults. It does
// NOT catch HANGS: livelocks / NaN storms / blocked-forever audio code that loop
// or block instead of trapping, so the exception hook never runs. This file adds
// a heartbeat monitor:
//
//   * The audio task bumps g_audioFrames once per Audio_callback while armed
//     (arch/am335x/hal/audio.c), and flips g_audioRunning across start/stop.
//   * A periodic SYS/BIOS Clock function runs in Swi context (Swi preempts the
//     audio Task, so it fires even while that task spins). Each tick it samples
//     the heartbeat; if the stream is running yet the frame counter has not
//     advanced for HANG_STALL_TICKS in a row, it declares a hang and calls
//     PanicBuffer_captureHang() (which snapshots + warm-reboots, reusing the trap
//     path's panic-buffer machinery).
//
// Zero cost when off: the Clock instance is created only on the first arm, so a
// release build with diagnostics never armed never creates it; the heartbeat
// store is gated on g_hangArmed. This half CANNOT be exercised in the emulator
// (hangs, like traps, are hardware-only), so it is written to a static-analysis +
// on-hardware-test discipline; see section 8.6 for the bench trigger.

#include <hal/crash.h>
#include <hal/log.h>

#include <ti/sysbios/knl/Clock.h>
#include <xdc/runtime/Error.h>

// Monitor cadence. The default Clock tick is 1 ms (common.cfg Clock.tickPeriod =
// 1000 us). A 50 ms period sampled 5 times => a hang is declared after ~250 ms
// of no frame advance: dozens of audio frames at 48 kHz even for large buffers,
// so a legitimately-running stream never trips, while a real freeze is caught
// well within a human blink.
#define HANG_MONITOR_PERIOD_TICKS 50u
#define HANG_STALL_TICKS 5u

extern "C"
{

  // Defined here (declared extern in hal/crash.h). The audio task reads it to
  // gate the heartbeat store; the monitor reads it to know it is live.
  volatile bool g_hangArmed = false;

  // Monitor state (file-static: only the Clock function and the arm touch it).
  static Clock_Handle g_hangClock = 0;
  static uint32_t s_lastFrames = 0;
  static uint32_t s_stall = 0;

  // Swi-context sampler. Bounded, allocation-free.
  static void hangMonitorTick(UArg arg)
  {
    (void)arg;

    if (!g_hangArmed)
    {
      return; // disarmed between ticks; the Clock is also being stopped.
    }
    if (Crash_captured())
    {
      return; // a record (trap or hang) is already sealed; device is rebooting.
    }

    bool running = g_audioRunning;
    uint32_t frames = g_audioFrames;

    if (!running)
    {
      // Stream legitimately stopped: the heartbeat freezes but that is not a
      // hang. Re-baseline so the first frame after a restart does not read stale.
      s_lastFrames = frames;
      s_stall = 0;
      return;
    }

    if (frames != s_lastFrames)
    {
      s_lastFrames = frames; // progress: healthy.
      s_stall = 0;
      return;
    }

    // No progress this tick while running.
    if (++s_stall >= HANG_STALL_TICKS)
    {
      s_stall = 0; // avoid an immediate re-trip if capture returns (autoReboot off).
      PanicBuffer_captureHang(); // seals a HANG record, cache-cleans, warm-reboots.
    }
  }

  void Crash_hangArm(bool on)
  {
    if (on)
    {
      if (g_hangClock == 0)
      {
        Clock_Params params;
        Error_Block eb;
        Error_init(&eb);
        Clock_Params_init(&params);
        params.period = HANG_MONITOR_PERIOD_TICKS; // periodic
        params.startFlag = FALSE;                  // started explicitly below
        g_hangClock = Clock_create((Clock_FuncPtr)hangMonitorTick,
                                   HANG_MONITOR_PERIOD_TICKS, &params, &eb);
        if (g_hangClock == 0)
        {
          logError("HangWatchdog: Clock_create failed; hang capture disabled.");
          return;
        }
        logInfo("HangWatchdog: monitor created (%u ms period, %u-tick stall).",
                (unsigned)HANG_MONITOR_PERIOD_TICKS, (unsigned)HANG_STALL_TICKS);
      }
      // Baseline BEFORE opening the gate so a counter left stale from a prior arm
      // cannot read as an instant stall.
      s_lastFrames = g_audioFrames;
      s_stall = 0;
      g_hangArmed = true;
      Clock_start(g_hangClock);
    }
    else
    {
      g_hangArmed = false;
      if (g_hangClock != 0)
      {
        Clock_stop(g_hangClock); // a stopped Clock does not fire: zero cost off.
      }
    }
  }

} // extern "C"
