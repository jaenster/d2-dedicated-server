# macOS 1.14d translation-unit map

Reconstructed `__text` layout of `DiabloII_macho` (Ghidra session `ce51a192`), one contiguous
address range per Blizzard source file. This is the primary evidence tool for judging whether a
name in the Mac database sits on the right function.

## Why this works

The Mac build kept its `__FILE__` assertion strings with the original build paths, e.g.

```
/Users/bclemetson/dev/diablo2/Diablo2/Source/DiabloAll/../Fog/Src/QServer/QServerNT.cpp
```

Each such string is referenced by the functions in that translation unit that contain an assert.
Resolving `string -> xref -> containing function` yields an *anchor*: a function known to live in
a known .cpp. The linker emits `__text` object file by object file, so a TU occupies one
contiguous range, and anchors pin it down.

**237 assert-path strings resolve to 236 files with at least one anchor** (`QServer98.cpp` is
referenced but has no anchoring function, so it contributes no range). Together they anchor
1,146 distinct functions out of 11,977.

## The contiguity check that validates the model

Sorting every anchor by address and walking the sequence produces **236 runs for 236 files, with
zero files split across more than one run**. No file's anchors interleave with another's. If the
TU-contiguity assumption were wrong, files would appear in multiple runs; none do. A second check
found **zero functions that assert against two different source files**, so no anchor is ambiguous.

That makes the map a decisive refutation tool, not a heuristic.

## How to use it

Each row has two ranges:

- **core** = first anchor .. last anchor. Everything in this interval provably belongs to that
  file, because the TU is contiguous and both endpoints are inside it. **A function whose address
  is inside the core range of file X cannot belong to file Y. This refutes outright, no judgement
  required.**
- **extent** = first anchor .. the address before the next file's first anchor. The tail of the
  extent is *not* proven: the gap between one file's last anchor and the next file's first anchor
  may contain further unanchored TUs. Treat the extent as an upper bound only, and never refute on
  it alone. Where `funcs` greatly exceeds `anchors` the gap is large and almost certainly holds
  unanchored translation units — `QUESTS.CPP` (902 functions) and the trailing `SRP.cpp` row are
  the worst offenders and must not be read as single TUs.

A candidate falling in a gap between two core ranges is **inconclusive**, not confirmed.

The Ghidra namespaces in this database follow `Module::Dir::Basename`, which maps directly onto a
row in this table — that is what makes a bulk namespace-versus-TU audit possible.

## Map

`core` is the proven range, `ext` the unproven upper bound, `a` the anchor count, `n` the number
of functions in the extent.

