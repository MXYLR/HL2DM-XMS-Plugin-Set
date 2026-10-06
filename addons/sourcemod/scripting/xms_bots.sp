#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION  "2.5"
#define PLUGIN_URL      "www.hl2dm.community"
#define PLUGIN_UPDATE   "http://raw.githubusercontent.com/utharper/sourcemod-hl2dm/master/addons/sourcemod/xms_bots.upd"

public Plugin myinfo = {
    name              = "XMS - Bot Controller",
    version           = PLUGIN_VERSION,
    description       = "Built-in HL2MP bot controller for XMS servers",
    // currently only supports a single bot -- automatically leaves when player count exceeds 1
    author            = "harper",
    url               = PLUGIN_URL
};

/**************************************************************
 * INCLUDES
 *************************************************************/
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <morecolors>
#include <smlib>

#undef REQUIRE_PLUGIN
#include <updater>

#define REQUIRE_PLUGIN
#include <jhl2dm>
#include <xms>

/**************************************************************
 * GLOBAL VARS
 *************************************************************/
int  giBotClient;
int  giState;
int  giJoinDelay;
int  giLeaveDelay;
int  giDamagePercent = 100;
int  giCatchRadius;

// How close an incoming object has to be before the swing presses the attack
// key, as a ceiling on the gun's own reach.  0 means "as far as the gun
// reaches", which is the only setting that cannot miss.
int  giGrabRange;

// How long the engine's own prop hold may run before the plugin throws it for
// the bot, in seconds.  0 leaves the hold alone, which is the game's own
// behaviour: a bot with nothing to throw at keeps what it picked up.
int  giPropHoldTime;

// Whether a map with no navigation mesh gets one generated rather than only a
// complaint in the log.  See CheckNavMesh.
bool gbNavGenerate;

// The map a generation has already been started for in this server run.
// nav_generate reloads the map when it is done, so the second look at the same
// map is the one that tells a failure from a success.
char gsNavTried[MAX_MAP_LENGTH];

// A walk over every map that has no navigation mesh, named in "NavPassMaps".
// Only the map that is running can be generated for, so the pass changes to the
// next map on the list each time one starts and stops when the list is done.
// The list is empty in normal running, which is what keeps the pass off.
//
// It is sized for the whole map folder, not a handful: an installed set of
// sixty-odd maps is what this is for, and a list that does not fit is silently
// cut off part way through.
char  gsNavPass[4096];
bool  gbNavPassOn;
bool  gbNavPassDone;
int   giNavPassChanges;

// The maps this pass has already started a generation for, so a map that
// produces nothing is left alone instead of being changed to over and over.
// Arriving at a map is deliberately not recorded here: being sent to a map is
// what earns it its one generation, and marking it on the way in would leave
// every map on the list looking already done.
StringMap gNavPassSeen;

// The maps this pass has already changed to, so a map that never loads is not
// handed to the engine again and again.  Separate from the set above because
// asking for a map and generating for it are different steps that happen on
// different map starts.
StringMap gNavPassAsked;

// Bunnyhop settings, from the Bots section: whether the bot hops at all, the
// speed it stops strafing at (0 = no cap), and how far off its velocity the
// strafe pushes (0 = straight sideways, the fastest gain).
bool gbAutoBhop;
int  giBhopMaxSpeed;
int  giBhopAngle = 0;

// Alternated while the bot is on the ground so its jump button is released every
// other frame; see OnPlayerRunCmd for why a held button never jumps.
bool gbJumpFlip;

bool gbEnabled;
bool gbContinue;
bool gbSourceTV;

char gsBotName[MAX_NAME_LENGTH];

// The model to pin the bot to, from the "Model" key in xms.cfg.  Empty leaves
// the choice to the game, which is what it does today.
char gsBotModel[PLATFORM_MAX_PATH];

// Its precache index, which is what the model pin compares against.
int  giBotModelIndex;

// Which of the game's three voice sets that model calls for, chosen exactly the
// way the game chooses it.  -1 leaves the voice to the game: the model matches
// none of the sets, or this build has no such client property.
int  giBotSoundType;

// The last animation sequence the bot was seen playing.  Setting a model --
// the game's own re-pick as much as the pin below -- restarts the animation at
// sequence 0, which for these models is the `reference` pose, the T-shape.  On
// the ground the next activity change repairs that within a frame; in the air
// the jump's activity does not change, so the T-shape lasts the whole jump.
// This is the value put back when the sequence is found at 0.
int  giLastSequence;

// The voice pin is logged once, since after the first line the rest say the
// same thing.  The body and sequence repairs are logged a few times each,
// because whether they fire in the air is what the log is there to answer.  The
// frag search is logged once per frag entity rather than against a budget the
// frags share: a frag the bot never reacts to otherwise leaves no trace at all,
// which is the one outcome the log has to be able to explain, and a budget runs
// out in the middle of a map -- which is how a test that threw a grenade at the
// bot came back with nothing at all to read.
// The weapon-switch refusal is logged a few times as well.  It is the one part
// of the swing whose working cannot be inferred from the outcome: a swing that
// still fails looks the same whether the game switched the gun away behind the
// hook's back or the hook refused a switch that was never the problem.
int  giBodyLogs;
int  giSequenceLogs;
int  giSwitchLogs;
bool gbVoiceLogged;

// How fast a frag is going is measured from how far it has moved since the last
// look, not read from the entity.  Neither velocity field will answer it: a tick
// with six frags inside the 400-unit radius reported 0 u/s for every one of
// them, so a gate on either turned away frags that were plainly in the air.  The
// origin does read -- every distance in that same line comes from it -- so the
// motion is taken from the origin's own movement between two ticks.
//
// Indexed by entity, overwritten as frags come and go.  A gap longer than half a
// second is not carried over: that is the swing holding the timer off, and by
// then the slot may hold a different frag.
//
// 2048 is the engine's own edict ceiling (GetMaxEntities), which the include set
// here does not name as a constant.
#define FRAG_TRACK_MAX 2048

float gfFragLastTime[FRAG_TRACK_MAX];
float gfFragLastPos[FRAG_TRACK_MAX][3];

// A prop's speed is measured the same way and for the same reason: reading
// m_vecAbsVelocity off every prop in the list returned exactly 0 on all of them
// for a whole test round, while the bot carried barrels around and threw them,
// so the gate that turns away anything under PROP_INCOMING_SPEED was turning
// away the entire map.  A physics prop keeps its motion in its physics object
// and never writes it back to either entity field; the origin is honest, so the
// motion comes from the origin's own movement between two ticks.  See the note
// on gfFragLastPos above.
float gfPropLastTime[FRAG_TRACK_MAX];
float gfPropLastPos[FRAG_TRACK_MAX][3];

// One line per entity per map, for the frags the bot passes up.  The index a
// frag leaves behind can be handed to a later one, which then says nothing of
// its own -- the log is there to explain a test, and the first frag a test
// throws is the one that has to be explained.
bool  gbFragSaid[FRAG_TRACK_MAX];

// The engine's own prop hold, watched and, past a limit, broken.  Its hold
// action (server.dll 0x1804BA8C0) keeps whatever the gravity gun has picked up
// until it has something to throw at, and the report is that a bot sometimes
// stands there holding an explosive barrel and apparently never puts it down --
// which is the no target case, since a bot with something to throw at throws.
//
// The plugin cannot move the prop itself and has no server-side "let go" input
// to press, but it can press the gun's own throw key: launching what the claw
// holds is the one thing the engine's gun has been shown to do on a press (it
// is what the swing throws a caught frag with), and it is also what the bot
// meant to do with the prop in the first place.  So a hold that runs past
// PropHoldTime is ended with a press of IN_ATTACK, and the log says for how
// long it had been carried.  Which of the two cases above it was is still
// logged once at three seconds, along with whether a real player was in sight.
int   giHeldProp;
float gfHeldSince;
bool  gbHeldLogged;
bool  gbHoldThrow;    // the prop hold has run too long; press the throw key
int   giHoldDrops;    // how many forced throws have been logged
int   giHoldLogs;

// Where a forced throw is aimed.  The gun launches along the view, so the prop
// goes wherever the bot happens to be looking -- and a bot whose AI has it
// facing a wall two feet in front of it throws the barrel into that wall, which
// is the report this answers.  A line with room in it is chosen when the throw
// is armed (PickThrowPoint) and the view is put on it there; the command hook
// writes it again for the frame the key goes down, so the aim has a whole frame
// on the bot before the press -- the same gap the swing's turn-onto-the-thrower
// stage keeps, for the same reason.
float gfHoldThrowAt[3];
bool  gbHoldAimed;    // the aim has been on for a frame; the key goes down now

// The map's chargers and its physics props, found once, and what the watched
// bot does with either.
//
// The engine's own health action already has the chargers: the bot's GetHealth
// (the action module in server.dll) searches item_healthcharger,
// func_healthcharger and a "*charger*" wildcard beside the health kits, and
// answers a bot that was healed with "Health refilled by the Charger" and one
// standing at a dead charger with "Charger is out of juice!".  So the behaviour
// exists on the engine's side, and what was missing was any way to see whether
// it runs -- those answers go to the developer channel, and this server's log
// has never held one.  The evidence is gathered here instead: the bot standing
// at a charger, the bot's own command pressing the use key while it is there, and
// its health going up as it stands there.  The first line without the second
// means the engine never pressed the key; the second without the third means the
// charger refused.
//
// Nothing here presses that key.  The engine's action is the thing being
// measured, a press from this plugin would look exactly like the engine's in the
// log, and it would be the wrong answer if the engine turns out to be doing it
// already.  The levers that were moved instead are the engine's own, in
// cfg/xms_bots.cfg.
//
// The props are the other half of the same sweep and a different errand: a prop
// a player punts at the bot is worth a swing, and the list is what the search
// runs over (see FindIncomingProp).  The charger list is a snapshot of the map
// as it stood when the first bot thought, which is right -- a charger is part of
// the map's geometry and cannot appear later -- and it keeps the every-tick
// searches off the entity list.
//
// The prop list cannot stay a snapshot, and treating it as one is what made a
// bot ignore a barrel thrown at it: the props that get thrown in this game are
// `prop_physics_respawnable`, and a barrel that is destroyed and respawns does so
// as a *new* entity with a new index, which a one-time list does not have.  Every
// barrel that had been blown up and come back was therefore invisible to the
// search.  So the prop half is rebuilt on a timer instead; see PROP_SCAN_EVERY.
#define CHARGER_MAX   16      // chargers the list keeps
#define CHARGER_RANGE 100.0   // how close counts as standing at one
#define PROP_MAX      128     // props the list keeps
#define PROP_SCAN_EVERY 2.0   // seconds between rebuilds of the prop list

int  giChargers[CHARGER_MAX];
int  giChargerCount;
int  giChargerSeen;
int  giChargerHealth;
bool gbChargerPressed;
int  giChargerLogs;

// The refill line has its own budget.  It is the one line that proves the
// charger was actually used, and the two lines above it are the ones a bot
// standing next to a charger it cannot use spends -- sharing one counter let
// the visits eat the proof.  See WatchCharger.
int  giChargerHeals;

int  giProps[PROP_MAX];
int  giPropCount;
bool gbWorldScanned;
float gfPropsScanAt;   // when the prop list is next rebuilt

// The blunting itself is logged a few times, because the one thing the code
// cannot check about itself is which entity the engine names as the inflictor of
// a bullet -- and the whole attenuation hangs off that.
int  giDamageLogs;

// The gravity-gun swing.  The engine's own bot has no reflex for an incoming
// frag or combine ball -- a disassembly of server.dll shows its prop code only
// ever looking for something to take, and its ball handling reaches no further
// than precaching the class -- so the swing is driven from here.  What is
// driven is only the input side: the bot is turned onto the object, handed the
// physcannon, and made to press the attack key, and the engine's own weapon
// code does the claw, the pull and the launch.  That is the whole point of
// doing it this way: nothing in this plugin moves the object, so what the
// player sees is the game's gravity gun being used, not a plugin faking one.
//
// One object at a time, in stages.  Only the catch timer starts a swing and
// only the command hook advances one, because a bot's buttons exist nowhere
// else.
//
// The keys are the game's own: the physcannon takes hold of a physics object
// with IN_ATTACK2 and throws it with IN_ATTACK.  Both kinds of object go
// through the claw for that reason -- a frag is pulled in on the secondary key
// and launched on the primary, and a ball is asked for the same way, which is
// the only one of the gun's moves this build has been shown to answer.  The
// primary attack on an empty claw is tried as well if the claw lets the ball
// through, and the log says which of the two turned it.  Pressing the two keys
// the wrong way round is what made a caught frag fly off in whatever direction
// the bot was facing.
enum
{
    SWING_NONE = 0,   // not swinging
    SWING_ARM,        // waiting for the physcannon to come up
    SWING_GRAB,       // the gun is asked to take it, once it is close enough
    SWING_TAKE,       // waiting for the engine's claw to close on it
    SWING_TURN,       // it is held; turning onto whoever threw it
    SWING_PUNT        // the key is down, or is about to go down
};

// What the swing is for.  All three are taken with the claw and thrown with the
// primary key; the difference is only what "back" means and what the log calls
// them.  A frag is thrown at whoever threw it.  A ball is thrown the same way
// when the claw takes it, and is watched for the engine having swatted it
// instead.  A prop is whatever a player punted at the bot -- a barrel, a crate --
// and it goes back the same way a frag does.
enum
{
    SWING_KIND_FRAG = 0,  // reel it in, then throw it back at the thrower
    SWING_KIND_BALL,      // take it, or have it swatted, and send it back
    SWING_KIND_PROP       // a thrown prop: claw it in, then punt it back
};

// What the swing is carrying, for the lines that have to say it.  A prop and a
// frag travel the same road; only the word differs.
void SwingObjectName(int iKind, char[] sOut, int iMaxLen)
{
    if (iKind == SWING_KIND_BALL) {
        Format(sOut, iMaxLen, "ball");
    }
    else if (iKind == SWING_KIND_PROP) {
        Format(sOut, iMaxLen, "prop");
    }
    else {
        Format(sOut, iMaxLen, "frag");
    }
}

