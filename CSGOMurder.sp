#pragma semicolon 1

#define DEBUG

#define PLUGIN_AUTHOR "R3TROATTACK"
#define PLUGIN_VERSION "1.1"

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>

#pragma newdecls required

EngineVersion g_Game;

public Plugin myinfo = 
{
	name = "Murder", 
	author = PLUGIN_AUTHOR, 
	description = "There is one cop like role and one murder role and a bunch of innocents chaos ensues", 
	version = PLUGIN_VERSION, 
	url = "www.memerland.com"
};

int g_iTrailColors[][] =  {
	{ 255, 0, 0, 255 }, { 255, 127, 0, 255 }, { 255, 255, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 }, { 75, 0, 130, 255 }, { 148, 0, 211, 255 }
};
int g_iMurder = -1;

int g_iTrail[MAXPLAYERS + 1];
int g_iFakeWeapon[MAXPLAYERS + 1];
int g_iEvidenceCount[MAXPLAYERS + 1];

bool g_bGameActive = false;
Handle g_hRoundStartTimer, g_hEvidenceTimer;

float g_fLastMessage[MAXPLAYERS + 1];

int g_iAlive = -1, g_iKills = -1, g_iDeaths = -1, g_iAssists = -1, g_iScore = -1, g_iCollisionGroup = -1;

ConVar g_cPlayersNeeded, g_cTrailLife, g_cEvidenceCount;

ArrayList g_hMapProps, g_hActiveEvidence;

public void OnPluginStart()
{
	g_Game = GetEngineVersion();
	if (g_Game != Engine_CSGO)
	{
		SetFailState("This plugin is for CSGO only.");
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
	g_cPlayersNeeded = CreateConVar("murder_min_players", "3", "How many players are needed to start a game?", FCVAR_NONE, true, 0.0);
	g_cTrailLife = CreateConVar("murder_trail_life", "5.0", "How long does the trail innocents have last for?", FCVAR_NONE, true, 0.0);
	g_cEvidenceCount = CreateConVar("murder_evidence_count", "3", "How many pieces of evidence needed to exchange for a gun?");
	
	CreateConVar("murder_version", PLUGIN_VERSION, "Their is one cop like role and one murder role and a bunch of innocents chaos ensues", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	
	g_hMapProps = new ArrayList();
	g_hActiveEvidence = new ArrayList();
	
	g_iCollisionGroup = FindSendPropInfo("CBaseEntity", "m_CollisionGroup");
	g_iAlive = FindSendPropInfo("CCSPlayerResource", "m_bAlive");
	if (g_iAlive == -1)
		SetFailState("CCSPlayerResource.m_bAlive offset is invalid");
	
	g_iKills = FindSendPropInfo("CCSPlayerResource", "m_iKills");
	if (g_iKills == -1)
		SetFailState("CCSPlayerResource \"m_iKills\" offset is invalid");
	
	g_iDeaths = FindSendPropInfo("CCSPlayerResource", "m_iDeaths");
	if (g_iDeaths == -1)
		SetFailState("CCSPlayerResource \"m_iDeaths\"  offset is invalid");
	
	g_iAssists = FindSendPropInfo("CCSPlayerResource", "m_iAssists");
	if (g_iAssists == -1)
		SetFailState("CCSPlayerResource \"m_iAssists\"  offset is invalid");
	
	g_iScore = FindSendPropInfo("CCSPlayerResource", "m_iScore");
	if (g_iScore == -1)
		SetFailState("CCSPlayerResource \"m_iScore\"  offset is invalid");
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("player_blind", Event_PlayerBlind);
	AddCommandListener(Listern_PlayerTeam, "jointeam");
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_iTrail[i] != INVALID_ENT_REFERENCE)
			KillTrail(i);
	}
}

public void OnClientDisconnect(int client)
{
	ResetClient(client);
	EnoughPlayersCheck();
}

public void OnClientPostAdminCheck(int client)
{
	ResetClient(client);
}

void ResetClient(int client)
{
	g_iFakeWeapon[client] = -1;
	g_iTrail[client] = INVALID_ENT_REFERENCE;
	g_fLastMessage[client] = GetGameTime();
}

public Action Listern_PlayerTeam(int client, const char[] cmd, int argc)
{
	EnoughPlayersCheck();
}

public void EnoughPlayersCheck()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
		{
			if (GetClientTeam(i) > 1)
			{
				count++;
			}
		}
	}
	if (g_bGameActive && count < g_cPlayersNeeded.IntValue)
		g_bGameActive = false;
	else if (!g_bGameActive && count >= g_cPlayersNeeded.IntValue)
	{
		g_bGameActive = true;
		ServerCommand("mp_restartgame 2");
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	EnoughPlayersCheck();
}

