# Holes in the server surface

What the ~4.5k server functions reference but the set does not satisfy.

## External symbols — referenced, not reconstructed (37)
Must be implemented or linked natively (CRT, Win32, Storm imports, intrinsics).

| symbol | call sites |
|-|-|
| IsBadCodePtr | 30 |
| GetTickCount | 26 |
| _memcpy | 23 |
| _sprintf | 8 |
| wsprintfA | 7 |
| __alldiv | 7 |
| _memmove | 5 |
| FloatToLong | 4 |
| D2PetListStrc | 4 |
| WSAGetLastError | 4 |
| builtin_strncpy | 3 |
| InitializeCriticalSection | 3 |
| _strrchr | 3 |
| GetModuleFileNameA | 3 |
| OutputDebugStringA | 3 |
| _fclose | 3 |
| _fwrite | 3 |
| CRT_GetErrNo | 3 |
| FID_conflict___time32 | 3 |
| CopyRect | 3 |
| D2UnitStrc | 2 |
| _tolower | 2 |
| __stricmp | 2 |
| _vsprintf | 2 |
| _fflush | 2 |
| WaitForSingleObject | 1 |
| AllocateAndInitializeSid | 1 |
| Chat | 1 |
| _toupper | 1 |
| ItemCubingSetup | 1 |
| _strstr | 1 |
| Offset | 1 |
| ExitOrCrashCleanUpJmp | 1 |
| thunk_WEATHER_FreeDC6Graphics | 1 |
| _strtoul | 1 |
| _fopen | 1 |
| Evil | 1 |

## Client/render/sound boundary — server calls into pruned code (307)
Each is a stub point: reimplement, no-op, or route over the wire.

