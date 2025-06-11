#pragma semicolon 1
#include <sourcemod>
#include <steamworks>

#pragma newdecls required

public Plugin myinfo =
{
    name = "shavit - Zoned Maps (Hybrid)",
    author = "SlidyBat + Hybrid HTTP Version by Nora",
    description = "Shows admins zoned/unzoned maps using DB and HTTP fallback",
    version = "1.2",
    url = "",
};

Database g_hDatabase;
char g_cMySQLPrefix[32];

ArrayList g_aAllMapsList;
ArrayList g_aZonedMapsList;

int g_iMapFileSerial = -1;
bool g_bReadFromMapsFolder = true;

public void OnPluginStart()
{
    g_aAllMapsList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_aZonedMapsList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

    RegAdminCmd("sm_zonedmaps", Command_ZonedMaps, ADMFLAG_CHANGEMAP);
    RegAdminCmd("sm_unzonedmaps", Command_UnzonedMaps, ADMFLAG_CHANGEMAP);
    RegAdminCmd("sm_allmaps", Command_AllMaps, ADMFLAG_CHANGEMAP);

    LoadAllMaps();
}

public void OnMapStart() { LoadAllMaps(); }
public void OnMapEnd() { g_iMapFileSerial = -1; }

public Action Command_ZonedMaps(int client, int args) { OpenMapsMenu(client, true); return Plugin_Handled; }
public Action Command_UnzonedMaps(int client, int args) { OpenMapsMenu(client, false); return Plugin_Handled; }
public Action Command_AllMaps(int client, int args) { OpenAllMapsMenu(client); return Plugin_Handled; }

void StrToLowercase(const char[] input, int length, char[] output)
{
    int i;
    for (i = 0; i < length && input[i] != '\0'; i++)
    {
        output[i] = CharToLower(input[i]);  // Convert each character to lowercase
    }
    output[i] = '\0';  // Null-terminate the string
}

public void OpenMapsMenu(int client, bool zoned)
{
    if (!g_aZonedMapsList.Length)
    {
        PrintToChat(client, "No zoned maps found...");
        return;
    }
    else if (!zoned && !g_aAllMapsList.Length)
    {
        PrintToChat(client, "No map list found...");
        return;
    }

    Menu menu = new Menu(MapsMenuHandler);
	char buffer[512];
	int i_mapsCount = 0;
	
    for (int i = 0; i < g_aAllMapsList.Length; i++)
    {
        g_aAllMapsList.GetString(i, buffer, sizeof(buffer));
        if (FindMap(buffer, buffer, sizeof(buffer)) == FindMap_NotFound)
            continue;

        // Convert map name to lowercase before checking
        char lowerMap[PLATFORM_MAX_PATH];
        StrToLowercase(buffer, sizeof(buffer), lowerMap);  // Use StrToLowercase here

        bool isZoned = g_aZonedMapsList.FindString(lowerMap) >= 0;
        if ((zoned && isZoned) || (!zoned && !isZoned))
        {
            menu.AddItem(buffer, buffer);
            i_mapsCount++;
        }
    }

    Format(buffer, sizeof(buffer), "%s Maps (%d):\n", zoned ? "Zoned" : "Unzoned", i_mapsCount);
    menu.SetTitle(buffer);
    menu.Display(client, MENU_TIME_FOREVER);
}

public void OpenAllMapsMenu(int client)
{
    if (!g_aAllMapsList.Length) return;

    char buffer[512];
    Menu menu = new Menu(MapsMenuHandler);
    Format(buffer, sizeof(buffer), "All Maps:\n");
    menu.SetTitle(buffer);

    for (int i = 0; i < g_aAllMapsList.Length; i++)
    {
        g_aAllMapsList.GetString(i, buffer, sizeof(buffer));
        if (FindMap(buffer, buffer, sizeof(buffer)) != FindMap_NotFound)
            menu.AddItem(buffer, buffer);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MapsMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char map[PLATFORM_MAX_PATH];
        GetMenuItem(menu, param2, map, sizeof(map));
        OpenChangeMapMenu(param1, map);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
}

public void OpenChangeMapMenu(int client, char[] map)
{
    Menu menu = new Menu(ChangeMapMenuHandler);
    char buffer[512];
    Format(buffer, sizeof(buffer), "Change map to %s?\n\n", map);
    menu.SetTitle(buffer);
    menu.AddItem(map, "Yes");
    menu.AddItem("no", "No");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int ChangeMapMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select && param2 == 0)
    {
        char map[PLATFORM_MAX_PATH];
        GetMenuItem(menu, param2, map, sizeof(map));
        PrintToChatAll("[SM] Changing map to %s ...", map);
        DataPack data;
        CreateDataTimer(2.0, Timer_ChangeMap, data);
        data.WriteString(map);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
}

public void LoadZonedMapsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("[SQL Error] - %s", error);
        return;
    }

    while (results.FetchRow())
    {
        char map[PLATFORM_MAX_PATH];
        results.FetchString(0, map, sizeof(map));

        // Convert map name to lowercase before adding to zoned maps list
        char lowerMap[PLATFORM_MAX_PATH];
        StrToLowercase(map, sizeof(map), lowerMap);  // Use StrToLowercase here

        g_aZonedMapsList.PushString(lowerMap);
    }

    // Check HTTP fallback for unlisted maps
    for (int i = 0; i < g_aAllMapsList.Length; i++)
    {
        char map[PLATFORM_MAX_PATH];
        g_aAllMapsList.GetString(i, map, sizeof(map));

        // Convert map name to lowercase before checking HTTP
        char lowerMap[PLATFORM_MAX_PATH];
        StrToLowercase(map, sizeof(map), lowerMap);  // Use StrToLowercase here

        if (g_aZonedMapsList.FindString(lowerMap) < 0)
        {
            char url[256];
            Format(url, sizeof(url), "http://zones-cstrike.srcwr.com/z/%s.json", map);
            Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
            if (hRequest != INVALID_HANDLE)
            {
                SteamWorks_SetHTTPRequestContextValue(hRequest, i);
                SteamWorks_SetHTTPCallbacks(hRequest, OnHTTPZoneCheck);
                SteamWorks_SendHTTPRequest(hRequest);
            }
        }
    }
}

