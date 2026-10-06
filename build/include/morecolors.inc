/**
 * morecolors.inc - MC_ API compatibility layer
 *
 * XMS/jhl2dm were written against a "more colors" include whose functions carry
 * the MC_ prefix.  That include is not distributed with the plugin sources, so
 * this file reimplements the subset XMS actually uses on top of modern
 * SourcePawn (1.12), keeping the original semantics:
 *
 *   {default}    -> \x01
 *   {teamcolor}  -> \x03 (only when an author client is supplied)
 *   {other}      -> \x07RRGGBB, or left untouched if the name is unknown
 *
 * Messages are sent through SayText2 with chat=true, falling back to
 * PrintToChat on engines that lack the SayText2 usermessage.
 */

#if defined _more_colors_included
  #endinput
#endif
#define _more_colors_included

#if !defined MAX_MESSAGE_LENGTH
  #define MAX_MESSAGE_LENGTH 256
#endif

#if !defined MAX_BUFFER_LENGTH
  #define MAX_BUFFER_LENGTH (MAX_MESSAGE_LENGTH * 4)
#endif

#define COLOR_RED   0xFF4040
#define COLOR_BLUE  0x99CCFF
#define COLOR_GRAY  0xCCCCCC
#define COLOR_GREEN 0x3EFF3E

static StringMap g_hColors = null;

static void MC_AddDefaultColors()
{
    MC_AddColor("white",        0xFFFFFF);
    MC_AddColor("black",        0x000000);
    MC_AddColor("red",          0xFF4040);
    MC_AddColor("green",        0x3EFF3E);
    MC_AddColor("lightgreen",   0x90EE90);
    MC_AddColor("blue",         0x99CCFF);
    MC_AddColor("grey",         0xCCCCCC);
    MC_AddColor("gray",         0xCCCCCC);
    MC_AddColor("yellow",       0xFFFF00);
    MC_AddColor("orange",       0xFFA500);
    MC_AddColor("purple",       0x8000FF);
    MC_AddColor("olive",        0x808000);
    MC_AddColor("lime",         0x00FF00);
    MC_AddColor("cyan",         0x00FFFF);
    MC_AddColor("magenta",      0xFF00FF);
    MC_AddColor("pink",         0xFFC0CB);
    MC_AddColor("brown",        0xA52A2A);
    MC_AddColor("gold",         0xFFD700);
    MC_AddColor("teal",         0x008080);
    MC_AddColor("navy",         0x000080);
    MC_AddColor("darkred",      0x8B0000);
    MC_AddColor("darkgreen",    0x006400);
    MC_AddColor("darkblue",     0x00008B);
    MC_AddColor("spectator",    0xCCCCCC);
}

static void MC_EnsureColors()
{
    if (g_hColors == null)
    {
        g_hColors = new StringMap();
        MC_AddDefaultColors();
    }
}

/**
 * Registers a colour that can be used as a {name} tag.
 *
 * @param name    Tag name, without braces. Matched case-insensitively.
 * @param color   Colour as 0xRRGGBB.
 * @return        True on success, false if the colour already exists.
 */
stock bool MC_AddColor(const char[] name, int color)
{
    MC_EnsureColors();

    char sName[64];
    strcopy(sName, sizeof(sName), name);
    for (int i = 0; sName[i] != '\0'; i++)
    {
        sName[i] = CharToLower(sName[i]);
    }

    int ignored;
    if (g_hColors.GetValue(sName, ignored))
    {
        return false;
    }

    g_hColors.SetValue(sName, color);
    return true;
}

/**
 * Replaces colour tags in a string with engine colour codes.
 *
 * @param buffer      String to process, modified in place.
 * @param maxlen      Size of the buffer.
 * @param author      Client used for {teamcolor}, or 0 for none.
 * @param removeTags  Strip tags instead of converting them to colours.
 */
