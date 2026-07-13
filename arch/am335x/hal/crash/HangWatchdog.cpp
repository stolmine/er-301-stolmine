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
#include <ti/sysbios/knl/Task.h> // [stol:crashdiag-ui-heartbeat] Task_self() at arm
#include <xdc/runtime/Error.h>

// Monitor cadence. The default Clock tick is 1 ms (common.cfg Clock.tickPeriod =
// 1000 us). A 50 ms period sampled 5 times => a hang is declared after ~250 ms
// of no frame advance: dozens of audio frames at 48 kHz even for large buffers,
// so a legitimately-running stream never trips, while a real freeze is caught
// well within a human blink.
#define HANG_MONITOR_PERIOD_TICKS 50u
#define HANG_STALL_TICKS 5u
// [stol:crashdiag-ui-heartbeat] The UI/main-thread stall threshold is MUCH higher
// than the audio one (~3s vs ~250ms). The audio task ticks every frame, so 250ms
// of silence is unambiguously dead; the main task legitimately runs long
// SYNCHRONOUS ops (preset load, package install, graph recompile) that a 250ms
// threshold would false-flag as hangs. 3s is well beyond any gesture/draw, and the
// Busy pump (xroot/Busy.lua -> app.uiHeartbeat) keeps a progress-reporting long op
// alive, so this only trips on a genuinely stuck main thread. UI detection is also
// a separate opt-in (g_uiHangArmed) so it never fires during normal use.
#define UI_STALL_TICKS 60u