int   giSwingEnt;             // the object being handled
int   giSwingStage = SWING_NONE;
int   giSwingKind;            // SWING_KIND_FRAG or SWING_KIND_BALL
int   giSwingTarget;          // who to send it back at, 0 for "the way it came"
int   giSwingTries;           // how often the gun has been asked for
int   giSwingRecover;         // frames the gun had to be taken back out again
int   giSwingPresses;         // how many times the attack key has gone down
int   giSwingAway;            // frames in a row the object has been getting further off
bool  gbSwingKey;             // the attack key is down at the end of this frame
bool  gbSwingClawTried;       // a ball has already been given the point-blank claw
float gfSwingAskAt;           // when the physcannon may next be asked for
float gfSwingPressAt;         // when the attack key may next be pressed
float gfSwingDeadline;        // the current stage gives up at this time
float gfSwingStart;           // when the swing started, for the log
float gfSwingLastDist;        // how far off the object was on the last frame
float gfSwingAimSet;          // the time the return aim was put on the thrower
float gfSwingDir[3];          // the way it came in, for a throw with nobody to aim at
float gfSwingRange;           // close enough for the gun's own trace to reach it

// The gun's own reach, read from physcannon_tracelength rather than assumed,
// so a server that retunes the gravity gun retunes the swing with it.  A swing
// only starts inside this, because the engine can only take what it can trace
// to.
float gfSwingReach = 250.0;

// The point the bot's view is being held on, and the time that hold ends.  Its
// own aiming writes the view angles every frame, so a hold set once is lost
// again immediately -- this is re-applied per frame for as long as it lasts.
float gfAimPoint[3];
float gfAimUntil;

// Frames the per-frame aim hook has run for the bot, shown by sm_bots: if this
// does not climb, the hook does not fire for these bots and the aim is only
// being set from the catch timer.
int giAimTicks;

/**************************************************************
 * WHY THIS DRIVES THE BUILT-IN BOTS
 *
 * HL2DM's own bots (CHL2MPBot, the hl2mp_bot_* cvars) are shipped
 * with the game, so unlike RCBot2 they need nothing installed and
 * they work on a 64-bit server.
 *
 * Two things make them look broken out of the box:
 *
 * 1. They are NextBots, so they cannot path without a navigation
 *    mesh. Some installed maps ship one and some do not, and the
 *    engine generates none on its own -- without maps/<map>.nav a
 *    bot spawns and then stands still. CheckNavMesh() says so in the
 *    log, and with "NavGenerate" set in the config it runs
 *    nav_generate for the map instead of only complaining.
 *
 * 2. hl2mp_bot_prop_freak_ratio defaults to 0.3, so only the bots
 *    that roll high ever go looking for something to pick up with
 *    the gravity gun. cfg/xms_bots.cfg, executed on every map
 *    start, raises it.
 *
 * Beyond that bookkeeping this plugin does four things the bot cannot
 * do for itself, all of them shaping the fight rather than the bot's
 * decisions:
 *
 * - "AutoBhop" (Bots section) makes the bot bunnyhop: it jumps the
 *   moment it lands and, in the air, strafes across its own velocity
 *   the way a TAS does, so it keeps gaining speed instead of shedding
 *   it to ground friction.  Only the move in its command is written --
 *   the engine's own movement code does the accelerating, and the view
 *   is left alone so the bot's aim solver and its own steering still
 *   work.  "BhopMaxSpeed" caps how fast it will strafe up to and
 *   "BhopAngle" trades gain for a straighter line.  0 disables it.
 * - "DamagePercent" (Bots section) blunts the damage the bot's own
 *   guns do to a real player.  What it picks up and throws is
 *   exempt, so the bot loses firepower without losing its signature
 *   move.
 * - "CatchRadius" (Bots section) lets it answer what is thrown at it:
 *   a grenade closing on the bot is caught with the gravity gun and
 *   launched back, and an incoming combine ball is batted out of the air.
 *   0 disables both.  The swing is not physics written by this plugin --
 *   it is input handed to the engine, which is what makes it look like a
 *   gravity gun instead of like a force field: the bot equips
 *   weapon_physcannon, turns onto the object, and presses the attack key,
 *   and the engine's own weapon code closes the claw, pulls the object in
 *   and launches it.  The radius is how early the bot starts watching and
 *   how early it brings the gun out; the key itself is only pressed
 *   inside the gun's own reach (physcannon_tracelength, 250 units, read
 *   at map start rather than assumed, and capped by "GrabRange").  A ball
 *   is asked for the same way as a frag; if the claw lets it through, the
 *   empty claw's primary attack is tried once as well, and whichever of
 *   the two turns it is what the log reports.  What counts as incoming
 *   is the object's own motion rather than who threw it: a frag the bot
 *   threw itself is leaving, so it is never caught, and a frag's thrower
 *   field on this build reads as junk.  The bot is turned onto the
 *   object for the whole swing, because the engine aims it at its enemy
 *   every frame and a gravity gun traces along the view -- left alone it
 *   would swing at whatever it was looking at, which is not the object.
 *   A returned frag goes at the thrower, or, with nobody to name, back
 *   out along the line it came in on.
 * - "Model" (Bots section) pins the body it wears.  A fake client has
 *   no cl_playermodel of its own and HL2DM picks the model from that
 *   convar, so an unset value leaves the bot changing model from one
 *   spawn to the next.  The game also re-picks the body about once a
 *   second while the bot is alive, so the pin is re-applied whenever
 *   the body has drifted back -- setting it at spawn alone does not
 *   hold.  Empty leaves the choice to the game.
 *
 * Bhop and damage leave the bot's aim solver and its weapon choice
 * alone.  The catch does not: a swing needs a particular weapon in hand
 * and a particular direction of view, so for the second or so it lasts
 * it takes both.  Between swings the bot is untouched.
 *
 * One engine quirk is unavoidable: once a bot has been added on a
 * map, the engine re-runs its own bot join every few hundred ms and
 * logs "HandleCommand_JoinTeam( 0 ) - invalid team index." each
 * time, even after the bot is kicked. It costs nothing but console
 * noise, and a map change clears it.
 *************************************************************/

public void OnPluginStart()
{
    LoadTranslations("xms_bot.phrases.txt");

    CreateConVar("xms_bots_version", PLUGIN_VERSION, _, FCVAR_NOTIFY);
    CreateTimer(1.0, T_CheckBots, _, TIMER_REPEAT);

    gNavPassSeen  = new StringMap();
    gNavPassAsked = new StringMap();

    // 20 Hz rather than 10: a thrown combine ball crosses the whole catch
    // radius in about a quarter of a second, so at 10 Hz there were only two
    // or three ticks in which a swing could be started at all.
    CreateTimer(0.05, T_BotCatch, _, TIMER_REPEAT);

    // Damage is hooked on whoever takes it, so hook anyone already here -- a
    // late plugin load would otherwise leave them unblunted.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsClientSourceTV(i)) {
            SDKHook(i, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
        }
    }

    RegAdminCmd("sm_bots", Cmd_Bots, ADMFLAG_GENERIC, "List the bots in game, or add/kick one: sm_bots [add|kick]");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    if (LibraryExists("updater")) {
        Updater_AddPlugin(PLUGIN_UPDATE);
    }
}

public void OnLibraryAdded(const char[] sName)
{
    if (StrEqual(sName, "updater")) {
        Updater_AddPlugin(PLUGIN_UPDATE);
    }
}

public void OnAllPluginsLoaded()
{
    gbEnabled = BotsAvailable();
}

public void OnMapStart()
{
    gbEnabled  = BotsAvailable();
    gbSourceTV = FindConVar("tv_enable").BoolValue;

    // The gun's reach is the swing's own limit, so it is taken from the gun.
    ConVar hReach = FindConVar("physcannon_tracelength");

    if (hReach != null) {
        gfSwingReach = hReach.FloatValue;
    }

    // The attack key only does anything inside that trace, and the margin is
    // for the object's own size and for the frame between pressing and the
    // engine tracing.  A "GrabRange" in the config can only shorten it.
    gfSwingRange = gfSwingReach * 0.85;

    if (giGrabRange > 0 && float(giGrabRange) < gfSwingRange) {
        gfSwingRange = float(giGrabRange);
    }

    // A swing cannot survive a map change: the object is gone and so is the
    // command that was going to press the key.
    giSwingStage  = SWING_NONE;
    giSwingEnt    = 0;
    giSwingTarget = 0;
    giSwingPresses = 0;
    gbSwingKey    = false;

    ReadNavPass();

    if (gbEnabled)
    {
        // bot behaviour cvars are reset on every map, so re-apply them
        ServerCommand("exec xms_bots.cfg");

        // The walk does its own generating, so the single-map complaint would
        // only be a second, wrong answer about the same map.
        if (!gbNavPassOn) {
            CheckNavMesh();
        }
    }

    // The walk is about the maps rather than the bots, so it runs whatever the
    // mode is and whether or not the bots are wanted on it.
    if (gbNavPassOn) {
        NavPass();
    }

    // Precached outside the bot check above, because a bot added by hand with
    // sm_bots is pinned too.  Precaching here is what keeps the per-spawn
    // SetEntityModel from being a late precache.
    giBotModelIndex = 0;

    if (gsBotModel[0]) {
        giBotModelIndex = PrecacheModel(gsBotModel);
    }

    giBotSoundType  = SoundTypeForModel(gsBotModel);
    giLastSequence  = 0;
    giBodyLogs      = 0;
    giSequenceLogs  = 0;
    giSwitchLogs    = 0;
    giDamageLogs    = 0;
    giHoldLogs      = 0;
    giHoldDrops     = 0;
    giHeldProp      = 0;
    gbHeldLogged    = false;
    gbHoldThrow     = false;
    gbHoldAimed     = false;
    gbVoiceLogged   = false;

    // What was said about a frag on the last map says nothing about this one --
    // the index it was said about can hold anything now -- so the frag lines are
    // all owed again.  The charger and prop lists are rebuilt the same way, on
    // the first tick a bot is here to look: see ScanWorld.
    for (int i = 0; i < FRAG_TRACK_MAX; i++) {
        gbFragSaid[i] = false;
    }

    gbWorldScanned   = false;
    giChargerCount   = 0;
    giPropCount      = 0;
    gfPropsScanAt    = 0.0;
    giChargerSeen    = 0;
    giChargerHealth  = 0;
    gbChargerPressed = false;
    giChargerLogs    = 0;
    giChargerHeals   = 0;
}

// The game's own SetPlayerSoundType, which a fake client never reaches.  It
// tests the model path for "human", then "police", then "combine", leaves the
// value alone if none of them match, and is case-insensitive -- combine models
// are spelled "Combine", so an exact-case match would never fire.
int SoundTypeForModel(const char[] sModel)
{
    if (sModel[0] == '\0') {
        return -1;
    }

    if (StrContains(sModel, "models/human", false) != -1) {
        return 0;
    }

    if (StrContains(sModel, "police", false) != -1) {
        return 2;
    }

    if (StrContains(sModel, "combine", false) != -1) {
        return 1;
    }

    return -1;
}

public void OnMapEnd()
{
    giBotClient   = 0;
    gfAimUntil    = 0.0;
    giAimTicks    = 0;
    giSwingStage  = SWING_NONE;
    giSwingEnt    = 0;
    giSwingTarget = 0;
    giSwingPresses = 0;
    gbSwingKey    = false;
}