|core|ext end|a|n|source file|
|-|-|-|-|-|
|`00009047`-`00009047`|`000095fb`|1|4|3rdParty/crashy/.../mach_override/mach_override.c|
|`000095fc`-`000096b0`|`0000b031`|4|28|StormMac/Storm Mac/SOURCE/STORM.CPP|
|`0000b032`-`0000b032`|`0000bfff`|1|23|StormMac/Storm Mac/SOURCE/SBig.cpp|
|`0000c000`-`0000c000`|`0000c420`|1|2|StormMac/Storm Mac/SOURCE/SBLT.CPP|
|`0000c421`-`0000c421`|`0000d43d`|1|6|StormMac/Storm Mac/SOURCE/SBMP.CPP|
|`0000d43e`-`0000dec7`|`0000e60f`|3|17|StormMac/Storm Mac/SOURCE/SCMD.CPP|
|`0000e610`-`0000e6e7`|`0000f190`|2|19|StormMac/Storm Mac/SOURCE/SCODE.CPP|
|`0000f191`-`0000f500`|`000111de`|3|35|StormMac/Storm Mac/SOURCE/SCOMP.CPP|
|`000111df`-`0001183c`|`0001204d`|3|16|StormMac/Storm Mac/SOURCE/SEVT.CPP|
|`0001204e`-`0001737c`|`00017885`|12|89|StormMac/Storm Mac/SOURCE/SFILE.CPP|
|`00017886`-`000179e0`|`00019531`|3|61|StormMac/Storm Mac/SOURCE/SGDI.CPP|
|`00019532`-`0001a2d0`|`0001c9bc`|5|95|StormMac/Storm Mac/SOURCE/SNET.CPP|
|`0001c9bd`-`0001c9bd`|`0001d301`|1|10|StormMac/Storm Mac/SOURCE/SSTR.CPP|
|`0001d302`-`0001d458`|`0001d69d`|2|4|StormMac/Storm Mac/SOURCE/SSignature.cpp|
|`0001d69e`-`0001d720`|`0001de66`|2|13|StormMac/Storm Mac/SOURCE/STRANS.CPP|
|`0001de67`-`0001df6a`|`0002d24b`|2|317|StormMac/Storm Mac/SOURCE/SVID.CPP|
|`0002d24c`-`0002d3ef`|`00036034`|2|196|StormMac/Win32 Mac/Source/Win32/Win32_utils.cpp|
|`00036035`-`00036035`|`0003aa46`|1|81|StormMac/Storm Mac/SOURCE/SDRAW_VidDriver.CPP|
|`0003aa47`-`0003cade`|`0003e309`|5|87|StormMac/Storm Mac/SOURCE/SRegMac.mm|
|`0003e30a`-`0003e30a`|`0003ec29`|1|9|D2Win/D2WinAnimImage.cpp|
|`0003ec2a`-`00041d07`|`000422a6`|7|37|D2Win/Src/D2Comp.cpp|
|`000422a7`-`000426bf`|`0004272c`|2|5|D2Win/Src/D2WinAccountList.cpp|
|`0004272d`-`000427eb`|`00042e6e`|2|9|D2Win/Src/D2WinArchive.cpp|
|`00042e6f`-`00042e6f`|`00043b2f`|1|14|D2Win/Src/D2WinButton.cpp|
|`00043b30`-`00043b30`|`000474eb`|1|31|D2Win/Src/D2WinEditBox.cpp|
|`000474ec`-`00048d48`|`00048efc`|4|28|D2Win/Src/D2WinFont.cpp|
|`00048efd`-`00049228`|`000497e2`|2|11|D2Win/Src/D2WinImage.cpp|
|`000497e3`-`00049f3e`|`0004a41e`|2|17|D2Win/Src/D2WinList.cpp|
|`0004a41f`-`0004b1f2`|`0004be0c`|2|46|D2Win/Src/D2WinMain.cpp|
|`0004be0d`-`0004be0d`|`0004c56b`|1|10|D2Win/Src/D2WinPalette.cpp|
|`0004c56c`-`0004c56c`|`0004c6ee`|1|3|D2Win/Src/D2WinProgressBar.cpp|
|`0004c6ef`-`0004c6ef`|`0004cf23`|1|13|D2Win/Src/D2WinScrollbar.cpp|
|`0004cf24`-`0004cf24`|`0004d29f`|1|8|D2Win/Src/D2WinSmack.cpp|
|`0004d2a0`-`0004ec70`|`0004f7b5`|6|36|D2Win/Src/D2WinTextBox.cpp|
|`0004f7b6`-`0004f7b6`|`0005251e`|1|92|D2Win/Src/D2WinTimer.cpp|
|`0005251f`-`00054562`|`00054b4b`|6|18|D2BNClient/BnDownload.cpp|
|`00054b4c`-`0005521e`|`00055847`|3|16|D2BNClient/BNetGW.cpp|
|`00055848`-`00055ac9`|`000565cf`|4|21|D2BNClient/BnMessQueue.cpp|
|`000565d0`-`00057551`|`00058b8e`|12|50|D2BNClient/BnSend.cpp|
|`00058b8f`-`0005a010`|`0005c2c9`|5|42|D2BNClient/CACHE.CPP|
|`0005c2ca`-`0005c676`|`0005cf37`|2|10|D2BNClient/BNNews.cpp|
|`0005cf38`-`0005d0c1`|`0005e1b5`|3|38|D2Client/CORE/ARCHIVE.CPP|
|`0005e1b6`-`0005e1b6`|`00060850`|1|36|D2Client/CORE/WINMAIN.CPP|
|`00060851`-`0006242f`|`000644e6`|5|55|D2Client/DRAW/dLightMap.cpp|
|`000644e7`-`00069a64`|`00069f2a`|34|64|D2Client/ENGINE/Gfx.cpp|
|`00069f2b`-`0006b675`|`0006babd`|5|20|D2Client/ENGINE/GfxUtil.cpp|
|`0006babe`-`0006bb4d`|`0006e916`|2|76|D2Client/ENGINE/Particle.cpp|
|`0006e917`-`0006ef31`|`0007323e`|2|148|D2Client/GAME/Game.cpp|
|`0007323f`-`0007323f`|`00073d3a`|1|20|D2Client/GAME/Msg.cpp|
|`00073d3b`-`00073f83`|`000744c3`|3|7|D2Client/GAME/PalShift.cpp|
|`000744c4`-`0007478d`|`00074b3b`|3|13|D2Client/GAME/Record.cpp|
|`00074b3c`-`00076073`|`0007633f`|7|61|D2Client/GAME/Roster.cpp|
|`00076340`-`000765ab`|`00076b6f`|4|19|D2Client/GAME/RosterPets.cpp|
|`00076b70`-`00079721`|`0007baab`|5|157|D2Client/GAME/SCmd.cpp|
|`0007baac`-`0007baac`|`0007c2b0`|1|4|D2Client/GAME/Select.cpp|
|`0007c2b1`-`0007c913`|`0007dcb4`|5|19|D2Client/GAME/View.cpp|
|`0007dcb5`-`0007dd1c`|`00081157`|2|54|D2Client/GAME/Wall2.cpp|
|`00081158`-`00084411`|`0008562d`|7|51|D2Client/SKILLS/Skills.cpp|
|`0008562e`-`0008562e`|`00087e7e`|1|37|D2Client/SKILLS/SkillsAma.cpp|
|`00087e7f`-`00089505`|`0008bf37`|4|41|D2Client/SKILLS/SkillsBar.cpp|
|`0008bf38`-`0008bf38`|`0008e65a`|1|32|D2Client/SKILLS/SkillsEMon.cpp|
|`0008e65b`-`0008e65b`|`00090bdb`|1|25|D2Client/SKILLS/SkillsMon.cpp|
|`00090bdc`-`00090bdc`|`000917b8`|1|7|D2Client/SKILLS/SkillsNec.cpp|
|`000917b9`-`000917b9`|`00094e22`|1|59|D2Client/SKILLS/SkillsPal.cpp|
|`00094e23`-`00095a6f`|`00097d39`|4|81|D2Client/Sound/SoundHdr.cpp|
|`00097d3a`-`0009afa3`|`000a14f6`|6|157|D2Client/UI/automap.cpp|
|`000a14f7`-`000a14f7`|`000a3200`|1|19|D2Client/UI/CmdTbl.cpp|
|`000a3201`-`000a3807`|`000a4c3b`|5|31|D2Client/UI/dialog.cpp|
|`000a4c3c`-`000a5510`|`000a8c6e`|4|62|D2Client/UI/editbox.cpp|
|`000a8c6f`-`000a9e45`|`000ab934`|3|45|D2Client/UI/Hireables.cpp|
|`000ab935`-`000bd4a2`|`000c778d`|11|232|D2Client/UI/inv.cpp|
|`000c778e`-`000c8797`|`000cf12f`|2|123|D2Client/UI/npcmenu.cpp|
|`000cf130`-`000cffc7`|`000d3047`|2|36|D2Client/UI/panel.cpp|
|`000d3048`-`000d3404`|`000d5cfd`|3|16|D2Client/UI/Party.cpp|
|`000d5cfe`-`000d5cfe`|`000dceee`|1|134|D2Client/UI/QuestLog.cpp|
|`000dceef`-`000dceef`|`000e19f5`|1|25|D2Client/UI/showitems.cpp|
|`000e19f6`-`000e6927`|`000ed80f`|7|92|D2Client/UI/SkillDesc.cpp|
|`000ed810`-`000ed810`|`000eebfb`|1|47|D2Client/UI/spellsel.cpp|
|`000eebfc`-`000f1365`|`000f5a07`|9|99|D2Client/UI/text.cpp|
|`000f5a08`-`000f9167`|`000fa812`|2|59|D2Client/UI/ui.cpp|
|`000fa813`-`000fab5f`|`000fcd74`|2|34|D2Client/UI/UseItem.cpp|
|`000fcd75`-`000ff410`|`0010089f`|4|65|D2Client/UNIT/CUnit.cpp|
|`001008a0`-`00106007`|`00106913`|15|60|D2Client/UNIT/Item.cpp|
|`00106914`-`00115174`|`00117ebe`|6|172|D2Client/UNIT/Missile.cpp|
|`00117ebf`-`0011c4c8`|`0011d336`|6|40|D2Client/UNIT/Monster.cpp|
|`0011d337`-`0011d337`|`0011ef77`|1|28|D2Client/UNIT/MonUnique.cpp|
|`0011ef78`-`0011f2e9`|`00120ee9`|2|37|D2Client/UNIT/Object.cpp|
|`00120eea`-`00122ed9`|`001245ec`|4|25|D2Client/UNIT/Player.cpp|
|`001245ed`-`001246d3`|`00124809`|3|7|D2Client/UNIT/PlayerList.cpp|
|`0012480a`-`00126a61`|`00127c77`|6|55|D2Client/UNIT/PlrSkills.cpp|
|`00127c78`-`00128364`|`00128c7f`|3|14|D2Client/UNIT/UnitMode.cpp|
|`00128c80`-`0012962f`|`0012b43c`|3|36|D2Client/UNIT/UnitSnd.cpp|
|`0012b43d`-`0012b541`|`0012b80f`|3|12|D2Client/UNIT/CUnitEvent.cpp|
|`0012b810`-`0012b91c`|`0012c99c`|2|46|D2CMP/SRC/CelCmp.cpp|
|`0012c99d`-`0012ca68`|`0012ce1b`|2|6|D2CMP/SRC/CelDataHash.cpp|
|`0012ce1c`-`0012ce1c`|`001311d1`|1|20|D2CMP/SRC/Codec.cpp|
|`001311d2`-`00131308`|`001317db`|3|7|D2CMP/SRC/FindTiles.cpp|
|`001317dc`-`001318ac`|`00131b2b`|2|3|D2CMP/SRC/GfxHash.cpp|
|`00131b2c`-`00131d65`|`00132472`|4|16|D2CMP/SRC/LRUCache.cpp|
|`00132473`-`00134467`|`00134fce`|7|42|D2CMP/SRC/SpriteCache.cpp|
|`00134fcf`-`00134fcf`|`001356b4`|1|15|D2CMP/SRC/Tilecmp.cpp|
|`001356b5`-`0013574f`|`00135921`|2|2|D2CMP/SRC/TileProjects.cpp|
|`00135922`-`001359c8`|`00135d4d`|2|10|D2Common/Chat/Chat.cpp|
|`00135d4e`-`00136058`|`001399c6`|2|43|D2Common/COLLISN/Collisn.cpp|
|`001399c7`-`00139aa0`|`00139c95`|2|7|D2Common/COMPOSIT/Composit.cpp|
|`00139c96`-`00139d8c`|`0013b74f`|2|23|D2Common/DATATBLS/AnimTbls.cpp|
|`0013b750`-`0014052b`|`00140d94`|12|24|D2Common/DATATBLS/DataTbls.cpp|
|`00140d95`-`00140ff9`|`00142776`|5|26|D2Common/DATATBLS/FieldTbls.cpp|
|`00142777`-`00144d10`|`001451a7`|17|63|D2Common/DATATBLS/ItemTbls.cpp|
|`001451a8`-`0014664e`|`001469f8`|10|30|D2Common/DATATBLS/LvlTbls.cpp|
|`001469f9`-`00146b5b`|`00146df6`|2|5|D2Common/DATATBLS/MissileTbls.cpp|
|`00146df7`-`0014a723`|`0014af33`|13|64|D2Common/DATATBLS/MonsterTbls.cpp|
|`0014af34`-`0014af34`|`0014b27a`|1|9|D2Common/DATATBLS/OverlayTbls.cpp|
|`0014b27b`-`0014b7f8`|`0014c39d`|3|37|D2Common/DATATBLS/TokTbls.cpp|
|`0014c39e`-`0014d533`|`0014da29`|6|32|D2Common/DRLG/Drlg.cpp|
|`0014da2a`-`0014da2a`|`0014e4ba`|1|12|D2Common/DRLG/DrlgAnim.cpp|
|`0014e4bb`-`0014e683`|`0014e78b`|3|13|D2Common/DRLG/DrlgGrid.cpp|
|`0014e78c`-`0014f15b`|`0014f703`|3|10|D2Common/DRLG/DrlgLogic.cpp|
|`0014f704`-`00150750`|`001508bf`|11|36|D2Common/DRLG/DrlgRoom.cpp|
|`001508c0`-`00150d54`|`00151496`|3|14|D2Common/DRLG/DrlgVer.cpp|
|`00151497`-`0015348b`|`001547b3`|2|31|D2Common/DRLG/Maze.cpp|
|`001547b4`-`00155c34`|`001576d0`|4|18|D2Common/DRLG/Outdoors.cpp|
|`001576d1`-`001576d1`|`00158be3`|1|12|D2Common/DRLG/OutJung.cpp|
|`00158be4`-`00158be4`|`0015c09d`|1|26|D2Common/DRLG/OutPlace.cpp|
|`0015c09e`-`0015c189`|`0015e1f1`|2|22|D2Common/DRLG/OutRoom.cpp|
|`0015e1f2`-`00161174`|`001622e8`|16|45|D2Common/DRLG/Preset.cpp|
|`001622e9`-`00163029`|`00164bbb`|5|19|D2Common/DRLG/RoomTile.cpp|
|`00164bbc`-`00165df9`|`001668d1`|7|86|D2Common/DUNGEON/Dungeon.cpp|
|`001668d2`-`00166beb`|`001670b8`|2|15|D2Common/ENVIRONMENT/Env.cpp|
|`001670b9`-`0016a3ce`|`0016bdba`|16|100|D2Common/INVENTORY/Inventory.cpp|
|`0016bdbb`-`0016bdbb`|`0016f7e6`|1|61|D2Common/ITEMS/ItemMods.cpp|
|`0016f7e7`-`0016f876`|`0017b827`|2|169|D2Common/ITEMS/Items.cpp|
|`0017b828`-`0017b828`|`0017baf6`|1|4|D2Common/Logging/Logging.cpp|
|`0017baf7`-`0017baf7`|`0017c275`|1|15|D2Common/Logging/ProfCore.cpp|
|`0017c276`-`0017c276`|`0017e67e`|1|18|D2Common/Monsters/MONSTERS.CPP|
|`0017e67f`-`0017e67f`|`001802ed`|1|9|D2Common/PATH/IDAstar.cpp|
|`001802ee`-`0018043a`|`00184c29`|2|120|D2Common/PATH/Path.cpp|
|`00184c2a`-`00184cbc`|`001867e4`|2|37|D2Common/QuestRecord/QuestRecord.cpp|
|`001867e5`-`00189eb7`|`0018aa66`|6|125|D2Common/SKILLS/Skills.cpp|
|`0018aa67`-`0018ae3e`|`0018afd3`|6|11|D2Common/Text/Text.cpp|
|`0018afd4`-`0018b044`|`0018d713`|2|48|D2Common/UNITS/Missile.cpp|
|`0018d714`-`0018d714`|`0018da7d`|1|5|D2Common/UNITS/MisStream.cpp|
|`0018da7e`-`0018dbac`|`0018e8e2`|3|19|D2Common/UNITS/UnitFinds.cpp|
|`0018e8e3`-`001930e7`|`00193ca6`|13|130|D2Common/UNITS/Units.cpp|
|`00193ca7`-`00193d04`|`00195633`|2|12|D2Common/WayPoint/Waypoint.cpp|
|`00195634`-`00196c48`|`0019784b`|7|82|D2Common/Stats/StatsEx.cpp|
|`0019784c`-`0019947c`|`0019c75f`|4|108|D2Common/Chat/Ignorelist.cpp|
|`0019c760`-`0019c79f`|`0019f2b5`|2|48|MacSpecific/Source/Mac Shell/GameSetup.cpp|
|`0019f2b6`-`0019f551`|`001a04f1`|2|8|MacSpecific/Source/Mac Shell/D2FlamingLogo.cpp|
|`001a04f2`-`001a125d`|`001a15d9`|3|7|D2Game/Ai/AiBaal.cpp|
|`001a15da`-`001a1e8a`|`001a39ab`|8|59|D2Game/Ai/AiGeneral.cpp|
|`001a39ac`-`001a39ac`|`001a6f69`|1|66|D2Game/Ai/AiTatics.cpp|
|`001a6f6a`-`001a70b7`|`001a77bc`|4|23|D2Game/GAME/Arena.cpp|
|`001a77bd`-`001a77bd`|`001a88f4`|1|17|D2Game/GAME/CCmd.cpp|
|`001a88f5`-`001aac62`|`001aaf69`|8|75|D2Game/GAME/Clients.cpp|
|`001aaf6a`-`001ab08a`|`001ac3f2`|3|35|D2Game/GAME/Event.cpp|
|`001ac3f3`-`001aee28`|`001b012e`|5|64|D2Game/GAME/Game.cpp|
|`001b012f`-`001b012f`|`001b0473`|1|9|D2Game/GAME/Level.cpp|
|`001b0474`-`001b3dbb`|`001b483e`|19|135|D2Game/GAME/SCmd.cpp|
|`001b483f`-`001b4b24`|`001b4c2a`|5|5|D2Game/GAME/Targets.cpp|
|`001b4c2b`-`001b4c2b`|`001b51c6`|1|7|D2Game/GAME/Task.cpp|
|`001b51c7`-`001b5919`|`001b5af5`|2|4|D2Game/INVENTORY/InvMode.cpp|
|`001b5af6`-`001c1535`|`001c4168`|49|113|D2Game/ITEMS/ItemMode.cpp|
|`001c4169`-`001c5ad7`|`001ca697`|3|50|D2Game/ITEMS/Items.cpp|
|`001ca698`-`001ca698`|`001d2816`|1|71|D2Game/MISSILES/Missiles.cpp|
|`001d2817`-`001d2ca7`|`001d7a84`|2|72|D2Game/MISSILES/MissMode.cpp|
|`001d7a85`-`001d7a85`|`001d8213`|1|11|D2Game/MONSTER/Monster.cpp|
|`001d8214`-`001d9431`|`001da7ad`|7|33|D2Game/MONSTER/MonsterAI.cpp|
|`001da7ae`-`001db226`|`001dd829`|3|46|D2Game/MONSTER/MonsterMode.cpp|
|`001dd82a`-`001dd82a`|`001dfb22`|1|7|D2Game/MONSTER/MonsterMsg.cpp|
|`001dfb23`-`001dff6e`|`001e9922`|2|112|D2Game/MONSTER/MonsterRegion.cpp|
|`001e9923`-`001e99bb`|`001efd3c`|2|76|D2Game/OBJECTS/Objects.cpp|
|`001efd3d`-`001f4ff6`|`001f556b`|8|78|D2Game/OBJECTS/ObjMode.cpp|
|`001f556c`-`001f5a51`|`001f5fc2`|4|19|D2Game/OBJECTS/objrgn.cpp|
|`001f5fc3`-`001f6c79`|`001f6e2f`|8|15|D2Game/PLAYER/PartyScreen.cpp|
|`001f6e30`-`001f8346`|`001f8d6e`|5|31|D2Game/PLAYER/Player.cpp|
|`001f8d6f`-`001fa5cd`|`001fb883`|11|43|D2Game/PLAYER/PlayerPets.cpp|
|`001fb884`-`001fb9ca`|`001fbae1`|2|2|D2Game/PLAYER/PlrIntro.cpp|
|`001fbae2`-`001fec98`|`001fef69`|11|40|D2Game/PLAYER/PlrModes.cpp|
|`001fef6a`-`0020680d`|`00206a8f`|15|125|D2Game/PLAYER/PlrMsg.cpp|
|`00206a90`-`00209d77`|`0020adaf`|7|31|D2Game/PLAYER/PlrSave.cpp|
|`0020adb0`-`0020d3cb`|`0020db63`|6|29|D2Game/PLAYER/PlrSave2.cpp|
|`0020db64`-`00212e8f`|`0021321b`|18|30|D2Game/PLAYER/PlrTrade.cpp|
|`0021321c`-`00216bf2`|`00245f57`|21|902|D2Game/QUESTS/QUESTS.CPP (extent unreliable)|
|`00245f58`-`00246a7d`|`002498a0`|2|28|D2Game/SKILLS/SkillAma.cpp|
|`002498a1`-`0024e6fb`|`002505b7`|5|55|D2Game/SKILLS/SkillAss.cpp|
|`002505b8`-`00252499`|`0025301a`|4|14|D2Game/SKILLS/SkillBar.cpp|
|`0025301b`-`00254f3e`|`00258a7f`|7|53|D2Game/SKILLS/SkillDruid.cpp|
|`00258a80`-`0025c0c7`|`0025de84`|7|57|D2Game/SKILLS/SkillItem.cpp|
|`0025de85`-`00260729`|`00262997`|2|51|D2Game/SKILLS/SkillMonst.cpp|
|`00262998`-`002678d4`|`00268163`|7|43|D2Game/SKILLS/SkillNec.cpp|
|`00268164`-`0026ea4f`|`0026f8f4`|18|105|D2Game/SKILLS/Skills.cpp|
|`0026f8f5`-`0026fc47`|`00272a9d`|2|24|D2Game/SKILLS/SkillSor.cpp|
|`00272a9e`-`002760a2`|`00276658`|7|23|D2Game/SKILLS/SkilPal.cpp|
|`00276659`-`002772fc`|`0027738c`|7|16|D2Game/UNIT/Party.cpp|
|`0027738d`-`002776e2`|`002779ff`|4|17|D2Game/UNIT/PlayerList.cpp|
|`00277a00`-`0027aa64`|`0027d0d4`|4|69|D2Game/UNIT/SUnit.cpp|
|`0027d0d5`-`00281796`|`00281820`|7|28|D2Game/UNIT/SUnitDmg.cpp|
|`00281821`-`00283a4b`|`00284d19`|7|19|D2Game/UNIT/SUnitInactive.cpp|
|`00284d1a`-`00285234`|`0028534e`|9|11|D2Game/UNIT/SUnitMsg.cpp|
|`0028534f`-`0028b849`|`0028b9d6`|21|45|D2Game/UNIT/SUNITNPC.CPP|
|`0028b9d7`-`0028d036`|`002a6fd6`|11|198|D2Game/UNIT/sunitproxy.cpp|
|`002a6fd7`-`002afe11`|`002b0b10`|8|66|D2Game/Ai/AiThink4.cpp|
|`002b0b11`-`002b0d05`|`002b0e03`|4|5|D2Game/UNIT/SUnitEvent.cpp|
|`002b0e04`-`002b1718`|`002b6887`|4|127|MacSpecific/Source/CD2Textures/CD2Textures.cpp|
|`002b6888`-`002b6e68`|`002b8049`|3|26|D2Hell/SRC/Archive.cpp|
|`002b804a`-`002b804a`|`002b87a1`|1|9|D2Lang/Unicode/UNISYS.CPP|
|`002b87a2`-`002b98b1`|`002bc82b`|5|70|D2Lang/StrTable/strtable.cpp|
|`002bc82c`-`002c11e5`|`002c5d5c`|7|161|D2Launch/Src/CharSel.cpp|
|`002c5d5d`-`002c96e5`|`002ccd9a`|4|120|D2Launch/Src/MainMenus.cpp|
|`002ccd9b`-`002ccd9b`|`002d0055`|1|64|D2MCPClient/Src/McpConnect.cpp|
|`002d0056`-`002d4627`|`002d4860`|4|55|D2Multi/Src/ChatDlg.cpp|
|`002d4861`-`002d7573`|`002dd100`|5|111|D2Multi/Src/ComCallback.cpp|
|`002dd101`-`002dd5e9`|`002dd7d0`|4|9|D2Net/SRC/Client.cpp|
|`002dd7d1`-`002dd882`|`002de19a`|2|20|D2Net/SRC/D2Net.cpp|
|`002de19b`-`002de19b`|`002dee37`|1|18|D2Net/SRC/Server.cpp|
|`002dee38`-`002deec5`|`002e1dde`|2|76|D2OpenGL/Src/oglBlocks.cpp|
|`002e1ddf`-`002e1e1e`|`002e20d3`|2|8|D2OpenGL/Src/oglPerspective.cpp|
|`002e20d4`-`002e22fb`|`002e2b6f`|3|6|D2OpenGL/Src/oglSmack.cpp|
|`002e2b70`-`002e2cd0`|`002e4810`|2|16|D2OpenGL/Src/oglSprite.cpp|
|`002e4811`-`002e4850`|`002e5f99`|2|14|D2OpenGL/Src/oglVertex.cpp|
|`002e5f9a`-`002e69e2`|`002e7df0`|3|28|D2OpenGL/Src/COGLAGPTextures.cpp|
|`002e7df1`-`002e7ed1`|`002e8c20`|2|26|D2Sound/Src/D2SoundFast.cpp|
|`002e8c21`-`002e8db5`|`002e9ffb`|2|40|D2Sound/Src/D2SoundSmp.cpp|
|`002e9ffc`-`002ea100`|`002ea168`|3|5|D2Sound/Src/D2SoundUtil.cpp|
|`002ea169`-`002ea9e5`|`002ed07e`|5|33|Fog/Src/AsyncData.cpp|
|`002ed07f`-`002ed19e`|`002ed6e7`|3|13|Fog/Src/D2QSQueue.cpp|
|`002ed6e8`-`002ed812`|`002edd11`|2|6|Fog/Src/D2QSSocket.cpp|
|`002edd12`-`002eddae`|`002ef0fd`|2|23|Fog/Src/DataArrays.cpp|
|`002ef0fe`-`002ef2cc`|`002f11cf`|2|56|Fog/Src/ErrorManager.cpp|
|`002f11d0`-`002f2858`|`002f2913`|8|19|Fog/Src/Excel/Excel.cpp|
|`002f2914`-`002f2c27`|`002f3493`|2|29|Fog/Src/Safesock.cpp|
|`002f3494`-`002f5370`|`002f5fca`|10|38|Fog/Src/QServer/QServer.cpp|
|`002f5fcb`-`002f7042`|`002f8a01`|5|30|Fog/Src/QServer/QServerNT.cpp|
|`002f8a02`-`002f8a02`|`002f9339`|1|9|SRP/SHA.cpp|
|`002f933a`-`002f933a`|end of `__text`|1|716|SRP/SRP.cpp (extent unreliable)|

`Fog/Src/QServer/QServer98.cpp` has an assert string but no anchoring function, so it has no range.

## What the map measured

Because the namespaces encode `Module::Dir::Basename`, every named function can be tested against
its own claimed TU. Restricting to cases where the namespace names a real anchored TU *and* the
function's address lands inside some proven core range:

|outcome|count|
|-|-|
|namespace TU == actual TU|647|
|namespace TU != actual TU|289|

**289 of 936 decidable names (31%) sit in a translation unit that contradicts their own name.**
That independently reproduces the "roughly a third are wrong" estimate. A further 1,876 named
functions land in gaps between core ranges and are undecidable by this method.

Two distinct failure modes hide behind that 31%:

- the leaf name is wrong — the function is not what it says it is. These are the dangerous ones.
- the leaf name is right but the namespace is wrong, typically client code filed under `D2Game`
  or `D2Common`. Misleading, but the name still describes the code.
