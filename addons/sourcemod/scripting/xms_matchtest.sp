#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION  "1.0"

#include <sourcemod>

public Plugin myinfo =
{
    name        = "XMS - Match Test",
    author      = "hl2dm-server",
    description = "Start a short, no-fraglimit match for testing XMS pause, teams, spectator lock and SourceTV recording",
    version     = PLUGIN_VERSION,
    url         = ""
};

/**************************************************************
 * WHAT THIS IS FOR
 *
 * A real XMS match needs a vote, three players and a matchable
 * gamemode, which is exactly what a test server does not have.
 * The one path with none of those checks is the server console's
 * own "start": Cmd_Start returns early when it is called with no
 * client and calls Start() straight away.  So the command below
 * only has to get the round limits right and then say "start" to
 * the console.
 *
 * The limits go in first because the match reads them when the
 * round restarts, and mp_fraglimit 0 is what makes it a match with
 * no kill limit.  SetGamemode is not involved on this path (only
 * the modes in xms.cfg go through it, and its Command would
 * overwrite mp_timelimit with the mode's own), so the minute set
 * here is the minute played.
 *
 * SourceTV has to already be running for the demo to be recorded,
 * which is why cfg/server.cfg turns it on at startup -- XMS starts
 * and stops the recording itself around the match.
 *
 * If the console is not reachable, the same thing by hand is
 * "mp_fraglimit 0", "mp_timelimit 1", "start".
 *
 * The command is open to everyone on purpose: this test server has
 * no admin entries in admins.cfg, so an admin-only command would be
 * refused to the very player it is for.  If the server is ever
 * opened to strangers, move it back to RegAdminCmd before that.
 *************************************************************/

public void OnPluginStart()
{
    CreateConVar("xms_matchtest_version", PLUGIN_VERSION, _, FCVAR_NOTIFY);

    RegConsoleCmd("sm_matchtest", Cmd_MatchTest,
                  "Start a test match with no frag limit: sm_matchtest [minutes] (default 1)");
}

public Action Cmd_MatchTest(int iClient, int iArgs)
{
    int iMinutes = 1;

    if (iArgs >= 1)
    {
        char sArg[8];

        GetCmdArg(1, sArg, sizeof(sArg));
        iMinutes = StringToInt(sArg);
    }

    if (iMinutes < 1) {
        iMinutes = 1;
    }

    ServerCommand("mp_fraglimit 0");
    ServerCommand("mp_timelimit %d", iMinutes);
    ServerCommand("start");

    LogMessage("[XMS] test match started from %L: %d minute(s), no frag limit", iClient, iMinutes);
    ReplyToCommand(iClient, "[XMS] test match: %d minute(s), no frag limit. \"cancel\" ends it early, \"pause\" tests the pause.", iMinutes);

    return Plugin_Handled;
}