public void OnClientPutInServer(int iClient)
{
    if (!IsClientSourceTV(iClient)) {
        SDKHook(iClient, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
    }

    // Pin the model before the first spawn, so the game never has to pick one.
    if (IsFakeClient(iClient) && !IsClientSourceTV(iClient)) {
        PinBotModel(iClient);

        // Hooking the bot's own think is the only way to hold its view on
        // something: the hook runs after the engine's bot has aimed, so the
        // angle written here is the one that survives the frame.
        SDKHook(iClient, SDKHook_PostThinkPost, Hook_BotThink);

        // A swing is several frames long and the engine's bot re-picks a weapon
        // every frame, so the gun has to be kept in its hands while one is in
        // progress; see Hook_BotWeaponSwitch.
        SDKHook(iClient, SDKHook_WeaponSwitch, Hook_BotWeaponSwitch);
    }

    if (gbEnabled && IsClientInGame(iClient) && IsFakeClient(iClient) && !IsClientSourceTV(iClient))
    {
        giBotClient = iClient;
        GetClientName(giBotClient, gsBotName, sizeof(gsBotName));
        CreateTimer(2.0, T_BotAnnounce, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnClientDisconnected(int iClient)
{
    // the bot can also be removed by the engine, not only by us
    if (iClient == giBotClient) {
        giBotClient = FindBotClient();
    }
}

public Action OnClientSayCommand(int iClient, const char[] sCommand, const char[] sArgs)
{
    if (!iClient || giBotClient <= 0 || !IsClientInGame(giBotClient)) {
        return Plugin_Continue;
    }

    if (StrContains(sArgs, "!") != 0 && StrContains(sArgs, "/") != 0 && !CommandExists(sArgs))
    {
        // not a command

        if (StrContains(sArgs, gsBotName, false) != -1 || Math_GetRandomInt(1, 2) == 2)
        {
            // Reply to 50% of chat, or if bot name is said
            CreateTimer(1.0, T_BotResponse, TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    return Plugin_Continue;
}

public void OnGamestateChanged(int iNewState, int iOldState)
{
    if (iNewState == GAME_OVER)
    {
        if (giBotClient > 0 && IsClientInGame(giBotClient))
        {
            char sText[MAX_SAY_LENGTH];

            Format(sText, sizeof(sText), "xms_bot_end%i", Math_GetRandomInt(1, 2));
            Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);

            MC_PrintToChatAllFrom(giBotClient, false, sText);
        }
    }
    else if (iOldState == GAME_CHANGING)
    {
        gbContinue = (giBotClient > 0 && IsClientInGame(giBotClient));
    }

    giState = iNewState;
}

public Action T_CheckBots(Handle hTimer)
{
    if (gbEnabled && (GetTimeElapsed() >= giJoinDelay || gbContinue))
    {
        int iTotal       = GetClientCount2(true, true) - view_as<int>(gbSourceTV);
        int iPlayers     = GetClientCount2(true, false);
        int iConnecting  = GetClientCount2(false, false) - iPlayers;

        if (iPlayers == 1)
        {
            if (!iConnecting && giBotClient == 0)
            {
                giBotClient = -1;
                CreateTimer(1.0, T_BotAdd, _, TIMER_FLAG_NO_MAPCHANGE);
            }
        }
        else if (giBotClient)
        {
            CreateTimer(view_as<float>(clamp(giLeaveDelay, 0, 999)), T_BotRemove, _, TIMER_FLAG_NO_MAPCHANGE);
        }

        if (iTotal > iPlayers + 1)
        {
           LogMessage("More bots spawned than expected, kicking..");
           KickBots();
           giBotClient = FindBotClient();
        }
    }

    return Plugin_Continue;
}

public Action T_BotAdd(Handle hTimer)
{
    if (GetClientCount2(true, false) == 1 && giState == GAME_DEFAULT) {
        AddBot();
    }

    return Plugin_Handled;
}

public Action T_BotAnnounce(Handle hTimer)
{
    static int iTimer;
    static int iRan;

    if (giBotClient > 0 && IsClientInGame(giBotClient))
    {
        char sText[MAX_SAY_LENGTH];

        iRan = Math_GetRandomIntNot(1, 3, iRan);

        if (gbContinue)
        {
            char sMap[MAX_MAP_LENGTH];

            GetCurrentMap(sMap, sizeof(sMap));

            Format(sText, sizeof(sText), "xms_bot_%sknownmap%i", NavMeshExists(sMap) ? "" : "un", iRan);
            Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
            MC_PrintToChatAllFrom(giBotClient, false, sText);

            return Plugin_Stop;
        }
        else
        {
            if (iTimer == 0)
            {
                Format(sText, sizeof(sText), "xms_bot_greet%i", iRan);
                Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
                MC_PrintToChatAllFrom(giBotClient, false, sText);
            }
            else if (iTimer >= 2)
            {
                Format(sText, sizeof(sText), "xms_bot_play%i", iRan);
                Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
                MC_PrintToChatAllFrom(giBotClient, false, sText);

                iTimer = 0;
                return Plugin_Stop;
            }

            iTimer++;
        }
    }

    return Plugin_Continue;
}

public Action T_BotRemove(Handle hTimer)
{
    static int iRan;

    if (GetClientCount2(true, false) != 1 && giState == GAME_DEFAULT)
    {
        if (giBotClient > 0 && IsClientInGame(giBotClient))
        {
            char sText[MAX_SAY_LENGTH];

            iRan = Math_GetRandomIntNot(1, 3, iRan);

            Format(sText, sizeof(sText), "xms_bot_quit%i", iRan);
            Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
            MC_PrintToChatAllFrom(giBotClient, false, sText);

            KickBots();
            giBotClient = 0;
        }
    }

    return Plugin_Handled;
}

public Action T_BotTaunt(Handle hTimer)
{
    static int iText;

    if (giBotClient > 0 && IsClientInGame(giBotClient))
    {
        char sText[MAX_SAY_LENGTH];

        iText = Math_GetRandomIntNot(1, 6, iText);

        Format(sText, sizeof(sText), "xms_bot_taunt%i", iText);
        Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
        MC_PrintToChatAllFrom(giBotClient, false, sText);
    }

    return Plugin_Stop;
}

public Action T_BotDeath(Handle hTimer, bool bSuicide)
{
    static int iText;

    if (giBotClient > 0 && IsClientInGame(giBotClient))
    {
        char sText[MAX_SAY_LENGTH];

        iText = Math_GetRandomIntNot(1, bSuicide ? 3 : 6, iText);

        Format(sText, sizeof(sText), "xms_bot_%s%i", bSuicide ? "suicide" : "death", iText);
        Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
        MC_PrintToChatAllFrom(giBotClient, false, sText);
    }

    return Plugin_Stop;
}

public Action T_BotResponse(Handle hTimer)
{
    static int iText;

    if (giBotClient > 0 && IsClientInGame(giBotClient))
    {
        char sText[MAX_SAY_LENGTH];

        iText = Math_GetRandomIntNot(1, 7, iText);

        Format(sText, sizeof(sText), "xms_bot_response%i", iText);
        Format(sText, sizeof(sText), "%T", sText, LANG_SERVER);
        MC_PrintToChatAllFrom(giBotClient, false, sText);
    }

    return Plugin_Stop;
}

public Action Event_PlayerDeath(Event hEvent, const char[] sEvent, bool bDontBroadcast)
{
    if (!gbEnabled || !giBotClient) {
        return Plugin_Continue;
    }

    bool bBotAttacker = (giBotClient == GetClientOfUserId(GetEventInt(hEvent, "attacker")));
    bool bBotVictim   = (giBotClient == GetClientOfUserId(GetEventInt(hEvent, "userid")));

    if (bBotAttacker && bBotVictim)
    {
        // suicide
        CreateTimer(1.0, T_BotDeath, true, TIMER_FLAG_NO_MAPCHANGE);
    }
    else if (bBotAttacker)
    {
        // player killed by bot, 33% chance to taunt
        if (Math_GetRandomInt(1, 3) == 1) {
            CreateTimer(1.0, T_BotTaunt, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    else if (bBotVictim)
    {
        // bot killed by player, 33% chance to comment
        if (Math_GetRandomInt(1, 3) == 1) {
            CreateTimer(1.0, T_BotDeath, false, TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    return Plugin_Continue;
}

public void Event_PlayerSpawn(Event hEvent, const char[] sEvent, bool bDontBroadcast)
{
    int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));

    if (iClient > 0 && IsFakeClient(iClient) && !IsClientSourceTV(iClient)) {
        PinBotModel(iClient);
    }
}

// A bot is a fake client, so it has no cl_playermodel of its own -- and that
// convar is where the game reads a player's model from.  Unset, the body is
// picked at random and re-picked about once a second, so the bot is seen
// changing model as it plays.  Both halves are set here: the convar the game
// reads, and the model itself, which is what other players actually see.  That
// alone only covers the spawn, because the game re-picks afterwards as well --
// Hook_BotThink puts the model back when it drifts.
void PinBotModel(int iClient)
{
    if (gsBotModel[0] == '\0') {
        return;
    }

    SetFakeClientConVar(iClient, "cl_playermodel", gsBotModel);

    // A sequence remembered against some other body says nothing about this one.
    giLastSequence = 0;

    if (IsPlayerAlive(iClient)) {
        SetEntityModel(iClient, gsBotModel);
    }

    PinBotVoice(iClient);
}

// A bot's footsteps and death lines come from m_iPlayerSoundType, and the game
// only ever writes it from the client-driven model path -- the same path a fake
// client never takes for its model.  Left unwritten it keeps its default
// 0 = NPC_Citizen, which is a human voice, so a bot in a Combine body was heard
// walking and dying as a citizen.  The value is the one the game would have
// picked for the model it is wearing, set now and put back by Hook_BotThink if
// the game rewrites it.
//
// The game reaches the property through a raw offset, so the plugin has to look
// the name up -- and this is the one place that says so if it is not there.
void PinBotVoice(int iClient)
{
    if (giBotSoundType < 0) {
        return;
    }

    if (!HasEntProp(iClient, Prop_Send, "m_iPlayerSoundType")) {
        LogMessage("[XMS] no m_iPlayerSoundType on a client in this build; the bot voice is left to the game");
        giBotSoundType = -1;
        return;
    }

    // Logged on the change, so one line says the property is real, that it was
    // the citizen default, and what it is now -- and a respawn says nothing.
    if (GetEntProp(iClient, Prop_Send, "m_iPlayerSoundType") != giBotSoundType) {
        SetEntProp(iClient, Prop_Send, "m_iPlayerSoundType", giBotSoundType);
        LogMessage("[XMS] bot voice pinned to sound type %d", giBotSoundType);
    }
}

// Turns the bot to look at a point for the next fHold seconds.  A frag coming
// at it or a combine ball being batted back should be something the bot is
// visibly aiming at, which is what the gravity-gun catch looks like from the
// outside -- and the throw itself is solved ballistically, so the view has no
// say in whether it lands.
void AimBotAt(const float fTarget[3], float fHold)
{
    gfAimPoint   = fTarget;
    gfAimUntil   = GetGameTime() + fHold;

    ApplyBotAim();
}

void ApplyBotAim()
{
    float fBot[3], fDir[3], fAngles[3];

    if (giBotClient <= 0 || !IsClientInGame(giBotClient) || !IsPlayerAlive(giBotClient)) {
        return;
    }

    GetClientEyePosition(giBotClient, fBot);
    SubtractVectors(gfAimPoint, fBot, fDir);
    GetVectorAngles(fDir, fAngles);

    TeleportEntity(giBotClient, NULL_VECTOR, fAngles, NULL_VECTOR);
}

public Action Hook_BotThink(int iClient)
{
    if (iClient != giBotClient) {
        return Plugin_Continue;
    }

    giAimTicks++;

    if (GetGameTime() < gfAimUntil) {
        ApplyBotAim();
    }

    // The game re-picks a fake client's body roughly once a second for as long as
    // the bot is alive -- not just when it spawns -- so a model set once drifts
    // back to a random citizen within the second.  It is put back here, after the
    // bot has thought and before the frame is sent, which is why the pin holds.
    // The index is checked first so an undisturbed frame costs one property read.
    //
    // The pin used to stop at death, and that is what "the bot sometimes changes
    // model when it dies" turned out to be: the game's own re-pick does not stop
    // at death, and the body the bot is wearing when it dies is the one its
    // ragdoll is made from -- so a re-pick that lands between the last living
    // frame and the ragdoll is a corpse in the wrong body.  The model is put back
    // on a dead bot as well now, and the log says when that happened.
    if (giBotModelIndex
        && GetEntProp(iClient, Prop_Send, "m_nModelIndex") != giBotModelIndex)
    {
        bool bAlive  = IsPlayerAlive(iClient);
        bool bGround = (GetEntityFlags(iClient) & FL_ONGROUND) != 0;
        char sPicked[PLATFORM_MAX_PATH];
        sPicked[0] = '\0';

        if (giBodyLogs < 25) {
            GetEntPropString(iClient, Prop_Data, "m_ModelName", sPicked, sizeof(sPicked));
        }

        SetEntityModel(iClient, gsBotModel);

        if (giBodyLogs < 25) {
            giBodyLogs++;
            LogMessage("[XMS] bot body re-picked by the game (%s, it had chosen %s), pinned back",
                       bAlive ? (bGround ? "on the ground" : "in the air") : "dead", sPicked);
        }
    }

    // Whatever set the model -- the game's re-pick just above, or the pin that
    // answered it -- restarted the animation at sequence 0, so the bot is in the
    // reference pose until its activity next changes.  In the air the jump's
    // activity does not change, which is where the T-shape comes from.  The last
    // sequence the bot was actually playing is a valid pose for the body it wears
    // either way, so it is put back and the animation carries on from there.
    // Sequence 0 is not a pose a player is ever meant to be seen in, so this
    // only ever repairs -- and it is not conditioned on the model having been
    // re-picked, because a model set to the value it already had resets the
    // animation just the same without changing the index.
    if (IsPlayerAlive(iClient)) {
        int iSequence = GetEntProp(iClient, Prop_Send, "m_nSequence");

        if (iSequence != 0) {
            giLastSequence = iSequence;
        } else if (giLastSequence != 0) {
            SetEntProp(iClient, Prop_Send, "m_nSequence", giLastSequence);

            if (giSequenceLogs < 10) {
                giSequenceLogs++;
                LogMessage("[XMS] bot animation reset to the reference pose (%s), put back to sequence %d",
                           (GetEntityFlags(iClient) & FL_ONGROUND) ? "on the ground" : "in the air",
                           giLastSequence);
            }
        }
    }

    // The game's model refresh is what writes the voice, so that pin is
    // re-asserted after it -- same reason, same place.
    if (giBotSoundType >= 0
        && GetEntProp(iClient, Prop_Send, "m_iPlayerSoundType") != giBotSoundType)
    {
        SetEntProp(iClient, Prop_Send, "m_iPlayerSoundType", giBotSoundType);

        if (!gbVoiceLogged) {
            gbVoiceLogged = true;
            LogMessage("[XMS] bot voice re-picked by the game, pinned back to sound type %d",
                       giBotSoundType);
        }
    }

    return Plugin_Continue;
}

// Auto-bunnyhop: the bot jumps again the moment it lands and, in the air, moves
// across its own velocity at the angle that adds the most speed.  This is the input
// half of what a TAS does, so the engine's own movement code still does the
// accelerating and the physics stay the game's rather than a reimplementation.
//
// The view is left alone.  A TAS steers with the strafe key and its own eyes, but a
// bot's eyes are its movement: its command asks to walk "forward" and the engine
// reads that against the view, so turning the view would send the bot wherever it
// happened to be drifting instead of where its AI wanted to go.  Instead the move
// pair is written straight out, which reaches the same wish direction without the
// bot ever losing sight of where it is going -- or of what it is shooting at.
float NormalizeAngle(float fAngle)
{
    while (fAngle > 180.0) {
        fAngle -= 360.0;
    }

    while (fAngle < -180.0) {
        fAngle += 360.0;
    }

    return fAngle;
}

public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, float fVel[3],
                             float fAngles[3], int &iWeapon, int &iSubtype, int &iCmdnum,
                             int &iTickcount, int &iSeed, int iMouse[2])
{
    if (iClient != giBotClient) {
        return Plugin_Continue;
    }

    bool bChanged = false;

    // The engine fires on the *edge* of the attack key, and a bot's command
    // keeps its buttons from one frame to the next, so a key this plugin
    // pressed would stay down and the next press would never count.  It is
    // lifted on the frame after the press, which is what makes the press after
    // it a real edge.  This runs whether or not a swing is still going, because
    // the last press of a swing lands on the same frame the swing ends.
    if (gbSwingKey)
    {
        iButtons &= ~(IN_ATTACK | IN_ATTACK2);
        gbSwingKey = false;
        bChanged   = true;
    }

    if (!IsPlayerAlive(iClient)) {
        return bChanged ? Plugin_Changed : Plugin_Continue;
    }

    // What the bot does at a charger, watched and never driven; see the note on
    // giChargers.
    WatchCharger(iClient, iButtons);

    // The swing goes first: it may want the view, and the bunnyhop reads the
    // view back out of the command.
    if (DriveSwing(iClient, iButtons, fAngles)) {
        bChanged = true;
    }
    // A prop hold that has run past PropHoldTime is ended by pressing the gun's
    // own throw key.  The bit is left up for this frame only -- gbSwingKey is
    // what lifts it on the next one, and that lift is what makes this a press
    // rather than a held key the engine would ignore.
    //
    // The press is one frame behind the aim on purpose.  The gun launches along
    // the view the engine is holding, and that view is what the bot's own AI
    // aims every frame, so aiming and pressing on one frame is pressing along
    // the aim the bot had a moment ago -- which is the barrel-into-the-wall bug.
    // This is the same one-frame gap the swing's turn-onto-the-thrower stage
    // keeps, for the same reason.
    else if (gbHoldThrow && giSwingStage == SWING_NONE)
    {
        if (!gbHoldAimed)
        {
            // The frame the aim goes on.  Nothing is pressed yet.
            gbHoldAimed = true;
            FacePoint(iClient, gfHoldThrowAt, fAngles);
            bChanged = true;
        }
        else
        {
            // The frame the key goes down.  The gun can have been put away since
            // the aim was taken -- the bot's AI picks a weapon for itself every
            // frame -- and a holstered gun lets go of whatever the claw holds,
            // so there may be nothing left to throw and a press would fire
            // whatever is in the bot's hands instead.
            char sHeld[64];

            gbHoldThrow = false;
            gbHoldAimed = false;

            if (PhyscannonInHand(iClient) && PropInClaw(iClient, sHeld, sizeof(sHeld)) != 0)
            {
                FacePoint(iClient, gfHoldThrowAt, fAngles);

                gbSwingKey = true;
                iButtons  |= IN_ATTACK;
                bChanged   = true;
            }
        }
    }

    if (!gbAutoBhop) {
        return bChanged ? Plugin_Changed : Plugin_Continue;
    }

    float fVelocity[3];
    GetEntPropVector(iClient, Prop_Data, "m_vecVelocity", fVelocity);

    float fSpeed = SquareRoot(fVelocity[0] * fVelocity[0] + fVelocity[1] * fVelocity[1]);

    // Always start from a released jump so the press below is a real edge.
    iButtons &= ~IN_JUMP;

    if (GetEntityFlags(iClient) & FL_ONGROUND)
    {
        // The engine jumps on the *edge* of IN_JUMP, and a bot's command keeps its
        // buttons from one frame to the next -- so a bit that is already held stays
        // held and is never counted as a press.  A bot can therefore sit there with
        // IN_JUMP down and never leave the ground.  Releasing it on alternate frames
        // is what makes a press available again, and a fresh press is exactly what a
        // bunnyhop needs on landing anyway.
        if (gbJumpFlip = !gbJumpFlip) {
            iButtons |= IN_JUMP;
        }
    }
    else if (fSpeed >= 1.0 && (giBhopMaxSpeed <= 0 || fSpeed <= float(giBhopMaxSpeed)))
    {
        float fVelYaw = ArcTangent2(fVelocity[1], fVelocity[0]);
        float fViewYaw = DegToRad(fAngles[1]);

        // The direction the bot's own command asks to go in.  Its move pair is read
        // against the view, so forward is the view yaw; side and forward together
        // tilt that.  This is the bot's AI steering, kept as is.
        float fMove = SquareRoot(fVel[0] * fVel[0] + fVel[1] * fVel[1]);
        float fHeading = fViewYaw;

        if (fMove > 0.0) {
            fHeading = fViewYaw - ArcTangent2(fVel[1], fVel[0]);
        }

        // Push across the velocity on the side that bends it toward that heading.
        // Sideways is also what keeps the air-accelerate cap from biting: going
        // straight adds nothing above 30 u/s, while a perpendicular push adds the
        // full 30 -- which is the whole trick.  As the velocity turns onto the
        // heading the side flips on its own, so the speed climbs without the bot
        // wandering off.
        float fTurn = NormalizeAngle(RadToDeg(fHeading - fVelYaw));
        float fOffset = (fTurn >= 0.0) ? (90.0 - float(giBhopAngle)) : -(90.0 - float(giBhopAngle));
        float fPush = fVelYaw + DegToRad(fOffset);

        // Written as the move pair in the bot's own view frame: forward is the view
        // yaw and right is 90 degrees clockwise of it, so the wish direction the
        // engine will build is fPush.  450 is its full stride; keeping the length
        // there is what makes the push as strong as it can be.
        fVel[0] = 450.0 * Cosine(fPush - fViewYaw);
        fVel[1] = -450.0 * Sine(fPush - fViewYaw);
    }

    return bChanged ? Plugin_Changed : Plugin_Continue;
}

bool BotsAvailable()
{
    static bool bBotSupport;

    char sCurrentMode   [MAX_MODE_LENGTH];
    char sSupportedModes[192];

    if (!bBotSupport)
    {
        // the built-in bots are part of the game, so their cvars are the test
        if (FindConVar("hl2mp_bot_quota") != null) {
            bBotSupport = true;
        }
        else {
            LogError("The built-in HL2MP bots are not available on this server");
        }
    }

    if (bBotSupport)
    {
        GetGamemode(sCurrentMode, sizeof(sCurrentMode));
        if (GetConfigString(sSupportedModes, sizeof(sSupportedModes), "Gamemodes", "Bots"))
        {
            giJoinDelay  = GetConfigInt("JoinDelay", "Bots");
            giLeaveDelay = GetConfigInt("QuitDelay", "Bots");

            // GetConfigInt gives 0 for a key that is not there, which for both
            // of these means "leave it off" rather than "nerf it to nothing".
            int iDamage = GetConfigInt("DamagePercent", "Bots");
            giDamagePercent = (iDamage > 0 && iDamage <= 100) ? iDamage : 100;

            giCatchRadius = GetConfigInt("CatchRadius", "Bots");
            if (giCatchRadius < 0) {
                giCatchRadius = 0;
            }

            // Read here and put against the gun's reach in OnMapStart, because
            // the reach is only known once the map has loaded.
            giGrabRange = GetConfigInt("GrabRange", "Bots");
            if (giGrabRange < 0) {
                giGrabRange = 0;
            }

            // Both absent-as-off: no limit on the hold, and no generating.
            giPropHoldTime = GetConfigInt("PropHoldTime", "Bots");
            if (giPropHoldTime < 0) {
                giPropHoldTime = 0;
            }

            gbNavGenerate = GetConfigInt("NavGenerate", "Bots") != 0;

            // An absent key reads as 0, which is the off value for the first two
            // and the fastest strafe for the third, so each is only clamped.
            gbAutoBhop     = GetConfigInt("AutoBhop", "Bots") != 0;

            giBhopMaxSpeed = GetConfigInt("BhopMaxSpeed", "Bots");
            if (giBhopMaxSpeed < 0) {
                giBhopMaxSpeed = 0;
            }

            giBhopAngle = GetConfigInt("BhopAngle", "Bots");
            giBhopAngle = clamp(giBhopAngle, 0, 89);

            // Anything but a value leaves the model to the game.
            gsBotModel[0] = '\0';
            GetConfigString(gsBotModel, sizeof(gsBotModel), "Model", "Bots");

            if (IsItemInList(sCurrentMode, sSupportedModes)) {
                return true;
            }
        }
    }

    return false;
}

bool NavMeshExists(const char[] sMap)
{
    char sPath[PLATFORM_MAX_PATH];

    Format(sPath, sizeof(sPath), "maps/%s.nav", sMap);

    return FileExists(sPath, true);
}

void CheckNavMesh()
{
    char sMap[MAX_MAP_LENGTH];

    GetCurrentMap(sMap, sizeof(sMap));

    if (NavMeshExists(sMap)) {
        return;
    }

    // Generating takes the map down and puts it back up, so it is not done to
    // people who are playing.  Whoever is on gets the complaint instead.
    if (!gbNavGenerate || RealPlayerPresent())
    {
        LogError("No navigation mesh for %s -- the bots will spawn but cannot move or reach props. Generate one with: nav_generate", sMap);
        return;
    }

    // nav_generate finishes by reloading the map, so this function is looked at
    // again afterwards.  Seeing the same map twice means the generation did not
    // produce a mesh, and asking a second time would reload the map forever.
    if (StrEqual(sMap, gsNavTried))
    {
        LogError("nav_generate produced no navigation mesh for %s -- giving up, run it by hand", sMap);
        return;
    }

    strcopy(gsNavTried, sizeof(gsNavTried), sMap);

    LogMessage("[XMS] generating a navigation mesh for %s (the map will reload)", sMap);

    // nav_generate is behind sv_cheats, and the reload at the end of it clears
    // the flag again -- the second command is there for the case where the
    // generation turns out not to reload at all.
    ServerCommand("sv_cheats 1");
    ServerCommand("nav_generate");
    ServerCommand("sv_cheats 0");
}

// Reads the map list the walk works through.  An absent key leaves it empty,
// which is the off value: a server that is not being regenerated for is never
// reloaded or changed by any of this.
void ReadNavPass()
{
    gsNavPass[0] = '\0';

    GetConfigString(gsNavPass, sizeof(gsNavPass), "NavPassMaps", "Bots");

    // This runs at every map start, so a walk that has already finished or
    // given up stays finished until the server is restarted -- otherwise the
    // list would start it again on the next map, forever.
    gbNavPassOn = gsNavPass[0] != '\0' && !gbNavPassDone;
}

// Stops the walk for the rest of this server run, leaving the reason and what
// is still without a mesh in the log.
void NavPassStop(const char[] sCurrent, const char[] sReason)
{
    NavPassLogLeft(sCurrent, sReason);
    gbNavPassOn   = false;
    gbNavPassDone = true;
}

// Whether the pass may still start a generation for this map.  A second attempt
// at a map that produced no mesh would change the map back and forth forever,
// so each map is generated for once per server run.
bool NavPassMayTry(const char[] sMap)
{
    return !gNavPassSeen.ContainsKey(sMap);
}

// Whether the pass may still send the server to this map.  A failed change
// would otherwise be repeated for the rest of the run.
bool NavPassMayAsk(const char[] sMap)
{
    return !gNavPassAsked.ContainsKey(sMap);
}

// How many map names the list holds, so the walk can be bounded by its length.
int NavPassCount()
{
    int iCount = 0;
    int iPos   = 0;
    int iLen   = strlen(gsNavPass);

    while (iPos < iLen)
    {
        int iEnd = iPos;

        while (iEnd < iLen && gsNavPass[iEnd] != ',') {
            iEnd++;
        }

        if (iEnd > iPos) {
            iCount++;
        }

        iPos = iEnd + 1;
    }

    return iCount;
}

// Generates a mesh for the map that is up, or moves on to the next one that
// needs it.  The engine can only build a mesh for the map it is running, so the
// pass is driven by the map starts themselves: each one either generates for
// what is up or changes to something that still needs generating for.
void NavPass()
{
    char sMap [MAX_MAP_LENGTH];
    char sList[sizeof(gsNavPass)];
    char sNext[MAX_MAP_LENGTH];

    GetCurrentMap(sMap, sizeof(sMap));

    // Both of these reload or change the map, so neither happens to people who
    // are playing.  The rest of the list is dropped rather than held, because
    // the server may well be played on for the rest of its life.
    if (RealPlayerPresent())
    {
        NavPassStop(sMap, "a real player is on the server");
        return;
    }

    // A map that cannot be generated for must not become an endless walk, so
    // the number of moves is bounded by the length of the list: every map costs
    // one change to reach it and one generation once there.
    if (giNavPassChanges > 2 * NavPassCount() + 8)
    {
        NavPassStop(sMap, "too many map changes");
        return;
    }

    // What is up now comes first: generating for it reloads the same map rather
    // than changing to another one, and it is the map the pass was aimed at.
    if (!NavMeshExists(sMap) && NavPassMayTry(sMap))
    {
        gNavPassSeen.SetValue(sMap, 1, true);
        giNavPassChanges++;

        LogMessage("[XMS] nav pass: generating a navigation mesh for %s", sMap);

        ServerCommand("sv_cheats 1");
        ServerCommand("nav_generate");
        ServerCommand("sv_cheats 0");
        return;
    }

    // Otherwise hand the server the next map on the list that has no mesh.
    strcopy(sList, sizeof(sList), gsNavPass);
    sNext[0] = '\0';

    int iPos  = 0;
    int iLen  = strlen(sList);

    while (iPos < iLen)
    {
        int iEnd = iPos;

        while (iEnd < iLen && sList[iEnd] != ',') {
            iEnd++;
        }

        if (iEnd > iPos)
        {
            char sCandidate[MAX_MAP_LENGTH];

            strcopy(sCandidate, (iEnd - iPos) + 1, sList[iPos]);
            TrimString(sCandidate);

            if (sCandidate[0]
                && !StrEqual(sCandidate, sMap)
                && !NavMeshExists(sCandidate)
                && NavPassMayTry(sCandidate)
                && NavPassMayAsk(sCandidate))
            {
                strcopy(sNext, sizeof(sNext), sCandidate);
                break;
            }
        }

        iPos = iEnd + 1;
    }

    if (!sNext[0])
    {
        NavPassStop(sMap, "every map on the list has been dealt with");
        return;
    }

    gNavPassAsked.SetValue(sNext, 1, true);
    giNavPassChanges++;

    LogMessage("[XMS] nav pass: changing to %s to generate for it", sNext);

    ServerCommand("changelevel %s", sNext);
}

// What is left of the walk, and why it stopped.  "There is nothing left" is not
// the same as "every map has a mesh" -- a map the engine could not build one
// for stays on the list, and this is where that is visible.
void NavPassLogLeft(const char[] sCurrent, const char[] sReason)
{
    // Room for the maps a failed walk left behind, short of what LogMessage
    // itself will carry in one line.
    char sLeft[640];
    char sList[sizeof(gsNavPass)];

    sLeft[0] = '\0';
    strcopy(sList, sizeof(sList), gsNavPass);

    int iPos  = 0;
    int iLen  = strlen(sList);

    while (iPos < iLen)
    {
        int iEnd = iPos;

        while (iEnd < iLen && sList[iEnd] != ',') {
            iEnd++;
        }

        if (iEnd > iPos)
        {
            char sCandidate[MAX_MAP_LENGTH];

            strcopy(sCandidate, (iEnd - iPos) + 1, sList[iPos]);
            TrimString(sCandidate);

            if (sCandidate[0] && !NavMeshExists(sCandidate))
            {
                if (sLeft[0]) {
                    StrCat(sLeft, sizeof(sLeft), ",");
                }

                StrCat(sLeft, sizeof(sLeft), sCandidate);
            }
        }

        iPos = iEnd + 1;
    }

    if (sLeft[0]) {
        LogMessage("[XMS] nav pass: %s", sReason);
        LogMessage("[XMS] nav pass: stopped on %s after %i changes; still no mesh for: %s", sCurrent, giNavPassChanges, sLeft);
    }
    else {
        LogMessage("[XMS] nav pass: %s", sReason);
        LogMessage("[XMS] nav pass: stopped on %s after %i changes; every map on the list has a mesh", sCurrent, giNavPassChanges);
    }
}

// Whether a real player is on the server.  A bot is not one, and neither is
// the SourceTV relay, which the engine keeps as a client like any other.
bool RealPlayerPresent()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i)) {
            return true;
        }
    }

    return false;
}

void KickBots()
{
    ServerCommand("hl2mp_bot_kick all");
}

void AddBot()
{
    // The team is not optional.  A bare "hl2mp_bot_add" makes the new client
    // fail HandleCommand_JoinTeam( 0 ) - invalid team index -- it connects,
    // never spawns, and stands at a fixed origin for the rest of the map.
    // That is the "bot that will not move" this plugin used to produce.
    // Naming a real team lets it spawn properly.
    ServerCommand("hl2mp_bot_add combine");
}

int FindBotClient()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && IsFakeClient(i) && !IsClientSourceTV(i)) {
            return i;
        }
    }

    return 0;
}

public Action Cmd_Bots(int iClient, int iArgs)
{
    char sArg[8];

    if (iArgs >= 1)
    {
        GetCmdArg(1, sArg, sizeof(sArg));

        if (StrEqual(sArg, "add", false))
        {
            AddBot();
            ReplyToCommand(iClient, "[XMS] added a bot");
            return Plugin_Handled;
        }
        else if (StrEqual(sArg, "kick", false))
        {
            KickBots();
            giBotClient = 0;
            ReplyToCommand(iClient, "[XMS] kicked the bots");
            return Plugin_Handled;
        }
    }

    char  sMap[MAX_MAP_LENGTH];
    char  sName[MAX_NAME_LENGTH];
    char  sWeapon[64];
    char  sHeld[64];
    char  sModel[64];
    float fOrigin[3];
    int   iBots;

    GetCurrentMap(sMap, sizeof(sMap));

    ReplyToCommand(iClient, "[XMS] map %s: nav mesh %s%s", sMap,
        NavMeshExists(sMap) ? "present" : "MISSING",
        gbNavGenerate ? " (a missing one is generated)" : "");
    ReplyToCommand(iClient, "[XMS] bot gun damage %i%%, catch radius %i units (gun reaches %.0f, key presses inside %.0f)",
        giDamagePercent, giCatchRadius, gfSwingReach, gfSwingRange);

    if (giPropHoldTime > 0) {
        ReplyToCommand(iClient, "[XMS] a prop held longer than %i s is thrown for the bot", giPropHoldTime);
    }

    if (gbAutoBhop) {
        if (giBhopMaxSpeed > 0) {
            ReplyToCommand(iClient, "[XMS] bot bunnyhop on, stops at %i u/s, strafe %i degrees off sideways",
                           giBhopMaxSpeed, giBhopAngle);
        }
        else {
            ReplyToCommand(iClient, "[XMS] bot bunnyhop on, no speed cap, strafe %i degrees off sideways",
                           giBhopAngle);
        }
    }
    else {
        ReplyToCommand(iClient, "[XMS] bot bunnyhop off");
    }

    if (gsBotModel[0]) {
        ReplyToCommand(iClient, "[XMS] bot model pinned to %s", gsBotModel);
    }
    else {
        ReplyToCommand(iClient, "[XMS] bot model left to the game");
    }

    if (giBotClient > 0 && IsClientInGame(giBotClient)) {
        // A number that keeps climbing means the aim hook really does run after
        // the bot's own aiming; a frozen one means it does not.
        ReplyToCommand(iClient, "[XMS] bot aim hook ran on %i frames", giAimTicks);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i) || IsClientSourceTV(i)) {
            continue;
        }

        iBots++;

        GetClientName(i, sName, sizeof(sName));
        GetClientAbsOrigin(i, fOrigin);
        GetClientModel(i, sModel, sizeof(sModel));

        int iWeapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");

        strcopy(sHeld, sizeof(sHeld), "-");

        if (iWeapon > MaxClients && IsValidEntity(iWeapon)) {
            GetEdictClassname(iWeapon, sWeapon, sizeof(sWeapon));

            // A gravity gun keeps the prop it is holding in m_hAttachedObject,
            // which is the only networked evidence that a bot is actually using
            // it -- worth watching when tuning prop_freak_ratio.  Only that one
            // weapon has the property: asking any other gun for it throws, which
            // is how this command used to die the moment a bot drew a shotgun.
            int iHeld = 0;

            if (HasEntProp(iWeapon, Prop_Send, "m_hAttachedObject")) {
                iHeld = GetEntPropEnt(iWeapon, Prop_Send, "m_hAttachedObject");
            }

            if (iHeld > MaxClients && IsValidEntity(iHeld)) {
                GetEdictClassname(iHeld, sHeld, sizeof(sHeld));
            }
        }
        else {
            strcopy(sWeapon, sizeof(sWeapon), "none");
        }

        ReplyToCommand(iClient, "  #%i %s  alive %i  health %i  speed %i  weapon %s  holding %s  model %s  origin %.0f %.0f %.0f",
            i,
            sName,
            view_as<int>(IsPlayerAlive(i)),
            GetClientHealth(i),
            GetClientVelocity(i),
            sWeapon,
            sHeld,
            sModel,
            fOrigin[0],
            fOrigin[1],
            fOrigin[2]
        );
    }

    if (!iBots) {
        ReplyToCommand(iClient, "  no bots in game");
    }

    return Plugin_Handled;
}