public void OnHTTPZoneCheck(Handle request, bool failure, bool success, EHTTPStatusCode statusCode, any index)
{
    if (!success || failure || statusCode != k_EHTTPStatusCode200OK)
        return;

    char map[PLATFORM_MAX_PATH];
    g_aAllMapsList.GetString(index, map, sizeof(map));

    // Convert map name to lowercase before checking
    char lowerMap[PLATFORM_MAX_PATH];
    StrToLowercase(map, sizeof(map), lowerMap);  // Use StrToLowercase here

    if (g_aZonedMapsList.FindString(lowerMap) < 0)
    {
        g_aZonedMapsList.PushString(lowerMap);
    }
}

public void LoadAllMaps()
{
    SQL_SetPrefix();

    g_aAllMapsList.Clear();
    g_aZonedMapsList.Clear();

    if (g_bReadFromMapsFolder)
        LoadFromMapsFolder(g_aAllMapsList);
    else if (ReadMapList(g_aAllMapsList, g_iMapFileSerial, "timer-zonedmaps", MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_MAPSFOLDER) == null)
        LogError("Unable to create a valid map list.");

    char error[256];
    g_hDatabase = SQL_Connect("shavit", true, error, sizeof(error));

    if (g_hDatabase == INVALID_HANDLE)
    {
        delete g_hDatabase;
        delete g_aAllMapsList;
        delete g_aZonedMapsList;
        SetFailState("[SQL Error] - %s", error);
    }

    char query[512];
    Format(query, sizeof(query), "SELECT a.map FROM mapzones AS a WHERE a.track = 0 AND a.type = 0 AND EXISTS (SELECT 1 FROM mapzones AS b WHERE a.map = b.map AND b.track = 0 AND b.type = 1) ORDER BY a.map", g_cMySQLPrefix);
    g_hDatabase.Query(LoadZonedMapsCallback, query, _, DBPrio_High);
}

bool LoadFromMapsFolder(ArrayList array)
{
    Handle mapdir = OpenDirectory("maps/");
    char name[PLATFORM_MAX_PATH];
    FileType filetype;

    if (mapdir == INVALID_HANDLE) return false;

    while (ReadDirEntry(mapdir, name, sizeof(name), filetype))
    {
        if (filetype != FileType_File) continue;
        int namelen = strlen(name) - 4;
        if (StrContains(name, ".bsp", false) != namelen) continue;
        name[namelen] = '\0';

        // Convert map name to lowercase before adding to the list
        char lowerMap[PLATFORM_MAX_PATH];
        StrToLowercase(name, sizeof(name), lowerMap);  // Use StrToLowercase here
        array.PushString(lowerMap);
    }

    CloseHandle(mapdir);
    return true;
}

void SQL_SetPrefix()
{
    char sFile[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sFile, sizeof(sFile), "configs/shavit-prefix.txt");
    File fFile = OpenFile(sFile, "r");
    if (fFile == null)
        SetFailState("Cannot open shavit-prefix.txt");

    char sLine[PLATFORM_MAX_PATH * 2];
    while (fFile.ReadLine(sLine, sizeof(sLine)))
    {
        TrimString(sLine);
        strcopy(g_cMySQLPrefix, sizeof(g_cMySQLPrefix), sLine);
        break;
    }
    delete fFile;
}

public Action Timer_ChangeMap(Handle timer, DataPack data)
{
    char map[PLATFORM_MAX_PATH];
    data.Reset();
    data.ReadString(map, sizeof(map));
    SetNextMap(map);
    ForceChangeLevel(map, "RTV Mapvote");
}