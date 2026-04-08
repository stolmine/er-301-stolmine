// Bot AI for Doom screensaver — adapted from ZCajun (ZDoom, BSD-3)
// Simplified for single-player monster combat: no deathmatch, no inventory
// classes, no ZDoom actor extensions.

#include "b_bot.h"
#include "doomstat.h"
#include "doomdef.h"
#include "d_event.h"
#include "p_local.h"
#include "m_random.h"
#include "d_player.h"
#include "r_main.h"
#include "tables.h"

#include <stdlib.h>
#include <string.h>

boolean bot_enabled = false;
bot_state_t bot;

// Movement tables (same values as p_enemy.c)
static const bot_dirtype_t bot_opposite[9] = {
    DI_WEST, DI_SOUTHWEST, DI_SOUTH, DI_SOUTHEAST,
    DI_EAST, DI_NORTHEAST, DI_NORTH, DI_NORTHWEST, DI_NODIR
};
static const bot_dirtype_t bot_diags[4] = {
    DI_NORTHWEST, DI_NORTHEAST, DI_SOUTHWEST, DI_SOUTHEAST
};
static const fixed_t bot_xspeed[8] = {
    FRACUNIT, 47000, 0, -47000, -FRACUNIT, -47000, 0, 47000
};
static const fixed_t bot_yspeed[8] = {
    0, 47000, FRACUNIT, 47000, 0, -47000, -FRACUNIT, -47000
};

// From g_game.c
extern fixed_t forwardmove[2];

// From p_map.c
extern line_t *spechit[];
extern int numspechit;

static player_t *botplayer(void)
{
    return &players[consoleplayer];
}

static mobj_t *botmo(void)
{
    return players[consoleplayer].mo;
}

//----------------------------------------------------------------------
// Reachable: check if bot can physically walk to target
// (not just see it — traces through linedefs checking passability)
// Adapted from ZCajun DBot::Reachable (BSD-3)
//----------------------------------------------------------------------
#define BOT_MAXMOVEHEIGHT (24*FRACUNIT)

static mobj_t *reach_target;
static sector_t *reach_last_sector;
static fixed_t reach_last_z;
static boolean reach_result;
static fixed_t reach_estimated_dist;

static boolean PTR_ReachTraverse(intercept_t *in)
{
    if (in->isaline)
    {
        line_t *line = in->d.line;

        // One-sided line = solid wall
        if (!(line->flags & ML_TWOSIDED) || (line->flags & ML_BLOCKING))
        {
            reach_result = false;
            return false; // stop traversal
        }

        // Two-sided: check if we can walk through
        sector_t *s;
        if (line->backsector == reach_last_sector)
            s = line->frontsector;
        else
            s = line->backsector;

        if (!s)
        {
            reach_result = false;
            return false;
        }

        fixed_t floorh = s->floorheight;
        fixed_t ceilh = s->ceilingheight;

        // Can we fit through?
        if (ceilh - floorh < botmo()->height)
        {
            reach_result = false;
            return false;
        }

        // Is the step too high?
        if (floorh > reach_last_z + BOT_MAXMOVEHEIGHT)
        {
            // Unless it's a door (ceiling == floor means closed door with special)
            if (!(ceilh == floorh && line->special))
            {
                reach_result = false;
                return false;
            }
        }

        reach_last_z = floorh;
        reach_last_sector = s;
        return true; // continue
    }
    else
    {
        // Thing intercept
        mobj_t *thing = in->d.thing;
        if (thing == botmo())
            return true; // skip self
        if (thing == reach_target)
        {
            reach_result = true;
            return false; // found target, stop
        }
        return true; // continue past other things
    }
}

