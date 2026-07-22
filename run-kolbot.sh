#!/bin/bash
# run-kolbot.sh — launch a HEADED wine D2 1.14d client with BOTH our d2gs.dll (realm
# gateway redirect to 127.0.0.1 + Battle.net checkrev bypass + auto-login) and
# blizzhackers D2BS.dll (kolbot bot engine) injected, so a wine client logs into the
# LOCAL realm stack and runs a kolbot script (Mephisto) with char EpicSorc.
#
# Prereqs (all already true in this repo):
#   - realmd + qqserver(:4000) + real-engine GS(:4100) stack UP (see run.sh --realm)
#   - EpicSorc.d2s imported into realmd's chars/tester/
#   - a FULL D2 install symlinked at ./114clean (headed renderer needs real MPQs)
#
# The client dir (./clientgame) is assembled with: Game.exe + full MPQs (hardlinked),
# our dbghelp proxy + d2gs.dll + D2BS.dll, a d2bs.ini with an [EpicSorc] profile, and
# the kolbot script tree under d2bs/kolbot/. The dbghelp proxy LoadLibrary's each
# --loaddll in order: d2gs.dll first (patches gateway+checkrev before the menu), then
# D2BS.dll (which reads d2bs.ini next to Game.exe and runs DefaultGameScript in-game).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

D2GS_CLIENT_SRC="${D2GS_CLIENT_SRC:-$ROOT/114clean}"
CG="${D2GS_CLIENTDIR:-$ROOT/clientgame}"
KOLBOT="${KOLBOT_SRC:-$HOME/code/js/kolbot-fresh}"
WINE="${WINE:-wine}"

die() { echo "error: $1" >&2; exit 1; }
[ -e "$D2GS_CLIENT_SRC/d2data.mpq" ] || die "no FULL D2 install at $D2GS_CLIENT_SRC (symlink ./114clean)"
[ -f "$KOLBOT/d2bs/D2BS.dll" ] || die "no D2BS.dll under KOLBOT_SRC=$KOLBOT"
command -v "$WINE" >/dev/null || die "wine not found (set WINE=)"

# Build our DLLs (dbghelp proxy + d2gs payload).
zig build dlls

