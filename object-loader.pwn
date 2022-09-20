/*==============================================================================


	Southclaw's Map Loader/Parser

		Loads .map files populated with CreateObject (or any variation) lines.
		Existence of a 'maps.cfg' file enables Unix style option input.
		Currently only supports '-d<0-4>' for various levels of debugging.


==============================================================================*/


#define FILTERSCRIPT

#include <a_samp>


/*==============================================================================

	Predefinitions and External Dependencies

==============================================================================*/


#undef MAX_PLAYERS
#define MAX_PLAYERS (175)

#include <streamer>					// By Incognito:			http://forum.sa-mp.com/showthread.php?t=102865
#include <sscanf2>					// By Y_Less:				http://forum.sa-mp.com/showthread.php?t=120356
#include <FileManager>				// By JaTochNietDan:		http://forum.sa-mp.com/showthread.php?t=92246


/*==============================================================================

	Constants

==============================================================================*/


#define DIRECTORY_SCRIPTFILES	"./scriptfiles/"
#define DIRECTORY_MAPS			"Maps/"
#define DIRECTORY_SESSION		"session/"
#define CONFIG_FILE				DIRECTORY_MAPS"maps.cfg"

#define MAX_REMOVED_OBJECTS		(1000)
#define MAX_MATERIAL_SIZE		(14)
#define MAX_MATERIAL_LEN		(8)
#define SESSION_NAME_LEN		(40)


/*==============================================================================

	Debug levels

==============================================================================*/


enum
{
	DEBUG_LEVEL_NONE = -1,	// (-1) No prints
	DEBUG_LEVEL_INFO,		// (0) Print information messages
	DEBUG_LEVEL_FOLDERS,	// (1) Print each folder
	DEBUG_LEVEL_FILES,		// (2) Print each loaded file
	DEBUG_LEVEL_DATA,		// (3) Print each loaded data line in each file
	DEBUG_LEVEL_LINES		// (4) Print each line in each file
}

enum E_REMOVE_DATA
{
	e_Model,
	Float: e_PosX,
	Float: e_PosY,
	Float: e_PosZ,
	Float: e_Range
}


/*==============================================================================

	Variables

==============================================================================*/


new g_DebugLevel = 0;
new	g_TotalLoadedObjects;
new	g_TotalObjectsToRemove;
new	g_ModelRemoveData[MAX_REMOVED_OBJECTS][E_REMOVE_DATA];
new	g_LoadedRemoveBuffer[MAX_PLAYERS][MAX_REMOVED_OBJECTS][5];

/*==============================================================================

	Core

==============================================================================*/


public OnFilterScriptInit()
{
	if (!dir_exists(DIRECTORY_SCRIPTFILES))
	{
		print("ERROR: Directory '"DIRECTORY_SCRIPTFILES"' not found. Creating directory.");
		dir_create(DIRECTORY_SCRIPTFILES);
	}

	if (!dir_exists(DIRECTORY_SCRIPTFILES DIRECTORY_MAPS))
	{
		print("ERROR: Directory '"DIRECTORY_SCRIPTFILES DIRECTORY_MAPS"' not found. Creating directory.");
		dir_create(DIRECTORY_SCRIPTFILES DIRECTORY_MAPS);
	}

	if (!dir_exists(DIRECTORY_SCRIPTFILES DIRECTORY_MAPS DIRECTORY_SESSION))
	{
		print("ERROR: Directory '"DIRECTORY_SCRIPTFILES DIRECTORY_MAPS DIRECTORY_SESSION"' not found. Creating directory.");
		dir_create(DIRECTORY_SCRIPTFILES DIRECTORY_MAPS DIRECTORY_SESSION);
	}

	// Load config if exists
	if (fexist(CONFIG_FILE))
		LoadConfig();

	if (g_DebugLevel > DEBUG_LEVEL_NONE)
		printf("INFO: [Init] Debug Level: %d", g_DebugLevel);

	LoadMapsFromFolder(DIRECTORY_MAPS);

	// Yes a standard loop is required here.
	for (new i = 0; i < MAX_PLAYERS; i++)
	{
		if (IsPlayerConnected(i))
			RemoveObjects_OnLoad(i);
	}

	if (g_DebugLevel >= DEBUG_LEVEL_INFO)
	{
		printf("INFO: [Init] %d Total objects", g_TotalLoadedObjects);
		printf("INFO: [Init] %d Objects to remove", g_TotalObjectsToRemove);
	}

	return 1;
}