public Action Hook_OnTakeDamage(int iClient, int &iAttacker, int &iInflictor, float &fDamage, int &iDamageType)
{
    if (giDamagePercent >= 100 || giDamagePercent <= 0) {
        return Plugin_Continue;
    }

    // Only what the bot does to a real player is blunted, and only with a gun.
    // Props, frags and combine balls it sends back keep their full damage --
    // that is the bot's signature move, not its aim.
    if (iAttacker <= 0 || iAttacker > MaxClients || !IsFakeClient(iAttacker)) {
        return Plugin_Continue;
    }

    char sWhat[64];

    DescribeInflictor(iInflictor, sWhat, sizeof(sWhat));

    if (IsThrownDamage(iInflictor))
    {
        if (giDamageLogs < 8) {
            giDamageLogs++;
            LogMessage("[XMS] bot damage left at full: %s did %.1f to %N", sWhat, fDamage, iClient);
        }

        return Plugin_Continue;
    }

    float fBefore = fDamage;

    fDamage *= float(giDamagePercent) / 100.0;

    if (giDamageLogs < 8) {
        giDamageLogs++;
        LogMessage("[XMS] bot damage blunted to %d%%: %s did %.1f, now %.1f, on %N",
                   giDamagePercent, sWhat, fBefore, fDamage, iClient);
    }

    return Plugin_Changed;
}

