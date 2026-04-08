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
  extern thinker_t thinkercap;
  void G_DeferedInitNew(skill_t skill, int episode, int map);
}

namespace od
{

  // Bot key input queue
  static const int KEY_QUEUE_SIZE = 32;
  static struct
  {
    unsigned char key;
    int pressed;
  } sKeyQueue[KEY_QUEUE_SIZE];
  static int sKeyHead = 0;
  static int sKeyTail = 0;

  static void pushKey(unsigned char key, int pressed)
  {
    int next = (sKeyTail + 1) % KEY_QUEUE_SIZE;
    if (next != sKeyHead)
    {
      sKeyQueue[sKeyTail].key = key;
      sKeyQueue[sKeyTail].pressed = pressed;
      sKeyTail = next;
    }
  }

  // Pointer to current FrameBuffer for DG_DrawFrame blit
  static FrameBuffer *sMainFB = nullptr;
  static int *sColLUT = nullptr;
  static int *sRowLUT = nullptr;
  static bool sDoomReady = false;
  static bool sDoomCreated = false;

  // Bot state
  enum BotState
  {
    BOT_WANDER,
    BOT_CHASE,
    BOT_ATTACK
  };
  static BotState sBotState = BOT_WANDER;
  static int sBotTurnTimer = 0;
  static int sBotStuckTimer = 0;
  static int sBotUseTimer = 0;
  static int sBotFireTimer = 0;
  static fixed_t sLastX = 0, sLastY = 0;

  // Track which keys the bot currently holds
  static bool sBotForward = false;
  static bool sBotLeft = false;
  static bool sBotRight = false;
  static bool sBotFire = false;
  static bool sBotUse = false;

  // Set a bot key — only sends event on state change
  static void botHold(unsigned char key, bool &state, bool want)
  {
    if (want && !state)
    {
      pushKey(key, 1);
      state = true;
    }
    else if (!want && state)
    {
      pushKey(key, 0);
      state = false;
    }
  }

  static void botReleaseAll()
  {
    botHold(KEY_UPARROW, sBotForward, false);
    botHold(KEY_LEFTARROW, sBotLeft, false);
    botHold(KEY_RIGHTARROW, sBotRight, false);
    botHold(KEY_FIRE, sBotFire, false);
    botHold(KEY_USE, sBotUse, false);
  }

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