LoadConfig()
{
	new
		File:file,
		line[32];

	file = fopen(CONFIG_FILE, io_read);

	if (file)
	{
		new len;

		fread(file, line, 32);

		len = strlen(line);

		for (new i = 0; i < len; i++)
		{
			switch(line[i])
			{
				case ' ', '-', '\r', '\n':
					continue;
			}

			if (line[i] == 'd' && (i < len - 3))
			{
				i++;

				new val = line[i] - 48;

				if (DEBUG_LEVEL_NONE < val <= DEBUG_LEVEL_LINES)
					g_DebugLevel = val;

				continue;
			}

			printf("ERROR: Unknown option character at column %d.", i);

			/*
				Ideas for future options:
				-r[path] = set the root directory to load maps from
				-s[value] = set default stream distance
				-S[value] = override all per-file stream distances
				-m[value] = set object limit
				-I[path] = include another directory for loading maps
			*/

		}

		fclose(file);
	}

	return 1;
}

LoadMapsFromFolder(const folder[])
{
	new
		foldername[256],
		dir:dirhandle,
		item[64],
		type,
		filename[256];

	format(foldername, sizeof(foldername), DIRECTORY_SCRIPTFILES"%s", folder);
	dirhandle = dir_open(foldername);

	if (g_DebugLevel >= DEBUG_LEVEL_FOLDERS)
	{
		new
			totalfiles,
			totalmapfiles,
			totalfolders;

		while (dir_list(dirhandle, item, type))
		{
			if (type == FM_FILE)
			{
				totalfiles++;

				if (!strcmp(item[strlen(item) - 4], ".map"))
					totalmapfiles++;
			}

			if (type == FM_DIR && strcmp(item, "..") && strcmp(item, ".") && strcmp(item, "_"))
				totalfolders++;
		}

		// Reopen the directory so the next code can run properly.
		dir_close(dirhandle);
		dirhandle = dir_open(foldername);

		printf("DEBUG: [LoadMapsFromFolder] Reading directory '%s': %d files, %d .map files, %d folders", foldername, totalfiles, totalmapfiles, totalfolders);
	}

	while (dir_list(dirhandle, item, type))
	{
		if (type == FM_FILE)
		{
			if (!strcmp(item[strlen(item) - 4], ".map"))
			{
				filename[0] = EOS;
				format(filename, sizeof(filename), "%s%s", folder, item);
				LoadMap(filename);
			}
		}

		if (type == FM_DIR && strcmp(item, "..") && strcmp(item, ".") && strcmp(item, "_"))
		{
			filename[0] = EOS;
			format(filename, sizeof(filename), "%s%s/", folder, item);
			LoadMapsFromFolder(filename);
		}
	}

	dir_close(dirhandle);

	if (g_DebugLevel >= DEBUG_LEVEL_FOLDERS)
		print("DEBUG: [LoadMapsFromFolder] Finished reading directory.");
}