// What the bot sent with its own hands rather than its gun.  Everything else it
// does to a real player is blunted; what it throws is left alone.
//
// This is asked the other way round from the obvious one on purpose.  Listing
// what to blunt would mean naming the inflictor of a bullet, and a bullet's
// inflictor is not reliably its weapon -- the engine fills the field from
// whichever entity fired, and the damage can therefore arrive as the gun, as the
// crossbow's own bolt, or as the shooter itself with no weapon named at all.
// Whichever it is, it is not in this list, so it gets blunted.  Listing what to
// leave alone instead is a short list of classnames that does not change, and
// the worst case if one is ever wrong is that a thrown prop hurts as much as it
// did before -- never that the bot's gun quietly goes back to full strength.
bool IsThrownDamage(int iInflictor)
{
    if (iInflictor <= MaxClients || !IsValidEntity(iInflictor)) {
        return false;
    }

    char sClass[64];

    GetEdictClassname(iInflictor, sClass, sizeof(sClass));

    // Every prop the gravity gun can hold, which is how a thrown barrel or
    // crate arrives.
    if (strncmp(sClass, "prop_physics", 12) == 0) {
        return true;
    }

    return StrEqual(sClass, "npc_grenade_frag")
        || StrEqual(sClass, "prop_combine_ball");
}

void DescribeInflictor(int iInflictor, char[] sWhat, int iMaxLen)
{
    if (iInflictor <= 0)
    {
        strcopy(sWhat, iMaxLen, "nothing (no inflictor named)");
        return;
    }

    if (iInflictor <= MaxClients)
    {
        Format(sWhat, iMaxLen, "the shooter itself (inflictor is client %d)", iInflictor);
        return;
    }

    if (!IsValidEntity(iInflictor))
    {
        strcopy(sWhat, iMaxLen, "an entity that is already gone");
        return;
    }

    GetEdictClassname(iInflictor, sWhat, iMaxLen);
}

// A gravity gun reaches what it can see.  The trace runs to the entity being
// reached for and ignores players, so the bot cannot reel a frag through a wall
// or out of a crate.
bool IsReachable(int iIgnore, const float fTo[3])
{
    float fFrom[3];

    GetClientEyePosition(giBotClient, fFrom);

    TR_TraceRayFilter(fFrom, fTo, MASK_SOLID, RayType_EndPoint, TraceFilter_Reach, iIgnore);

    return TR_GetFraction() >= 1.0;
}

public bool TraceFilter_Reach(int iEntity, int iContentsMask, any iIgnore)
{
    if (iEntity == iIgnore) {
        return false;
    }

    return iEntity == 0 || iEntity > MaxClients;
}

public Action T_BotCatch(Handle hTimer)
{
    if (giCatchRadius <= 0 || giBotClient <= 0 || !IsClientInGame(giBotClient) || !IsPlayerAlive(giBotClient))
    {
        // Nothing left to swing with.  The object is dropped rather than held
        // over: the next bot to come along is not the one that started this.
        giSwingStage  = SWING_NONE;
        giSwingEnt    = 0;
        giSwingTarget = 0;

        return Plugin_Continue;
    }

    // The map's chargers are listed once, on the first tick a bot is here to
    // look at them; see ScanWorld.
    if (!gbWorldScanned) {
        ScanWorld();
    }

    // The props are listed again on a timer, because the ones that get thrown
    // are the ones that respawn and a respawned barrel is a new entity at a new
    // index -- a list taken once would spend the map ignoring every barrel that
    // had already been blown up and come back.  See ScanProps.
    float fNow = GetGameTime();

    if (fNow >= gfPropsScanAt)
    {
        gfPropsScanAt = fNow + PROP_SCAN_EVERY;

        ScanProps();
    }

    // Watched on every tick, including the ones a swing is using, since the
    // engine's own prop hold is not something this plugin drives.
    WatchPropHold();

    // One swing at a time, and the swing keeps the bot until it is done.
    if (giSwingStage != SWING_NONE) {
        return Plugin_Continue;
    }

    float fBot[3];
    GetClientEyePosition(giBotClient, fBot);

    float fOrigin[3], fDist;
    int   iEnt;

    // A frag is the most urgent of the three: its fuse is already running.  A
    // ball is next, since it hurts when it lands.  A prop is last, and it is
    // also the slowest of them, which is why it is the one that can be seen
    // coming from furthest off.
    iEnt = FindIncomingFrag(fBot, fOrigin, fDist);

    if (iEnt)
    {
        // Turn onto it as soon as it is worth watching, so the bot is already
        // looking at it by the time it is close enough to take -- a gravity gun
        // traces along the view, and the view takes time to swing round.
        AimBotAt(fOrigin, 0.2);

        // Started at the catch radius rather than at the gun's own trace: the
        // gun has to be brought out and the bot turned onto the object before
        // there is any point in pressing, and a swing that only began inside
        // the trace spent its whole life arming while the frag flew past it and
        // burst.  The press itself still waits for the trace length.
        StartSwing(iEnt, GetOnlyRealPlayer(), SWING_KIND_FRAG, fOrigin, fDist,
                   "an incoming grenade");

        return Plugin_Continue;
    }

    bool bStillBall;

    iEnt = FindIncomingBall(fBot, fOrigin, fDist, bStillBall);

    if (iEnt)
    {
        AimBotAt(fOrigin, 0.2);

        StartSwing(iEnt, GetBallThrower(iEnt), SWING_KIND_BALL, fOrigin, fDist,
                   bStillBall ? "a combine ball the map left lying"
                              : "an incoming combine ball");

        return Plugin_Continue;
    }

    iEnt = FindIncomingProp(fBot, fOrigin, fDist);

    if (iEnt)
    {
        AimBotAt(fOrigin, 0.2);

        StartSwing(iEnt, GetOnlyRealPlayer(), SWING_KIND_PROP, fOrigin, fDist,
                   "a prop thrown at the bot");
    }

    return Plugin_Continue;
}

// Says a line about a frag once and not again: see the note on gbFragSaid.
bool SayFrag(int iEnt)
{
    if (gbFragSaid[iEnt]) {
        return false;
    }

    gbFragSaid[iEnt] = true;

    return true;
}