| function | call sites | subsystem |
|-|-|-|
| D2ApplyPercent | 48 | D2Client/_SkillHelpers |
| SOUND_PlaySound | 36 | D2Sound/Sound |
| GFX_LoadUnitModeCof | 25 | D2Client/Engine |
| GFX_AddOverlayToUnit | 25 | D2Client/Engine |
| SetPosVectorShifted | 22 | D2Client/Engine |
| GFX_ClearAllModeFlags | 21 | D2CMP/CelCmp |
| ITEM_SetItemOnHand | 20 | D2Client/UI |
| CLIENT_CheckExpansion | 20 | D2Client/Game |
| GetUIFlag | 19 | D2Client/UI |
| GAMEDATA_GetExitFlag3 | 18 | D2Client/Game |
| SetOffsetVector | 18 | D2Client/Engine |
| IfPlayer | 17 | D2Client/Engine |
| SPELLSEL_ActivateSkillSlot | 16 | D2Client/UI |
| SPELLSEL_HandleSkillSelection | 16 | D2Client/UI |
| GetType | 13 | D2Client/Game |
| SetUIFlag | 12 | D2Client/UI |
| RollBetweenMinAndMax | 11 | D2Client/Draw |
| GetLocaleString | 11 | D2Win/StrTable |
| gnRecordingIndex | 11 | D2Client/Game |
| UI_SendMouseMoveMessage | 11 | D2Client/UI |
| ResetThings | 10 | D2Client/UI |
| INV_GetUniqueItemsTxtLine | 9 | D2Client/_SkillHelpers |
| SOUND_StopUnitSoundByIndex | 9 | D2Sound/Sound |
| AllocParticle | 9 | D2Client/Engine |
| ResetPartyUi | 8 | D2Client/UI |
| RNG_GetRandomInRange | 7 | D2Client/Engine |
| AllocLightMap | 7 | D2Client/Draw |
| SKILL_GetMaxLevelForSkill | 7 | D2Client/UI |
| FreeGfxInfo | 7 | D2Client/Engine |
| PARTICLE_SetStoppedWithFade | 6 | D2Client/Engine |
| GFX_SetAllGfxInfoFlags | 6 | D2Client/Engine |
| COMPOSIT_GetWeaponClassWithTransform | 5 | D2Client/Composit |
| PARTICLE_SetReverseDirection | 5 | D2Client/Engine |
| GFX_RemoveOverlayById | 5 | D2Client/Engine |
| FindWaypointIdByLevelId | 5 | D2Client/Waypoint |
| GetExpireFrame | 5 | D2Client/Chat |
| COMPOSIT_HasWeaponDrawn | 5 | D2Client/Composit |
| SOUND_StopChannelById | 5 | D2Sound/Sound |
| PARTICLE_SetBoundsOffset | 5 | D2Client/Engine |
| PARTICLE_GetPosZShifted | 4 | D2Client/Engine |
| TXT_Skills_GetSkillRange | 4 | D2Client/UI |
| D2WINBUTTON_SetHoverAndClickImages | 4 | D2Client/Forms |
| PARTICLE_InitProjectile | 4 | D2Client/Engine |
| SOUND_SetChannelPriority | 4 | D2Sound/Sound |
| PARTICLE_SetVelocityOffset | 4 | D2Client/Engine |
| CheckMonStatId | 4 | D2Client/UI |
| GetDificulity | 4 | D2Client/Game |
| SOUND_FindChannelForSound | 3 | D2Sound/Sound |
| SOUNDHDR_GetSoundField0x60 | 3 | D2Sound/Sound |
| GetRadiusX | 3 | D2Client/Draw |
| FORMS_DestroyLists | 3 | D2Client/MainMenus |
| PANEL_SetBeltSlotHoverFlag | 3 | D2Client/UI |
| D2WINMAIN_SetControlVisible | 3 | D2Win/D2WinMain |
| PARTICLE_SetAttachedToOwner | 3 | D2Client/Engine |
| D2GFX_SetPaletteForDraw | 3 | D2Client/MainMenus |
| GetSetsLine | 3 | D2Client/_SkillHelpers |
| EnableWaypoint | 3 | D2Client/Waypoint |
| PARTICLE_GetScreenZ | 3 | D2Client/Engine |
| GAMEDATA_GetFlags0070f2bc | 2 | D2Client/Game |
| CMD_InitKeyConfigUI | 2 | D2Client/UI |
| TEXT_SetUnitOverheadFromSoundTable | 2 | D2Client/UI |
| SOUNDHDR_GetGlobal2 | 2 | D2Sound/Sound |
| LIGHTMAP_SetRadius | 2 | D2Client/Draw |
| GetSkillDescription | 2 | D2Client/UI |
| PARTICLE_ClearLifetimeFlag | 2 | D2Client/Engine |
| GFX_SetCofDataFlags | 2 | D2Client/Engine |
| PANEL_ClearBeltSlotHover | 2 | D2Client/UI |
| SOUND_StopById | 2 | D2Sound/Sound |
| GFX_SetPalShiftIndex | 2 | D2Client/Engine |
| AUTOMAP_CenterOnPlayer | 2 | D2Client/UI |
| GFXUTIL_BuildCofParams | 2 | D2Client/Engine |
| D2WINPAL_LoadActPalette | 2 | D2Win/D2WinPalette |
| D2CLIENT_SetExitVar1 | 2 | D2Client/ClientModeInGame |
| GAMEDATA_GetFlags0070f234 | 2 | D2Client/Game |
| SOUNDHDR_GetGlobal0 | 2 | D2Sound/Sound |
| GAMEDATA_SetValue007a04fc | 2 | D2Client/Game |
| DRAW_GetWorldOffsetX | 2 | D2Client/UI |
| SPRITECACHE_GetOrLoadSprite | 2 | D2CMP/SpriteCache |
| COMPOSIT_BuildCofPath | 2 | D2Client/Composit |
| SetRadiusY | 2 | D2Client/Draw |
| CopyWaypoint | 2 | D2Client/Waypoint |
| SOUND_GetOptionsMusic | 2 | D2Sound/D2SoundFast |
| D2CLIENT_SetExitVar3ToTrue | 2 | D2Client/Game |
| CHARSEL_UpdateSelectedCharDisplay | 2 | D2Client/CharSel |
| SOUND_SetMusicEnabled | 2 | D2Sound/D2SoundFast |
| CHARSEL_DestroyAllCharEntries | 2 | D2Client/CharSel |
| ANIM_ResetMonsterFrameCache | 2 | D2Client/Engine |
| D2WINPAL_SetGammaRamp | 2 | D2Win/D2WinPalette |
| MAINMENU_ShowPopupWithCancel | 2 | D2Client/MainMenus |
| GetEntryIndex | 2 | D2Client/Game |
| UI_FreeAllPanelAssets | 2 | D2Client/UI |
| PARTICLE_UpdatePosition | 2 | D2Client/Engine |
| CLIENT_PreloadMonsterCofsInAdjacentRooms | 2 | D2Client/Engine |
| FORMS_CreateAnyFormFromListExEx | 2 | D2Client/MainMenus |
| LIGHTMAP_ValidateAndReset | 2 | D2Client/Draw |
| CheckWaypoint | 2 | D2Client/Waypoint |
| GFX_HasOverlayOfType | 2 | D2Client/Engine |
| D2CLIENT_SetExitVar2 | 2 | D2Client/Game |
| FreeParticle | 2 | D2Client/Engine |
| DRAW_GetWorldOffsetY | 2 | D2Client/UI |
| D2WINMAIN_SetFocusedControl | 2 | D2Win/D2WinMain |
| UIMENU_DialogWindowChatCommands | 2 | D2Client/OOGUtilities |
| UI_ResetInputState | 2 | D2Client/Game |
| D2WINMAIN_SetBackgroundDC6 | 1 | D2Win/D2WinMain |
| CHARSEL_CreateCharEntry | 1 | D2Client/CharSel |
| MPQ_UnloadAllMediaMpqFiles | 1 | D2Win/D2WinArchive |
| CHARSEL_InitRealmSelection | 1 | D2Client/CharSel |
| SetPendingExitCutsceneId | 1 | D2Client/Game |
| SetExitCutscenePlayed | 1 | D2Client/Game |
| NPCMENU_OnItemUnequip | 1 | D2Client/UI |
| GAMEDATA_ExtendTimeout | 1 | D2Client/Game |
| AUTOMAP_GetFade | 1 | D2Client/UI |
| LOADER_SetConnectionLostFlag | 1 | D2Client/Engine |
| DRAW_LocalCharsInSelectionScreen0 | 1 | D2Client/CharSel |
| CLIENT_SetExpansion | 1 | D2Client/Game |
| NPCMENU_HandleTradeMoney | 1 | D2Client/UI |
| TEXT_ProcessChatMessage | 1 | D2Client/UI |
| BuildPacket0x27Messages | 1 | D2Client/Text |
| MISC_GetLanguageCode | 1 | D2Win/StrTable |
| SOUNDHDR_GetGlobal1 | 1 | D2Sound/Sound |
| D2WINTEXTBOX_SetScrollbarCallbackB | 1 | D2Client/Forms |
| NPCMENU_IsShopActive | 1 | D2Client/UI |
| PATH_GetKnownFolderPath | 1 | D2Client/Engine |
| TEXT_HandleOverheadTextPacket | 1 | D2Client/UI |
| TEXT_HandleEventMessagePacket | 1 | D2Client/UI |
| AUTOMAP_SetLeft | 1 | D2Client/UI |
| D2CLIENT_ExitGame | 1 | D2Client/Game |
| SAVEFILE_ParseSaveData | 1 | D2Client/CharSel |
| SOUNDHDR_GetSoundGroupSize | 1 | D2Sound/Sound |
| PARTICLE_GetX | 1 | D2Client/Engine |
| UIMENU_ServerDown | 1 | D2Client/OOGUtilities |
| PARTICLE_GetY | 1 | D2Client/Engine |
| AUTOMAP_SetFade | 1 | D2Client/UI |
| Cleanup | 1 | D2Sound/Sound |
| GFXUTIL_IsDC6BlockOnScreen | 1 | D2Client/Engine |
| NPCMENU_SetSelectedMercIndex | 1 | D2Client/UI |
| D2WINTEXTBOX_SetScrollbarMaxRange | 1 | D2Client/Forms |
| D2WINMAIN_SetControlDisabled | 1 | D2Win/D2WinMain |
| STRING_GetWideStringLength | 1 | D2Win/Unicode |
| SOUNDHDR_AdjustReferenceCount | 1 | D2Sound/Sound |
| FORMS_DestroyAnyForm | 1 | D2Win/D2WinMain |
| AUTOMAP_SetRefreshDelay | 1 | D2Client/UI |
| SOUND_FadeOutAllSoundEffects | 1 | D2Sound/D2SoundFast |
| GetLanguageCode | 1 | D2Client/Chat |
| MPQ_LoadVideoMpqFiles | 1 | D2Win/D2WinArchive |
| INV_ClearItemDescription | 1 | D2Client/UI |
| DoesBodyHaveAppearanceColors | 1 | D2Client/Composit |
| NPCMENU_HandleQuestItemPacket | 1 | D2Client/UI |
| TEXT_ClearUnitHoverText | 1 | D2Client/UI |
| GAMEDATA_GetExitFlag2 | 1 | D2Client/Game |
| WND_GetActiveWindow | 1 | D2Client/WindowHandle |
| SOUND_StopSound | 1 | D2Sound/Sound |
| PALETTE_GetItemPalette | 1 | D2CMP/Pallete |
| MAINMENU_GetRealmCount | 1 | D2Client/MainMenus |
| StoreLastSkillHit | 1 | D2Client/Engine |
| CURSOR_SetCursorItem | 1 | D2Client/UI |
| QUESTLOG_SetZooSpawnFlag | 1 | D2Client/UI |
| PARTICLE_GetBounceCount | 1 | D2Client/Engine |
| Realm | 1 | D2Client/BNGatewayAccess |
| UI_LoadAllPanelAssets | 1 | D2Client/UI |
| D2WINEDITBOX_Destroy | 1 | D2Client/Forms |
| SOUNDHDR_GetGlobal3 | 1 | D2Sound/Sound |
| STRUCT_AllocTxtMessageForPacket0x27 | 1 | D2Client/Text |
| UIMENU_MainMenu | 1 | D2Client/MainMenus |
| ESCMENU_RestoreUIState | 1 | D2Client/UI |
| STRING_CopyWideString | 1 | D2Win/Unicode |
| PARTICLE_IsStoppedOrFading | 1 | D2Client/Engine |
| D2GFX_PlayCutScene | 1 | D2Client/D2GFX |
| GetPing | 1 | D2Client/Game |
| FORMS_CreateAnyFormFromList | 1 | D2Client/MainMenus |
| CHARSEL_FindRealmByName | 1 | D2Client/MainMenus |
| NPCMENU_HandleTradePacket | 1 | D2Client/UI |
| SetRGB | 1 | D2Client/Draw |
| D2GFX_SetPerspectiveCapable | 1 | D2Client/D2GFX |
| CLIENT_GetGameVersionInfo | 1 | D2Client/ClientModeInGame |
| GFX_LoadMonsterCofArchive | 1 | D2CMP/CelCmp |
| PARTICLE_GetPosXShifted | 1 | D2Client/Engine |
| StoreLastKnownIpTcpIp | 1 | D2Client/Forms |
| GFX_RemoveAllOverlays | 1 | D2Client/Engine |
| UI_GetFlag | 1 | D2Client/UI |
| GetInteractedUnitGuid | 1 | D2Client/UI |
| SOUND_GetSoundChannel | 1 | D2Sound/Sound |
| AUTOMAP_GetPartyNames | 1 | D2Client/UI |
| SetText | 1 | D2Client/Forms |
| ESCMENU_ShowMenu | 1 | D2Client/UI |
| FINDTILE_Lookup | 1 | D2CMP/FindTiles |
| UI_HandleNpcInteractionPacket | 1 | D2Client/UI |
| GAMEDATA_GetValue007a04fc | 1 | D2Client/Game |
| D2WINTEXTBOX_SetTextW | 1 | D2Client/Forms |
| NPCMENU_OnItemRemovedFromContainer | 1 | D2Client/UI |
| PALETTE_SetAct | 1 | D2CMP/Pallete |
| UI_HandleHoradricCubePacket | 1 | D2Client/UI |
| INV_ToggleExpansionTab | 1 | D2Client/UI |
| CHARSEL_FreeCachedRealmData | 1 | D2Client/CharSel |
| GFX_GetPalShiftIndex | 1 | D2Client/Engine |
| CMD_RevertKeyBindings | 1 | D2Client/UI |
| GFXUTIL_GetUnitCofDirectionOnScreen | 1 | D2Client/Engine |
| FreeMCP | 1 | D2Client/McpConnect |
| CLIENT_ConnectionRefused | 1 | D2Client/Game |
| PARTICLE_SetStopped | 1 | D2Client/Engine |
| MPQ_LoadAllMediaMpqFiles | 1 | D2Win/D2WinArchive |
| CLIENT_GetD2GSGameType | 1 | D2Client/Game |
| SetResolutionModeWithEndCutScene | 1 | D2Client/D2GFX |
| TEXT_ClearNpcMenuSelection | 1 | D2Client/UI |
| CLIENT_SetLadder | 1 | D2Client/Game |
| GFX_Noop | 1 | D2CMP/CelCmp |
| SAVEFILE_FindAllSaveFiles | 1 | D2Client/MainMenus |
| QUESTLOG_HandleSpecialPacket | 1 | D2Client/UI |
| CLIENT_AllocAct | 1 | D2Client/Game |
| GAMEDATA_SetClickModifier | 1 | D2Client/Game |
| CHARSEL_EnumerateLocalSaves | 1 | D2Client/CharSel |
| CLIENT_SetDifficulty | 1 | D2Client/Game |
| GetDC6OffsetY | 1 | D2CMP/CelCmp |
| AUTOMAP_GetLeft | 1 | D2Client/UI |
| GFX_PrecacheMonsterAllModes | 1 | D2Client/Engine |
| AddMercForHireToGlobalList | 1 | D2Client/UI |
| QUESTLOG_HandleQuestStatePacket | 1 | D2Client/UI |
| PARTICLE_GetPosYShifted | 1 | D2Client/Engine |
| DRAW_GetTypeOfBorder | 1 | D2Client/UI |
| GetDC6Height | 1 | D2CMP/CelCmp |
| D2WINBUTTON_SetCustomData | 1 | D2Client/Forms |
| D2GFX_GetResolutionMode | 1 | D2Client/D2GFX |
| AllocGfxInfo | 1 | D2Client/Engine |
| STRTABLE_GetRegistryLanguage | 1 | D2Win/StrTable |
| NPCMENU_SetTransactionMode | 1 | D2Client/UI |
| AUTOMAP_GetParty | 1 | D2Client/UI |
| MAINMENU_GetRealmName | 1 | D2Client/MainMenus |
| D2WINTEXTBOX_SetScrollbarCallbackA | 1 | D2Client/Forms |
| GetDC6OffsetX | 1 | D2CMP/CelCmp |
| SOUNDHDR_GetSoundLoopFlag | 1 | D2Sound/Sound |
| UTF8_ConvertToWideChar | 1 | D2Lang |
| GetStepsOfMissileMovement | 1 | D2Client/Game |
| GetDC6Width | 1 | D2CMP/CelCmp |
| GetMouseX | 1 | D2Client/UI |
| COMPOSIT_GetBodyPartTransform | 1 | D2Client/Composit |
| SOUND_LocalizeSoundPath | 1 | D2Sound/Sound |
| TEXT_HandleScrollLinePacket | 1 | D2Client/UI |
| UIMENU_CreateHeroSinglePlayer | 1 | D2Client/MainMenus |
| D2WINBUTTON_SetBounds | 1 | D2Client/Forms |
| SOUND_StopMusic | 1 | D2Sound/Sound |
| GFX_FreeNonBaseGfxInfoEntries | 1 | D2Client/Engine |
| NPCMENU_OnItemPutInContainer | 1 | D2Client/UI |
| SOUND_StopChannelGracefully | 1 | D2Sound/Sound |
| D2WINMAIN_SetFormFourth | 1 | D2Win/D2WinMain |
| IsUnitDistanceLowerThan700 | 1 | D2Sound/Sound |
| SetLanguageCode | 1 | D2Client/Chat |
| SOUNDHDR_UpdateRegistryVersion | 1 | D2Sound/Sound |
| WARDEN_HandleServerPacket | 1 | D2Client/Warden |
| UI_CloseActivePanels | 1 | D2Client/UI |
| GFX_IsUnitOnScreen | 1 | D2Client/Engine |
| MAINMENU_QueryAndBuildRealmList | 1 | D2Client/MainMenus |
| TEXT_IsScrollingTextActive | 1 | D2Client/UI |
| GFX_GetCofDataFlags | 1 | D2Client/Engine |
| GFX_UpdateGfxThrottled | 1 | D2Client/Engine |
| SOUND_GetSoundId | 1 | D2Sound/Sound |
| D2WINEDITBOX_ClearText | 1 | D2Client/Forms |
| SPELLSEL_SetSkillSlot | 1 | D2Client/UI |
| CHARSEL_CacheRealmData | 1 | D2Client/CharSel |
| SOUNDHDR_RandomizeSoundFromGroup | 1 | D2Sound/Sound |
| AUTOMAP_SetPartyNames | 1 | D2Client/UI |
| PARTICLE_SetBounceParams | 1 | D2Client/Engine |
| SetPlayersMercInfo | 1 | D2Client/UI |
| QUESTLOG_ToggleQuestScreen | 1 | D2Client/UI |
| QUEST_Horadric_0048a540 | 1 | D2Client/UI |
| wsprintf | 1 | D2Client/UI |
| NPCMENU_OnItemPutInBelt | 1 | D2Client/UI |
| UIMENU_CreateTcpIpGameList | 1 | D2Client/OOGUtilities |
| D2GFX_BeginCutScene | 1 | D2Client/D2GFX |
| AUTOMAP_SetParty | 1 | D2Client/UI |
| D2WINTIMER_Start | 1 | D2Client/Forms |
| WAYPOINT_Init | 1 | D2Client/UI |
| GFX_FreeAllModesGfxInfo | 1 | D2Client/Engine |
| NPCMENU_OnItemEquip | 1 | D2Client/UI |
| TEXT_SetNpcMenuSelection | 1 | D2Client/UI |
| DEBUG_UnwindStackFrames | 1 | D2Client/Engine |
| TEXT_GetOverheadSpeakerUnit | 1 | D2Client/UI |
| WEATHER_ClearParticleArrays | 1 | D2Client/Draw |
| D2WINMAIN_ClearMessageLoopFlag | 1 | D2Win/D2WinMain |
| D2WINTEXTBOX_ClearAllLines | 1 | D2Client/Forms |
| SPELLSEL_ClearWaitingForSkillFlag | 1 | D2Client/UI |
| SetupMiniPanel | 1 | D2Client/UI |
| TRADE_HandleTradeGoldUpdate | 1 | D2Client/UI |
| UIMENU_PrintSmallTitleOnCenterScreen | 1 | D2Client/ChatDlg |
| CMD_SaveKeyBindings | 1 | D2Client/UI |
| CHARSEL_AddCreateNewEntry | 1 | D2Client/CharSel |
| UIMENU_JoinGame | 1 | D2Client/OOGUtilities |
| SPELLSEL_SetMouseHandFlag | 1 | D2Client/UI |
| NPCMENU_HandleMercListPacket | 1 | D2Client/UI |
| InitializeUI | 1 | D2Client/UI |
| TXT_sounds_GetLineBySoundId | 1 | D2Sound/Sound |
| GFX_IsUnitInsideBounds | 1 | D2Client/Engine |
| D2WINTEXTBOX_SetTextFromAnsi | 1 | D2Client/Forms |
| D2WINTEXTBOX_SetTextFromAnsiSimple | 1 | D2Client/Forms |
| STRUCT_FreeTxtMessageForPacket0x27 | 1 | D2Client/Text |
| NPCMENU_OnItemInShop | 1 | D2Client/UI |
| TEXT_CopyHoverMessageString | 1 | D2Client/Chat |
| INV_GetCharStatsTxtLine | 1 | D2Client/_SkillHelpers |
| TEXT_FreeHoverText | 1 | D2Client/UI |
| DEBUG_CaptureThreadContext | 1 | D2Client/Engine |
| CreateThread | 1 | D2Client/McpConnect |
| GFXUTIL_UnitHasAnimMode | 1 | D2Client/Engine |
| CLIENT_SetAnimModeAndMoveToCurrentPos | 1 | D2Client/Engine |
| NPCMENU_OnCursorItemRemoved | 1 | D2Client/UI |
| UIMENU_DrawLadderTextOnTopRight | 1 | D2Client/ChatDlg |
| QuestHandeling | 1 | D2Client/UI |
| DEBUG_FormatAddressInfo | 1 | D2Client/Engine |
| FORMS_SetGlobalFormImage | 1 | D2Win/D2WinMain |