static boolean Bot_Reachable(mobj_t *target)
{
    mobj_t *mo = botmo();

    if (!target || target == mo)
        return false;

    // Quick height check: can we fit in target's sector?
    if (target->subsector && target->subsector->sector)
    {
        sector_t *ts = target->subsector->sector;
        if (ts->ceilingheight - ts->floorheight < mo->height)
            return false;
    }

    reach_target = target;
    reach_last_sector = mo->subsector->sector;
    reach_last_z = reach_last_sector->floorheight;
    reach_result = true; // assume reachable unless proven otherwise
    reach_estimated_dist = P_AproxDistance(mo->x - target->x, mo->y - target->y);

    P_PathTraverse(mo->x, mo->y, target->x, target->y,
                   PT_ADDLINES | PT_ADDTHINGS, PTR_ReachTraverse);

    return reach_result;
}

//----------------------------------------------------------------------
// Check_LOS: visibility check with field-of-view constraint
//----------------------------------------------------------------------
static boolean Check_LOS(mobj_t *to, angle_t vangle)
{
    mobj_t *mo = botmo();
    angle_t an, diff;

    if (!P_CheckSight(mo, to))
        return false;
    if (vangle >= ANG180 * 2) // 360 degrees
        return true;
    if (vangle == 0)
        return false;

    an = R_PointToAngle2(mo->x, mo->y, to->x, to->y);
    diff = an - mo->angle;
    if (diff > ANG180)
        diff = -(angle_t)(0xFFFFFFFF - diff + 1);
    return (angle_t)abs((int)diff) <= (vangle / 2);
}

//----------------------------------------------------------------------
// Find_enemy: scan thinkers for nearest visible monster
//----------------------------------------------------------------------
static mobj_t *Find_enemy(void)
{
    extern thinker_t thinkercap;
    mobj_t *mo = botmo();
    mobj_t *best = NULL;
    fixed_t bestdist = 0x7FFFFFFF;
    thinker_t *th;

    for (th = thinkercap.next; th != &thinkercap; th = th->next)
    {
        mobj_t *target;
        fixed_t dist;

        if (th->function.acp1 != (actionf_p1)P_MobjThinker)
            continue;

        target = (mobj_t *)th;

        if (!(target->flags & MF_COUNTKILL))
            continue;
        if (target->health <= 0)
            continue;
        if (!(target->flags & MF_SHOOTABLE))
            continue;
        // Skip enemy we recently determined is unreachable
        if (target == bot.ignore_enemy && bot.ignore_timer > 0)
            continue;

        dist = P_AproxDistance(target->x - mo->x, target->y - mo->y);
        if (dist > BOT_CHASE_DIST)
            continue;

        if (!Check_LOS(target, ANG180))
            continue;

        if (dist < bestdist)
        {
            bestdist = dist;
            best = target;
        }
    }
    return best;
}

//----------------------------------------------------------------------
// Set_enemy: update current enemy target
//----------------------------------------------------------------------
static void Set_enemy(void)
{
    mobj_t *oldenemy = NULL;

    if (bot.enemy && bot.enemy->health > 0 && P_CheckSight(botmo(), bot.enemy))
        oldenemy = bot.enemy;
    else
        oldenemy = NULL;

    bot.enemy = Find_enemy();
    if (!bot.enemy)
        bot.enemy = oldenemy;

    // Verify enemy is still valid
    if (bot.enemy && (bot.enemy->health <= 0 || !(bot.enemy->flags & MF_SHOOTABLE)))
        bot.enemy = NULL;
}

//----------------------------------------------------------------------
// CleanAhead: check if position is passable (adapted from FCajunMaster)
//----------------------------------------------------------------------
static boolean CleanAhead(mobj_t *thing, fixed_t x, fixed_t y)
{
    // Temporarily remove pickup flag to avoid side effects
    int savedFlags = thing->flags;
    thing->flags &= ~MF_PICKUP;
    boolean ok = P_CheckPosition(thing, x, y);
    thing->flags = savedFlags;
    return ok;
}

