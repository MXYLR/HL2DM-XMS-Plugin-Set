#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION  "1.0"
#define PLUGIN_URL      "www.hl2dm.community"

public Plugin myinfo = {
    name              = "xShadows",
    version           = PLUGIN_VERSION,
    description       = "Stops carried weapons from casting bogus shadows (demoplayback / thirdperson)",
    author            = "local",
    url               = PLUGIN_URL
};

/**************************************************************
 * INCLUDES
 *************************************************************/
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

/**************************************************************
 * WHY THIS EXISTS
 *
 * A holstered weapon is hidden with EF_NODRAW only
 * (CBaseCombatWeapon::SetWeaponVisible). Every renderable treats
 * EF_NODRAW as "casts no shadow" except C_BaseCombatWeapon, whose
 * ShadowCastType() has EF_NODRAW commented out of the test. On top
 * of that C_BaseEntity::CreateShadow() never asks ShouldDraw().
 * All carried weapons are bone merged onto their owner, so in a
 * demo or in third person every weapon of the loadout keeps
 * casting a render-to-texture shadow in the player's hands and the
 * shadow shows the whole loadout instead of the weapon in use
 * (players see it as "always holding a crossbow").
 *
 * EF_NOSHADOW is part of the networked m_fEffects prop, so the
 * server can put the bit on the weapon entities. The client then
 * runs OnDataChanged -> CreateShadow() -> ShadowCastType() and
 * destroys the shadow. The bit is only ever set while the weapon
 * is carried, and only bits this plugin set are ever cleared, so
 * map entities using "disableshadows" are left alone.
 *************************************************************/

#define EF_NOSHADOW     0x010
#define UPDATE_INTERVAL 0.2

enum
{
    SHADOW_OFF,      // 0 - do nothing
    SHADOW_CARRIED,  // 1 - no carried weapon casts a shadow
    SHADOW_INACTIVE  // 2 - holstered weapons stop casting one, the weapon in use keeps a correct one
};

/**************************************************************
 * GLOBAL VARS
 *************************************************************/
ConVar    gConVar_Mode;
ArrayList gmHidden;    // entrefs of every weapon this plugin has set EF_NOSHADOW on

/**************************************************************/

public void OnPluginStart()
{
    gConVar_Mode = CreateConVar("xshadows_mode", "2", "0 = off, 1 = no carried weapon casts a shadow, 2 = only holstered weapons stop casting one", _, true, 0.0, true, 2.0);
    gConVar_Mode.AddChangeHook(OnModeChanged);
    CreateConVar("xshadows_version", PLUGIN_VERSION, _, FCVAR_NOTIFY);
    AutoExecConfig();

    gmHidden = new ArrayList();
    RegAdminCmd("sm_shadows", Cmd_Shadows, ADMFLAG_GENERIC, "Show the shadow state of every weapon carried by the players");
}

public void OnPluginEnd()
{
    // give the weapons their shadows back in case the plugin is unloaded mid-map
    for (int i = 0; i < gmHidden.Length; i++)
    {
        int iWeapon = EntRefToEntIndex(gmHidden.Get(i));

        if (iWeapon != INVALID_ENT_REFERENCE) {
            SetEffectsFlag(iWeapon, EF_NOSHADOW, false);
        }
    }

    gmHidden.Clear();
}