// The frag that is worth a swing, or 0.  Its distance comes back through fDist
// so the caller can tell whether it is inside the gun's reach, and its origin
// through fOrigin so the bot can be aimed at it.
//
// Two kinds of frag count, and they are picked apart.  One is coming at the bot:
// it is closing along the line to it, and it is preferred whenever there is one,
// because its fuse is running.  The other has already arrived and stopped -- a
// grenade a player threw that fell short, rolled, or is lying on the floor
// beside the bot -- which is closing at nothing at all, and a gate on closing
// speed alone turns it away for good.  That gate is what the report about a
// thrown grenade was about: the bot reacted to frags that flew at it and to
// nothing else.  So a stopped frag is taken too, but only inside the gun's own
// reach and only while it is barely moving, which keeps the bot from setting off
// after every frag on the map and from catching its own throw back out of the
// air.
//
// What counts as incoming is the frag's own motion rather than who threw it.
// On this build m_bIsLive and m_hThrower both read as junk -- a frag a human
// had just thrown came back not live, carrying a thrower handle that pointed at
// the SourceTV entity -- so a gate on either would have turned away every frag
// there is.  Motion answers the same question honestly, and what the frag is
// thrown at does not depend on it: a frag always goes back at the one real
// player.
int FindIncomingFrag(const float fBot[3], float fOrigin[3], float &fDist)
{
    int   iBest, iBestStill;
    float fBestDist, fBestStillDist;
    float fBestAt[3], fStillAt[3];

    int iEnt = -1;

    while ((iEnt = FindEntityByClassname(iEnt, "npc_grenade_frag")) != -1)
    {
        // Only the origin is read from the frag; see the note on
        // gfFragLastPos for why its own velocity fields are not asked.
        float fHere[3], fPull[3], fVel[3], fToBot[3];

        GetEntPropVector(iEnt, Prop_Data, "m_vecOrigin", fHere);

        fVel[0] = fVel[1] = fVel[2] = 0.0;

        float fNow     = GetGameTime();
        float fElapsed = fNow - gfFragLastTime[iEnt];

        // Sampled before anything is decided, so a frag that spends a tick out
        // of range still has a position to be measured from when it comes in.
        if (fElapsed > 0.0 && fElapsed < 0.5)
        {
            fVel[0] = (fHere[0] - gfFragLastPos[iEnt][0]) / fElapsed;
            fVel[1] = (fHere[1] - gfFragLastPos[iEnt][1]) / fElapsed;
            fVel[2] = (fHere[2] - gfFragLastPos[iEnt][2]) / fElapsed;
        }

        gfFragLastTime[iEnt]    = fNow;
        gfFragLastPos[iEnt][0]  = fHere[0];
        gfFragLastPos[iEnt][1]  = fHere[1];
        gfFragLastPos[iEnt][2]  = fHere[2];

        SubtractVectors(fBot, fHere, fPull);

        float fLen = GetVectorLength(fPull);

        // Below one unit there is no direction left to normalize; past the
        // radius the frag is not this bot's business yet.
        if (fLen < 1.0 || fLen > float(giCatchRadius)) {
            continue;
        }

        NormalizeVector(fPull, fToBot);

        // Under 50 units/s along the line to the bot it is not coming at the
        // bot, it is drifting.
        float fClosing = -GetVectorDotProduct(fVel, fToBot);
        float fSpeed   = GetVectorLength(fVel);

        // A frag that has stopped where the gun can already reach it.  150 u/s
        // is about a walking player's speed and far under any throw, so a frag
        // the bot has just punted -- which leaves at several hundred units a
        // second -- cannot be picked straight back up on its way out.
        bool bStill   = fLen <= gfSwingRange && fSpeed < 150.0;
        bool bClosing = fClosing >= 50.0;

        if (!bClosing && !bStill) {
            SayFragIgnored(iEnt, fLen, bClosing, fClosing, fSpeed, false);
            continue;
        }

        if (!IsReachable(iEnt, fHere)) {
            SayFragIgnored(iEnt, fLen, bClosing, fClosing, fSpeed, true);
            continue;
        }

        // A frag that is still coming in is the urgent one, so the two are
        // tracked apart and the closing one wins whenever there is one: a
        // stopped frag keeps.  See the note above the function.
        if (bClosing)
        {
            if (!iBest || fLen < fBestDist)
            {
                iBest     = iEnt;
                fBestDist = fLen;

                fBestAt[0] = fHere[0];
                fBestAt[1] = fHere[1];
                fBestAt[2] = fHere[2];
            }
        }
        else if (!iBestStill || fLen < fBestStillDist)
        {
            iBestStill     = iEnt;
            fBestStillDist = fLen;

            fStillAt[0] = fHere[0];
            fStillAt[1] = fHere[1];
            fStillAt[2] = fHere[2];
        }
    }

    // Locals nobody wrote a value into are zero, which is what the first test of
    // each pair above reads.
    if (iBest)
    {
        fDist      = fBestDist;
        fOrigin[0] = fBestAt[0];
        fOrigin[1] = fBestAt[1];
        fOrigin[2] = fBestAt[2];

        return iBest;
    }

    if (iBestStill)
    {
        fDist      = fBestStillDist;
        fOrigin[0] = fStillAt[0];
        fOrigin[1] = fStillAt[1];
        fOrigin[2] = fStillAt[2];

        return iBestStill;
    }

    fDist = 0.0;

    return 0;
}

// One line per frag the bot passes up, with everything that can name the reason:
// what it is, how far off, how it is moving by both measures there are, and
// whether the gun could trace to it.  A frag the bot never reacts to otherwise
// leaves no trace at all, which is the one outcome the log has to be able to
// explain -- the line before this one was a budget of ten per map, and it ran
// out before a test that threw a grenade had even happened.
void SayFragIgnored(int iEnt, float fLen, bool bClosing, float fClosing,
                    float fSpeed, bool bTraced)
{
    if (!SayFrag(iEnt)) {
        return;
    }

    char  sClass[64];
    float fRaw[3];

    GetEdictClassname(iEnt, sClass, sizeof(sClass));
    GetEntPropVector(iEnt, Prop_Data, "m_vecAbsVelocity", fRaw);

    if (bTraced)
    {
        LogMessage("[XMS] a %s %.0f units out (%s, %.0f u/s along the line to the bot) is not in sight of the gun, ignored",
                   sClass, fLen, bClosing ? "closing" : "stopped", fClosing);

        return;
    }

    LogMessage("[XMS] a %s %.0f units out is not closing and is not close enough to be taken (%.0f u/s along the line to the bot, %.0f u/s by its movement, %.0f u/s in m_vecAbsVelocity), ignored",
               sClass, fLen, fClosing, fSpeed, GetVectorLength(fRaw));
}

// The same question for a combine ball, for two different balls: the orb
// somebody fired at the bot, and the map's own.
//
// The map's balls matter because of how they are born.  A map places
// func_combine_ball_spawner, which is implemented in this build of server.dll
// and turns balls loose to drift inside its own radius -- the KeyValues on
// dm_killbox_kbh_2p's spawner read minspeed/maxspeed 75, so those balls are out
// of play for a gate that waits for 200 units a second, and the bot walked past
// every ball the map had without ever touching one.  Nothing in the world
// distinguishes them from a thrown orb except their speed, so speed is what
// decides it: fast and closing is a thrown orb, slow and within the gun's own
// reach is one of the map's.  They are tracked apart the way the frag's two are
// (the closing one wins, the still one keeps) so an orb coming in is still the
// urgent one.
int FindIncomingBall(const float fBot[3], float fOrigin[3], float &fDist,
                     bool &bStillBall)
{
    int   iBest, iBestStill;
    float fBestDist, fBestStillDist;
    float fBestAt[3], fStillAt[3];

    int iEnt = -1;

    bStillBall = false;

    // The ball already in the claw reads as a ball at rest a short way in front
    // of the bot, which is exactly what the second test below is looking for --
    // so it has to be named and left out, or the bot would spend the map
    // snatching at the ball it is already carrying.  (The engine's own prop AI
    // can put one there without this plugin having swung at anything.)
    char sHeld[64];
    int  iHeld = PropInClaw(giBotClient, sHeld, sizeof(sHeld));

    while ((iEnt = FindEntityByClassname(iEnt, "prop_combine_ball")) != -1)
    {
        if (iEnt == iHeld) {
            continue;
        }

        // m_vecAbsVelocity, not m_vecVelocity: the orb's own velocity is the
        // one that reads on this build.
        float fHere[3], fPull[3], fVel[3];

        GetEntPropVector(iEnt, Prop_Data, "m_vecOrigin",      fHere);
        GetEntPropVector(iEnt, Prop_Data, "m_vecAbsVelocity", fVel);
        SubtractVectors(fBot, fHere, fPull);

        float fLen = GetVectorLength(fPull);

        if (fLen < 1.0 || fLen > float(giCatchRadius)) {
            continue;
        }

        float fSpeed = GetVectorLength(fVel);

        // Below 200 units/s it is not flying, and a ball not coming toward the
        // bot is on its way out -- which is also what keeps the swing from
        // starting again on the ball it has just thrown.
        bool bClosing = (fSpeed >= 200.0 && GetVectorDotProduct(fVel, fPull) > 0.0);

        // Or it is not going anywhere and the gun can already reach it, which
        // is the map's ball.  150 units/s sits above the spawner's drift and
        // far below any throw, so the ball the bot has just punted -- which
        // leaves at several hundred units a second -- cannot be caught on its
        // way out and handed straight back to itself.
        bool bStill = (fLen <= gfSwingRange && fSpeed < 150.0);

        if (!bClosing && !bStill) {
            continue;
        }

        if (!IsReachable(iEnt, fHere)) {
            continue;
        }

        if (bClosing)
        {
            if (!iBest || fLen < fBestDist)
            {
                iBest     = iEnt;
                fBestDist = fLen;

                fBestAt[0] = fHere[0];
                fBestAt[1] = fHere[1];
                fBestAt[2] = fHere[2];
            }
        }
        else if (!iBestStill || fLen < fBestStillDist)
        {
            iBestStill     = iEnt;
            fBestStillDist = fLen;

            fStillAt[0] = fHere[0];
            fStillAt[1] = fHere[1];
            fStillAt[2] = fHere[2];
        }
    }

    // Locals nobody wrote a value into are zero, which is what the first test of
    // each pair above reads.
    if (iBest)
    {
        fDist      = fBestDist;
        fOrigin[0] = fBestAt[0];
        fOrigin[1] = fBestAt[1];
        fOrigin[2] = fBestAt[2];

        return iBest;
    }

    if (iBestStill)
    {
        fDist      = fBestStillDist;
        fOrigin[0] = fStillAt[0];
        fOrigin[1] = fStillAt[1];
        fOrigin[2] = fStillAt[2];

        bStillBall = true;

        return iBestStill;
    }

    fDist = 0.0;

    return 0;
}

// How fast a prop has to be going to count as thrown rather than carried or
// lying about.  A gravity-gun punt sends one off at several hundred units a
// second and a bot walks with one at well under 300, so the ones that are being
// thrown at the bot are the ones above this.
#define PROP_INCOMING_SPEED 250.0

// A physics prop a player has thrown at the bot -- a barrel, a crate, whatever
// the gun punted -- or 0.  The map's props were listed once (see giProps); this
// is which of them, if any, is on its way in.
//
// Props are everywhere, so the gate has to tell a thrown one from a carried one,
// a dropped one and one the bot has just thrown itself.  Only its speed does
// that honestly: a prop standing on the floor is at rest, one in the bot's claw
// moves with the bot, and one the bot has just punted is going the other way --
// which is what the closing test takes out as well.  Not in the frag search's
// shape, because a prop is a big thing at a wall's distance: the radius is twice
// the frag's, so there is a second or so of travel to get the gun out and turn
// onto it in.
int FindIncomingProp(const float fBot[3], float fOrigin[3], float &fDist)
{
    int   iBest;
    float fBestDist;

    float fRange = float(giCatchRadius) * 2.0;

    char sHeld[64];
    int  iHeld = PropInClaw(giBotClient, sHeld, sizeof(sHeld));

    float fNow     = GetGameTime();
    float fElapsed;

    for (int i = 0; i < giPropCount; i++)
    {
        int iEnt = giProps[i];

        // The list is a snapshot and an index can be handed to something else
        // when its prop is destroyed, so what is there now is asked what it is.
        if (!IsValidEntity(iEnt) || iEnt == iHeld) {
            continue;
        }

        char sClass[64];

        GetEdictClassname(iEnt, sClass, sizeof(sClass));

        if (StrContains(sClass, "prop_physics", false) != 0
            && StrContains(sClass, "func_physbox", false) != 0) {
            continue;
        }

        float fHere[3], fPull[3], fVel[3];

        GetEntPropVector(iEnt, Prop_Data, "m_vecOrigin", fHere);

        // Sampled before anything is decided, exactly as the frag search does
        // it, so a prop that spends a tick out of the watched radius still has a
        // position for the next tick to measure it from.
        fVel[0] = fVel[1] = fVel[2] = 0.0;

        fElapsed = fNow - gfPropLastTime[iEnt];

        if (fElapsed > 0.0 && fElapsed < 0.5)
        {
            fVel[0] = (fHere[0] - gfPropLastPos[iEnt][0]) / fElapsed;
            fVel[1] = (fHere[1] - gfPropLastPos[iEnt][1]) / fElapsed;
            fVel[2] = (fHere[2] - gfPropLastPos[iEnt][2]) / fElapsed;

            // A respawnable barrel that has just been blown up comes back at its
            // spawn point, and that jump is not flight.  Nothing a punt sends at
            // a bot is near this fast, so anything past it is read as a teleport
            // and thrown away.
            if (GetVectorLength(fVel) > 3000.0)
            {
                fVel[0] = fVel[1] = fVel[2] = 0.0;
            }
        }

        gfPropLastTime[iEnt]   = fNow;
        gfPropLastPos[iEnt][0] = fHere[0];
        gfPropLastPos[iEnt][1] = fHere[1];
        gfPropLastPos[iEnt][2] = fHere[2];

        SubtractVectors(fBot, fHere, fPull);

        float fLen = GetVectorLength(fPull);

        // Below one unit there is no direction left, and the frag search's own
        // floor is the same.  It used to be 150 here, which quietly threw away
        // the one case a player testing this creates: a barrel punted at the bot
        // from close up is inside 150 units for its whole flight, so the bot
        // never reacted and the log never said why.  A prop the bot is already
        // holding is taken out by name above, and one lying at its feet by the
        // speed gate below, so nothing needs that floor.
        if (fLen < 1.0) {
            continue;
        }

        float fSpeed = GetVectorLength(fVel);

        // Out of reach, or moving too slowly to be a throw.  Both are most of a
        // map's props and say nothing a log line would not repeat for every
        // crate in the level.
        if (fLen > fRange || fSpeed < PROP_INCOMING_SPEED) {
            continue;
        }

        // A prop that is flying fast and *away* is the one near miss there is:
        // it reads as a throw and is turned down, so it is worth saying once.
        if (GetVectorDotProduct(fVel, fPull) <= 0.0)
        {
            if (SayFrag(iEnt)) {
                LogMessage("[XMS] a %s %.0f units out is flying at %.0f u/s but away from the bot, not chased",
                           sClass, fLen, fSpeed);
            }

            continue;
        }

        if (!IsReachable(iEnt, fHere))
        {
            if (SayFrag(iEnt)) {
                LogMessage("[XMS] a %s %.0f units out is flying at %.0f u/s toward the bot but the gun cannot trace to it, ignored",
                           sClass, fLen, fSpeed);
            }

            continue;
        }

        if (!iBest || fLen < fBestDist)
        {
            iBest     = iEnt;
            fBestDist = fLen;

            fOrigin[0] = fHere[0];
            fOrigin[1] = fHere[1];
            fOrigin[2] = fHere[2];
        }
    }

    fDist = fBestDist;

    return iBest;
}