stock void MC_ReplaceColorCodes(char[] buffer, int maxlen, int author = 0, bool removeTags = false)
{
    MC_EnsureColors();

    if (removeTags)
    {
        ReplaceString(buffer, maxlen, "{default}", "", false);
        ReplaceString(buffer, maxlen, "{teamcolor}", "", false);
    }
    else
    {
        ReplaceString(buffer, maxlen, "{default}", "\x01", false);

        if (author > 0 && author <= MaxClients && IsClientInGame(author))
        {
            ReplaceString(buffer, maxlen, "{teamcolor}", "\x03", false);
        }
    }

    char sOutput[MAX_BUFFER_LENGTH];
    strcopy(sOutput, sizeof(sOutput), buffer);

    int iLen = strlen(buffer);
    int iPos = 0;

    while (iPos < iLen)
    {
        if (buffer[iPos] != '{')
        {
            iPos++;
            continue;
        }

        int iEnd = iPos + 1;
        while (iEnd < iLen && buffer[iEnd] != '}' && (iEnd - iPos) < 31)
        {
            char c = buffer[iEnd];
            bool bValid =
                (c >= 'a' && c <= 'z') ||
                (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9');

            if (!bValid)
            {
                break;
            }

            iEnd++;
        }

        if (iEnd >= iLen || buffer[iEnd] != '}')
        {
            iPos++;
            continue;
        }

        int iTagLen = iEnd - iPos - 1;
        if (iTagLen <= 0 || (iEnd - iPos) >= 31)
        {
            iPos = iEnd + 1;
            continue;
        }

        char sTag[32];
        char sFull[40];

        strcopy(sTag, sizeof(sTag), buffer[iPos + 1]);
        sTag[iTagLen] = '\0';

        strcopy(sFull, sizeof(sFull), buffer[iPos]);
        sFull[iTagLen + 2] = '\0';

        for (int i = 0; sTag[i] != '\0'; i++)
        {
            sTag[i] = CharToLower(sTag[i]);
        }

        int iColor;
        if (g_hColors.GetValue(sTag, iColor))
        {
            if (removeTags)
            {
                ReplaceString(sOutput, sizeof(sOutput), sFull, "", false);
            }
            else
            {
                char sCode[16];
                Format(sCode, sizeof(sCode), "\x07%06X", iColor);
                ReplaceString(sOutput, sizeof(sOutput), sFull, sCode, false);
            }
        }

        iPos = iEnd + 1;
    }

    strcopy(buffer, maxlen, sOutput);
}

/**
 * Sends an already colour-coded message to a single client.
 *
 * @param client   Recipient.
 * @param message  Message text.
 * @param author   Client the message is attributed to.
 */
stock void MC_SendMessage(int client, const char[] message, int author = 0)
{
    if (author == 0)
    {
        author = client;
    }

    char sBuffer[MAX_MESSAGE_LENGTH];
    strcopy(sBuffer, sizeof(sBuffer), message);

    UserMsg iIndex = GetUserMessageId("SayText2");
    if (iIndex == INVALID_MESSAGE_ID)
    {
        PrintToChat(client, "%s", sBuffer);
        return;
    }

    Handle hMsg = StartMessageOne("SayText2", client, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS);
    if (hMsg == null)
    {
        return;
    }

    if (GetUserMessageType() == UM_Protobuf)
    {
        PbSetInt(hMsg, "ent_idx", author);
        PbSetBool(hMsg, "chat", true);
        PbSetString(hMsg, "msg_name", sBuffer);
        PbAddString(hMsg, "params", "");
        PbAddString(hMsg, "params", "");
        PbAddString(hMsg, "params", "");
        PbAddString(hMsg, "params", "");
    }
    else
    {
        BfWriteByte(hMsg, author);
        BfWriteByte(hMsg, true);
        BfWriteString(hMsg, sBuffer);
    }

    EndMessage();
}

/**
 * Prints a colour-tagged message to one client's chat.
 */
stock void MC_PrintToChat(int client, const char[] sFormat, any...)
{
    if (client <= 0 || client > MaxClients)
    {
        ThrowError("Invalid client index %i", client);
    }

    if (!IsClientInGame(client))
    {
        return;
    }

    char sBuffer[MAX_BUFFER_LENGTH];
    char sBuffer2[MAX_BUFFER_LENGTH];

    SetGlobalTransTarget(client);
    Format(sBuffer, sizeof(sBuffer), "\x01%s", sFormat);
    VFormat(sBuffer2, sizeof(sBuffer2), sBuffer, 3);
    MC_ReplaceColorCodes(sBuffer2, sizeof(sBuffer2), client);
    MC_SendMessage(client, sBuffer2, client);
}

/**
 * Prints a colour-tagged message to every client's chat.
 */
stock void MC_PrintToChatAll(const char[] sFormat, any...)
{
    char sBuffer[MAX_BUFFER_LENGTH];
    char sBuffer2[MAX_BUFFER_LENGTH];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        SetGlobalTransTarget(i);
        Format(sBuffer, sizeof(sBuffer), "\x01%s", sFormat);
        VFormat(sBuffer2, sizeof(sBuffer2), sBuffer, 2);
        MC_ReplaceColorCodes(sBuffer2, sizeof(sBuffer2), i);
        MC_SendMessage(i, sBuffer2, i);
    }
}

/**
 * Prints a colour-tagged message to one client's chat, attributing
 * {teamcolor} to another client.
 */
stock void MC_PrintToChatEx(int client, int author, const char[] sFormat, any...)
{
    if (client <= 0 || client > MaxClients)
    {
        ThrowError("Invalid client index %i", client);
    }

    if (!IsClientInGame(client))
    {
        return;
    }

    if (author <= 0 || author > MaxClients)
    {
        ThrowError("Invalid client index %i", author);
    }

    if (!IsClientInGame(author))
    {
        return;
    }

    char sBuffer[MAX_BUFFER_LENGTH];
    char sBuffer2[MAX_BUFFER_LENGTH];

    SetGlobalTransTarget(client);
    Format(sBuffer, sizeof(sBuffer), "\x01%s", sFormat);
    VFormat(sBuffer2, sizeof(sBuffer2), sBuffer, 4);
    MC_ReplaceColorCodes(sBuffer2, sizeof(sBuffer2), author);
    MC_SendMessage(client, sBuffer2, author);
}

/**
 * Prints a colour-tagged message as a reply, matching SourceMod's
 * ReplyToCommand routing (console when client is 0).
 */
stock void MC_ReplyToCommand(int client, const char[] sFormat, any...)
{
    char sBuffer[MAX_BUFFER_LENGTH];

    SetGlobalTransTarget(client == 0 ? LANG_SERVER : client);
    VFormat(sBuffer, sizeof(sBuffer), sFormat, 3);

    if (client == 0)
    {
        MC_ReplaceColorCodes(sBuffer, sizeof(sBuffer), 0, true);
        PrintToServer("%s", sBuffer);
    }
    else if (IsClientInGame(client))
    {
        MC_ReplaceColorCodes(sBuffer, sizeof(sBuffer), client);
        MC_SendMessage(client, sBuffer, client);
    }
}