public void Event_PlayerBlind(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	
	if (IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) > 1)
	{
		float fDuration = GetEntPropFloat(client, Prop_Send, "m_flFlashDuration");
		CreateTimer(fDuration, Timer_RemoveRadar, userid);
	}
}

public void OnMapStart()
{
	PrecacheModel("materials/sprites/physbeam.vmt", true);
	int playermanager = FindEntityByClassname(0, "cs_player_manager");
	SDKHook(playermanager, SDKHook_ThinkPost, PlayerManagerThinkPost);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_iMurder = -1;
	if (g_hRoundStartTimer != null)
		g_hRoundStartTimer = null;
	g_hRoundStartTimer = CreateTimer(1.0, Timer_SelectRoles);
	
	g_hMapProps.Clear();
	g_hActiveEvidence.Clear();
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iEvidenceCount[i] = 0;
	}
	int ent = 0;
	while ((ent = FindEntityByClassname(ent, "prop_dynamic")) != -1)
	{
		g_hMapProps.Push(ent);
	}
	ent = 0;
	while ((ent = FindEntityByClassname(ent, "prop_dynamic_override")) != -1)
	{
		g_hMapProps.Push(ent);
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 0; i < g_hActiveEvidence.Length; i++)
	{
		int ent = g_hActiveEvidence.Get(i);
		if (IsValidEntity(ent))
		{
			SetEntProp(ent, Prop_Send, "m_bShouldGlow", 0);
		}
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidClient(client))
	{
		StripClientWeapons(client);
		int weapon = GivePlayerItem(client, "weapon_decoy");
		g_iFakeWeapon[client] = EntIndexToEntRef(weapon);
		CreateTimer(1.0, Timer_CreateTrail, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(0.0, Timer_RemoveRadar, event.GetInt("userid"));
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (!IsValidClient(client))
		return Plugin_Continue;
	
	if (buttons & IN_USE)
	{
		int aim = GetClientAimTarget(client, false);
		if (aim > MaxClients)
		{
			char class[128];
			GetEntityClassname(aim, class, sizeof(class));
			if (StrEqual(class, "prop_ragdoll", false))
			{
				if (GetGameTime() - g_fLastMessage[client] >= 1.0)
				{
					int owner = GetClientOfUserId(GetEntProp(aim, Prop_Send, "m_hOwnerEntity"));
					if (owner <= 0)
						PrintToChat(client, " \x06[Murder] \x01Ther owner of this body is: \x02Disconnected!");
					else
						PrintToChat(client, " \x06[Murder] \x01The owner of this body is \x02%N", owner);
					
					g_fLastMessage[client] = GetGameTime();
				}
			}
			else if (StrContains(class, "prop_dynamic", false) != -1)
			{
				float vec[3], pPos[3];
				GetEntPropVector(aim, Prop_Data, "m_vecOrigin", vec);
				GetClientAbsOrigin(client, pPos);
				if (GetVectorDistance(vec, pPos) < 200.0)
				{
					int index = -1;
					if ((index = IsActiveEvidence(aim)) != -1)
					{
						if (g_iEvidenceCount[client] < g_cEvidenceCount.IntValue)
						{
							g_iEvidenceCount[client]++;
							SetEntProp(aim, Prop_Send, "m_bShouldGlow", 0);
							g_hActiveEvidence.Erase(index);
							if (g_iEvidenceCount[client] >= g_cEvidenceCount.IntValue && g_iMurder != client)
							{
								GivePlayerItem(client, "weapon_revolver");
								SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", EntRefToEntIndex(g_iFakeWeapon[client]));
							}
						}
					}
				}
			}
		}
	}
	
	int decoy = EntRefToEntIndex(g_iFakeWeapon[client]);
	int active = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (active == decoy && IsValidEntity(decoy))
	{
		SetEntProp(client, Prop_Data, "m_bDrawViewmodel", 0);
		float fUnlockTime = GetGameTime() + 0.5;
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", fUnlockTime);
		SetEntPropFloat(decoy, Prop_Send, "m_flNextPrimaryAttack", fUnlockTime);
	}
	else
		SetEntProp(client, Prop_Data, "m_bDrawViewmodel", 1);
	return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidClient(client))
	{
		int iRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
		if (iRagdoll > 0)
			AcceptEntityInput(iRagdoll, "Kill");
		CreateDeathRagdoll(client);
		KillTrail(client);
		CheckForWin();
	}
	SetEventBroadcast(event, true);
	return Plugin_Changed;
}

public void CreateDeathRagdoll(int client)
{
	int ent = CreateEntityByName("prop_ragdoll");
	if (ent == -1)
		return;
	
	char sModel[PLATFORM_MAX_PATH];
	GetClientModel(client, sModel, sizeof(sModel));
	DispatchKeyValue(ent, "model", sModel);
	DispatchSpawn(ent);
	ActivateEntity(ent);
	SetEntProp(ent, Prop_Send, "m_hOwnerEntity", GetClientUserId(client));
	SetEntData(ent, g_iCollisionGroup, 2, 4, true);
	float vec[3];
	GetClientAbsOrigin(client, vec);
	TeleportEntity(ent, vec, NULL_VECTOR, NULL_VECTOR);
}