## Ambiguous-resolution gaps — reconstructed server fns referenced but not in closure (6)
Likely real edges dropped because the callee name collides across modules. Review.

| function | call sites | subsystem |
|-|-|-|
| CHATDLG_DestroyAllForms | 5 | Game/Launcher |
| GetHoradricStaffTombLevelId | 4 | D2Common/Dungeon |
| IsWindowMode | 1 | D2Game/Game |
| HasWaypoint | 1 | D2Common/Dungeon |
| AllocPlayerList | 1 | D2Common/Unit |
| Transmorgify | 1 | D2Common/Skills |

## Type / data surface — structs the server set touches (1062)
The data structures a native port must define (usedTypes frequency).

| type | uses |
|-|-|
| D2UnitStrc | 2556 |
| int32_t | 1667 |
| undefined4 /* resolvedType: int */ | 1620 |
| undefined4 /* resolvedType: int32_t */ | 1607 |
| D2GameStrc | 1282 |
| undefined4 /* resolvedType: D2UnitStrc * */ | 1104 |
| undefined4 /* resolvedType: uint32_t */ | 881 |
| undefined4 /* resolvedType: uint */ | 660 |
| uint32_t | 595 |
| undefined4 /* resolvedType: BOOL */ | 430 |
| undefined4 /* resolvedType: DWORD */ | 393 |
| undefined4 /* resolvedType: D2RoomStrc * */ | 354 |
| undefined4 /* resolvedType: eD2UnitType */ | 342 |
| D2RoomStrc | 229 |
| undefined1 /* resolvedType: byte */ | 221 |
| undefined1 /* resolvedType: bool */ | 209 |
| D2AiParamStrc | 201 |
| undefined4 /* resolvedType: int * */ | 194 |
| D2ClientStrc | 192 |
| undefined4 /* resolvedType: D2MissilesTxt * */ | 183 |
| undefined4 /* resolvedType: eD2Skills */ | 181 |
| undefined4 /* resolvedType: D2GameStrc * */ | 173 |
| undefined4 /* resolvedType: D2MonStatsTxt * */ | 173 |
| undefined4 /* resolvedType: D2SkillStrc * */ | 155 |
| undefined4 /* resolvedType: D2StatListExStrc * */ | 148 |
| undefined4 /* resolvedType: D2InventoryStrc * */ | 146 |
| eD2Skills | 141 |
| D2DrlgLevelStrc | 138 |
| undefined2 /* resolvedType: short */ | 132 |
| undefined4 /* resolvedType: D2SkillsTxt * */ | 131 |
| undefined4 /* resolvedType: D2ItemsTxt * */ | 130 |
| undefined4 /* resolvedType: D2ClientStrc * */ | 129 |
| undefined4 /* resolvedType: D2SeedStrc * */ | 123 |
| D2RoomExStrc | 122 |
| undefined4 /* resolvedType: eD2LevelId */ | 117 |
| undefined1 /* resolvedType: char */ | 116 |
| undefined4 /* resolvedType: char * */ | 114 |
| D2SkillArgStrc | 113 |
| undefined4 /* resolvedType: eD2States */ | 108 |
| undefined4 /* resolvedType: D2AiGeneralStrc * */ | 102 |
| eD2ServerIncomingStatus | 100 |
| undefined4 /* resolvedType: D2UnitDataPlayerStrc * */ | 98 |
| undefined4 /* resolvedType: void * */ | 81 |
| D2PoolManagerStrc | 80 |
| D2DynamicPathStrc | 80 |
| D2InventoryStrc | 79 |
| undefined2 /* resolvedType: eCollisionFlags */ | 78 |
| undefined2 /* resolvedType: ushort */ | 75 |
| undefined4 /* resolvedType: D2DynamicPathStrc * */ | 73 |
| undefined2 /* resolvedType: int16_t */ | 72 |
| undefined4 /* resolvedType: eD2ItemTypes */ | 71 |
| uint16_t | 67 |
| undefined4 /* resolvedType: D2RoomExStrc * */ | 67 |
| undefined2 /* resolvedType: uint16_t */ | 65 |
| eD2LevelId | 63 |
| undefined8 /* resolvedType: POINT */ | 62 |
| D2SkillStrc | 61 |
| int16_t | 60 |
| D2StatListExStrc | 60 |
| eD2UnitType | 59 |
| eCollisionFlags | 57 |
| undefined4 /* resolvedType: D2PoolManagerStrc * */ | 56 |
| D2ObjectOperateFnArg | 54 |
| undefined1 /* resolvedType: eInventoryPage */ | 54 |
| eD2States | 53 |
| undefined4 /* resolvedType: eD2PlayerAnimMode */ | 52 |
| undefined4 /* resolvedType: byte * */ | 48 |
| eD2UnitStat | 47 |
| uint8_t | 46 |
| undefined4 /* resolvedType: D2ObjectsTxt * */ | 46 |
| undefined4 /* resolvedType: short * */ | 43 |
| D2UnitDataUnion | 40 |
| D2UnitStrc * | 39 |
| undefined4 /* resolvedType: D2QuestDataStrc * */ | 37 |
| undefined1 /* resolvedType: uint8_t */ | 33 |
| undefined4 /* resolvedType: uint * */ | 33 |
| D2AiGeneralStrc | 31 |
| eD2ItemFlag | 31 |
| D2BitBufferStrc | 31 |
| undefined4 /* resolvedType: eD2UnitStat */ | 29 |
| undefined4 /* resolvedType: size_t */ | 29 |
| undefined4 /* resolvedType: POINT * */ | 28 |
| undefined1[32] /* resolvedType: D2MonsterKillStrc */ | 28 |
| undefined4 /* resolvedType: D2ItemStatCostTxt * */ | 28 |
| D2DamageStrc | 28 |
| D2DrlgGridStrc | 28 |
| undefined1 /* resolvedType: eD2BodyLoc */ | 28 |
| D2DrlgLevelDataWildernessLevel | 26 |
| POINT | 25 |
| eMissilesId | 25 |
| undefined8 /* resolvedType: D2SeedStrc */ | 25 |
| D2DrlgStrc | 25 |
| undefined4 /* resolvedType: D2MonStats2Txt * */ | 25 |
| D2MissileDamageDataStrc | 23 |
| undefined4 /* resolvedType: D2RosterStrc * */ | 23 |
| undefined4 /* resolvedType: D2DrlgLevelStrc * */ | 23 |
| undefined4 /* resolvedType: D2MonsterAiParameterStruct */ | 22 |
| undefined4 /* resolvedType: D2LightMapStrc * */ | 22 |
| undefined4 /* resolvedType: D2BitBufferStrc * */ | 21 |
| D2ItemGenContextStrc | 21 |
| D2SeedStrc | 21 |
| undefined4 /* resolvedType: D2RoomCollisionGridStrc * */ | 21 |
| undefined4 /* resolvedType: D2UnitStrc * * */ | 21 |
| D2DrlgTileDataStrc | 21 |
| D2DrlgActStrc | 21 |
| D2ObjectInitFnArg | 21 |
| D2MonsterKillStrc | 20 |
| undefined4 /* resolvedType: eMissilesId */ | 20 |
| undefined4 /* resolvedType: D2DataTableTxtStrc * */ | 20 |
| undefined4 /* resolvedType: D2DrlgTileGridStrc * */ | 20 |
| D2UnitDataPlayerStrc | 20 |
| undefined1[24] /* resolvedType: D2UnitDataItemDetailsStrc */ | 20 |
| undefined1[92] /* resolvedType: D2SkillArgStrc */ | 20 |
| undefined4 /* resolvedType: uint32_t * */ | 19 |
| undefined1[32] /* resolvedType: D2DrlgRoomCoordsStrc */ | 19 |
| D2UnitDataMonsterStrc | 19 |
| D2ShrinesTxt | 19 |
| undefined4 /* resolvedType: D2DrlgTileDataStrc * */ | 19 |
| undefined4 /* resolvedType: D2RoomStrc * * */ | 18 |
| undefined1 /* resolvedType: eD2InventoryGridType */ | 18 |
| undefined4 /* resolvedType: int32_t * */ | 18 |
| undefined4 /* resolvedType: D2MonsterAiCmdStrc * */ | 18 |
| D2ArchiveStrc | 17 |
| eD2ItemTypes | 16 |
| eD2MonsterAnimMode | 16 |
| undefined4 /* resolvedType: D2DrlgGridStrc * */ | 16 |
| D2QuestDataStrc | 16 |
| undefined4 /* resolvedType: ushort * */ | 16 |
| undefined1[20] /* resolvedType: D2BitBufferStrc */ | 15 |
| undefined4 /* resolvedType: eD2UnitFlags * */ | 15 |
| undefined1 /* resolvedType: eD2ServerIncomingStatus */ | 15 |
| D2MonsterAiStrc | 15 |
| undefined4 /* resolvedType: D2HirelingTxt * */ | 15 |
| D2RoomCollisionGridStrc | 14 |
| D2DrlgMapStrc | 14 |
| undefined4 /* resolvedType: D2PresetUnitStrc * */ | 14 |
| undefined4 /* resolvedType: D2MonsterRegionStrc * */ | 14 |
| D2RoomCoordListStrc | 14 |
| undefined4 /* resolvedType: D2RoomCoordListStrc * */ | 14 |
| D2ServerMessageHandleStrc | 14 |
| undefined4 /* resolvedType: D2LevelDefsTxt * */ | 14 |
| int * | 14 |
| undefined8 /* resolvedType: longlong */ | 13 |
| undefined4 /* resolvedType: D2LevelsTxt * */ | 13 |
| undefined4 /* resolvedType: eD2Sounds */ | 13 |
| undefined4 /* resolvedType: D2StatStrc * */ | 13 |
| undefined4 /* resolvedType: D2TimerListStrc * */ | 13 |
| undefined4 /* resolvedType: eCollisionFlags * */ | 13 |
| undefined4 /* resolvedType: HANDLE */ | 13 |
| D2DrlgLevelPlacementStrc | 13 |
| undefined1 /* resolvedType: eAct */ | 13 |
| D2UnitDataItemDetailsStrc | 13 |
| undefined4 /* resolvedType: eD2ItemFlag */ | 13 |
| undefined4 /* resolvedType: LONG */ | 13 |
| D2MPQFileStrc | 13 |
| D2DrlgCoordsStrc | 12 |
| undefined4 /* resolvedType: D2MonSoundsTxt * */ | 12 |
| undefined4 /* resolvedType: D2GameNpcStrc * */ | 12 |
| D2PresetUnitStrc | 12 |
| undefined4 /* resolvedType: D2MagicAffixTxt * */ | 12 |
| D2UnitDataItemStrc | 12 |
| undefined4 /* resolvedType: uint16_t * */ | 12 |
| undefined8 /* resolvedType: D2AiCmdArgumentsStrc */ | 12 |
| undefined4 /* resolvedType: D2StatesTxt * */ | 12 |
| D2BoundingBoxStrc | 12 |
| D2QServerStrc | 12 |
| undefined4 /* resolvedType: D2ShrinesTxt * */ | 11 |
| undefined4 /* resolvedType: eD2MonsterAnimMode */ | 11 |
| undefined4 /* resolvedType: D2SetItemsTxt * */ | 11 |
| undefined4 /* resolvedType: DWORD * */ | 11 |
| undefined4 /* resolvedType: D2LvlPrestTxt * */ | 11 |
| D2GSPacketSrv0x | 11 |
| undefined4 /* resolvedType: D2DrlgVertexStrc * */ | 11 |
| undefined4 /* resolvedType: float */ | 10 |
| D2QServerClientConnectionStrc | 10 |
| undefined4 /* resolvedType: D2UniqueItemsTxt * */ | 10 |
| D2LvlSubTxt | 10 |
| D2UnitFindArgStrc | 10 |
| eD2BodyLoc | 10 |
| undefined4 /* resolvedType: D2MonsterAiSubStrc * */ | 10 |
| undefined1[38] /* resolvedType: D2UnknownCreateMonsterStrc */ | 10 |
| undefined4 /* resolvedType: D2AiParamStrc * */ | 10 |
| undefined4 /* resolvedType: D2InventoryGridInfoStrc * */ | 10 |
| undefined4 /* resolvedType: byte */ | 10 |
| FILE | 10 |
| undefined4 /* resolvedType: WCHAR * */ | 9 |
| undefined4 /* resolvedType: D2ExperienceTxt * */ | 9 |
| undefined1[260] /* resolvedType: char[260] */ | 9 |
| undefined4 /* resolvedType: D2MonsterAiStrc * */ | 9 |
| undefined4 /* resolvedType: D2DrlgOrthStrc * */ | 9 |
| undefined4 /* resolvedType: D2DrlgFileStrc * */ | 9 |
| undefined4 /* resolvedType: D2DifficultyLevelsTxt * */ | 9 |
| undefined4 /* resolvedType: D2RosterPetStrc * */ | 9 |
| undefined4 /* resolvedType: char */ | 9 |
| eInventoryPage | 9 |
| undefined4 /* resolvedType: D2SkillListStrc * */ | 9 |
| D2FogHeapDescStrc | 9 |
| D2TileLibraryEntryStrc | 9 |
| undefined4 /* resolvedType: eOverlayId */ | 9 |
| D2MonsterAiParameterStruct | 9 |
| undefined4 /* resolvedType: D2DrlgStrc * */ | 8 |
| D2MonStatsTxt | 8 |
| undefined1[44] /* resolvedType: D2UnitFindDataStrc */ | 8 |
| undefined4 /* resolvedType: D2UnitDataPlayerPetsStrc * */ | 8 |
| undefined4 /* resolvedType: D2CharStatsTxt * */ | 8 |
| D2ItemsTxt | 8 |
| undefined4 /* resolvedType: eD2UnitType * */ | 8 |
| D2UnitDataPlayerInteractedNPCStrc | 7 |
| undefined4 /* resolvedType: D2HoverTextStrc * */ | 7 |
| void * | 7 |
| undefined1[2052] /* resolvedType: int[513] */ | 7 |
| undefined4 /* resolvedType: D2DrlgCoordsStrc * */ | 7 |
| D2RoomStrc * | 7 |
| undefined4 /* resolvedType: D2DrlgDeleteStrc * */ | 7 |
| D2DrlgOrthStrc | 7 |
| undefined1[24] /* resolvedType: D2GridScreenCoordinates */ | 7 |
| D2DrlgVertexStrc | 7 |
| D2ObjectsTxt | 7 |
| D2DrlgUnknStrc_0x38 | 7 |
| undefined4 /* resolvedType: D2UnitDataPlayerInteractedNPCStrc * */ | 7 |
| undefined1[16] /* resolvedType: D2BoundingBoxStrc */ | 7 |
| undefined8 /* resolvedType: int[2] */ | 7 |
| undefined4 /* resolvedType: D2MPQFileStrc * */ | 7 |
| undefined4 /* resolvedType: D2DrlgActStrc * */ | 7 |
| undefined4 /* resolvedType: D2AnimDataStrc * */ | 7 |
| D2SkillsTxt | 7 |
| undefined4 /* resolvedType: char[4] */ | 7 |
| undefined4 /* resolvedType: uD2UnitMode */ | 7 |
| undefined4 /* resolvedType: D2WaypointStrc * */ | 7 |
| D2DrlgCoordStrc | 7 |
| D2QuestArgStrc | 6 |
| D2PetListStrc | 6 |
| D2RosterStrc | 6 |
| undefined4 /* resolvedType: D2QuestArgStrc */ | 6 |
| undefined4 /* resolvedType: D2ArchiveStrc * */ | 6 |
| undefined4 /* resolvedType: eD2ItemQuality */ | 6 |
| undefined4 /* resolvedType: LPVOID */ | 6 |
| undefined4 /* resolvedType: D2UnitPartyControlSubSub * */ | 6 |
| D2UnitDataMissileStrc | 6 |
| deflate_state | 6 |
| LPDWORD | 6 |
| undefined4 /* resolvedType: D2DrlgFileStrc * * */ | 6 |
| undefined4 /* resolvedType: D2DrlgCoordListStrc * */ | 6 |
| undefined4 /* resolvedType: D2SuperUniquesTxt * */ | 6 |
| D2UnkOutdoorStrc | 6 |
| D2MonsterRegionStrc * | 6 |
| D2FogHeapBlockHdrStrc | 6 |
| undefined4 /* resolvedType: D2PetStrc * */ | 6 |
| undefined4 /* resolvedType: D2UnitPlayerListStrc * */ | 6 |
| undefined1[16] /* resolvedType: char[16] */ | 6 |
| undefined4 /* resolvedType: D2DrlgEnvironmentStrc * */ | 6 |
| undefined4 /* resolvedType: int * * */ | 6 |
| D2TimerStrc | 6 |
| undefined4 /* resolvedType: D2UnitPartyControlSub * */ | 6 |
| D2SkillListStrc | 6 |
| undefined4 /* resolvedType: D2MonsterDataMinionList * */ | 6 |
| D2ItemStatCostTxt | 5 |
| fpMonsterAiForEach | 5 |
| eD2TimerTypeDWORD | 5 |
| D2TimerListStrc | 5 |
| D2MonsterAiCmdStrc | 5 |
| undefined4 /* resolvedType: D2PetDataStrc * */ | 5 |
| undefined1[20] /* resolvedType: D2ObjectOperateFnArg */ | 5 |
| undefined1[1024] /* resolvedType: int[256] */ | 5 |
| D2DrlgEnvironmentStrc | 5 |
| undefined1[16] /* resolvedType: D2DrlgCoordsStrc */ | 5 |
| undefined4 /* resolvedType: D2DrlgMapStrc * */ | 5 |
| eD2QuestState | 5 |
| D2CubeMainTxt | 5 |
| D2UnitFindDataStrc | 5 |
| undefined4 /* resolvedType: eD2UnitFlags */ | 5 |
| undefined4 /* resolvedType: D2InventoryToBeUpdatedStrc * */ | 5 |
| D2AiGeneralStrc * | 5 |
| undefined4 /* resolvedType: D2RosterPartyListStrc * */ | 5 |
| undefined4 /* resolvedType: D2TimerArgStrc * */ | 5 |
| FARPROC | 5 |
| undefined4 /* resolvedType: D2MonsterRegionFieldStrc * */ | 5 |
| D2MagicAffixTxt | 5 |
| D2LevelDefsTxt | 5 |
| undefined4 /* resolvedType: eD2QuestState */ | 5 |
| undefined1[260] /* resolvedType: CHAR[260] */ | 5 |
| undefined4 /* resolvedType: D2ServerMessageHandleStrc */ | 5 |
| D2DrlgActWarpsInfoStrc | 5 |
| D2DrlgDeleteStrc | 5 |
| undefined4 /* resolvedType: D2RosterLinkListStrc * */ | 5 |
| undefined4 /* resolvedType: D2UnitNodeStrc * */ | 5 |
| undefined1 /* resolvedType: eD2PlayerClassID */ | 5 |
| eD2PlayerClassID | 5 |
| eD2Quests | 5 |
| uD2UnitMode | 5 |
| D2HirelingTxt | 5 |
| undefined1[28] /* resolvedType: int[7] */ | 4 |
| undefined4 /* resolvedType: D2MonSeqMonsterTbls * */ | 4 |
| undefined4 /* resolvedType: D2StaticPathStrc * */ | 4 |
| undefined4 /* resolvedType: D2SetsTxt * */ | 4 |
| undefined4 /* resolvedType: D2MonSeqTxt * */ | 4 |
| LPCRITICAL_SECTION | 4 |
| undefined4 /* resolvedType: LONG * */ | 4 |
| WCHAR | 4 |
| undefined4 /* resolvedType: D2PlayerListSubStrc * */ | 4 |
| undefined4 /* resolvedType: D2ItemGenContextStrc * */ | 4 |
| D2StatInfoStrc | 4 |
| D2DrlgRoomCoordsStrc | 4 |
| undefined1[128] /* resolvedType: D2UnitStrc *[32] */ | 4 |
| pointer | 4 |
| undefined4 /* resolvedType: D2QuestDataA5Q5Strc * */ | 4 |
| D2DrlgRoomTilesListStrc | 4 |
| undefined4 /* resolvedType: void * * */ | 4 |
| undefined4 /* resolvedType: D2ParsedTreasureClassStrc * */ | 4 |
| undefined4 /* resolvedType: LPCRITICAL_SECTION */ | 4 |
| undefined4 /* resolvedType: eDrlgDirection */ | 4 |
| undefined4 /* resolvedType: D2StatInfoStrc * */ | 4 |
| undefined4 /* resolvedType: D2PlayerListStrc * */ | 4 |
| D2LvlPrestTxt | 4 |
| undefined4 /* resolvedType: D2SaveFileHeaderStrc * */ | 4 |
| va_list | 4 |
| D2MonsterRegionStrc | 4 |
| undefined1[20] /* resolvedType: D2DrlgGridStrc */ | 4 |
| undefined1[1024] /* resolvedType: char[1024] */ | 4 |
| undefined4 /* resolvedType: D2RuneTableStrc * */ | 4 |
| undefined1 /* resolvedType: int32_t */ | 4 |
| undefined4 /* resolvedType: D2MissileDamageDataStrc * */ | 4 |
| D2DrlgTileGridStrc | 4 |
| D2MissilesTxt | 4 |
| undefined4 /* resolvedType: D2DrlgActWarpsInfoStrc * */ | 4 |
| D2LevelsTxt | 4 |
| D2UnknownItemRelatedStruct | 4 |
| D2CubeSetupStrc | 4 |
| D2DrlgOutdoorRoomStrc | 4 |
| undefined4 /* resolvedType: eD2Quests */ | 4 |
| undefined4 /* resolvedType: FILE * */ | 4 |
| undefined4 /* resolvedType: D2ItemTypesTxt * */ | 4 |
| undefined4 /* resolvedType: D2SUnitMsgStrc * */ | 4 |
| undefined4 /* resolvedType: bool[4] */ | 4 |
| eDrlgDirection | 4 |
| undefined1[1024] /* resolvedType: ushort[2] */ | 4 |
| D2SUnitMsgStrc | 4 |
| char * | 4 |
| undefined1[520] /* resolvedType: WCHAR[260] */ | 4 |
| D2DrlgPresetRoomStrc | 4 |
| undefined4 /* resolvedType: D2NpcTxt * */ | 3 |
| D2ParsedTreasureClassStrc | 3 |
| undefined4 /* resolvedType: D2RoomExStrc * * */ | 3 |
| undefined1[512] /* resolvedType: ushort[2] */ | 3 |
| D2ObjectModeArg | 3 |
| undefined4 /* resolvedType: D2GridScreenCoordinates * */ | 3 |
| undefined1[256] /* resolvedType: ushort[2] */ | 3 |
| undefined4 /* resolvedType: D2StateExArgStrc */ | 3 |
| undefined1[128] /* resolvedType: D2StatStrc[16] */ | 3 |
| undefined8 /* resolvedType: ulonglong */ | 3 |
| D2QuestDataA1Q4Strc | 3 |
| undefined1[20] /* resolvedType: D2DrlgRoomCoordsStrc */ | 3 |
| D2QuestSpecificDataUnion | 3 |
| undefined4 /* resolvedType: D2TimerListStrc * * */ | 3 |
| undefined8 /* resolvedType: time_t */ | 3 |
| eD2QuestsInternal | 3 |
| undefined4 /* resolvedType: D2SkillDescTxt * */ | 3 |
| undefined4 /* resolvedType: LPCVOID */ | 3 |
| eAct | 3 |
| fpTimerFunction | 3 |
| undefined4 /* resolvedType: D2UnitFindArgStrc * */ | 3 |
| undefined1[124] /* resolvedType: D2MissileDamageDataStrc */ | 3 |
| undefined4 /* resolvedType: D2AiDispatchCallbacksStrc * */ | 3 |
| undefined4 /* resolvedType: DWORD[7] */ | 3 |
| undefined4 /* resolvedType: PRTL_CRITICAL_SECTION_DEBUG */ | 3 |
| D2MonUModTxt | 3 |
| undefined4 /* resolvedType: D2UnitDataItemStrc * */ | 3 |
| undefined4 /* resolvedType: CRITICAL_SECTION * */ | 3 |
| undefined1[64] /* resolvedType: int[16] */ | 3 |
| D2LvlMazeTxt | 3 |
| undefined4 /* resolvedType: D2fpSkillFuncSub */ | 3 |
| undefined4 /* resolvedType: D2UnitDataUnion */ | 3 |
| undefined4 /* resolvedType: D2InactiveUnitListStrc * */ | 3 |
| undefined4 /* resolvedType: D2WaypointStrc * * */ | 3 |
| undefined4 /* resolvedType: D2UnitDataMonsterStrc * */ | 3 |
| D2UnitNodeStrc | 3 |
| D2InactiveMonsterRecordStrc | 3 |
| undefined4 /* resolvedType: CHAR * */ | 3 |
| undefined4 /* resolvedType: D2SkillArgStrc * */ | 3 |
| D2GameNpcStrc | 3 |
| undefined4 /* resolvedType: D2DrlgTileLinkStrc * */ | 3 |
| D2InventoryToBeUpdatedStrc | 3 |
| undefined4 /* resolvedType: eD2GridCellFlags * */ | 3 |
| D2UnknownCreateMonsterStrc | 3 |
| undefined4 /* resolvedType: uint8_t */ | 3 |
| undefined1[32] /* resolvedType: uint32_t[8] */ | 3 |
| undefined4 /* resolvedType: eD2QuestsInternal */ | 3 |
| D2StatStrc | 3 |
| undefined4 /* resolvedType: AI_Main * */ | 3 |
| undefined1[40] /* resolvedType: D2MonsterAiParameterStruct */ | 3 |
| undefined1[4096] /* resolvedType: int[1024] */ | 3 |
| undefined4 /* resolvedType: D2DamageStrc * */ | 3 |
| undefined4 /* resolvedType: D2UnknownStructure0x18 * */ | 3 |
| undefined4 /* resolvedType: D2CUnitEventStrc * */ | 3 |
| undefined4 /* resolvedType: D2FogHeapDescStrc * */ | 3 |
| undefined4 /* resolvedType: D2DrlgRoomCoordsStrc * */ | 3 |
| undefined1[16] /* resolvedType: int[4] */ | 3 |
| undefined4 /* resolvedType: D2SetsTxtFStrc * */ | 3 |
| D2NpcTxt | 3 |
| D2MonSoundsTxt | 3 |
| D2LightMapStrc | 3 |
| D2GSPacketSrv0x4E | 3 |
| undefined4 /* resolvedType: BYTE * */ | 3 |
| D2DrlgUnknStrc_0x | 3 |
| D2DrlgTileDataStrc * | 3 |
| D2UnitPartyControlSub | 3 |
| eD2GridCellFlags | 3 |
| undefined4 /* resolvedType: eD2GridCellFlags */ | 3 |
| fTownAutoMap | 3 |
| undefined1[16] /* resolvedType: D2DrlgCoordStrc */ | 3 |
| eD2ItemQuality | 3 |
| undefined4 /* resolvedType: D2UnknownStructure0x18 * * */ | 3 |
| undefined4 /* resolvedType: LPVOID * */ | 3 |
| D2SaveFileHeaderStrc | 3 |
| undefined1[32] /* resolvedType: char[32] */ | 3 |
| undefined4 /* resolvedType: char * * */ | 3 |
| undefined4 /* resolvedType: eD2LevelId * */ | 3 |