void StartSwing(int iEnt, int iTarget, int iKind, const float fAt[3], float fDist,
                const char[] sWhat)
{
    giSwingEnt      = iEnt;
    giSwingTarget   = iTarget;
    giSwingKind     = iKind;
    giSwingStage    = SWING_ARM;
    giSwingTries    = 0;
    giSwingRecover  = 0;
    giSwingPresses  = 0;
    giSwingAway     = 0;
    gbSwingKey      = false;
    gbSwingClawTried = false;
    gfSwingAskAt    = 0.0;
    gfSwingPressAt  = 0.0;
    gfSwingAimSet   = 0.0;
    gfSwingStart    = GetGameTime();
    gfSwingDeadline = gfSwingStart + 1.0;   // the arming stage's own limit
    gfSwingLastDist = fDist;

    // The line it came in on, kept for the throw: with nobody to name as the
    // thrower this is the only direction that is known to be the right one.
    float fEye[3];

    GetClientEyePosition(giBotClient, fEye);
    SubtractVectors(fAt, fEye, gfSwingDir);
    NormalizeVector(gfSwingDir, gfSwingDir);

    LogMessage("[XMS] bot %N swings the gravity gun at %s (%.0f units out)",
               giBotClient, sWhat, fDist);
}

// Ends a swing with a reason that says how far it got.  A failed swing is only
// ever visible in this log, and "it did not work" is not enough to tell one
// failure from another.
void EndSwingAt(int iClient, const char[] sWhy)
{
    char sText[192];

    Format(sText, sizeof(sText), "%s (%.2f s in, stage %d, %d presses)",
           sWhy, GetGameTime() - gfSwingStart, giSwingStage, giSwingPresses);

    EndSwing(iClient, sText);
}

// Whether the object is now on its way back out along the line it came in on.
// Only a combine ball's own velocity reads on this build -- a frag's velocity
// fields come back junk -- so a frag answers no and is judged by having been
// launched instead.
bool SwingHeadingBack()
{
    if (giSwingKind != SWING_KIND_BALL) {
        return false;
    }

    float fVel[3];

    GetEntPropVector(giSwingEnt, Prop_Data, "m_vecAbsVelocity", fVel);

    return GetVectorDotProduct(fVel, gfSwingDir) > 0.0;
}

// The swing, one frame of it at a time.  Everything in here is input -- which
// weapon is in hand, where the bot looks, when the key goes down -- and the
// claw, the pull and the launch are the engine's own weapon code.  That is the
// point of doing it this way: no object is ever moved by this plugin, so what
// the player sees is the game's gravity gun, not an imitation of one.
bool DriveSwing(int iClient, int &iButtons, float fAngles[3])
{
    if (giSwingStage == SWING_NONE) {
        return false;
    }

    float fNow = GetGameTime();

    // Held down from the previous frame, the attack key is not a press, so both
    // bits are cleared here on every frame of the swing and only the frame that
    // means to press sets one back.  (The hook clears them once more after a
    // press, because a swing can end on the frame it presses.)
    iButtons &= ~(IN_ATTACK | IN_ATTACK2);

    // A swing can lose its object halfway through: a frag's fuse runs out, a
    // ball is destroyed, and a real player can pick it up first.
    if (!IsValidEntity(giSwingEnt))
    {
        EndSwingAt(iClient, "the object is gone");
        return false;
    }

    float fAt[3], fEye[3], fTo[3], fDist;

    GetEntPropVector(giSwingEnt, Prop_Data, "m_vecOrigin", fAt);
    GetClientEyePosition(iClient, fEye);
    SubtractVectors(fAt, fEye, fTo);
    fDist = GetVectorLength(fTo);

    // Past it: an object that keeps getting further away over a few frames is
    // no longer coming at the bot, and swinging at it would only chase it.
    // Watched only while the swing is waiting for the object to arrive -- once
    // the claw has it, or once it has been batted, being further away again is
    // the point.
    if (fDist > gfSwingLastDist + 2.0) {
        giSwingAway++;
    }
    else {
        giSwingAway = 0;
    }

    gfSwingLastDist = fDist;

    if (giSwingAway >= 4
        && (giSwingStage == SWING_ARM || giSwingStage == SWING_GRAB || giSwingStage == SWING_TAKE))
    {
        EndSwingAt(iClient, "it went past without being taken");
        return false;
    }

    if (fNow >= gfSwingDeadline
        && giSwingStage != SWING_PUNT)
    {
        if (giSwingStage == SWING_TAKE) {
            EndSwingAt(iClient, giSwingKind == SWING_KIND_BALL
                               ? "neither the claw nor the swat turned the ball"
                               : "it would not come to the claw");
        }
        else if (giSwingStage == SWING_ARM) {
            EndSwingAt(iClient, "the gun never came out in time");
        }
        else {
            EndSwingAt(iClient, "it never came within reach of the gun");
        }

        return false;
    }

    // A gravity gun traces along the view, so the bot is turned onto the object
    // here -- after its own aim solver has had its say this frame, and before
    // the weapon is asked to fire.  The same point goes to AimBotAt, which the
    // think hook re-applies, so what everyone else sees is the aim the trace
    // actually uses.
    float fLook[3];

    if (SwingLookPoint(fLook))
    {
        AimBotAt(fLook, 0.15);
        FacePoint(iClient, fLook, fAngles);
    }

    // Past the arming stage every key below belongs to the gravity gun, and the
    // bot's own AI picks a weapon for itself every frame -- the gun is not what
    // it wants, so it goes back on the bot's hip between any two frames of the
    // swing.  Pressing then would be pressing whatever it is holding instead --
    // a shotgun's second barrel, or nothing at all.  Hook_BotWeaponSwitch is
    // what normally stops that from happening; this is the fallback for a frame
    // it still got through, and taking the gun back out is cheap enough to do
    // here rather than abandoning a swing the bot has already committed to.
    if (giSwingStage != SWING_ARM && !PhyscannonInHand(iClient))
    {
        if (++giSwingRecover > 30)
        {
            EndSwingAt(iClient, "the gravity gun was put away and would not come back");
            return false;
        }

        FakeClientCommand(iClient, "use weapon_physcannon");

        if (!PhyscannonInHand(iClient)) {
            return true;
        }
    }

    switch (giSwingStage)
    {
        case SWING_ARM:
        {
            if (fNow >= gfSwingAskAt)
            {
                // Asked for immediately and then every tenth of a second: the
                // engine's own "use" command, so the gun comes out the way the
                // game brings it out rather than being written into the weapon
                // slot by hand.  A bot that turns out not to carry one is given
                // one once: its loadout is not something to assume.
                gfSwingAskAt = fNow + 0.1;

                if (++giSwingTries <= 3) {
                    FakeClientCommand(iClient, "use weapon_physcannon");
                }
                else if (giSwingTries == 4) {
                    GivePlayerItem(iClient, "weapon_physcannon");
                }
                else
                {
                    EndSwingAt(iClient, "no gravity gun came up");
                    return false;
                }
            }

            if (!PhyscannonInHand(iClient)) {
                return true;
            }

            giSwingStage    = SWING_GRAB;
            gfSwingDeadline = fNow + 1.0;   // the time the object needs to arrive
        }

        case SWING_GRAB:
        {
            // The key only does anything inside the gun's own trace, and the
            // swing is aimed straight at the object, so this is the moment.
            if (fDist > gfSwingRange) {
                return true;
            }

            giSwingPresses++;

            if (giSwingKind == SWING_KIND_BALL)
            {
                // The claw is asked first, the same as for a frag, because the
                // claw is the one key on this build that has been *shown* to
                // take hold of a moving object.  A ball is travelling at 1500
                // units a second, so it is asked for as early as the gun's
                // reach allows and then again every tenth of a second; if the
                // claw never takes it, the swat is tried once from SWING_TAKE.
                iButtons  |= IN_ATTACK2;
                gbSwingKey = true;

                LogMessage("[XMS] bot %N closes the claw on the ball at %.0f units", iClient, fDist);

                giSwingStage    = SWING_TAKE;
                gfSwingPressAt  = fNow + 0.1;   // asked again this often
                gfSwingDeadline = fNow + 0.6;   // a ball crosses the reach in 0.14 s

                return true;
            }

            // A frag is reeled in with the *secondary* key and thrown with the
            // primary.  It was the other way round before, which is what threw
            // a caught frag off in whatever direction the bot happened to be
            // facing: the primary key on an empty claw is the swat, not the
            // grab.
            iButtons  |= IN_ATTACK2;
            gbSwingKey = true;

            LogMessage("[XMS] bot %N closes the claw on the frag at %.0f units", iClient, fDist);

            giSwingStage    = SWING_TAKE;
            gfSwingPressAt  = fNow + 0.25;   // asked again this often until it holds
            gfSwingDeadline = fNow + 1.0;

            return true;
        }

        case SWING_TAKE:
        {
            if (PhyscannonHolds(iClient, giSwingEnt))
            {
                giSwingStage    = SWING_TURN;
                gfSwingAimSet   = 0.0;
                gfSwingDeadline = fNow + 0.5;

                return true;
            }

            // The engine may have answered the claw with the swat instead of
            // taking hold -- which of the two it does is exactly what these log
            // lines are here to settle, so a ball that has turned round without
            // ever being held is a swat that worked.
            if (giSwingKind == SWING_KIND_BALL)
            {
                if (SwingHeadingBack())
                {
                    EndSwingAt(iClient, "the ball was swatted back");
                    return false;
                }

                if (fNow >= gfSwingPressAt)
                {
                    gfSwingPressAt = fNow + 0.1;
                    giSwingPresses++;

                    if (!gbSwingClawTried)
                    {
                        // The claw has had its first chance and the ball is
                        // still coming in, so the other move an empty gravity
                        // gun has gets its turn: the primary attack.  Once
                        // only, so a swing that somehow does both says in the
                        // log which one turned the ball.
                        gbSwingClawTried = true;

                        iButtons  |= IN_ATTACK;
                        gbSwingKey = true;

                        LogMessage("[XMS] bot %N tries the swat on the ball at %.0f units",
                                   iClient, fDist);
                    }
                    else if (fDist <= gfSwingRange)
                    {
                        iButtons  |= IN_ATTACK2;
                        gbSwingKey = true;

                        LogMessage("[XMS] bot %N closes the claw on the ball again at %.0f units",
                                   iClient, fDist);
                    }
                }

                return true;
            }

            // The claw did not close on the first press.  A frag that is still
            // coming in can be asked for again.
            if (fNow >= gfSwingPressAt && fDist <= gfSwingRange)
            {
                gfSwingPressAt = fNow + 0.25;

                iButtons  |= IN_ATTACK2;
                gbSwingKey = true;
                giSwingPresses++;

                LogMessage("[XMS] bot %N closes the claw again at %.0f units", iClient, fDist);
            }

            return true;
        }

        case SWING_TURN:
        {
            // The claw has it.  The aim has been moved onto the thrower by
            // SwingLookPoint above, and the launch goes wherever the bot is
            // looking, so one whole frame is spent looking at the thrower
            // before the launch -- pressing on the frame the aim is written
            // would fire along the aim the bot had a moment ago.
            if (!gfSwingAimSet)
            {
                gfSwingAimSet = fNow;
                return true;
            }

            giSwingStage = SWING_PUNT;
        }

        case SWING_PUNT:
        {
            // The claw has it and the bot is looking at whoever threw it, so
            // this press is the throw -- for a ball exactly as for a frag.  The
            // hold is read once more because a swing that got this far can
            // still lose what it is carrying, and a launch that never happened
            // is better said out loud than counted as a return.
            bool bHeld = PhyscannonHolds(iClient, giSwingEnt);

            if (giSwingKind == SWING_KIND_BALL)
            {
                if (!bHeld)
                {
                    EndSwingAt(iClient, "the ball was dropped before it could be thrown");
                    return false;
                }

                iButtons  |= IN_ATTACK;
                gbSwingKey = true;
                giSwingPresses++;

                EndSwingAt(iClient, "the ball was caught and thrown back");
                return true;
            }

            char sName[16], sWhy[96];

            SwingObjectName(giSwingKind, sName, sizeof(sName));

            if (!bHeld)
            {
                Format(sWhy, sizeof(sWhy), "the %s was dropped before it could be thrown", sName);

                EndSwingAt(iClient, sWhy);
                return false;
            }

            iButtons  |= IN_ATTACK;
            gbSwingKey = true;
            giSwingPresses++;

            Format(sWhy, sizeof(sWhy), "the %s was thrown back", sName);

            EndSwingAt(iClient, sWhy);
            return true;
        }
    }

    return true;
}

void EndSwing(int iClient, const char[] sWhy)
{
    LogMessage("[XMS] bot %N's gravity-gun swing: %s", iClient, sWhy);

    giSwingStage  = SWING_NONE;
    giSwingEnt    = 0;
    giSwingTarget = 0;
}

// Where the swing wants the bot looking.  There is always an answer, because a
// gravity gun only ever fires along the view: leaving the view alone is the
// same as throwing the object wherever the bot happened to be facing.
//
// At the object while it is still coming in, because that is the line the trace
// and the swat both follow; at whoever threw it once the claw has it, because
// that is the line the launch throws along.  With nobody to name -- only one
// real player is ever watched, and a bot's own throw has no owner -- the aim
// goes back out along the line the object came in on, which is where the
// thrower is.
bool SwingLookPoint(float fLook[3])
{
    if (giSwingStage >= SWING_TURN)
    {
        if (giSwingTarget > 0 && IsClientInGame(giSwingTarget) && IsPlayerAlive(giSwingTarget))
        {
            GetClientEyePosition(giSwingTarget, fLook);
            return true;
        }

        float fEye[3];

        GetClientEyePosition(giBotClient, fEye);

        fLook[0] = fEye[0] + gfSwingDir[0] * 512.0;
        fLook[1] = fEye[1] + gfSwingDir[1] * 512.0;
        fLook[2] = fEye[2] + gfSwingDir[2] * 512.0;

        return true;
    }

    GetEntPropVector(giSwingEnt, Prop_Data, "m_vecOrigin", fLook);

    return true;
}

// The gun traces along the command's view angles, and the bot's aim solver
// writes those every frame, so the swing writes them again here.  The networked
// aim is the same point, applied from the think hook.
void FacePoint(int iClient, const float fAt[3], float fAngles[3])
{
    float fEye[3], fDir[3], fWant[3];

    GetClientEyePosition(iClient, fEye);
    SubtractVectors(fAt, fEye, fDir);
    GetVectorAngles(fDir, fWant);

    fAngles[0] = fWant[0];
    fAngles[1] = fWant[1];
    fAngles[2] = 0.0;
}

