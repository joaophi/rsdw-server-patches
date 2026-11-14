# rsdw-server-patches

Unofficial binary hotfixes for the **RuneScape: Dragonwilds dedicated server**
(Steam app `4019830`, Linux). They fix crashes and lost items/progress until
Jagex ships fixes. **Not affiliated with Jagex. Use at your own risk; keep
backups of your saves.**

This branch is for **game 1.0.2.1, Steam build 26574459 (CL 260223)**. Each
game version gets its own branch, and the default branch is the latest one.
On any other build the script changes nothing: every patch reports
`skipped: bytes differ`.

## Patches

| # | Patch | Problem | Upstream |
|---|---|---|---|
| 1 | Bow-break crash | Server SIGSEGVs ~100 ms after a player's bow breaks mid-shot (null bow in `UPlayerRangedAttackComponent::UpdateProjectileLaunchBasedOnClientData`) | — |
| 2 | Building-facade crash | Server SIGSEGVs when a player joins/teleports and a building piece destroyed earlier in the run is replicated (`FBuildingPieceActorFacade::GetSerializableId`, `BuildingPieceActorFacade.cpp:81`) | [#32](https://github.com/runescape/rsdw-dedicated/issues/32), [#36](https://github.com/runescape/rsdw-dedicated/issues/36) |
| 3 | Save on shutdown | A clean stop (SIGTERM) never saves the world; restarts lose up to 5 minutes | [#28](https://github.com/runescape/rsdw-dedicated/issues/28) |
| 4 | Travel pause | The server waits 4 s before switching from the startup map to the world | — |
| 5 | Station load drop | On restart, station inputs that only an **add-on** recipe uses (Tanner's Kit, Loom Harness, Crucible) are deleted, e.g. Cursed Essence in a Tanner | — |

The comments in [`patch.sh`](patch.sh) give the function, address and exact
instruction change for each one.

### How they work (short)

1. **Bow**: the getter `return this->[0x2f0]` (vaddr `0x834e600`) becomes
   null-safe; its caller already handles a null result.
2. **Facade**: the call `RawPiece->IsBuildingPieceValid()` on a dangling
   pointer (vaddr `0xa5cef8c`) becomes `xor eax,eax`, so the function takes
   its own "invalid piece" branch (warning in the log, empty id).
3. **Save on shutdown**: `ADominionGameMode::PrepareForWorldTeardown()`
   returns the "save deferred" flag (`+0x3a9`), which is almost never set, so
   `BeginWorldTeardown` skips its save. One byte makes it return "saving
   enabled" (`+0x3a8`). Your container must deliver SIGTERM to the server
   process (exec it as PID 1) for this to help.
4. **Travel pause**: `AGameModeBase::ProcessServerTravel` only zeroes the 4 s
   `ServerTravelPause` countdown for non-networked servers; its `je` is NOPed.
5. **Station load drop**: station add-ons register their recipes
   (`AddExtraRecipes`) after the station's inventory is restored, so the
   inventory rejects add-on-only inputs and
   `HandleLoadedItemWithInvalidSlot` deletes them ("Unable to find space for
   all of a misplaced item, skipping what can't be stored"). The reject branch
   in `UInventoryComponent::LoadStateFromJson` is detoured to 19 bytes in
   int3 padding: if the inventory is a station input inventory
   (`UResourceInventoryComponent`) the item is kept, otherwise it is dropped
   as before. The add-on's recipes arrive in the same frame, before anyone
   can join. Side effect: if an add-on is really gone, its inputs stay in the
   station until someone takes them out.

## Usage

Run with the server **stopped**:

```sh
./patch.sh status /path/to/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping
./patch.sh apply  /path/to/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping
./patch.sh revert /path/to/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping
```

It needs only `bash`, `od`, `dd` and `sed`.

Revert **before** SteamCMD updates the game and apply **after**. That way
the binary matches Steam's copy during the update, so SteamCMD doesn't
re-download it as a changed file. A typical container entrypoint:

```sh
BIN=/server/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping
./patch.sh revert "$BIN"
steamcmd +force_install_dir /server +login anonymous +app_update 4019830 +quit
./patch.sh apply "$BIN"
exec "$BIN" RSDragonwilds -log ...   # exec, so SIGTERM reaches the server
```

`apply` prints one line per patch (`applied`, `already applied` or
`skipped: bytes differ`). After a game update, expect `skipped` until a branch
for the new build exists.

## After a game update

The patches are byte windows at fixed file offsets, so a new build moves
them. To port them:

1. Search the new binary for each original window (the left hex string in
   `patch.sh`). From 1.0.1.x to 1.0.2.1, all of them were found exactly once,
   just shifted.
2. Confirm each hit is still the same function with the
   `RSDragonwildsServer-Linux-Shipping.sym` file that ships with the server
   (UE symbol format; its addresses are vaddr − `0x200000`). Also check that
   the bug is still there.
3. Update the offsets (file offset = vaddr − `0x201000` for `.text` in
   26574459), dry-run `apply`/`revert` on a copy, and check that `revert`
   gives back a byte-identical Steam copy.

## Verification

On 26574459, all patches run on a live server:

- `apply` → `apply` (already applied) → `revert` gives a byte-identical Steam
  binary (SHA-256 in `patch.sh`). Every patched site was disassembled to check
  the result.
- **3** and **4**: checked in the server log (`Save to slot … Success` on
  `docker stop`; the startup map switches at frame 1 instead of 120).
- **5**: traced with gdb (the station's accepted inputs before and after
  `AddExtraRecipes`). Tested by loading a save with Cursed Essence in a
  Tanner: nothing was dropped, and the essence was saved back.
- **1** and **2**: written from real crash reports (build 26161880) and
  ported unchanged. The crashes weren't reproduced on purpose.

## License

MIT for the script and docs. The server binary is Jagex's and is not included.