# Assemble the client dir (hardlink the install, no copies).
mkdir -p "$CG"
for f in "$D2GS_CLIENT_SRC"/*; do
    [ -f "$f" ] || continue
    ln -f "$f" "$CG/$(basename "$f")" 2>/dev/null || cp "$f" "$CG/$(basename "$f")"
done
cp "$ROOT/zig-out/bin/dbghelp.dll" "$CG/dbghelp.dll"
cp "$ROOT/zig-out/bin/d2gs.dll"    "$CG/d2gs.dll"
cp "$KOLBOT/d2bs/D2BS.dll"         "$CG/D2BS.dll"
rm -f "$CG/d2gs_log.txt" "$CG/d2bs.log"

# D2BS.dll dynamically links mozjs.dll (601 MSVC-mangled ?JS_*@@ imports) — it MUST be
# the matching blizzhackers SpiderMonkey build, NOT any other mozjs on disk. The aether
# GCC mozjs (0 matching exports) makes D2BS throw 0xe06d7363 at init. We stage the
# symbol-matching build from the D2BS deps; the DEBUG one additionally needs the DEBUG
# CRT (msvcr100d/msvcp100d) in the wine prefix — supply the RELEASE mozjs from the
# official D2BS release bundle (or the debug CRT) for a clean load.
MOZJS_SRC="${MOZJS_SRC:-$HOME/code/CPP/d2bs/dependencies/libs/debug/mozjs.dll}"
if [ -f "$MOZJS_SRC" ]; then
    cp "$MOZJS_SRC" "$CG/mozjs.dll"
    if strings -n 6 "$CG/mozjs.dll" 2>/dev/null | grep -q "GCC: (GNU)"; then
        echo "WARNING: $CG/mozjs.dll is a GCC build — ABI-INCOMPATIBLE with D2BS.dll (it will crash)."
    fi
    if strings -n 6 "$CG/mozjs.dll" 2>/dev/null | grep -qi "MSVCR100D.dll"; then
        echo "NOTE: mozjs.dll is the DEBUG build — installing CRT shims (msvcr100d/msvcp100d -> release CRT)."
        # Build (if toolchain present) + install the debug-CRT shims that let the debug
        # mozjs load against the wine release CRT. Verified: with these, JS_NewRuntime +
        # JS_NewContext (the exact call D2BS throws on) succeed. See tools/crtshim/.
        SHIM="$ROOT/tools/crtshim"
        if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
            (cd "$SHIM" && MOZJS="$CG/mozjs.dll" WINEPREFIX="${WINEPREFIX:-$HOME/.wine}" ./build.sh) || \
                echo "WARNING: crtshim build failed — using prebuilt shims if present."
        fi
        SYS="${WINEPREFIX:-$HOME/.wine}/drive_c/windows/syswow64"
        for d in msvcr100d.dll msvcp100d.dll; do
            [ -f "$SHIM/$d" ] && { cp "$SHIM/$d" "$SYS/$d"; cp "$SHIM/$d" "$CG/$d"; } || \
                echo "WARNING: missing shim $SHIM/$d — D2BS will crash without the debug CRT."
        done
    fi
else
    echo "WARNING: no mozjs.dll at MOZJS_SRC=$MOZJS_SRC — D2BS will crash at init without it."
fi
for d in libwinpthread-1.dll; do [ -f "$KOLBOT/d2bs/$d" ] && cp "$KOLBOT/d2bs/$d" "$CG/$d" 2>/dev/null; done

# kolbot scripts next to Game.exe: <dir>/d2bs/kolbot/ (ScriptPath=d2bs\kolbot in d2bs.ini —
# D2BS builds szScriptPath = <Game.exe dir> + ScriptPath, so it must include the d2bs\ prefix).
# Refresh from source, then (re)generate our overrides — rsync --delete wipes anything not
# in the source tree, so the overrides MUST be written after it, every run.
mkdir -p "$CG/d2bs"
rsync -a --delete "$KOLBOT/d2bs/kolbot/" "$CG/d2bs/kolbot/" 2>/dev/null \
    || cp -R "$KOLBOT/d2bs/kolbot" "$CG/d2bs/kolbot"

# Override 0: config/_customconfig.js — setup.bat/setup.ps1 normally copies this from
# +setup/config/_CustomConfig.js; without it Config.init throws "CustomConfig is not
# defined" and default.dbj aborts before the Mephisto script runs. Stage it lowercase to
# match the include path (config/_customconfig.js) under wine's case-sensitive resolver.
cp "$KOLBOT/+setup/config/_CustomConfig.js" "$CG/d2bs/kolbot/libs/config/_customconfig.js" 2>/dev/null \
    || printf 'const CustomConfig = {};\n' > "$CG/d2bs/kolbot/libs/config/_customconfig.js"

# Override 0b: stage the D2Bot#-manager subsystem configs (automule/crafting/torch/gambling/
# gameaction/mulelogger/…). setup.ps1 overlays these from +setup/<sys>/*.js into
# libs/systems/<sys>/[config/]; without them default.dbj's init block throws at
# CraftingSystem.buildLists() + the AutoMule/Torch/Gambling/GameAction inGameCheck()s
# ("module systems/.../config not found") and the game script aborts before Mephisto runs.
# Same src->dst list as setup.ps1 (automule goes under a config/ subdir; the rest sit in the
# system dir). rsync --delete wipes these each run, so re-stage here every time.
SYS="$CG/d2bs/kolbot/libs/systems"
stage_cfg() { # <src-rel-under-+setup> <dst-rel-under-systems>
    local src="$KOLBOT/+setup/$1" dst="$SYS/$2"
    [ -f "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}
stage_cfg automule/MuleConfig.js        automule/config/MuleConfig.js
stage_cfg automule/TorchAnniMules.js    automule/config/TorchAnniMules.js
stage_cfg automule/StarterConfig.js     automule/config/StarterConfig.js
stage_cfg channel/ChannelConfig.js      channel/ChannelConfig.js
stage_cfg cleaner/CleanerConfig.js      cleaner/CleanerConfig.js
stage_cfg crafting/TeamsConfig.js       crafting/TeamsConfig.js
stage_cfg follow/FollowConfig.js        follow/FollowConfig.js
stage_cfg gambling/TeamsConfig.js       gambling/TeamsConfig.js
stage_cfg gameaction/GameActionConfig.js gameaction/GameActionConfig.js
stage_cfg lead/LeadConfig.js            lead/LeadConfig.js
stage_cfg mulelogger/LoggerConfig.js    mulelogger/LoggerConfig.js
stage_cfg pubjoin/PubJoinConfig.js      pubjoin/PubJoinConfig.js
stage_cfg torch/FarmerConfig.js         torch/FarmerConfig.js
stage_cfg charrefresher/RefresherConfig.js charrefresher/RefresherConfig.js
stage_cfg autorush/RushConfig.js        autorush/RushConfig.js

# Override 1: per-char config that runs ONLY Mephisto (loaded by me.charname via the
# Class.Charname.js format in libs/core/Config.js).
cat > "$CG/d2bs/kolbot/libs/config/Sorceress.EpicSorc.js" <<'EOF'
function LoadConfig () {
  Scripts.UserAddon = false;        // must be false to run boss/area scripts
  Scripts.Mephisto = true;
  Config.Mephisto.KillCouncil = false;
  Config.Mephisto.MoatTrick = false;
  Config.Mephisto.TakeRedPortal = true;
  Config.MainSkill = "auto";
  Config.AttackSkill = [0, 0, 0, 0, 0, 0];
}
EOF

# Override 2: manager-less (no D2Bot#) menu starter that DRIVES login itself via D2BS's
# native login()/selectCharacter()/createGame() globals (they read the -profile section).
# No d2gs --auto-login needed. In-game, D2BS runs DefaultGameScript (default.dbj) -> Mephisto.
cat > "$CG/d2bs/kolbot/starter.dbj" <<'EOF'
var PROFILE = "EpicSorc";
function main () {
  print("ÿc2starterÿc0 :: manager-less login for " + PROFILE);
  var gameNum = 0;
  while (true) {
    if (me.ingame) { delay(1000); continue; }
    try {
      login(PROFILE); delay(1000);
      selectCharacter(PROFILE); delay(1000);
      gameNum += 1;
      var name = "meph" + (getTickCount() % 100000) + gameNum;
      createGame(name, "", 2);
      print("ÿc2starterÿc0 :: create game '" + name + "'");
      // WAIT for the world to finish loading (me.ingame) before abandoning it. The world
      // stream + game-view init can take 10-40s; the old delay(5000) looped and created a
      // NEW game before me.ingame ever set, so default.dbj (GameJoined) never fired.
      var t = getTickCount();
      while (!me.ingame && (getTickCount() - t) < 60000) { delay(500); }
      if (me.ingame) { print("ÿc2starterÿc0 :: IN GAME — me.ingame=true, handing to default.dbj"); }
      else { print("ÿc1starterÿc0 :: me.ingame never set in 60s — leaving + retrying"); }
    } catch (e) {
      print("ÿc1starterÿc0 :: " + e + " (loc " + getLocation() + ") - retrying");
      delay(2000);
    }
  }
}
EOF

# d2bs.ini (with the [EpicSorc] battle.net profile → gateway 127.0.0.1) must sit next
# to Game.exe. Staged in-repo at ./clientgame/d2bs.ini; recreate if missing.
[ -f "$CG/d2bs.ini" ] || die "missing $CG/d2bs.ini (the [EpicSorc] profile)"

DGS="Z:$(echo "$CG/d2gs.dll" | tr '/' '\\')"
D2BS="Z:$(echo "$CG/D2BS.dll" | tr '/' '\\')"

# Only kill a prior CLIENT (clientgame) — NOT the real-engine GS (testgame\Game.exe),
# which shares this wineprefix. Do NOT `wineserver --kill`: it would take the GS down too.
pkill -9 -f 'clientgame\\Game.exe' 2>/dev/null || true
sleep 1

cd "$CG"
# D2BS is NOT --loaddll'd (that injects it pre-WinMain and its startup thread throws an
# uncaught C++ exception). Pass it via --d2bs so d2gs.dll defers the LoadLibrary until the
# game window exists — mirroring D2BS's own `--inject <pid>` loader. `-profile EpicSorc`
# activates the [EpicSorc] section (D2BS SwitchToProfile). LOGIN is driven by our
# starter.dbj calling D2BS's login()/createGame() — NOT by d2gs --auto-login (which would
# fight D2BS for the menu). d2gs.dll stays ONLY for the 127.0.0.1 gateway list (realmgw)
# + Battle.net checkrev bypass, which the stock client needs against our realmd.
# D2BS's ParseCommandLine (CommandLine.cpp:76) captures the -profile value ONLY between
# double quotes, so it MUST be passed as -profile "EpicSorc" (unquoted -> empty -> "Profile
# not found"). The literal quotes have to survive into Game.exe's command line.
# No -profile cmdline (wine mangles the quoted value). starter.dbj calls login("EpicSorc")
# with the literal name instead; UseProfileScript=false makes D2BS run starter.dbj at the
# menu. d2gs.dll stays ONLY for the 127.0.0.1 gateway list + checkrev bypass (no --auto-login).
# --no-compress: the D2GS Huffman codec is SYMMETRIC — this client and the realm GS
# (run.sh --realm, which also passes --no-compress) must agree. With one side compressed
# and the other not, the world stream is garbage and the join dies right after 0xAF
# (SrvJoinAct never fires). Both --no-compress = uncompressed wire = the world streams.
echo "launching HEADED kolbot client: Game.exe --loaddll <d2gs> --d2bs <D2BS> --realm-gw 127.0.0.1 --bypass-checkrev --no-compress (starter.dbj drives login) (ctrl-c to stop)"
exec env WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="dbghelp=n" \
    "$WINE" Game.exe -w -nosound \
    --loaddll "$DGS" --d2gs --d2bs "$D2BS" \
    --realm-gw 127.0.0.1 --bypass-checkrev --no-compress "$@"