void CheckForWin()
{
	if (g_iMurder == -1 || !IsPlayerAlive(g_iMurder))
	{
		PrintToChatAll(" \x06[Murder] \x04Innocents \x01win!");
		CS_TerminateRound(2.0, CSRoundEnd_CTWin);
		return;
	}
	
	bool alive = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
			if (GetClientTeam(i) > 1)
			if (IsPlayerAlive(i) && g_iMurder != i)
		{
			alive = true;
			break;
		}
	}
	if (!alive)
	{
		PrintToChatAll(" \x06[Murder] \x02Murderer \x01win!");
		CS_TerminateRound(2.0, CSRoundEnd_TerroristWin);
	}
}

public void KillTrail(int client)
{
	if (!IsValidEntity(g_iTrail[client]) || g_iTrail[client] == 0)
	{
		g_iTrail[client] = INVALID_ENT_REFERENCE;
		return;
	}
	
	AcceptEntityInput(g_iTrail[client], "kill", 0, 0, 0);
	g_iTrail[client] = INVALID_ENT_REFERENCE;
}

public void CreateTrail(int client)
{
	if (g_iTrail[client] != INVALID_ENT_REFERENCE)
	{
		KillTrail(client);
	}
	
	int ent = CreateEntityByName("env_spritetrail");
	if (ent != -1)
	{
		float vec[3];
		DispatchKeyValueFloat(ent, "lifetime", g_cTrailLife.FloatValue);
		DispatchKeyValue(ent, "startwidth", "2.5");
		DispatchKeyValue(ent, "endwidth", "1");
		DispatchKeyValue(ent, "spritename", "materials/sprites/physbeam.vmt");
		DispatchKeyValue(ent, "renderamt", "255");
		DispatchKeyValue(ent, "rendercolor", "255 255 255");
		DispatchKeyValue(ent, "rendermode", "4");
		DispatchSpawn(ent);
		SetEntPropFloat(ent, Prop_Send, "m_flTextureRes", 0.05);
		GetClientAbsOrigin(client, vec);
		vec[2] -= 35.0;
		TeleportEntity(ent, vec, NULL_VECTOR, NULL_VECTOR);
		SetVariantString("!activator");
		AcceptEntityInput(ent, "SetParent", client, client, 0);
		SetVariantString("grenade0");
		AcceptEntityInput(ent, "SetParentAttachmentMaintainOffset");
		
		int color[4];
		color = g_iTrailColors[GetRandomInt(0, sizeof(g_iTrailColors) - 1)];
		SetEntityRenderColor(ent, color[0], color[1], color[2], color[3]);
		SDKHook(ent, SDKHook_SetTransmit, Hook_SetTransmit);
		g_iTrail[client] = ent;
		CreateTimer(0.1, Timer_FixSpriteTrail, ent, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_NewEvidence(Handle timer)
{
	if (g_hMapProps.Length == 0)
	{
		KillTimer(g_hEvidenceTimer);
		g_hEvidenceTimer = null;
		return Plugin_Handled;
	}
	
	int ent = -1, index = -1;
	while (!IsValidEntity(ent))
	{
		index = GetRandomInt(0, g_hMapProps.Length - 1);
		ent = g_hMapProps.Get(index);
	}
	g_hActiveEvidence.Push(ent);
	g_hMapProps.Erase(index);
	SetEntProp(ent, Prop_Send, "m_bShouldGlow", 1);
	SetEntProp(ent, Prop_Send, "m_nGlowStyle", 0);
	SetEntPropFloat(ent, Prop_Send, "m_flGlowMaxDist", 1000.0);
	SetEntData(ent, GetEntSendPropOffs(ent, "m_clrGlow"), 0, _, true);
	SetEntData(ent, GetEntSendPropOffs(ent, "m_clrGlow") + 1, 255, _, true);
	SetEntData(ent, GetEntSendPropOffs(ent, "m_clrGlow") + 2, 0, _, true);
	SetEntData(ent, GetEntSendPropOffs(ent, "m_clrGlow") + 3, 255, _, true);
	return Plugin_Continue;
}

public Action Timer_FixSpriteTrail(Handle timer, any ent)
{
	if (IsValidEntity(ent))
	{
		SetVariantString("OnUser1 !self:SetScale:1:0.5:-1");
		AcceptEntityInput(ent, "AddOutput");
		AcceptEntityInput(ent, "FireUser1");
	}
}

public Action Timer_CreateTrail(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (g_iMurder == client)
		return Plugin_Handled;
	if (IsValidClient(client))
		CreateTrail(client);
	
	return Plugin_Handled;
}

public Action Timer_RemoveRadar(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	
	if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
		SetEntProp(client, Prop_Send, "m_iHideHUD", 1 << 12);
}

public Action Timer_SelectRoles(Handle timer)
{
	ArrayList array = new ArrayList();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
		{
			if (GetClientTeam(i) > 1)
				array.Push(i);
		}
	}
	
	if (g_cPlayersNeeded.IntValue > array.Length)
	{
		g_bGameActive = false;
		PrintToChatAll(" \x06[Murder] \x02%i \x01total players are required to play!", g_cPlayersNeeded.IntValue);
		return;
	}
	
	if (g_hEvidenceTimer != null)
	{
		KillTimer(g_hEvidenceTimer);
		g_hEvidenceTimer = null;
	}
	g_hEvidenceTimer = CreateTimer(20.0, Timer_NewEvidence, _, TIMER_REPEAT);
	
	int index = GetRandomInt(0, array.Length - 1);
	g_iMurder = array.Get(index);
	GivePlayerItem(g_iMurder, "weapon_knife");
	PrintToChat(g_iMurder, " \x06[Murder] \x01You are the \x02Murder \x01kill everyone!");
	SetEntPropEnt(g_iMurder, Prop_Data, "m_hActiveWeapon", EntRefToEntIndex(g_iFakeWeapon[g_iMurder]));
	KillTrail(g_iMurder);
	array.Erase(index);
	index = GetRandomInt(0, array.Length - 1);
	int temp = array.Get(index);
	GivePlayerItem(temp, "weapon_revolver");
	g_iEvidenceCount[temp] = 3;
	SetEntPropEnt(temp, Prop_Data, "m_hActiveWeapon", EntRefToEntIndex(g_iFakeWeapon[temp]));
	PrintToChat(temp, " \x06[Murder] \x01You have been given the revolver, use it wisely.");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThinkPost, Hook_OnPostThinkPost);
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
	SDKHook(client, SDKHook_WeaponCanUse, Hook_CanUseWeapon);
}

public Action Hook_CanUseWeapon(int client, int weapon)
{
	char sWeapon[32];
	GetEntityClassname(weapon, sWeapon, sizeof(sWeapon));
	
	if (!StrEqual("weapon_decoy", sWeapon, false))
	{
		if (!StrEqual(sWeapon, "weapon_knife", false) && g_iMurder == client)
			return Plugin_Handled;
		else if (StrEqual(sWeapon, "weapon_knife", false) && g_iMurder != client)
			return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public void Hook_OnPostThinkPost(int client)
{
	SetEntProp(client, Prop_Send, "m_iAddonBits", 0);
}

public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (!IsValidClient(attacker) || !IsValidClient(victim))
		return Plugin_Continue;
	
	if (weapon == -1)
		return Plugin_Continue;
	char classname[PLATFORM_MAX_PATH];
	GetEntityClassname(weapon, classname, sizeof(classname));
	if (StrEqual(classname, "weapon_knife", false) || StrEqual(classname, "weapon_revolver", false) || StrEqual(classname, "weapon_deagle", false))
	{
		damage = 1000.0;
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

//Snippet from TTT plugin
public void PlayerManagerThinkPost(int entity)
{
	int isAlive[65] =  { true, ... };
	SetEntDataArray(entity, g_iAlive, isAlive, 65);
	
	int iSixtyNine[MAXPLAYERS + 1] =  { 69, ... };
	
	SetEntDataArray(entity, g_iKills, iSixtyNine, MaxClients + 1);
	SetEntDataArray(entity, g_iDeaths, iSixtyNine, MaxClients + 1);
	SetEntDataArray(entity, g_iAssists, iSixtyNine, MaxClients + 1);
	SetEntDataArray(entity, g_iScore, iSixtyNine, MaxClients + 1);
}

public Action Hook_SetTransmit(int ent, int client)
{
	return g_iMurder == client ? Plugin_Continue : Plugin_Handled;
}

stock bool IsValidClient(int client)
{
	if (client <= 0 || client > MaxClients)
		return false;
	
	if (!IsClientInGame(client) || !IsClientConnected(client))
		return false;
	
	return true;
}

stock void StripClientWeapons(int client)
{
	int iEnt;
	for (int i = 0; i <= 4; i++)
	{
		while ((iEnt = GetPlayerWeaponSlot(client, i)) != -1)
		{
			RemovePlayerItem(client, iEnt);
			AcceptEntityInput(iEnt, "Kill");
		}
	}
}

stock int IsActiveEvidence(int ent)
{
	for (int i = 0; i < g_hActiveEvidence.Length; i++)
	{
		int item = g_hActiveEvidence.Get(i);
		if (item == ent)
			return i;
	}
	return -1;
} 