LoadMap(const filename[])
{
	new
		File:file,
		line[256],

		linenumber = 1,
		objects,
		operations,
		
		funcname[32],
		funcargs[256],
		
		globalworld = -1,
		globalinterior = -1,
		Float:globalrange = 350.0,

		modelid,
		Float:posx,
		Float:posy,
		Float:posz,
		Float:rotx,
		Float:roty,
		Float:rotz,
		world,
		interior,
		Float:range,

		tmpObjID,
		tmpObjIdx,
		tmpObjMod,
		tmpObjTxd[32],
		tmpObjTex[32],
		tmpObjMatCol,

		tmpObjText[128],
		tmpObjResName[32],
		tmpObjRes,
		tmpObjFont[32],
		tmpObjFontSize,
		tmpObjBold,
		tmpObjFontCol,
		tmpObjBackCol,
		tmpObjAlign,

		matSizeTable[MAX_MATERIAL_SIZE][MAX_MATERIAL_LEN] =
		{
			"32x32",
			"64x32",
			"64x64",
			"128x32",
			"128x64",
			"128x128",
			"256x32",
			"256x64",
			"256x128",
			"256x256",
			"512x64",
			"512x128",
			"512x256",
			"512x512"
		};

	if (!fexist(filename))
	{
		printf("ERROR: file: \"%s\" NOT FOUND", filename);
		return 0;
	}

	file = fopen(filename, io_read);

	if (!file)
	{
		printf("ERROR: file: \"%s\" NOT LOADED", filename);
		return 0;
	}

	if (g_DebugLevel >= DEBUG_LEVEL_FILES)
	{
		new totallines;

		while (fread(file, line))
			totallines++;

		// Reopen the file so the actual read code runs properly.
		fclose(file);
		file = fopen(filename, io_read);

		printf("\nDEBUG: [LoadMap] Reading file '%s': %d lines.", filename, totallines);
	}

	while (fread(file, line))
	{
		if (g_DebugLevel == DEBUG_LEVEL_LINES)
			print(line);

		if (line[0] < 65)
		{
			linenumber++;
			continue;
		}

		if (sscanf(line, "p<(>s[32]p<)>s[256]{s[96]}", funcname, funcargs))
		{
			linenumber++;
			continue;
		}

		if (strfind(funcname, "=") != -1 && strfind(funcname, "Create") != -1) strdel(funcname, 0, strfind(funcname, "Create"));
		if (!strcmp(funcname, "options", false))
		{
			if (!sscanf(funcargs, "p<,>ddf", globalworld, globalinterior, globalrange))
			{
				if (g_DebugLevel >= DEBUG_LEVEL_DATA)
					printf(" DEBUG: [LoadMap] Updated options to: %d, %d, %f", globalworld, globalinterior, globalrange);

				operations++;
			}
		}

		if (!strcmp(funcname, "Create", false, 6)) // Scan for any function starting with 'Create', this covers CreateObject, CreateDynamicObject, CreateStreamedObject, etc.
		{
			if (!sscanf(funcargs, "p<,>dffffffD(-1)D(-1){D(-1)}F(-1.0)", modelid, posx, posy, posz, rotx, roty, rotz, world, interior, range))
			{
				if (world == -1)
					world = globalworld;

				if (interior == -1)
					interior = globalinterior;

				if (range == -1.0)
					range = globalrange;

				if (g_DebugLevel == DEBUG_LEVEL_DATA)
				{
					printf(" DEBUG: [LoadMap] Object: %d, %.2f, %.2f, %.2f, %.2f, %.2f, %.2f (%d, %d, %f)",
						modelid, posx, posy, posz, rotx, roty, rotz, world, interior, range);
				}

				tmpObjID = CreateDynamicObject(modelid, posx, posy, posz, rotx, roty, rotz, world, interior, -1, range + 100.0, range);

				g_TotalLoadedObjects++;
				objects++;
				operations++;
			}
		}

		if (!strcmp(funcname, "SetObjectMaterialText"))
		{
			if (!sscanf(funcargs, "p<,>{s[16]} p<\">{s[1]}s[128]p<,>{s[1]} d s[32] p<\">{s[1]}s[32]p<,>{s[1]} ddxxd", tmpObjText, tmpObjIdx, tmpObjResName, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign))
			{
				if (g_DebugLevel == DEBUG_LEVEL_DATA)
				{
					printf(" DEBUG: [LoadMap] Object Text: '%s', %d, '%s', '%s', %d, %d, %x, %x, %d",
						tmpObjText, tmpObjIdx, tmpObjResName, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign);
				}

				new len = strlen(tmpObjText);

				tmpObjRes = strval(tmpObjResName[0]);

				if (tmpObjRes == 0)
				{
					for (new i = 0; i < sizeof(matSizeTable); i++)
					{
						if (strfind(tmpObjResName, matSizeTable[i]) != -1)
							tmpObjRes = (i + 1) * 10;
					}
				}

				for (new i = 0; i < len; i++)
				{
					if (tmpObjText[i] == '\\' && i != len-1)
					{
						if (tmpObjText[i+1] == 'n')
						{
							strdel(tmpObjText, i, i+1);
							tmpObjText[i] = '\n';
						}
					}
				}

				SetDynamicObjectMaterialText(tmpObjID, tmpObjIdx, tmpObjText, tmpObjRes, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign);
				operations++;
			}
		}

		if (!strcmp(funcname, "SetDynamicObjectMaterialText"))
		{
			if (!sscanf(funcargs, "p<,>{s[32]} d p<\">{s[2]}s[128]p<,>{s[2]} s[32] p<\">{s[2]}s[32]p<,>{s[2]} ddxxd", tmpObjIdx, tmpObjText, tmpObjResName, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign))
			{
				if (g_DebugLevel == DEBUG_LEVEL_DATA)
				{
					printf(" DEBUG: [LoadMap] Object Text: '%s', %d, '%s', '%s', %d, %d, %x, %x, %d",
						tmpObjText, tmpObjIdx, tmpObjResName, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign);
				}

				new len = strlen(tmpObjText);

				tmpObjRes = strval(tmpObjResName[0]);

				if (tmpObjRes == 0)
				{
					for (new i = 0; i < sizeof(matSizeTable); i++)
					{
						if (strfind(tmpObjResName, matSizeTable[i]) != -1)
							tmpObjRes = (i + 1) * 10;
					}
				}

				for (new i = 0; i < len; i++)
				{
					if (tmpObjText[i] == '\\' && i != len-1)
					{
						if (tmpObjText[i+1] == 'n')
						{
							strdel(tmpObjText, i, i+1);
							tmpObjText[i] = '\n';
						}
					}
				}

				SetDynamicObjectMaterialText(tmpObjID, tmpObjIdx, tmpObjText, tmpObjRes, tmpObjFont, tmpObjFontSize, tmpObjBold, tmpObjFontCol, tmpObjBackCol, tmpObjAlign);
				operations++;
			}
		}

		if (!strcmp(funcname, "SetObjectMaterial") || !strcmp(funcname, "SetDynamicObjectMaterial"))
		{
			if (!sscanf(funcargs, "p<,>{s[16]}dd p<\">{s[1]}s[32]p<,>{s[1]} p<\">{s[1]}s[32]p<,>{s[1]} x", tmpObjIdx, tmpObjMod, tmpObjTxd, tmpObjTex, tmpObjMatCol))
			{
				if (g_DebugLevel == DEBUG_LEVEL_DATA)
				{
					printf(" DEBUG: [LoadMap] Object Material: %d, %d, '%s', '%s', %x",
						tmpObjIdx, tmpObjMod, tmpObjTxd, tmpObjTex, tmpObjMatCol);
				}

				SetDynamicObjectMaterial(tmpObjID, tmpObjIdx, tmpObjMod, tmpObjTxd, tmpObjTex, tmpObjMatCol);
				operations++;
			}
		}

		if (!strcmp(funcname, "RemoveBuildingForPlayer"))
		{
			if (g_TotalObjectsToRemove < MAX_REMOVED_OBJECTS)
			{
				if (!sscanf(funcargs, "p<,>{s[16]}dffff", modelid, posx, posy, posz, range))
				{
					if (g_DebugLevel == DEBUG_LEVEL_DATA)
					{
						printf(" DEBUG: [LoadMap] Removal: %d, %.2f, %.2f, %.2f, %.2f",
							modelid, posx, posy, posz, range);
					}
			
					g_ModelRemoveData[g_TotalObjectsToRemove][e_Model] = modelid;
					g_ModelRemoveData[g_TotalObjectsToRemove][e_PosX] = posx;
					g_ModelRemoveData[g_TotalObjectsToRemove][e_PosY] = posy;
					g_ModelRemoveData[g_TotalObjectsToRemove][e_PosZ] = posz;
					g_ModelRemoveData[g_TotalObjectsToRemove][e_Range] = range;
			
					g_TotalObjectsToRemove++;
					operations++;
				}
			}
			else
			{
				printf(" ERROR: [LoadMap] Removal on line %d failed. Removal limit reached.", linenumber);
			}
		}

		linenumber++;
	}

	fclose(file);

	if (g_DebugLevel >= DEBUG_LEVEL_FILES)
		printf("DEBUG: [LoadMap] Finished reading file. %d objects loaded from %d lines, %d total operations.", objects, linenumber, operations);

	return linenumber;
}

