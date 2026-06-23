# Misclassified functions — server logic filed under client

Functions in a pruned (client/render/sound) namespace that the server
calls and that themselves touch NO presentation code — i.e. pure logic in
the wrong place. Move out (most belong in D2Common / D2Game). Move the
symbol in Ghidra (`move_symbol_to_namespace`); it flows to the recon on regen.

Verified example moved: D2ApplyPercent (0x483360) _SkillHelpers -> D2Common::Stats.

| function | call sites | current namespace |
|-|-|-|
| D2ApplyPercent | 48 | D2Client/_SkillHelpers |
| ITEM_SetItemOnHand | 20 | D2Client/UI |
| CLIENT_CheckExpansion | 20 | D2Client/Game |
| GetUIFlag | 19 | D2Client/UI |
| GAMEDATA_GetExitFlag3 | 18 | D2Client/Game |
| IfPlayer | 17 | D2Client/Engine |
| GetType | 13 | D2Client/Game |
| RollBetweenMinAndMax | 11 | D2Client/Draw |
| gnRecordingIndex | 11 | D2Client/Game |
| ResetThings | 10 | D2Client/UI |
| INV_GetUniqueItemsTxtLine | 9 | D2Client/_SkillHelpers |
| RNG_GetRandomInRange | 7 | D2Client/Engine |
| AllocLightMap | 7 | D2Client/Draw |
| SKILL_GetMaxLevelForSkill | 7 | D2Client/UI |
| FindWaypointIdByLevelId | 5 | D2Client/Waypoint |
| COMPOSIT_GetWeaponClassWithTransform | 5 | D2Client/Composit |
| GetExpireFrame | 5 | D2Client/Chat |
| COMPOSIT_HasWeaponDrawn | 5 | D2Client/Composit |
| TXT_Skills_GetSkillRange | 4 | D2Client/UI |
| CheckMonStatId | 4 | D2Client/UI |
| GetDificulity | 4 | D2Client/Game |
| GetSetsLine | 3 | D2Client/_SkillHelpers |
| EnableWaypoint | 3 | D2Client/Waypoint |
| COMPOSIT_BuildCofPath | 2 | D2Client/Composit |
| GAMEDATA_GetFlags0070f2bc | 2 | D2Client/Game |
| CMD_InitKeyConfigUI | 2 | D2Client/UI |
| CopyWaypoint | 2 | D2Client/Waypoint |
| CheckWaypoint | 2 | D2Client/Waypoint |
| D2CLIENT_SetExitVar3ToTrue | 2 | D2Client/Game |
| D2CLIENT_SetExitVar2 | 2 | D2Client/Game |
| GetSkillDescription | 2 | D2Client/UI |
| D2CLIENT_SetExitVar1 | 2 | D2Client/ClientModeInGame |
| GAMEDATA_GetFlags0070f234 | 2 | D2Client/Game |
| GetEntryIndex | 2 | D2Client/Game |
| GAMEDATA_SetValue007a04fc | 2 | D2Client/Game |
| UI_ResetInputState | 2 | D2Client/Game |
| DEBUG_FormatAddressInfo | 1 | D2Client/Engine |
| FORMS_SetGlobalFormImage | 1 | D2Win/D2WinMain |
| CMD_RevertKeyBindings | 1 | D2Client/UI |
| GAMEDATA_GetExitFlag2 | 1 | D2Client/Game |
| FreeMCP | 1 | D2Client/McpConnect |
| SetPendingExitCutsceneId | 1 | D2Client/Game |
| SetExitCutscenePlayed | 1 | D2Client/Game |
| TEXT_ClearNpcMenuSelection | 1 | D2Client/UI |
| GAMEDATA_ExtendTimeout | 1 | D2Client/Game |
| CLIENT_GetD2GSGameType | 1 | D2Client/Game |
| LOADER_SetConnectionLostFlag | 1 | D2Client/Engine |
| StoreLastSkillHit | 1 | D2Client/Engine |
| CLIENT_SetLadder | 1 | D2Client/Game |
| QUESTLOG_SetZooSpawnFlag | 1 | D2Client/UI |
| Realm | 1 | D2Client/BNGatewayAccess |
| SAVEFILE_FindAllSaveFiles | 1 | D2Client/MainMenus |
| QUESTLOG_HandleSpecialPacket | 1 | D2Client/UI |
| GAMEDATA_SetClickModifier | 1 | D2Client/Game |
| CLIENT_SetExpansion | 1 | D2Client/Game |
| NPCMENU_HandleTradeMoney | 1 | D2Client/UI |
| STRUCT_AllocTxtMessageForPacket0x27 | 1 | D2Client/Text |
| CLIENT_SetDifficulty | 1 | D2Client/Game |
| STRING_CopyWideString | 1 | D2Win/Unicode |
| AddMercForHireToGlobalList | 1 | D2Client/UI |
| BuildPacket0x27Messages | 1 | D2Client/Text |
| MISC_GetLanguageCode | 1 | D2Win/StrTable |
| TEXT_SetNpcMenuSelection | 1 | D2Client/UI |
| DEBUG_UnwindStackFrames | 1 | D2Client/Engine |
| GetPing | 1 | D2Client/Game |
| NPCMENU_IsShopActive | 1 | D2Client/UI |
| PATH_GetKnownFolderPath | 1 | D2Client/Engine |
| SetRGB | 1 | D2Client/Draw |
| AllocGfxInfo | 1 | D2Client/Engine |
| CLIENT_GetGameVersionInfo | 1 | D2Client/ClientModeInGame |
| NPCMENU_SetTransactionMode | 1 | D2Client/UI |
| TEXT_GetOverheadSpeakerUnit | 1 | D2Client/UI |
| STRING_GetWideStringLength | 1 | D2Win/Unicode |
| D2CLIENT_ExitGame | 1 | D2Client/Game |
| SetupMiniPanel | 1 | D2Client/UI |
| CMD_SaveKeyBindings | 1 | D2Client/UI |
| GetStepsOfMissileMovement | 1 | D2Client/Game |
| UTF8_ConvertToWideChar | 1 | D2Lang |
| COMPOSIT_GetBodyPartTransform | 1 | D2Client/Composit |
| TXT_sounds_GetLineBySoundId | 1 | D2Sound/Sound |
| UI_GetFlag | 1 | D2Client/UI |
| TEXT_HandleScrollLinePacket | 1 | D2Client/UI |
| GetInteractedUnitGuid | 1 | D2Client/UI |
| STRUCT_FreeTxtMessageForPacket0x27 | 1 | D2Client/Text |
| TEXT_CopyHoverMessageString | 1 | D2Client/Chat |
| INV_GetCharStatsTxtLine | 1 | D2Client/_SkillHelpers |
| GAMEDATA_GetValue007a04fc | 1 | D2Client/Game |
| IsUnitDistanceLowerThan700 | 1 | D2Sound/Sound |
| SetLanguageCode | 1 | D2Client/Chat |
| DEBUG_CaptureThreadContext | 1 | D2Client/Engine |
| CreateThread | 1 | D2Client/McpConnect |
| GetLanguageCode | 1 | D2Client/Chat |
| GFXUTIL_UnitHasAnimMode | 1 | D2Client/Engine |
| TEXT_IsScrollingTextActive | 1 | D2Client/UI |
| CLIENT_SetAnimModeAndMoveToCurrentPos | 1 | D2Client/Engine |
| INV_ToggleExpansionTab | 1 | D2Client/UI |
| INV_ClearItemDescription | 1 | D2Client/UI |
| DoesBodyHaveAppearanceColors | 1 | D2Client/Composit |
| QuestHandeling | 1 | D2Client/UI |