bool PhyscannonInHand(int iClient)
{
    int iGun = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");

    if (iGun <= MaxClients || !IsValidEntity(iGun)) {
        return false;
    }

    char sClass[64];

    GetEdictClassname(iGun, sClass, sizeof(sClass));

    return StrEqual(sClass, "weapon_physcannon");
}

// The engine's bot picks a weapon for itself every frame, and the gravity gun
// is never what it picks -- so the gun a swing has just brought out is gone
// again by the next frame.  For a swing that is fatal rather than merely
// annoying: taking the gun out of the bot's hands runs its Holster, which
// ForceDrops whatever the claw is holding, so a grabbed frag or ball is lost
// before it can be aimed at anybody.  While a swing is in progress the bot is
// therefore not allowed to put the gun away -- the AI's choice is refused, and
// it gets its own way again the moment the swing ends.  The physcannon itself
// is always allowed through, so a swing that still has to ask for the gun can.
public Action Hook_BotWeaponSwitch(int iClient, int iWeapon)
{
    if (iClient != giBotClient || giSwingStage == SWING_NONE) {
        return Plugin_Continue;
    }

    if (iWeapon > MaxClients && IsValidEntity(iWeapon))
    {
        char sClass[64];

        GetEdictClassname(iWeapon, sClass, sizeof(sClass));

        if (StrEqual(sClass, "weapon_physcannon")) {
            return Plugin_Continue;
        }

        if (giSwitchLogs < 6) {
            giSwitchLogs++;
            LogMessage("[XMS] the bot's weapon switch to %s was refused: a swing is in progress",
                       sClass);
        }

        return Plugin_Handled;
    }

    if (giSwitchLogs < 6) {
        giSwitchLogs++;
        LogMessage("[XMS] the bot's weapon switch to an empty hand was refused: a swing is in progress");
    }

    return Plugin_Handled;
}

// Whether the engine's claw has actually closed on the object.  This is the
// only evidence of a successful grab there is: the pull happens inside the
// weapon and is written nowhere this plugin can see.
bool PhyscannonHolds(int iClient, int iEnt)
{
    int iGun = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");

    return iGun > MaxClients && IsValidEntity(iGun)
        && GetEntPropEnt(iGun, Prop_Send, "m_hAttachedObject") == iEnt;
}

// What the gravity gun is holding, or 0.  Nothing here acts on it -- see the
// note on giHeldProp.
int PropInClaw(int iClient, char[] sClass, int iMaxLen)
{
    int iGun = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");

    if (iGun <= MaxClients || !IsValidEntity(iGun)) {
        return 0;
    }

    char sGun[64];

    GetEdictClassname(iGun, sGun, sizeof(sGun));

    if (!StrEqual(sGun, "weapon_physcannon")) {
        return 0;
    }

    int iHeld = GetEntPropEnt(iGun, Prop_Send, "m_hAttachedObject");

    if (iHeld <= MaxClients || !IsValidEntity(iHeld)) {
        return 0;
    }

    GetEdictClassname(iHeld, sClass, iMaxLen);

    return iHeld;
}

// The map's chargers, listed once, and its physics props, listed again on a
// timer.  A charger cannot appear after the map has loaded, so one walk of the
// edict list is all it needs and the searches that use it then cost a distance
// each instead of a walk of their own.  The props are a different matter; see
// ScanProps for why they are rebuilt.
//
// A charger is any classname with "charger" in it, which is the same wildcard
// the engine's own health action uses: the maps in this folder carry
// item_healthcharger, item_suitcharger, func_healthcharger and custom ones
// besides.  A prop is one of the two classes a punt can send at the bot.  Both
// counts go to the log, because a list that came back empty is the one way this
// could fail without saying anything.
void ScanWorld()
{
    gbWorldScanned = true;
    giChargerCount = 0;
    giPropCount    = 0;

    char sFound[192];

    sFound[0] = '\0';

    // FRAG_TRACK_MAX is the engine's edict ceiling, which the include set here
    // does not name as a constant.
    for (int i = MaxClients + 1; i < FRAG_TRACK_MAX; i++)
    {
        if (!IsValidEntity(i)) {
            continue;
        }

        char sClass[64];

        GetEdictClassname(i, sClass, sizeof(sClass));

        if (StrContains(sClass, "charger", false) != -1)
        {
            if (giChargerCount >= CHARGER_MAX) {
                continue;
            }

            if (giChargerCount < 3)
            {
                // StrCat, not Format: Format writes from the front of the
                // buffer, so three Formats leave one charger named and two
                // silently dropped -- which is exactly what the first run of
                // this logged, "(, item_suitcharger#36)".
                char sAppend[96];

                Format(sAppend, sizeof(sAppend), "%s%s#%d",
                       (sFound[0] != '\0') ? ", " : "", sClass, i);

                StrCat(sFound, sizeof(sFound), sAppend);
            }

            giChargers[giChargerCount++] = i;

            continue;
        }
    }

    ScanProps();

    LogMessage("[XMS] the map has %d chargers (%s) and %d physics props watched",
               giChargerCount, (sFound[0] != '\0') ? sFound : "none", giPropCount);
}

// The physics props the catch search runs over, rebuilt from the entity list.
// Re-run rather than kept, because the props that matter are the ones that
// respawn: a barrel blown up and come back is a new entity at a new index, and a
// list taken once at map start never learns about it.  Cheap enough at one walk
// every PROP_SCAN_EVERY seconds.
void ScanProps()
{
    giPropCount = 0;

    for (int i = MaxClients + 1; i < FRAG_TRACK_MAX; i++)
    {
        if (!IsValidEntity(i)) {
            continue;
        }

        char sClass[64];

        GetEdictClassname(i, sClass, sizeof(sClass));

        if (StrContains(sClass, "prop_physics", false) == 0
            || StrContains(sClass, "func_physbox", false) == 0)
        {
            if (giPropCount >= PROP_MAX) {
                return;
            }

            giProps[giPropCount++] = i;
        }
    }
}

// The charger the bot is standing at, or 0, with how far off it is.
int ChargerAt(int iClient, float &fDist)
{
    float fBot[3];

    GetClientEyePosition(iClient, fBot);

    int iNear = 0;

    fDist = 0.0;

    for (int i = 0; i < giChargerCount; i++)
    {
        if (!IsValidEntity(giChargers[i])) {
            continue;
        }

        float fAt[3];

        GetEntPropVector(giChargers[i], Prop_Data, "m_vecOrigin", fAt);

        float fHere = GetVectorDistance(fBot, fAt);

        if (fHere > CHARGER_RANGE) {
            continue;
        }

        if (!iNear || fHere < fDist)
        {
            iNear = giChargers[i];
            fDist = fHere;
        }
    }

    return iNear;
}

// What the bot does at a charger, said on each visit.  See the note on
// giChargers for what the three kinds of line mean; nothing here presses a key
// of its own.
void WatchCharger(int iClient, int iButtons)
{
    if (giChargerCount == 0) {
        return;
    }

    float fDist;
    int   iAt = ChargerAt(iClient, fDist);

    if (!iAt)
    {
        giChargerSeen    = 0;
        giChargerHealth  = 0;
        gbChargerPressed = false;

        return;
    }

    int iHealth = GetClientHealth(iClient);

    if (iAt != giChargerSeen)
    {
        char sClass[64];

        giChargerSeen    = iAt;
        giChargerHealth  = iHealth;
        gbChargerPressed = false;

        if (giChargerLogs++ < 24)
        {
            GetEdictClassname(iAt, sClass, sizeof(sClass));

            LogMessage("[XMS] the bot is at a charger (%s #%d, %.0f units off, health %d)",
                       sClass, iAt, fDist, iHealth);
        }

        return;
    }

    if ((iButtons & IN_USE) && !gbChargerPressed)
    {
        gbChargerPressed = true;

        if (giChargerLogs++ < 24) {
            LogMessage("[XMS] the bot's own command pressed the use key at the charger (health %d)", iHealth);
        }
    }

    if (iHealth > giChargerHealth && giChargerHeals++ < 8) {
        LogMessage("[XMS] the charger refilled the bot's health %d -> %d while it stood there",
                   giChargerHealth, iHealth);
    }

    giChargerHealth = iHealth;
}

// How far a forced throw looks for somewhere to send the prop.  Long enough
// that whatever room the map has is measured, short enough that the trace is
// cheap.
#define HOLD_THROW_PROBE 1200.0

// Where a prop the bot is carrying can be thrown without coming back onto it.
//
// The gun launches along the view, and a bot's own AI leaves it looking at
// whatever it was last interested in -- often a wall, a crate, or the floor.
// The candidates are a ring of directions around the bot, each tilted up so a
// throw into open space arcs away instead of dropping at its feet, and the one
// whose ray runs furthest before it strikes anything wins: the further the prop
// travels before it lands, the further off the blast is.  A steeper tilt is
// charged a little, so an equally open flat direction is preferred to a throw at
// the ceiling.
//
// iIgnore is the prop itself, which must not count as an obstruction on the only
// line the claw has.  The length that won comes back, because it is the one
// number that explains the throw's outcome.
float PickThrowPoint(int iClient, int iIgnore, float fOut[3])
{
    float fEye[3];
    float fBest   = -1.0;
    float fBestAt = 0.0;

    GetClientEyePosition(iClient, fEye);

    for (int iYaw = 0; iYaw < 360; iYaw += 45)
    {
        for (int iPitch = 0; iPitch <= 30; iPitch += 15)
        {
            float fAngles[3], fDir[3], fEnd[3], fHit[3];

            // Source pitch is negative upward.
            fAngles[0] = -float(iPitch);
            fAngles[1] = float(iYaw);
            fAngles[2] = 0.0;

            GetAngleVectors(fAngles, fDir, NULL_VECTOR, NULL_VECTOR);

            fEnd[0] = fEye[0] + fDir[0] * HOLD_THROW_PROBE;
            fEnd[1] = fEye[1] + fDir[1] * HOLD_THROW_PROBE;
            fEnd[2] = fEye[2] + fDir[2] * HOLD_THROW_PROBE;

            TR_TraceRayFilter(fEye, fEnd, MASK_SOLID, RayType_EndPoint,
                              TraceFilter_Reach, iIgnore);

            TR_GetEndPosition(fHit);

            float fLen   = GetVectorDistance(fEye, fHit);
            float fScore = fLen - float(iPitch) * 2.0;

            if (fScore > fBest)
            {
                fBest   = fScore;
                fBestAt = fLen;

                fOut[0] = fHit[0];
                fOut[1] = fHit[1];
                fOut[2] = fHit[2];
            }
        }
    }

    return fBestAt;
}

void WatchPropHold()
{
    char sHeld[64];
    int  iHeld = PropInClaw(giBotClient, sHeld, sizeof(sHeld));

    float fNow = GetGameTime();

    // Nothing in the claw, or a different thing than last looked at: start over.
    if (iHeld == 0 || iHeld != giHeldProp)
    {
        giHeldProp   = iHeld;
        gfHeldSince  = fNow;
        gbHeldLogged = false;
        gbHoldThrow  = false;

        return;
    }

    float fHeld = fNow - gfHeldSince;

    // Past the config's limit the bot is made to throw what it is carrying.
    // Nothing here moves the object: the press goes through the same command
    // hook the swing presses the attack key with, and the engine's own gun does
    // the launching.  A swing owns the buttons while it is running, so the
    // press waits for one to finish.
    //
    // Where it is thrown is the whole of the fix.  The gun launches along the
    // view, so a bot left facing the wall in front of it throws the barrel into
    // that wall and the blast is on top of it -- which is what the report was.
    // A direction with room in it is chosen here, and the view is put on it now
    // rather than at the press, so the bot is already looking somewhere the prop
    // can travel by the time the command hook presses the key.
    if (giPropHoldTime > 0 && fHeld >= float(giPropHoldTime) && giSwingStage == SWING_NONE)
    {
        float fClear = PickThrowPoint(giBotClient, iHeld, gfHoldThrowAt);

        gbHoldThrow  = true;
        gbHoldAimed  = false;
        gfHeldSince  = fNow;   // the next press is another PropHoldTime away
        gbHeldLogged = false;

        AimBotAt(gfHoldThrowAt, 0.3);

        if (giHoldDrops < 6)
        {
            giHoldDrops++;
            LogMessage("[XMS] the bot has held %s for %.1f s -- throwing it for the bot along %.0f units of clear line%s",
                       sHeld, fHeld, fClear,
                       (fClear < 200.0) ? " (close: the blast may still reach the bot)" : "");
        }
    }

    if (gbHeldLogged || fHeld < 3.0) {
        return;
    }

    gbHeldLogged = true;

    if (giHoldLogs >= 6) {
        return;
    }

    giHoldLogs++;

    bool bInSight = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == giBotClient || !IsClientInGame(i) || !IsPlayerAlive(i) || IsFakeClient(i)) {
            continue;
        }

        float fWhere[3];

        GetClientEyePosition(i, fWhere);

        if (IsReachable(i, fWhere)) {
            bInSight = true;
            break;
        }
    }

    LogMessage("[XMS] the bot has held %s for %.1f s (a real player is %s)",
               sHeld, fNow - gfHeldSince, bInSight ? "in sight" : "not in sight");
}


int GetBallThrower(int iEnt)
{
    int iOwner = GetEntPropEnt(iEnt, Prop_Send, "m_hOwnerEntity");

    if (iOwner > 0 && iOwner <= MaxClients)
    {
        if (!IsFakeClient(iOwner) && IsClientInGame(iOwner)) {
            return iOwner;
        }

        // the bot's own orb, leave it alone
        return 0;
    }

    // An orb fired by a weapon points at that weapon rather than at the player.
    if (iOwner > MaxClients && IsValidEntity(iOwner))
    {
        int iCarrier = GetEntPropEnt(iOwner, Prop_Send, "m_hOwnerEntity");

        if (iCarrier > 0 && iCarrier <= MaxClients && !IsFakeClient(iCarrier) && IsClientInGame(iCarrier)) {
            return iCarrier;
        }
    }

    // The orb does not always carry a usable thrower, and with a single human
    // on the server there is only one candidate anyway.
    return GetOnlyRealPlayer();
}

int GetOnlyRealPlayer()
{
    int iFound;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
        {
            if (iFound) {
                return 0;
            }

            iFound = i;
        }
    }

    return iFound;
}

int Math_GetRandomIntNot(int iMin, int iMax, int iNot)
{
    int i;

    do {
        i = Math_GetRandomInt(iMin, iMax);
    }
    while (i == iNot);

    return i;
}