    sColLUT = mColLUT;
    sRowLUT = mRowLUT;
  }

  void Doom::reset()
  {
    mTickAccum = 0.0f;
    mStartupTicks = 0;
    mInitialized = false;
    mWadMissing = false;
    sBotState = BOT_WANDER;
    sBotTurnTimer = 0;
    sBotStuckTimer = 0;
    sBotUseTimer = 0;
    sBotFireTimer = 0;
    sKeyHead = sKeyTail = 0;
    sDoomReady = false;
    botReleaseAll();

    if (sDoomCreated)
    {
      // Doom globals survive — just resume
      mInitialized = true;
      sDoomReady = true;
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
    sDoomCreated = true;
    mInitialized = true;
    sDoomReady = true;
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

  void Doom::botTick()
  {
    if (!mInitialized || gamestate != GS_LEVEL || !players[0].mo)
      return;

    mobj_t *mo = players[0].mo;
    sBotTurnTimer++;
    sBotUseTimer++;
    sBotFireTimer++;

    // Stuck detection
    fixed_t dx = abs(mo->x - sLastX);
    fixed_t dy = abs(mo->y - sLastY);
    if (dx < FRACUNIT && dy < FRACUNIT)
      sBotStuckTimer++;
    else
      sBotStuckTimer = 0;
    sLastX = mo->x;
    sLastY = mo->y;

    // Desired key state this tick
    bool wantForward = false;
    bool wantLeft = false;
    bool wantRight = false;
    bool wantFire = false;
    bool wantUse = false;

    // Find nearest monster
    mobj_t *nearest = nullptr;
    fixed_t nearestDist = 0x7FFFFFFF;

    for (thinker_t *th = ::thinkercap.next; th != &::thinkercap; th = th->next)
    {
      if (th->function.acp1 != (actionf_p1)P_MobjThinker)
        continue;
      mobj_t *target = (mobj_t *)th;
      if (!(target->flags & MF_COUNTKILL))
        continue;
      if (target->health <= 0)
        continue;

      fixed_t tdx = abs(target->x - mo->x);
      fixed_t tdy = abs(target->y - mo->y);
      fixed_t dist = tdx + tdy;
      if (dist < nearestDist)
      {
        nearestDist = dist;
        nearest = target;
      }
    }

    // Determine angle to nearest monster
    angle_t targetAngle = 0;
    bool hasTarget = false;
    if (nearest && nearestDist < 1024 * FRACUNIT)
    {
      targetAngle = R_PointToAngle2(mo->x, mo->y, nearest->x, nearest->y);
      hasTarget = true;
    }

    if (hasTarget && nearestDist < 512 * FRACUNIT)
    {
      angle_t angleDiff = targetAngle - mo->angle;
      if (angleDiff > ANG180)
        angleDiff = -(angle_t)(0xFFFFFFFF - angleDiff + 1);

      if (abs((int)angleDiff) < ANG90 / 4)
      {
        // Facing monster — charge and shoot
        wantForward = true;
        if (sBotFireTimer > 4)
        {
          wantFire = true;
          sBotFireTimer = 0;
        }
      }
      else
      {
        // Turn toward monster
        if ((int)angleDiff > 0)
          wantLeft = true;
        else
          wantRight = true;
        wantForward = true;
      }
    }
    else
    {
      // Wander — always move forward
      wantForward = true;

      // Random turns
      if (sBotTurnTimer > 35 + Random::generateInteger(0, 70))
      {
        sBotTurnTimer = 0;
        if (Random::generateFloat(0.0f, 1.0f) < 0.5f)
          wantLeft = true;
        else
          wantRight = true;
      }

      // Unstuck
      if (sBotStuckTimer > 20)
      {
        wantLeft = true;
        if (sBotStuckTimer > 40)
        {
          sBotStuckTimer = 0;
          wantUse = true;
        }
      }
    }

    // Periodic use for doors
    if (sBotUseTimer > 70)
    {
      wantUse = true;
      sBotUseTimer = 0;
    }

    // Apply desired state — only sends events on transitions
    botHold(KEY_UPARROW, sBotForward, wantForward);
    botHold(KEY_LEFTARROW, sBotLeft, wantLeft);
    botHold(KEY_RIGHTARROW, sBotRight, wantRight);
    botHold(KEY_FIRE, sBotFire, wantFire);
    botHold(KEY_USE, sBotUse, wantUse);
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

    sMainFB = &m;

    // Run bot and tick Doom at 35fps (native rate)
    mTickAccum += GRAPHICS_REFRESH_PERIOD;
    float doomPeriod = 1.0f / 35.0f;
    while (mTickAccum >= doomPeriod)
    {
      mTickAccum -= doomPeriod;
      mStartupTicks++;

      // Bot runs once player is spawned and alive
      if (gamestate == GS_LEVEL && players[0].mo
          && players[0].playerstate == PST_LIVE)
        botTick();

      if (DG_ScreenBuffer)
        memset(DG_ScreenBuffer, 0, DOOMGENERIC_RESX * DOOMGENERIC_RESY * sizeof(pixel_t));
      doomgeneric_Tick();
    }

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
    if (od::sKeyHead == od::sKeyTail)
      return 0;
    *key = od::sKeyQueue[od::sKeyHead].key;
    *pressed = od::sKeyQueue[od::sKeyHead].pressed;
    od::sKeyHead = (od::sKeyHead + 1) % od::KEY_QUEUE_SIZE;
    return 1;
  }

  void DG_SetWindowTitle(const char *title)
  {
    (void)title;
  }
}