public OnPlayerConnect(playerid)
{
	RemoveObjects_FirstLoad(playerid);

	return 1;
}

public OnPlayerDisconnect(playerid, reason)
{
	new
		name[MAX_PLAYER_NAME],
		filename[SESSION_NAME_LEN];

	GetPlayerName(playerid, name, MAX_PLAYER_NAME);

	format(filename, sizeof(filename), DIRECTORY_MAPS DIRECTORY_SESSION"%s.dat", name);

	if (g_DebugLevel >= DEBUG_LEVEL_INFO)
		printf("INFO: [OnPlayerDisconnect] Removing session data file for %s", name);

	fremove(filename);

	return 1;
}

RemoveObjects_FirstLoad(playerid)
{
	new
		File:file,
		name[MAX_PLAYER_NAME],
		filename[SESSION_NAME_LEN],
		buffer[5];

	GetPlayerName(playerid, name, MAX_PLAYER_NAME);

	format(filename, sizeof(filename), DIRECTORY_MAPS DIRECTORY_SESSION"%s.dat", name);

	file = fopen(filename, io_write);

	if (!file)
		printf("ERROR: [RemoveObjects_FirstLoad] Opening file '%s' for write.", filename);

	if (g_DebugLevel >= DEBUG_LEVEL_INFO)
		printf("INFO: [RemoveObjects_FirstLoad] Created session data for %s", name);

	for (new i = 0; i < g_TotalObjectsToRemove; i++)
	{
		RemoveBuildingForPlayer(playerid,
			g_ModelRemoveData[i][e_Model],
			g_ModelRemoveData[i][e_PosX],
			g_ModelRemoveData[i][e_PosY],
			g_ModelRemoveData[i][e_PosZ],
			g_ModelRemoveData[i][e_Range]);

		// Build a list of removed objects for checking against when the script is
		// reloaded. This way, the reload function isn't called unnecessarily.

		buffer[0] = g_ModelRemoveData[i][e_Model];
		buffer[1] = _:g_ModelRemoveData[i][e_PosX];
		buffer[2] = _:g_ModelRemoveData[i][e_PosY];
		buffer[3] = _:g_ModelRemoveData[i][e_PosZ];
		buffer[4] = _:g_ModelRemoveData[i][e_Range];

		if (g_DebugLevel >= DEBUG_LEVEL_DATA)
			printf("INFO: [RemoveObjects_FirstLoad] Write: [%x.%x.%x.%x.%x]", buffer[0], buffer[1], buffer[2], buffer[3], buffer[4]);

		fblockwrite(file, buffer);
	}

	fclose(file);

	return 1;
}

