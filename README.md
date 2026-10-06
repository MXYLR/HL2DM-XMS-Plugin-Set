# HL2DM-XMS-Plugin-Set

A 64-bit port of [utharper/sourcemod-hl2dm](https://github.com/utharper/sourcemod-hl2dm), plus
a rebuilt bot plugin and a set of generated navigation meshes.

Upstream's plugins are built for 32-bit SourceMod. This tree compiles and runs
them on the **64-bit** SourceMod/MetaMod build of the HL2DM dedicated server
(`srcds_win64`), which needs a handful of small source fixes, and replaces the
RCBot2-based `xms_bots` with a controller for the **engine's own built-in
bots**.

Everything here is GPL-3.0 (see [LICENSE](LICENSE)) and is upstream's work with
the changes listed below. Original project and credit: **utharper**, Australian
Deathmatch. The plugin documentation further down this file is upstream's and
still applies unless a section says otherwise.

## What this fork changes

**64-bit compiler compatibility** (`spcomp64`, SourceMod 1.12). Three upstream
constructs do not compile or do not behave the same on the 64-bit toolchain:

| File | Change |
|---|---|
| `xms/mapmode.sp`, `xms/commands.sp` | `GetMapsArray`'s last parameter was `char[][] sArray2 = sArray`, an array default argument `spcomp64` rejects. The default is gone and every caller now passes the buffer explicitly. |
| `xms/xmenu.sp` | `char sLetters[26] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"` is 26 characters plus a terminator; the buffer is now `[27]` and the loop stops at `sizeof-1`. |
| `xms/clients.sp`, `xms/hud.sp` | The `T_AnnouncePlugin` centre-text ("~ eXtended Match System by harper ~") is removed from the join path. |

**`xms_bots` rewritten** — see [xms_bots](#xms_bots) below.

**New plugins**

* `xshadows` — stops carried weapons from casting bogus shadows, which is the
  "always holding a crossbow" artefact in demos and third person.
* `xms_matchtest` — `sm_matchtest [minutes]` starts a short no-fraglimit match,
  for testing XMS pause/teams/spectator lock/SourceTV on a server that has
  neither a vote nor three players.

**Generated navigation meshes** — `maps/*.nav`, 67 of them. See
[Navigation meshes](#navigation-meshes).

## Layout

```
addons/sourcemod/
  configs/xms.cfg          upstream's gamemode and feature config
  plugins/*.smx            built plugins (drop-in)
  scripting/*.sp           sources, plus xms/ (the XMS modules)
  translations/            phrases
build/
  build_xms.sh             builds every plugin in this tree
  include/                 smlib and friends, vendored (not shipped by SourceMod)
cfg/                       server.cfg, mapcycles, rates, xms_bots.cfg
maps/*.nav                 generated navigation meshes
sound/xms/                 XMS sounds
```

To install on a server, copy `addons/`, `cfg/` and `sound/` over the server's
`hl2mp/`, and drop `maps/*.nav` into `hl2mp/maps/` next to the `.bsp` files.

## Building

Needs a SourceMod install for `spcomp64` and the stock includes — 1.12 is what
this was built against; unpack one and point the script at it:

```bash
./build/build_xms.sh /path/to/addons/sourcemod
```

`SM_DIR` is read as an alternative, and an unpacked SourceMod folder sitting at
`../deps/sm-official` is found automatically. The `.smx` files are written
straight into `addons/sourcemod/plugins/`.

`smlib`, `morecolors`, `steamtools`, `updater` and `vphysics` are vendored under
`build/include/` because SourceMod does not ship them; they belong to their own
authors.

`gameme_hud.smx` and `xms_discord.smx` are upstream binaries — they are not
rebuilt here (`gameme_hud` needs the gameME extension and `xms_discord` the
SteamWorks one) and their sources are untouched.

## Navigation meshes

`maps/*.nav` are generated meshes for all 67 maps the server has installed.

The engine only builds a mesh for the map it is currently running, so they were
made one map at a time: move the map's `.nav` aside, restart the server on that
map, and `xms_bots` generates the missing mesh at map start (`CheckNavMesh`,
which needs `NavGenerate` set in `xms.cfg`). Each existing mesh was kept beside
the new one as `.nav.bak`, so nothing was silently overwritten.

**Four of them are not usable as meshes.** `nav_generate` reports
`Generation complete!` even when it found almost nothing, so a file's existence
is not coverage. These four came out with a single nav area (~153-204 bytes)
and bots will not navigate those maps:

* `dm_killbox_kbh_2p`
* `dm_egypt_story_b2`
* `jump_bunny_ruins_beta_v2`
* `z_umizuri_hydra`

Check any mesh by its size and by the engine's
`NavMesh Visibility List Lengths: min/avg/max` line — a healthy map reads like
`min 2, avg 67, max 160` and 100 KB or more, and any `max <= 3` is no mesh at
all. Re-running `nav_generate` reproduces the same result; those four need
hand-authored nav or community waypoints.

The meshes are committed as binary blobs (~73 MB across the set, the largest
12-14 MB). If that becomes a problem, they can move to a release artifact
instead.

---

The rest of this file is upstream's.

---

This page hosts my public Sourcemod plugins for [Half-Life 2 Deathmatch](https://store.steampowered.com/app/320/HalfLife_2_Deathmatch/) servers. These were originally created for Australian Deathmatch

* [xFov](#xFov) - Extended field-of-view for players
* [xFix](#xFix) - Fixes various game bugs/exploits/annoyances (previously called hl2dmfix)
* [XMS](#XMS) - eXtended Match System for competitive servers
  * [xms_bots](#xms_bots) - Bot controller for XMS servers
  * [xms_discord](#xms_discord) - Publish match results to discord server(s).
  * [xshadows](#xshadows) - Stops carried weapons casting bogus shadows
  * [xms_matchtest](#xms_matchtest) - Start a short test match
* [gameme_hud](#gameme_hud) - Displays a stats HUD in the scoreboard, using gameME data.
* [Misc](#Misc) - Other potentially useful stuff (work in progress).


# xFov
![FOV demonstration](https://i.imgur.com/8XydE9f.png)

HL2DM restricts player field-of-view to a value of 90, which is not ideal for widescreen monitors and can make the game feel very 'zoomed in' compared to other shooters.
This plugin allows players to set thier FOV to any range of values you permit. In the default configuration it will allow a minimum of 90, and a maximum of 110. 

Players can set their FOV by typing `fov <value>` in console, or via the **!fov** command. Their setting will be remembered between map changes and server reconnects, so they only need to do this once.

The FOV temporarily resets to 90 when players use zoom functions (such as toggle_zoom and crossbow secondary attack), to overcome glitchy behaviour seen in previous implementations.

### Convars
You can configure these in `cfg/sourcemod/plugins.xfov.cfg` after first load.

* `xfov_defaultfov` - Default FOV for new players. 90 by default.
* `xfov_minfov` - Minimum FOV allowed on server. 90 by default.
* `xfov_maxfov` - Maximum FOV allowed on server. 110 by default.

### Download
* [Download zip](https://github.com/utharper/sourcemod-hl2dm/releases/download/latest/xfov.zip)
* [Source](addons/sourcemod/scripting/xfov.sp)


# xFix
**Requires [VPhysics](https://builds.limetech.io/?project=vphysics) extension**

This plugin workarounds some of the issues with the game, such as scoring bugs, and aims to improve the overall player experience without compromising gameplay in any way.
This has not really been developed far but already fixes a few things:

- Remove case sensitivity for commands, and adds compatibility for the old `#.#` command prefix
- Disable team chat if mp_teamplay is 0
- Block annoying game chat spam such as 'Please wait x more seconds before trying to switch' and server cvar messages
- Disable showing the MOTD on connect if motd.txt doesn't exist or is empty
- Disable the spectator bottom menu, as the options are mislabeled and it tends to get stuck in place
- Disable an extra third-person spectator mode which serves no function
- Fix various small spectator bugs
- Fix all of the game's scoring bugs
- Improved save scores (if someone disconnects and rejoins the same round, their score is retained)
- Block an exploit which allows crouched players to have the visibility of a standing player
- (via Vphysics) Fix prop gravity not changing correctly with sv_gravity
- Fix mp_falldamage value not having any effect
- Block the annoying explosion ringing sound
- Includes shotgun altfire lag compensation fix, by **V952**
- Includes Hands animation fix, by **toizy**
- Includes env_sprite exploit fix, by **sidezz**

No configuration is required.

### Download
* [Download](https://github.com/utharper/sourcemod-hl2dm/releases/download/latest/xfix.smx)
* [Source](addons/sourcemod/scripting/xfix.sp)


# XMS
**Requires [SteamTools](https://builds.limetech.io/?p=steamtools) and [VPhysics](https://builds.limetech.io/?project=vphysics) extensions, and xFix**

**XMS** (eXtended Match System) is the most advanced system for competitive HL2DM servers. Commands are backwards compatible with VG servers and the old servermanagement plugin by gavvvr. It also features an easy player menu and is intended to be as simple for players to use as possible.

You can easily define your own custom gamemodes, but the default config contains **dm**, **tdm**, **kb** (killbox low-grav), **jm** (jump maps), **surf** (surf maps), **ctf** (Capture The Flag) and **arcade** (spawn with all weapons).

Everything is configured and explained in `addons\sourcemod\configs\xms.cfg`.

### Menu
XMS provides a simple menu which automatically opens and stays open. This allows players to quickly press ESC and access most functionality without having to type in commands:

![menu](https://i.imgur.com/Qt1PFL0.png)

From this menu players can choose their team, call a vote to change the map/gamemode, start/stop/pause a match, view other player's steam profiles, set their FOV (if xFov is in use), change their player model, etc etc.

Players need to set `cl_showpluginmessages 1` for the menu to be visible (in common with all Sourcemod menus in HL2DM, after a game update a few years ago). If they have not set this, a warning message will be displayed in their chat advising them how to do so.

### Commands
**!run** `<gamemode>`:`<map>`

(Vote to) change to the specified map and/or gamemode. eg: `!run tdm`, `!run tdm:lockdown`, `!run lockdown`.

For the map query, first a list of predefined map abbreviations (in xms.cfg) is checked, eg `ld` corresponds to`dm_lockdown`. If an exact match is not found there, then the server maps folder is searched directly. If multiple maps match the search term, then it will output a list to the player and take no action. This may seem over-complicated but is intended to be intuitive to players, instead of having to memorise a thousand map abbreviations.

You can input multiple modes/maps to create a multiple choice vote. eg: `!run lockdown, halls3, dm:runoff, tdm:runoff, arcade:powerhouse` (one command)

**!runnext** `<gamemode>`:`<map>`  _(or **!next**)_

Exactly the same as !run, but it sets the next map rather than changing immediately.

**!runrandom** _(or **!random**)_

Calls a vote to change to one of a selection of random maps and gamemodes.

**!start**

(Vote to) begin a countdown to start a competitive match. During a match several important game settings are enforced, and a match demo is recorded. Teams are also locked during a match: players can't switch teams, and spectators can't join.

**!cancel**

(Vote to) bring a match to a premature end. The match demo will be discarded.

**!list**

Display a list of available maps in the current gamemode. This can be overriden to show maps for another gamemode:
- `!list jm` will show all maps from the jm mode's mapcycle (mapcycle_jm.txt)
- `!list all` will show every map on the server.

**!coinflip** _(or **!flip**)_

Inherited from the old PMS plugin, this randomly returns heads or tails. Useful for determining who gets first map choice, etc.

**!profile** `<player name>`

Open the given player's Steam profile in a MOTD window.

**!forcespec** `<player name>`

*Requires Generic Admin*. Move the specified player to spectators. Useful if someone is AFK and blocking a match. Spectators will stay in spec between map-changes, until they manually change teams, so you'll only need to use this command on them once.

**!allow** `<player name>`

*Requires Generic Admin*. Allow the specified player to join an ongoing match. Useful to substitute players mid-game, or if one of the players has ragequit.

**!shuffle**

(Vote to) shuffle the teams. Team counts will be balanced, and all players assigned to a random team.

**!invert**

(Vote to) invert the teams. All players will swap from their current team, to the opposite team.

**!vote** `<motion>`

Call a custom yes/no vote. No action is taken on the outcome.

**!votekick** `<player name or id>`

Calls a vote to kick this player.

**!votemute** `<player name or id>`

Calls a vote to mute this player. They will not be able to talk on the mic.

**!pause**

Pause/unpause the game

**!menu**

(Re)open the menu if it was accidentally closed.

**!model**

Shortcut to open the player model submenu

**!hudcolor**

Shortcut to open the hud color submenu

### Some other features (extremely out of date)

- Scripting natives if a gamemode requires custom code
- Configurable voting system for core commands, with vote announce sounds taken from [Xonotic](https://xonotic.org/). 
- Remaining time HUD
- Spectator HUD, showing health/suit, pressed keys, angle and velocity. Original idea and implementation by **Adrian**
- End of game music (various tracks from HL2 and HL1), fading out as the map changes
- Working pause system, with auto-pause if someone disconnects during a match
- Working sudden-death overtime system
- Match information and results get saved to a .txt file alongside the .dem (match demo)
- Locked teams during a match, so the server does not need to be password protected
- Overrides the output of basecommands `timeleft`, `nextmap`, `currentmap` to corrected values
- Force player models to rebels or standard combine (no more gleaming white combine models unless a player chooses it)
- Optionally reverts to default mapcycle when server is empty (attracts random players using the simplified server browser)

### Configuration

After extracting the contents of xms.zip, you will want to edit `cfg/server.cfg` to set your desired hostname, sv_region, etc. Make sure to uncomment the correct rates config (first 2 lines). You should also set your hostname in `cfg/server_match.cfg` and `cfg/server_match_post.cfg`.

Make sure the server works, and then you can proceed to edit `xms.cfg` to your desired values. Everything is explained in there.

Finally, you will need to configure your mapcycles (these are also in the `cfg` folder). Be sure to only include maps that are actually in your maps folder. If maps in the mapcycle do not actually exist on the server, this may cause errors (and will be logged).

You can refer to any `error_` log files in `addons/sourcemod/logs` to help identify problems. If you need help, post in the #development channel on Discord.

### Download
* [Download zip](https://github.com/utharper/sourcemod-hl2dm/releases/download/latest/xms.zip)
* [Source](addons/sourcemod/scripting/xms.sp)


## xms_bots

**Requires XMS. No RCBot2** — this version drives the engine's own built-in
HL2DM bots (`CHL2MPBot`), the same ones `hl2mp_bot_quota` spawns.

Upstream's `xms_bots` was an RCBot2 controller. This one keeps upstream's
behaviour — a bot joins an empty server, plays until a second human connects,
then leaves — and adds the pieces the built-in bots are missing.

### What it adds

**Prop and grenade reactions.** The bots ignore thrown things. A player's
gravity-gun punt sends a crate or barrel past a bot with no answer, and a thrown
grenade is simply something to stand next to. The plugin watches the gravity gun
and swings it at whatever is coming in: it grabs a grenade or an energy ball out
of the air and throws it back, and bats a thrown prop the same way.

The bot cannot be asked to do this — there is no server-side "swing at that" —
so the plugin drives the gun's own keys, turning the bot onto the target and
pressing attack. It only ever presses what the engine's gun already does.

Two engine details shape the code, and both were established by measurement
rather than reading:

* A physics prop's speed cannot be read from `m_vecVelocity` or
  `m_vecAbsVelocity` — **both read exactly 0** on every `prop_physics` and
  `func_physbox`, including one the bot is visibly carrying. The motion lives in
  the prop's physics object and is never written back. Speed is measured from
  the change in `m_vecOrigin` between two ticks instead, and a jump past
  3000 u/s is treated as a teleport (a respawnable barrel coming back) rather
  than flight.
* A player-thrown `npc_grenade_frag` reads junk for `m_bIsLive` and
  `m_hThrower`, so the code never asks who threw it — it tests the frag's own
  closing speed toward the bot. That also keeps the bot from reeling back a frag
  it threw itself.

**Holding an explosive barrel.** The engine's own hold action keeps whatever the
gravity gun picked up until it has something to throw at, so a bot can stand
there holding a barrel indefinitely. The plugin gives a hold a deadline and, past
it, presses the gun's throw key — which is what the bot meant to do anyway — so
the barrel leaves its hands before something shoots it.

**Body, voice and animation.** A fake client never reaches the engine's
`SetPlayerModel` path, so a bot wears a Combine body while keeping the citizen
footsteps and death sound, and the engine re-picks its model several times a
second. The plugin re-asserts the sound type and the model after PostThink,
every frame. Re-picking a model restarts the animation at sequence 0, which for
these models is the `reference` pose — the T-shape — and in mid-air the activity
does not change, so the bot wore it for the whole jump. The plugin remembers the
last non-zero sequence and writes it back on any frame it reads 0.

**Damage attenuation.** Bot shots hit for less, so a bot is an opponent rather
than an aimbot. This is the only lever applied to aiming; the engine's bot AI is
otherwise left alone.

### Configuration

Every key below goes in the `"Bots"` section of `addons/sourcemod/configs/xms.cfg`.
**This tree ships upstream's `xms.cfg` unchanged**, so none of these keys are
present and each one falls back to its default — which for the whole list is
"off". Add the ones you want.

| Key | Default | What it does |
|---|---|---|
| `Gamemodes` | `dm,arcade` | Which gamemodes the bot spawns in. |
| `JoinDelay` | `10` | Seconds a map must have been running before the bot joins. |
| `QuitDelay` | `10` | Seconds to wait after a second player joins before leaving. |
| `DamagePercent` | `100` | How much of its normal damage the bot's weapons do to a real player. What the bot throws is exempt. |
| `CatchRadius` | `0` | How close an incoming frag or combine ball gets before the bot swings at it. |
| `GrabRange` | `0` | How close before the gun's key is pressed; clamped to 85% of the gun's 250-unit reach. |
| `PropHoldTime` | `0` | Seconds the bot may hold a prop before the plugin throws it. |
| `NavGenerate` | `0` | Let a server with no player generate a missing nav mesh at map start. |
| `NavPassMaps` | *(empty)* | A one-off list of maps to walk and generate meshes for; leave empty for normal running. |
| `AutoBhop` | `0` | Jump on landing and strafe in the air the way a TAS does. |
| `BhopMaxSpeed` | `0` | Speed at which the strafing stops, so the bot does not run away from the fight. |
| `BhopAngle` | `0` | Degrees off straight-sideways for the air strafe. |
| `Model` | *(empty)* | The model the bot wears. A fake client has no `cl_playermodel`, so without this the bot changes body at random. |

`cfg/xms_bots.cfg` (executed at map start) holds the *engine's* built-in bot
cvars this server runs with — difficulty, prop handling, health seeking — each
with a comment saying what it does and why. Note those are cheat-flagged, so
they need `sm_cvar`.

A bot only lives while a real player is on the server, so a bot added by rcon on
an empty server is dropped within about a second. Testing anything here needs a
player actually connected.

### Download
* [Source](addons/sourcemod/scripting/xms_bots.sp)


## xshadows

Stops carried weapons from casting shadows they should not.

A holstered weapon is hidden with `EF_NODRAW` alone (`CBaseCombatWeapon::SetWeaponVisible`),
and every renderable treats `EF_NODRAW` as "casts no shadow" — except
`C_BaseCombatWeapon`, whose `ShadowCastType()` has `EF_NODRAW` commented out of its
test. All carried weapons are bone-merged onto their owner, so in a demo or in third
person every weapon of the loadout keeps casting a render-to-texture shadow in the
player's hands, and the shadow shows the whole loadout instead of the weapon in use.
Players see it as "always holding a crossbow".

`EF_NOSHADOW` is part of the networked `m_fEffects` prop, so the server can set the
bit on the weapon entities and the client destroys the shadow. The bit is only set
while a weapon is carried, and only bits this plugin set are ever cleared, so map
entities using `disableshadows` are left alone.

`xshadows_mode`: `0` off, `1` no carried weapon casts a shadow, `2` (default) only
holstered weapons stop casting one, so the weapon actually in use keeps a correct
shadow.

A demo only looks right if it was *recorded* with the plugin running — the flag is
baked into the recorded snapshot, so demos recorded before it stay as they were.

### Download
* [Source](addons/sourcemod/scripting/xshadows.sp)


## xms_matchtest

A real XMS match needs a vote, three players and a matchable gamemode, which a
test server does not have. The one path with none of those checks is the server
console's own `start`: `Cmd_Start` returns early when called with no client and
calls `Start()` straight away.

`sm_matchtest [minutes]` (default 1) sets `mp_fraglimit 0` and
`mp_timelimit`, then issues `start` to the console. The limits go in first because
the match reads them when the round restarts, and `mp_fraglimit 0` is what makes it
a match with no kill limit. XMS's `SetGamemode` is not involved on this path, so
the minutes set here are the minutes played.

SourceTV has to already be running for the demo to be recorded, which is why
`cfg/server.cfg` turns it on at startup; XMS starts and stops the recording itself
around the match.

The command is open to everyone on purpose — this server has no admin entries in
`admins.cfg`, so an admin-only command would be refused to the player it is for. If
the server is ever opened to strangers, move it back to `RegAdminCmd` first.

### Download
* [Source](addons/sourcemod/scripting/xms_matchtest.sp)


## xms_discord
**Requires XMS and the [SteamWorks](https://forums.alliedmods.net/showthread.php?t=229556) extension**

![xms_discord output example](https://i.imgur.com/o41mcaN.png)

This plugin was created for the [HL2DM Community Discord server](https://hl2dm.community). It posts the results of all matches, along with links to download the match demo and view the participant's profiles. This is done via webhook(s), you can set up multiple webhooks if you wish.
It will also optionally post player feedback (submitted via the XMS menu) to a seperate webhook/channel.

Everything is configured in the `"Discord"` section of `xms.cfg`.

### Download
* Included with XMS download
* [Source](addons/sourcemod/scripting/xms_discord.sp)


# gameme_hud
**Requires the [gameME plugin](https://github.com/gamemedev/plugin-sourcemod) (gameME is a paid service)**

Displays a HUD (left of the scoreboard) showing your overall rank, kills, deaths, headshots, accuracy, etc.
It only shows when the scoreboard is open (by holding TAB). If you are spectating another player, it will show their stats instead.

![gameme_hud_example](https://i.imgur.com/zww76IL.png)

No configuration is required. If the server is also running XMS, it will use the player's desired `!hudcolor`.

It is not strictly just a HUD, as it also provides hacky natives for other plugins to access the data. This allows for stats to also appear in the XMS menu.

Unfortunately, this plugin causes a LOT of rcon message spam in the server console. See [Cleaning up console spam](#Misc).

### Download
* [Download zip](https://github.com/utharper/sourcemod-hl2dm/releases/download/latest/gameme_hud.zip)
* [Source](addons/sourcemod/scripting/gameme_hud.sp)


# Misc

### Cleaning up console spam.

Certain plugins/maps/actions can trigger a lot of annoying spam in the server console, making it difficult to see what is going on. 

This annoyance can be remedied with the [Cleaner](https://forums.alliedmods.net/showthread.php?p=1789738) extension. See an example cleaner.cfg below:

```
playerinfo
gameme_raw_message
[RCBot]
[RCBOT2]
rcon
Ignoring unreasonable position
"Server" requested "top10"
DataTable
Interpenetrating entities
logaddress_
gameME
changed cvar
ConVarRef room_type
Writing cfg/banned_
```
