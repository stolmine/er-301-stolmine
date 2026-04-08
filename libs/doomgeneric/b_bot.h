#ifndef __B_BOT_H__
#define __B_BOT_H__

#include "doomtype.h"
#include "doomdef.h"
#include "d_ticcmd.h"
#include "p_mobj.h"
#include "m_fixed.h"
#include "tables.h"

// 8-direction movement (same as p_enemy.c but not exported)
typedef enum
{
    DI_EAST,
    DI_NORTHEAST,
    DI_NORTH,
    DI_NORTHWEST,
    DI_WEST,
    DI_SOUTHWEST,
    DI_SOUTH,
    DI_SOUTHEAST,
    DI_NODIR,
    NUMDIRS
} bot_dirtype_t;

// Bot movement speeds (match player values from g_game.c)
#define BOT_FORWARDWALK  0x19
#define BOT_FORWARDRUN   0x32
#define BOT_SIDEWALK     0x18
#define BOT_SIDERUN      0x28

// Bot AI tuning
#define BOT_SHOOTFOV     ANG90        // field of view for shooting
#define BOT_MELEE_RANGE  (64*FRACUNIT)
#define BOT_CHASE_DIST   (4096*FRACUNIT)
#define BOT_STUCK_TICKS  15          // ~430ms before giving up on a path
#define BOT_TURN_SPEED   15          // max degrees per tic

typedef struct
{
    mobj_t *enemy;          // current target monster
    mobj_t *dest;           // navigation destination

    angle_t angle;          // desired facing angle
    boolean fire;           // wants to attack
    boolean use;            // wants to use/open

    boolean sleft;          // strafe direction toggle

    fixed_t old_x, old_y;  // previous position for stuck detection
    int stuckcount;

    mobj_t *ignore_enemy;   // unreachable enemy to skip
    int ignore_timer;       // ticks until we can re-acquire ignored enemy

    int t_strafe;           // strafe timer
    int t_react;            // reaction delay timer
    int t_roam;             // roam timeout
    int t_respawn;          // respawn delay

    boolean first_shot;     // first shot reaction delay flag
    boolean increase;       // aiming oscillation direction
} bot_state_t;

extern boolean bot_enabled;
extern bot_state_t bot;

void Bot_Init(void);
void Bot_BuildTiccmd(ticcmd_t *cmd);

#endif // __B_BOT_H__