//----------------------------------------------------------------------
// Bot_Move: try to move in current movedir (from ZCajun b_move.cpp)
//----------------------------------------------------------------------
static boolean Bot_Move(ticcmd_t *cmd)
{
    mobj_t *mo = botmo();
    fixed_t tryx, tryy;

    if (mo->movedir == DI_NODIR)
        return false;

    tryx = mo->x + 8 * bot_xspeed[mo->movedir];
    tryy = mo->y + 8 * bot_yspeed[mo->movedir];

    if (CleanAhead(mo, tryx, tryy))
    {
        cmd->forwardmove = BOT_FORWARDRUN;
        return true;
    }

    // Blocked — check if we hit a door/switch we can use
    if (numspechit > 0)
    {
        mo->movedir = DI_NODIR;
        // Try to use the special line (door, switch)
        if ((P_Random() % 4) >= 1)
        {
            cmd->buttons |= BT_USE;
            cmd->forwardmove = BOT_FORWARDRUN;
            return true;
        }
        return false;
    }

    return false;
}

//----------------------------------------------------------------------
// Bot_TryWalk: move + set random movecount
//----------------------------------------------------------------------
static boolean Bot_TryWalk(ticcmd_t *cmd)
{
    if (!Bot_Move(cmd))
        return false;
    botmo()->movecount = P_Random() & 60;
    return true;
}

//----------------------------------------------------------------------
// Bot_NewChaseDir: pick new 8-direction (from ZCajun/p_enemy.c)
//----------------------------------------------------------------------
static void Bot_NewChaseDir(ticcmd_t *cmd)
{
    mobj_t *mo = botmo();
    mobj_t *target = bot.dest ? bot.dest : bot.enemy;
    bot_dirtype_t d[3];
    bot_dirtype_t olddir, turnaround;
    fixed_t deltax, deltay;
    int tdir;

    if (!target)
        return;

    olddir = mo->movedir;
    turnaround = bot_opposite[olddir];

    deltax = target->x - mo->x;
    deltay = target->y - mo->y;

    if (deltax > 10 * FRACUNIT)
        d[1] = DI_EAST;
    else if (deltax < -10 * FRACUNIT)
        d[1] = DI_WEST;
    else
        d[1] = DI_NODIR;

    if (deltay < -10 * FRACUNIT)
        d[2] = DI_SOUTH;
    else if (deltay > 10 * FRACUNIT)
        d[2] = DI_NORTH;
    else
        d[2] = DI_NODIR;

    // Try direct diagonal
    if (d[1] != DI_NODIR && d[2] != DI_NODIR)
    {
        mo->movedir = bot_diags[((deltay < 0) << 1) + (deltax > 0)];
        if (mo->movedir != turnaround && Bot_TryWalk(cmd))
            return;
    }

    // Randomize priority
    if (P_Random() > 200 || abs(deltay) > abs(deltax))
    {
        tdir = d[1];
        d[1] = d[2];
        d[2] = tdir;
    }

    if (d[1] == turnaround) d[1] = DI_NODIR;
    if (d[2] == turnaround) d[2] = DI_NODIR;

    if (d[1] != DI_NODIR)
    {
        mo->movedir = d[1];
        if (Bot_TryWalk(cmd))
            return;
    }

    if (d[2] != DI_NODIR)
    {
        mo->movedir = d[2];
        if (Bot_TryWalk(cmd))
            return;
    }

    // Try old direction
    if (olddir != DI_NODIR)
    {
        mo->movedir = olddir;
        if (Bot_TryWalk(cmd))
            return;
    }

    // Random scan
    if (P_Random() & 1)
    {
        for (tdir = DI_EAST; tdir <= DI_SOUTHEAST; tdir++)
        {
            if (tdir != turnaround)
            {
                mo->movedir = tdir;
                if (Bot_TryWalk(cmd))
                    return;
            }
        }
    }
    else
    {
        for (tdir = DI_SOUTHEAST; tdir >= DI_EAST; tdir--)
        {
            if (tdir != turnaround)
            {
                mo->movedir = tdir;
                if (Bot_TryWalk(cmd))
                    return;
            }
        }
    }

    // Last resort: turnaround
    if (turnaround != DI_NODIR)
    {
        mo->movedir = turnaround;
        if (Bot_TryWalk(cmd))
            return;
    }

    mo->movedir = DI_NODIR;
}