RemoveObjects_OnLoad(playerid)
{
	new
		File:file,
		name[MAX_PLAYER_NAME],
		filename[SESSION_NAME_LEN],
		buffer[5],
		idx;

	GetPlayerName(playerid, name, MAX_PLAYER_NAME);

	format(filename, sizeof(filename), DIRECTORY_MAPS DIRECTORY_SESSION"%s.dat", name);

	if (!fexist(filename))
	{
		if (g_DebugLevel >= DEBUG_LEVEL_INFO)
			printf("INFO: [RemoveObjects_OnLoad] Session data for %s doesn't exist, running firstload.", name);

		RemoveObjects_FirstLoad(playerid);

		return 0;
	}

	file = fopen(filename, io_read);

	if (g_DebugLevel >= DEBUG_LEVEL_INFO)
		printf("INFO: [RemoveObjects_OnLoad] Loading removals for %s", name);

	// Build a list of existing removed objects for this player

	while (fblockread(file, g_LoadedRemoveBuffer[playerid][idx], 5))
		idx++;

	fclose(file);

	file = fopen(filename, io_append);

	for (new i = 0; i < g_TotalObjectsToRemove; i++)
	{
		new skip;

		for (new j = 0; j < idx; j++)
		{
			if (
				_:g_ModelRemoveData[i][e_Model] == g_LoadedRemoveBuffer[playerid][j][0] &&
				_:g_ModelRemoveData[i][e_PosX] == g_LoadedRemoveBuffer[playerid][j][1] &&
				_:g_ModelRemoveData[i][e_PosY] == g_LoadedRemoveBuffer[playerid][j][2] &&
				_:g_ModelRemoveData[i][e_PosZ] == g_LoadedRemoveBuffer[playerid][j][3] &&
				_:g_ModelRemoveData[i][e_Range] == g_LoadedRemoveBuffer[playerid][j][4])
			{
				skip = true;
				break;
			}
		}

		if (skip)
		{
			if (g_DebugLevel == DEBUG_LEVEL_DATA)
				printf(" DEBUG: [RemoveObjects_OnLoad] Skipping object removal %d (model: %d)", i, g_ModelRemoveData[i][e_Model]);

			continue;
		}

		if (g_DebugLevel == DEBUG_LEVEL_DATA)
			printf(" DEBUG: [RemoveObjects_OnLoad] Removing object %d (model: %d)", i, g_ModelRemoveData[i][e_Model]);

		RemoveBuildingForPlayer(playerid,
			g_ModelRemoveData[i][e_Model],
			g_ModelRemoveData[i][e_PosX],
			g_ModelRemoveData[i][e_PosY],
			g_ModelRemoveData[i][e_PosZ],
			g_ModelRemoveData[i][e_Range]);

		// This object is new, append it to the player's session data file.

		buffer[0] = g_ModelRemoveData[i][e_Model];
		buffer[1] = _:g_ModelRemoveData[i][e_PosX];
		buffer[2] = _:g_ModelRemoveData[i][e_PosY];
		buffer[3] = _:g_ModelRemoveData[i][e_PosZ];
		buffer[4] = _:g_ModelRemoveData[i][e_Range];

		if (g_DebugLevel >= DEBUG_LEVEL_DATA)
			printf("INFO: [RemoveObjects_OnLoad] Append: [%x.%x.%x.%x.%x]", buffer[0], buffer[1], buffer[2], buffer[3], buffer[4]);

		fblockwrite(file, buffer);
	}

	fclose(file);

	return 1;
}