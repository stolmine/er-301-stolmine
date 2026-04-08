#include <od/graphics/screensavers/Doom.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <od/config.h>
#include <hal/constants.h>
#include <hal/timing.h>
#include <hal/log.h>
#include <hal/fileops.h>
#include <cstring>
#include <cmath>

// doomgeneric C API and game state headers
extern "C"
{
#include "doomgeneric.h"
#include "doomkeys.h"
#include "d_player.h"
#include "p_mobj.h"
#include "p_local.h"
#include "doomstat.h"
#include "m_fixed.h"
#include "tables.h"
}

// Doom globals
extern "C"
{
  void G_DeferedInitNew(skill_t skill, int episode, int map);
  extern boolean bot_enabled;
  void Bot_Init(void);
}

namespace od
{

  static bool sDoomCreated = false;

  Doom::Doom()
  {
    initLUTs();
    reset();
  }

  Doom::~Doom()
  {
  }

  void Doom::initLUTs()
  {
    for (int i = 0; i < VP_WIDTH; i++)
      mColLUT[i] = (i * 320) / VP_WIDTH;
    for (int i = 0; i < VP_HEIGHT; i++)
      mRowLUT[i] = (((VP_HEIGHT - 1 - i) * 200) / VP_HEIGHT);

  }

  void Doom::reset()
  {
    mTickAccum = 0.0f;
    mInitialized = false;
    mWadMissing = false;

    if (sDoomCreated)
    {
      // Doom globals survive — just resume
      mInitialized = true;
      bot_enabled = true;
      return;
    }

    // Check for WAD file
    char wadPath[256];
    snprintf(wadPath, sizeof(wadPath), "%s/ER-301/doom/DOOM1.WAD",
             globalConfig.frontRoot);

    if (!pathExists(wadPath))
    {
      mWadMissing = true;
      return;
    }

    // Initialize Doom (only once — globals are not re-entrant)
    // All argv storage must be static — Doom keeps myargv = argv globally
    static char arg0[] = "doom";
    static char arg1[] = "-iwad";
    static char wadArg[256];
    strncpy(wadArg, wadPath, sizeof(wadArg) - 1);
    wadArg[sizeof(wadArg) - 1] = '\0';
    static char *argv[] = {arg0, arg1, wadArg, nullptr};
    doomgeneric_Create(3, argv);

    // Start a new game immediately — same path as menu "New Game"
    // sk_medium = 2, episode 1, map 1
    nomonsters = false;
    G_DeferedInitNew((skill_t)2, 1, 1);

    // Enable ZCajun-derived bot
    bot_enabled = true;
    Bot_Init();
    sDoomCreated = true;
    mInitialized = true;
  }

  void Doom::blitFrame(FrameBuffer &fb)
  {
    if (!DG_ScreenBuffer)
      return;

    for (int y = 0; y < VP_HEIGHT; y++)
    {
      int srcRow = mRowLUT[y];
      for (int x = 0; x < VP_WIDTH; x++)
      {
        int srcCol = mColLUT[x];
        pixel_t pixel = DG_ScreenBuffer[srcRow * DOOMGENERIC_RESX + srcCol];

        // ARGB to 4-bit grayscale
        int r = (pixel >> 16) & 0xFF;
        int g = (pixel >> 8) & 0xFF;
        int b = pixel & 0xFF;
        int gray = (r * 77 + g * 150 + b * 29) >> 8;
        int color = gray >> 4;

        fb.pixel(color, VP_LEFT + x, y);
      }
    }
  }

  void Doom::drawBorders(FrameBuffer &fb)
  {
    // Animated vertical scan lines in the letterbox areas
    // Slow scrolling noise pattern that changes over time
    int phase = (int)(mBorderPhase * 8.0f);

    for (int y = 0; y < 64; y++)
    {
      // Left border
      for (int x = 0; x < VP_LEFT; x++)
      {
        // Scrolling diagonal hash pattern
        int v = ((x + y + phase) * 7) & 0x1F;
        if (v < 2)
          fb.pixel(GRAY3, x, y);
      }
      // Right border
      for (int x = VP_LEFT + VP_WIDTH; x < 256; x++)
      {
        int v = ((x - y + phase) * 7) & 0x1F;
        if (v < 2)
          fb.pixel(GRAY3, x, y);
      }
    }

    // Thin border lines around viewport
    fb.vline(GRAY5, VP_LEFT - 1, 0, 63);
    fb.vline(GRAY5, VP_LEFT + VP_WIDTH, 0, 63);
  }

  void Doom::drawStatus(FrameBuffer &fb)
  {
    if (mInitialized && gamestate == GS_LEVEL && players[0].mo)
    {
      char buf[32];
      snprintf(buf, sizeof(buf), "HP:%d", players[0].health);
      fb.text(WHITE, 2, 2, buf, 10);
    }
  }

  void Doom::draw(FrameBuffer &m, FrameBuffer &s)
  {
    if (mWadMissing)
    {
      m.text(WHITE, 60, 28, "DOOM1.WAD not found", 10);
      m.text(GRAY7, 40, 16, "Place in front/ER-301/doom/", 10);
      return;
    }

    if (!mInitialized)
      return;

    // Tick Doom at 35fps (native rate). Bot runs inside G_BuildTiccmd.
    mTickAccum += GRAPHICS_REFRESH_PERIOD;
    float doomPeriod = 1.0f / 35.0f;
    int maxTicks = 2; // prevent spin-lock during wipe transitions
    while (mTickAccum >= doomPeriod && maxTicks > 0)
    {
      mTickAccum -= doomPeriod;
      maxTicks--;

      // If game left the level (death, intermission, finale),
      // restart immediately to keep the screensaver going
      if (gamestate != GS_LEVEL && gamestate != GS_DEMOSCREEN)
      {
        G_DeferedInitNew((skill_t)2, 1, 1);
        Bot_Init();
      }

      if (DG_ScreenBuffer)
        memset(DG_ScreenBuffer, 0, DOOMGENERIC_RESX * DOOMGENERIC_RESY * sizeof(pixel_t));
      doomgeneric_Tick();
    }
    if (mTickAccum > doomPeriod * 4)
      mTickAccum = 0; // drop frames if we fell too far behind

    // Blit the last rendered frame with correct aspect ratio
    mBorderPhase += GRAPHICS_REFRESH_PERIOD;
    if (mBorderPhase > 1000.0f)
      mBorderPhase = 0.0f;
    drawBorders(m);
    blitFrame(m);
    drawStatus(s);
  }

} /* namespace od */

// Platform callbacks for doomgeneric
extern "C"
{
  void DG_Init() {}

  void DG_DrawFrame()
  {
    // Frame is in DG_ScreenBuffer, blitted in Doom::draw()
  }

  void DG_SleepMs(uint32_t ms)
  {
    // No-op — we drive ticks manually
    (void)ms;
  }

  uint32_t DG_GetTicksMs()
  {
    return (uint32_t)(wallclock() * 1000.0f);
  }

  int DG_GetKey(int *pressed, unsigned char *key)
  {
    (void)pressed;
    (void)key;
    return 0; // Bot writes directly to ticcmd, no key events needed
  }

  void DG_SetWindowTitle(const char *title)
  {
    (void)title;
  }
}