//----------------------------------------------------------------------
// Bot_Roam: navigate toward destination
//----------------------------------------------------------------------
static void Bot_Roam(ticcmd_t *cmd)
{
    mobj_t *mo = botmo();

    if (bot.dest && Bot_Reachable(bot.dest))
    {
        // Can walk straight to destination
        bot.angle = R_PointToAngle2(mo->x, mo->y, bot.dest->x, bot.dest->y);
    }
    else if (mo->movedir < 8)
    {
        // Turn toward movement direction
        angle_t moveangle = (unsigned)(mo->movedir) << 29;
        angle_t diff = moveangle - (bot.angle & (7u << 29));
        if (diff != 0)
        {
            if (diff > ANG180)
                bot.angle -= ANG45;
            else
                bot.angle += ANG45;
        }
    }

    // Chase toward destination
    if (--mo->movecount < 0 || !Bot_Move(cmd))
    {
        Bot_NewChaseDir(cmd);
    }
}

//----------------------------------------------------------------------
// Bot_Dofire: decide whether to fire (simplified from ZCajun)
//----------------------------------------------------------------------
static void Bot_Dofire(ticcmd_t *cmd)
{
    mobj_t *mo = botmo();
    player_t *p = botplayer();
    fixed_t dist;

    if (!bot.enemy || !(bot.enemy->flags & MF_SHOOTABLE) || bot.enemy->health <= 0)
        return;

    if (p->readyweapon == wp_nochange)
        return;

    // Minimal reaction delay
    if (bot.first_shot)
    {
        bot.t_react = 1 + (P_Random() % 2); // 1-2 ticks (~29-57ms)
        bot.first_shot = false;
    }
    if (bot.t_react > 0)
        return;

    dist = P_AproxDistance(mo->x - bot.enemy->x, mo->y - bot.enemy->y);

    // Melee weapons: only fire if close
    if (p->readyweapon == wp_fist || p->readyweapon == wp_chainsaw)
    {
        if (dist > BOT_MELEE_RANGE * 3)
            return;
    }

    // Rocket launcher: don't fire too close (suicide prevention)
    if (p->readyweapon == wp_missile && dist < 128 * FRACUNIT)
        return;

    // Use P_AimLineAttack to check if a shot would actually hit the enemy
    // (not blocked by walls, windows, or height differences)
    {
        angle_t aimangle = R_PointToAngle2(mo->x, mo->y,
                                           bot.enemy->x, bot.enemy->y);
        angle_t diff = aimangle - mo->angle;
        if (diff > ANG180)
            diff = (angle_t)(0xFFFFFFFF - diff + 1);
        // Must be roughly facing (within ~22 degrees)
        if (diff > ANG45 / 2)
            return;

        // Trace a shot — linetarget tells us what we'd actually hit
        extern mobj_t *linetarget;
        P_AimLineAttack(mo, aimangle, dist + 16 * FRACUNIT);
        if (linetarget != bot.enemy)
            return; // Would hit a wall or wrong target
    }

    cmd->buttons |= BT_ATTACK;
}

