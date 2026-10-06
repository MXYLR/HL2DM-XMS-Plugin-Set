/**
 * steamtools.inc - SteamTools extension compatibility layer
 *
 * SteamTools has no 64-bit build, so its natives are emulated.  Only
 * Steam_SetGameDescription is used by XMS.
 */

#if defined _steamtools_included
  #endinput
#endif
#define _steamtools_included

#include <halflife>

/**
 * Overrides the game description reported to the server browser.
 *
 * Not emulated: the engine's game description is baked into the server DLL and
 * cannot be changed from SourcePawn without SteamTools.  This is a no-op, so
 * the server browser shows the stock HL2DM description instead of the active
 * gamemode's name.  Use the hostname cvar to disambiguate servers instead.
 *
 * @param description   Ignored.
 */
stock void Steam_SetGameDescription(const char[] description)
{
}

/**
 * Returns the game description reported to the server browser.
 *
 * The engine's built-in description is returned; any value supplied to
 * Steam_SetGameDescription is ignored by this emulation.
 *
 * @param buffer        Buffer to store the description.
 * @param maxlen        Maximum size of the buffer.
 * @return              Number of bytes written.
 */
stock int Steam_GetGameDescription(char[] buffer, int maxlen)
{
    return GetGameDescription(buffer, maxlen);
}

/**
 * Retrieves the public IP Steam reports for this server.
 *
 * Not emulated: SteamTools is required to query Steam's server info, and the
 * feature check that guards every caller in smlib reports the native as
 * unavailable, so this is never reached.  The octets are zeroed so an
 * accidental call cannot produce a bogus address.
 *
 * @param octets   Receives the address as four bytes, most significant first.
 * @noreturn
 */
stock void Steam_GetPublicIP(int octets[4])
{
    octets[0] = 0;
    octets[1] = 0;
    octets[2] = 0;
    octets[3] = 0;
}