extern "C"
{

  // Defined here (declared extern in hal/crash.h). The audio task reads it to
  // gate the heartbeat store; the monitor reads it to know it is live.
  volatile bool g_hangArmed = false;

  // [stol:crashdiag-ui-heartbeat] UI/main-thread heartbeat (defined here, declared
  // extern in hal/crash.h). The audio heartbeat above cannot see a spin on the
  // MAIN (app) task -- a hung gesture handler, an infinite draw, a stuck unit
  // constructor on insert -- because that task never bumps g_audioFrames. These
  // mirror the audio seam for the main loop: g_uiFrames advances on each busy=true
  // edge (once per event batch) and g_uiBusy is true EXACTLY while the main task is
  // mid-processing (between startEventTimer and the next waitForEvent), so a stale
  // g_uiFrames is a hang ONLY when g_uiBusy is set (idle blocking never trips it).
  // g_uiTask is the main/app task handle, resolved at arm time (the arm choke point
  // always runs on the main task; see Crash_hangArm).
  volatile uint32_t g_uiFrames = 0;
  volatile bool g_uiBusy = false;
  void *g_uiTask = 0;

  // [stol:crashdiag-ui-heartbeat] Separate opt-in for UI-hang detection (option c).
  // The general "Enable crash diagnostics?" arm covers audio + traps + stacks +
  // heap + guard with ZERO UI-reboot risk; this extra flag (the
  // enableUiHangDetection setting -> app.uiHangArm -> Crash_uiHangArm) turns on the
  // UI heartbeat + monitor check only while a developer is actively hunting a
  // suspected UI/constructor hang, since a legit long main-thread op could
  // otherwise false-trip. Default off.
  volatile bool g_uiHangArmed = false;

#ifdef BUILDOPT_CRASH_TEST
  // [stol:crashdiag-ui-heartbeat] UI analog of g_crashTestHang: raised by
  // PanicBuffer_checkTestTrigger for the 'U' bench trigger; Crash_uiHeartbeat spins
  // the main task on its next busy edge so the monitor catches a deliberate UI hang.
  volatile bool g_uiCrashTest = false;
#endif

  // Monitor state (file-static: only the Clock function and the arm touch it).
  static Clock_Handle g_hangClock = 0;
  static uint32_t s_lastFrames = 0;
  static uint32_t s_stall = 0;
  // [stol:crashdiag-ui-heartbeat] UI heartbeat monitor state (mirrors s_lastFrames
  // / s_stall for the main-task heartbeat).
  static uint32_t s_lastUiFrames = 0;
  static uint32_t s_uiStall = 0;

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

    // [stol:crashdiag-object-guard-event] Low-rate backstop for the audio-Event
    // pend-queue guard. The audio ISR is the primary (it trips on the FIRST post
    // after the wild write); this Swi-context poll also catches a breach that
    // lands while the stream is stopped (no posts) or between EDMA interrupts. It
    // seals + reboots on breach, so it must precede the heartbeat logic below.
    PanicBuffer_checkAudioEventGuard();

    // [stol:crashdiag-ui-heartbeat] UI/main-thread heartbeat check, in the SAME
    // tick as the audio one below. g_uiBusy is the idle-block gate: the Lua main
    // loop legitimately blocks in waitForEvent when idle (g_uiBusy false), so a
    // frozen g_uiFrames is a hang ONLY while g_uiBusy is set (the main task is
    // mid-processing a handler/draw/trigger). Runs BEFORE the audio block so its
    // early returns cannot skip UI coverage; capture is one-shot (Crash_captured),
    // so whichever heartbeat stalls first seals the record.
    // [stol:crashdiag-ui-heartbeat] Only when UI detection is separately opted in.
    if (g_uiHangArmed && g_uiBusy)
    {
      uint32_t uiFrames = g_uiFrames;
      if (uiFrames != s_lastUiFrames)
      {
        s_lastUiFrames = uiFrames; // progress: a handler/draw batch completed.
        s_uiStall = 0;
      }
      else if (++s_uiStall >= UI_STALL_TICKS)
      {
        s_uiStall = 0; // avoid an immediate re-trip if capture returns.
        // Target the MAIN/app task explicitly (resolved at arm) rather than
        // Task_self(): the tick Swi may have preempted the higher-priority audio
        // task, not the spinning main task, so Task_self() is not reliable here.
        PanicBuffer_captureHangTask(g_uiTask);
      }
    }
    else if (g_uiHangArmed)
    {
      // Idle-blocked in waitForEvent: the heartbeat freezes but that is NOT a
      // hang. Re-baseline so the first busy edge after idle is never a stale delta.
      s_lastUiFrames = g_uiFrames;
      s_uiStall = 0;
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
      // [stol:crashdiag-ui-heartbeat] Baseline the UI heartbeat too, and resolve
      // the main/app task handle for a UI-hang capture. The arm choke point always
      // runs ON the main task (the Lua app.flightRecorderArm binding and the
      // BUILDOPT_CRASH_TEST self-trigger both execute on it), so Task_self() here
      // IS the main/UI task; capturing its handle now avoids a Swi-time task walk
      // and is robust to which task the monitor's Swi happens to preempt.
      s_lastUiFrames = g_uiFrames;
      s_uiStall = 0;
      g_uiTask = (void *)Task_self();
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

  // [stol:crashdiag-ui-heartbeat] Separate opt-in for UI-hang detection (option c).
  // Called on the main task via the enableUiHangDetection setting (app.uiHangArm).
  // The monitor Clock itself runs only when the general facility is armed
  // (Crash_hangArm), so this switch is meaningful on top of that; it gates the UI
  // heartbeat producer + the monitor's UI check. Baselines the heartbeat + resolves
  // the main task handle so enabling never instant-trips on a stale counter.
  void Crash_uiHangArm(bool on)
  {
    if (on)
    {
      s_lastUiFrames = g_uiFrames;
      s_uiStall = 0;
      g_uiTask = (void *)Task_self();
    }
    g_uiHangArmed = on;
  }

  // [stol:crashdiag-ui-heartbeat] UI heartbeat producer, called from the Lua main
  // loop via app.uiHeartbeat(busy) (od/glue/CrashDiag.cpp). busy=true at
  // startEventTimer (a new event batch begins -> bump g_uiFrames), busy=false right
  // before waitForEvent (about to block idle). Gated on g_hangArmed so a disarmed
  // build pays one predicted branch and never touches the seam. Strong override of
  // the weak no-op in od/glue/CrashDiag.cpp (linked on the emu, which has no hang
  // capture).
  void Crash_uiHeartbeat(bool busy)
  {
    if (!g_uiHangArmed)
    {
      return; // zero cost when UI hang detection is off (its own opt-in).
    }
    if (busy)
    {
      // Bump BEFORE raising g_uiBusy so the monitor can never observe busy with a
      // not-yet-advanced counter on the very first edge after idle.
      g_uiFrames++;
      g_uiBusy = true;
#ifdef BUILDOPT_CRASH_TEST
      if (g_uiCrashTest)
      {
        // Deliberate UI livelock for the 'U' bench trigger: spin the main task in
        // a busy batch. The Clock monitor's UI heartbeat must catch it and capture
        // the main task. Mirrors the audio task's 'h' spin (arch/am335x/hal/audio.c).
        while (1)
        {
        }
      }
#endif
    }
    else
    {
      g_uiBusy = false;
    }
  }

} // extern "C"