//----------------------------------------------------------------------
// Bot_SelectWeapon: pick best available weapon
//----------------------------------------------------------------------
static void Bot_SelectWeapon(ticcmd_t *cmd)
{
    player_t *p = botplayer();
    fixed_t dist = 0;

    if (bot.enemy)
        dist = P_AproxDistance(botmo()->x - bot.enemy->x,
                               botmo()->y - bot.enemy->y);

    // Distance-aware weapon priority
    // Close: chainsaw > SSG > shotgun > chaingun > fist > pistol
    // Mid:   SSG > plasma > chaingun > shotgun > rocket > pistol
    // Far:   rocket > plasma > chaingun > SSG > shotgun > pistol > BFG
    static const weapontype_t close_pri[] = {
        wp_chainsaw, wp_supershotgun, wp_shotgun, wp_chaingun,
        wp_fist, wp_pistol, wp_nochange
    };
    static const weapontype_t mid_pri[] = {
        wp_supershotgun, wp_plasma, wp_chaingun, wp_shotgun,
        wp_missile, wp_pistol, wp_nochange
    };
    static const weapontype_t far_pri[] = {
        wp_missile, wp_plasma, wp_chaingun, wp_supershotgun,
        wp_shotgun, wp_pistol, wp_bfg, wp_nochange
    };

    const weapontype_t *pri;
    int count;

    if (dist < 128 * FRACUNIT)
    {
        pri = close_pri;
        count = 6;
    }
    else if (dist < 512 * FRACUNIT)
    {
        pri = mid_pri;
        count = 6;
    }
    else
    {
        pri = far_pri;
        count = 7;
    }

    int i;
    for (i = 0; i < count; i++)
    {
        weapontype_t w = pri[i];
        if (w == p->readyweapon)
            break; // already using best available
        if (!p->weaponowned[w])
            continue;

        // Check ammo
        ammotype_t ammo = am_noammo;
        switch (w)
        {
        case wp_pistol: case wp_chaingun: ammo = am_clip; break;
        case wp_shotgun: case wp_supershotgun: ammo = am_shell; break;
        case wp_missile: ammo = am_misl; break;
        case wp_plasma: case wp_bfg: ammo = am_cell; break;
        default: break;
        }
        if (ammo != am_noammo && p->ammo[ammo] <= 0)
            continue;

        // Found a better weapon — switch
        cmd->buttons |= BT_CHANGE;
        cmd->buttons |= w << BT_WEAPONSHIFT;
        break;
    }
}

//----------------------------------------------------------------------
// TurnToAng: smooth turning toward bot.angle (from ZCajun)
//----------------------------------------------------------------------
// Compute a clamped angleturn value toward bot.angle, without touching mo->angle.
// The engine applies angleturn via ticcmd — we must not also modify mo->angle directly.
static short CalcTurn(void)
{
    mobj_t *mo = botmo();
    angle_t diff = bot.angle - mo->angle;
    int maxturn = BOT_TURN_SPEED;
    angle_t maxang = (angle_t)maxturn << 24;

    if (diff == 0)
        return 0;

    if (diff <= ANG180)
    {
        if (diff > maxang)
            diff = maxang;
    }
    else
    {
        angle_t absdiff = (angle_t)(0xFFFFFFFF - diff + 1);
        if (absdiff > maxang)
            diff = (angle_t)(0xFFFFFFFF - maxang + 1);
    }

    return (short)(diff >> 16);
}

