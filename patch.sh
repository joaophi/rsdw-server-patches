#!/bin/bash
# Unofficial hotfixes for the RuneScape: Dragonwilds dedicated server
# (Steam app 4019830), Linux build 26574459 (game 1.0.2.1, CL 260223).
#
#   ./patch.sh status <RSDragonwildsServer-Linux-Shipping>
#   ./patch.sh apply  <RSDragonwildsServer-Linux-Shipping>
#   ./patch.sh revert <RSDragonwildsServer-Linux-Shipping>
#
# Run it while the server is stopped. Revert before SteamCMD updates the game
# (so the binary matches Steam's copy again) and apply after; see README.md.
#
# Every patch is a byte window: original -> patched. A window is only written
# when the current bytes match the other side, so running twice is harmless
# and a different build (neither side matches) is left alone ("skipped").
set -u

EXPECTED_SHA256=1b779665120e8d0df8c5d481969cdb2d1a4df52441cd5569ad2309ec62da1d26 # unpatched 26574459

function setPatch() { # name, file offset, original hex, patched hex, apply|revert|status
  local name=$1 off=$(($2)) orig=$3 new=$4 mode=$5 cur from to done
  cur=$(od -An -tx1 -v -j "$off" -N $((${#orig} / 2)) "$BIN" | tr -d ' \n')
  if [ "$mode" == "status" ]; then
    if [ "$cur" == "$new" ]; then echo "$name: applied"
    elif [ "$cur" == "$orig" ]; then echo "$name: not applied"
    else echo "$name: bytes differ (other build?)"; return 1; fi
    return 0
  fi
  if [ "$mode" == "apply" ]; then
    from=$orig; to=$new; done='applied'
  else
    from=$new; to=$orig; done='reverted'
  fi
  if [ "$cur" == "$from" ]; then
    printf "$(sed 's/../\\x&/g' <<<"$to")" |
      dd of="$BIN" bs=1 seek="$off" conv=notrunc status=none
    echo "$name patch $done"
  elif [ "$cur" == "$to" ]; then
    echo "$name patch already $done"
  else
    echo "$name patch skipped: bytes differ (other build?)"
    return 1
  fi
}

# 1. Bow-break crash. A bow breaking mid-shot SIGSEGVs the server in
# UPlayerRangedAttackComponent::UpdateProjectileLaunchBasedOnClientData: it
# calls a one-line getter (return this->[0x2f0]) on the destroyed, now-null
# bow. Make that getter (vaddr 0x834e600) return null for a null object; the
# caller already handles a null result.
function patchBowCrash() {
  setPatch 'Bow-break crash' 0x814d600 \
    488b87f0020000c3cccccccccccccccc 31c04885ff7407488b87f0020000c3cc "$1"
}

# 2. Building-facade crash (upstream #32/#36). A player joining or teleporting
# can SIGSEGV the server in FBuildingPieceActorFacade::GetSerializableId
# (BuildingPieceActorFacade.cpp:81) while replicating a facade whose building
# piece was already freed: when the facade's TJgxNativeObjectPtr no longer
# resolves to its cached raw FBuildingPiece*, it calls
# RawPiece->IsBuildingPieceValid() on the dangling pointer. Replace that call
# (vaddr 0xa5cef8c, 6 bytes: mov rax,[rdi]; call [rax+0x20]) with
# "xor eax,eax; nop4", so a mismatch takes the function's own "invalid piece"
# branch (logs a warning, returns an empty id).
function patchFacadeCrash() {
  setPatch 'Building-facade crash' 0xa3cdf83 \
    498b7e104839f8740e488b07ff502084 498b7e104839f8740e31c00f1f400084 "$1"
}

# 3. Save on shutdown (upstream #28). UPersistenceSubsystem::BeginWorldTeardown
# only saves when ADominionGameMode::PrepareForWorldTeardown() returns true,
# and that returns the "save requested but deferred" flag (+0x3a9), which is
# almost never set, so a SIGTERM restart loses up to 5 minutes. Make it return
# "saving enabled" (+0x3a8) instead: 1 byte at vaddr 0xa83cc8b. The startup
# map's game mode derives from AGameModeBase, so its teardown never reaches
# this (no empty-world overwrite). The server must receive SIGTERM (exec it as
# PID 1 or forward the signal) for this to matter.
function patchTeardownSave() {
  setPatch 'Save-on-shutdown' 0xa63bc88 \
    0fb69fa903000066c787a80300000000 0fb69fa803000066c787a80300000000 "$1"
}

# 4. No 4 s pause before the startup map switches to L_World.
# AGameModeBase::ProcessServerTravel only zeroes UWorld::NextSwitchCountdown
# (set by UWorld::Listen from NetDriver->ServerTravelPause, 4.0) when the
# server is not networked. NOP that `je` (vaddr 0x816fb75, 74 0f -> 66 90) so a
# non-seamless server travel switches on the next frame. Side effect: a client
# following an in-game world edit gets one shot at the travel packet.
function patchTravelPause() {
  setPatch 'Travel-pause' 0x7f6eb69 \
    4584ed0f8540ffffff4584ff740f488b 4584ed0f8540ffffff4584ff6690488b "$1"
}

# 5. Station inputs deleted on load. On world load
# UInventoryComponent::LoadStateFromJson asks IsValidSlotForItem for each item
# and hands rejects to HandleLoadedItemWithInvalidSlot, which deletes them when
# the inventory has no free slot ("Unable to find space for all of a misplaced
# item, skipping what can't be stored"). A station's input inventory
# (UResourceInventoryComponent) only accepts its station's recipe inputs, and
# station add-ons (Tanner's Kit, Loom Harness, Crucible) add their recipes
# (UProcessingStationComponent::AddExtraRecipes) only after the station's
# inventory was restored. So inputs that only an add-on recipe uses (e.g.
# Cursed Essence in a Tanner) are deleted on every restart. Detour the reject
# `je` (vaddr 0xa871244) to 19 bytes in int3 padding after
# EC_GFp_nistz256_method (vaddr 0xd909310): if the inventory's vtable is
# UResourceInventoryComponent's (0x251dfc8) keep the item (SetItemAtIndex
# path, 0xa87124a), else drop it as before (0xa871315). Other inventories and
# out-of-range slots are unchanged. The code is written first; the jump only
# if that worked.
function patchStationLoadDrop() {
  local site_orig=000084c00f84cb0000004c89ef4889ee site_new=000084c00f84c68009034c89ef4889ee
  local cave_orig=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  local cave_new=49817d00c8df51020f842c7ff6fce9f27ff6fccccccccccccccccccccccccccc
  case "$1" in
    apply)
      setPatch 'Station-load-drop (code)' 0xd708310 $cave_orig $cave_new apply &&
        setPatch 'Station-load-drop' 0xa670240 $site_orig $site_new apply ;;
    revert)
      setPatch 'Station-load-drop' 0xa670240 $site_orig $site_new revert
      setPatch 'Station-load-drop (code)' 0xd708310 $cave_orig $cave_new revert ;;
    status)
      setPatch 'Station-load-drop' 0xa670240 $site_orig $site_new status ;;
  esac
}

function setAllPatches() { # apply|revert|status
  patchBowCrash "$1"
  patchFacadeCrash "$1"
  patchTeardownSave "$1"
  patchTravelPause "$1"
  patchStationLoadDrop "$1"
}

MODE=${1:-}
BIN=${2:-}
if [[ ! "$MODE" =~ ^(apply|revert|status)$ ]] || [ ! -f "$BIN" ]; then
  echo "usage: $0 apply|revert|status <path to RSDragonwildsServer-Linux-Shipping>" >&2
  exit 2
fi
if [ "$MODE" != "status" ] && [ ! -w "$BIN" ]; then
  echo "error: $BIN is not writable" >&2
  exit 1
fi
if [ "$MODE" == "status" ] && command -v sha256sum >/dev/null; then
  sum=$(sha256sum "$BIN" | cut -d' ' -f1)
  [ "$sum" == "$EXPECTED_SHA256" ] && echo "binary: unpatched build 26574459 (Steam copy)" ||
    echo "binary: patched, or not build 26574459"
fi
setAllPatches "$MODE"
true
