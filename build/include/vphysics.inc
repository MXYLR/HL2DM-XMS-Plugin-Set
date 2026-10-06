/**
 * vphysics.inc - VPhysics extension compatibility layer
 *
 * The 64-bit VPhysics extension does not exist, so the handful of its natives
 * that XMS calls are emulated with stock SourceMod functionality.  Semantics
 * are close but not identical; see the notes on each function.
 */

#if defined _vphysics_included
  #endinput
#endif
#define _vphysics_included

#include <entity_prop_stocks>

/**
 * Returns whether an entity is a VPhysics-managed object.
 *
 * Emulated via the entity's move type: anything simulated by the physics
 * engine reports MOVETYPE_VPHYSICS.
 *
 * @param entity   Entity index.
 * @return         True if the entity is physics-managed.
 */
stock bool Phys_IsPhysicsObject(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
    {
        return false;
    }

    return GetEntityMoveType(entity) == MOVETYPE_VPHYSICS;
}

/**
 * Enables or disables an entity's physics simulation.
 *
 * Emulated by toggling the move type between MOVETYPE_VPHYSICS and
 * MOVETYPE_NONE.  Unlike the original, disabling does not put the prop to
 * sleep in place: it stops all movement entirely, so a prop disabled while
 * moving freezes rather than settling.
 *
 * @param entity   Entity index.
 * @param enable   True to simulate, false to freeze.
 */
stock void Phys_EnableMotion(int entity, bool enable)
{
    if (entity <= 0 || !IsValidEntity(entity))
    {
        return;
    }

    SetEntityMoveType(entity, enable ? MOVETYPE_VPHYSICS : MOVETYPE_NONE);
}

/**
 * Applies a gravity vector to the physics environment.
 *
 * Not emulated: there is no stock way to reach IVPhysicsEnvironment from
 * SourcePawn.  sv_gravity still takes effect for newly spawned props and for
 * players, but props already present on the map keep the gravity they were
 * created with until the map is reloaded.
 *
 * @param vec      Gravity vector (VPhysics uses Z as up).
 */
stock void Phys_SetEnvironmentGravity(const float vec[3])
{
}