//----------------------------------------------------------------------
// Bot_Think: main per-tick AI decision (adapted from DBot::Think)
//----------------------------------------------------------------------
static void Bot_Think(ticcmd_t *cmd)
{
    mobj_t *mo = botmo();
    player_t *p = botplayer();

    if (!mo || p->playerstate != PST_LIVE)
    {
        // Dead — press use to respawn
        if (bot.t_respawn > 0)
            bot.t_respawn--;
        else
            cmd->buttons |= BT_USE;
        return;
    }

    if (bot.enemy && bot.enemy->health <= 0)
        bot.enemy = NULL;

    // Tick ignore cooldown
    if (bot.ignore_timer > 0)
    {
        bot.ignore_timer--;
        // Clear ignore if the enemy died
        if (bot.ignore_enemy && bot.ignore_enemy->health <= 0)
        {
            bot.ignore_enemy = NULL;
            bot.ignore_timer = 0;
        }
    }

    Set_enemy();

    // Stuck detection
    {
        fixed_t dx = abs(mo->x - bot.old_x);
        fixed_t dy = abs(mo->y - bot.old_y);
        if (dx < FRACUNIT / 2 && dy < FRACUNIT / 2)
            bot.stuckcount++;
        else
            bot.stuckcount = 0;
        bot.old_x = mo->x;
        bot.old_y = mo->y;
    }

    // Decide movement
    // Decide destination and aim
    if (bot.enemy && P_CheckSight(mo, bot.enemy))
    {
        // Can see enemy — but can we reach it?
        bot.angle = R_PointToAngle2(mo->x, mo->y, bot.enemy->x, bot.enemy->y);

        if (Bot_Reachable(bot.enemy))
        {
            fixed_t dist = P_AproxDistance(mo->x - bot.enemy->x,
                                           mo->y - bot.enemy->y);

            // Weapon-aware combat distance
            fixed_t ideal_dist;
            boolean is_melee = (p->readyweapon == wp_fist ||
                                p->readyweapon == wp_chainsaw);
            boolean is_explosive = (p->readyweapon == wp_missile ||
                                    p->readyweapon == wp_bfg);
            boolean is_shotgun = (p->readyweapon == wp_shotgun ||
                                  p->readyweapon == wp_supershotgun);

            if (is_melee)
                ideal_dist = BOT_MELEE_RANGE;
            else if (is_explosive)
                ideal_dist = 384 * FRACUNIT; // keep distance with rockets
            else if (is_shotgun)
                ideal_dist = 196 * FRACUNIT; // shotgun sweet spot
            else
                ideal_dist = 256 * FRACUNIT; // chaingun, pistol, plasma

            if (dist < BOT_MELEE_RANGE)
            {
                // Enemy is on top of us — don't run away, stand and fight
                // (backing up at point blank just exposes our back)
                cmd->forwardmove = 0;
            }
            else if (dist < ideal_dist / 2 && !is_melee)
            {
                // Too close for this weapon — back up
                cmd->forwardmove = -BOT_FORWARDWALK;
            }
            else if (dist > ideal_dist)
            {
                // Too far — close in via navigation
                bot.dest = bot.enemy;
            }
            else
            {
                // In sweet spot — hold position
                cmd->forwardmove = 0;
            }

            // Strafe while fighting
            if (bot.t_strafe <= 0 && (bot.stuckcount > 3 || (P_Random() % 30) == 0))
            {
                bot.t_strafe = 5;
                bot.sleft = !bot.sleft;
            }
            cmd->sidemove = bot.sleft ? -BOT_SIDEWALK : BOT_SIDEWALK;

            Bot_Dofire(cmd);
            Bot_SelectWeapon(cmd);
            bot.first_shot = false;
        }
        else
        {
            // Visible but unreachable (window, ledge, gap)
            // Ignore and explore elsewhere
            bot.ignore_enemy = bot.enemy;
            bot.ignore_timer = 105;
            bot.dest = NULL;
            bot.enemy = NULL;
        }
    }
    else
    {
        // Can't see enemy
        bot.first_shot = true;

        if (!bot.dest || (bot.dest->health <= 0 && !(bot.dest->flags & MF_SPECIAL)))
            bot.dest = NULL;
    }

    // ALL movement goes through the navigation system
    if (bot.dest)
    {
        Bot_Roam(cmd);
    }
    else
    {
        // No destination at all — pick a random direction and walk
        if (mo->movecount <= 0 || mo->movedir == DI_NODIR)
        {
            mo->movedir = P_Random() % 8;
            mo->movecount = 15 + (P_Random() & 31);
        }
        Bot_Move(cmd);
        mo->movecount--;
    }

    // Periodic use for doors
    if ((gametic % 70) == 0)
        cmd->buttons |= BT_USE;

    // Smooth turning toward bot.angle
    cmd->angleturn = CalcTurn();

    // Decrement timers
    if (bot.t_strafe > 0) bot.t_strafe--;
    if (bot.t_react > 0) bot.t_react--;
    if (bot.t_roam > 0) bot.t_roam--;
}

//----------------------------------------------------------------------
// Public API
//----------------------------------------------------------------------
void Bot_Init(void)
{
    memset(&bot, 0, sizeof(bot));
    bot.first_shot = true;
    bot.t_respawn = 35; // wait 1 sec before first action
}

void Bot_BuildTiccmd(ticcmd_t *cmd)
{
    // cmd is already zeroed and consistancy set by G_BuildTiccmd
    Bot_Think(cmd);
}