public void OnMapStart()
{
    gmHidden.Clear();
    CreateTimer(UPDATE_INTERVAL, T_Refresh, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int iClient)
{
    if (!IsClientSourceTV(iClient)) {
        SDKHook(iClient, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    }
}

public void OnWeaponSwitchPost(int iClient, int iWeapon)
{
    // no waiting for the timer when a player switches weapons
    Refresh();
}

public void OnModeChanged(Handle hConVar, const char[] sOldValue, const char[] sNewValue)
{
    Refresh();
}

public Action T_Refresh(Handle hTimer)
{
    Refresh();
    return Plugin_Continue;
}

/**************************************************************
 * SHADOW STATE
 *************************************************************/
void Refresh()
{
    ArrayList hDesired = new ArrayList();
    int       iMode    = gConVar_Mode.IntValue;

    if (iMode != SHADOW_OFF)
    {
        for (int iClient = 1; iClient <= MaxClients; iClient++)
        {
            if (!IsClientInGame(iClient) || IsClientSourceTV(iClient)) {
                continue;
            }

            int  iActive = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon"),
                 iSlots  = GetEntPropArraySize(iClient, Prop_Send, "m_hMyWeapons");
            bool bAlive  = IsPlayerAlive(iClient);

            for (int iSlot = 0; iSlot < iSlots; iSlot++)
            {
                int iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hMyWeapons", iSlot);

                if (iWeapon <= MaxClients || !IsValidEntity(iWeapon)) {
                    continue;
                }

                // m_iState 0 means the weapon is lying in the world, not carried
                if (GetEntProp(iWeapon, Prop_Send, "m_iState") == 0) {
                    continue;
                }

                // nothing of a dead player is rendered, so none of his weapons should cast a shadow
                if (bAlive && iMode == SHADOW_INACTIVE && iWeapon == iActive) {
                    continue;
                }

                hDesired.Push(EntIndexToEntRef(iWeapon));
            }
        }
    }

    // weapons that are held again, dropped or gone get their shadow back
    for (int i = gmHidden.Length - 1; i >= 0; i--)
    {
        int iRef    = gmHidden.Get(i),
            iWeapon = EntRefToEntIndex(iRef);

        if (iWeapon != INVALID_ENT_REFERENCE && hDesired.FindValue(iRef) != -1) {
            continue;
        }

        if (iWeapon != INVALID_ENT_REFERENCE) {
            SetEffectsFlag(iWeapon, EF_NOSHADOW, false);
        }

        gmHidden.Erase(i);
    }

    // and the ones that have to lose theirs now
    for (int i = 0; i < hDesired.Length; i++)
    {
        int iRef = hDesired.Get(i);

        if (gmHidden.FindValue(iRef) != -1) {
            continue;
        }

        if (SetEffectsFlag(EntRefToEntIndex(iRef), EF_NOSHADOW, true)) {
            gmHidden.Push(iRef);
        }
    }

    delete hDesired;
}

// returns true if the entity's m_fEffects really changed
bool SetEffectsFlag(int iEntity, int iFlags, bool bSet)
{
    if (!IsValidEntity(iEntity)) {
        return false;
    }

    int iEffects = GetEntProp(iEntity, Prop_Send, "m_fEffects");

    if (bSet)
    {
        if ((iEffects & iFlags) != 0) {
            return false;
        }

        iEffects |= iFlags;
    }
    else
    {
        if ((iEffects & iFlags) == 0) {
            return false;
        }

        iEffects &= ~iFlags;
    }

    SetEntProp(iEntity, Prop_Send, "m_fEffects", iEffects);

    return true;
}

public Action Cmd_Shadows(int iClient, int iArgs)
{
    char sClass[64];

    ReplyToCommand(iClient, "[xShadows] mode %i, %i weapon(s) hidden by this plugin", gConVar_Mode.IntValue, gmHidden.Length);

    for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
    {
        if (!IsClientInGame(iPlayer) || IsClientSourceTV(iPlayer)) {
            continue;
        }

        int iActive = GetEntPropEnt(iPlayer, Prop_Send, "m_hActiveWeapon"),
            iSlots  = GetEntPropArraySize(iPlayer, Prop_Send, "m_hMyWeapons");

        for (int iSlot = 0; iSlot < iSlots; iSlot++)
        {
            int iWeapon = GetEntPropEnt(iPlayer, Prop_Send, "m_hMyWeapons", iSlot);

            if (iWeapon <= MaxClients || !IsValidEntity(iWeapon)) {
                continue;
            }

            GetEdictClassname(iWeapon, sClass, sizeof(sClass));
            ReplyToCommand(iClient, "  #%i %s  state %i%s  EF_NOSHADOW %s",
                iWeapon,
                sClass,
                GetEntProp(iWeapon, Prop_Send, "m_iState"),
                (iWeapon == iActive) ? " (active)" : "",
                (GetEntProp(iWeapon, Prop_Send, "m_fEffects") & EF_NOSHADOW) ? "set" : "unset"
            );
        }
    }

    return Plugin_Handled;
}
