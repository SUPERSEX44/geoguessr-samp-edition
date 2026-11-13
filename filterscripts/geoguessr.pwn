/*
==============================================================================
  GEOGUESSER PARA SA-MP  -  Filterscript
==============================================================================

  COMO FUNCIONA
  - El jugador escribe /geo, lee las reglas y empieza la partida.
  - Cada ronda tiene 2 fases:
      FASE 1 (GEO_TIEMPO_OBSERVAR): ve el lugar con la camara fija y ESC bloqueado.
      FASE 2 (GEO_TIEMPO_ADIVINAR): fundido a negro; ya puede pausar (queda en un
        senuelo) y marca donde cree que estaba: ESC -> clic DERECHO -> /confirmar.
  - Mientras mas cerca marque, mas puntos gana.
  - Cada jugador juega en su propio mundo virtual: pueden jugar varios a la vez.

  COMANDOS
  /geo o /geoayuda  - reglas / empezar
  /confirmar        - envia tu marca del mapa
  /siguiente        - salta la pantalla de resultado
  /salir            - abandona la partida
  (DEBUG) /geoguardar <nombre>  - guarda tu camara actual como nueva locacion
  (DEBUG) /georecargar          - vuelve a leer el .txt

  ARCHIVO DE LOCACIONES  (scriptfiles/geoguessr_locaciones.txt)
  Una locacion por linea:
      x, y, z, cx, cy, cz, nombre_de_la_zona
  x,y,z    = donde esta la camara (y el lugar que hay que adivinar)
  cx,cy,cz = hacia donde mira la camara
  Se aceptan lineas vacias y comentarios que empiecen con // o #
  Usa nombres SIN tildes ni enie.
==============================================================================
*/

#pragma tabsize 0
#include <a_samp>
#include <zcmd>
#include <foreach>
#pragma warning disable 239
// ============================ CONFIGURACION ===============================
#define GEO_ARCHIVO             "geoguessr_locaciones.txt"
#define GEO_RONDAS              5           // rondas por partida (maximo GEO_RONDAS_MAX)
#define DEBUG
//1min en total
#define GEO_TIEMPO_OBSERVAR     30          // fase 1: segundos para mirar el lugar (ESC bloqueado)
#define GEO_TIEMPO_ADIVINAR     30          // fase 2: segundos para marcar en el mapa (pantalla negra)

#define GEO_FUNDIDO_PASOS       10          // pasos del fundido a negro (1 paso = 100 ms)
#define GEO_NIVEL_HUD           5000        // SetPlayerDrunkLevel > 5000 oculta el HUD

#define GEO_SENUELO_X           0.0         /// donde queda el jugador en la fase 2: su flecha del
#define GEO_SENUELO_Y           0.0         // mapa de pausa apunta aca, nunca al lugar real
#define GEO_SENUELO_Z           0.0

#define GEO_PAUSA_RESULTADO     12          // segundos que se muestra el resultado
#define GEO_PUNTOS_MAX          5000        // puntos de una ronda perfecta
#define GEO_ESCALA_DISTANCIA    900.0       // mas alto = puntaje mas permisivo
#define GEO_RADIO_PERFECTO      40.0        // metros de margen para sacar el maximo
#define GEO_TAM_ZONA            100.0       // medio lado del cuadro rojo que revela el lugar
#define GEO_CONFIRMAR_MANUAL    1           // 1 = marcar + /confirmar | 0 = el clic en el mapa responde directo
#define GEO_MUNDO_BASE          7000        // mundo virtual de cada jugador = base + playerid

// ================================ INTERNO =================================
#define GEO_RONDAS_MAX          10
#define MAX_LOCACIONES          200
#define GEO_NOMBRE_LEN          48
#define GEO_SIN_ZONA            (-1)

#define DIALOG_GEO_REGLAS       7600
#define DIALOG_GEO_FIN          7601

#define COLOR_GEO               0x33CCFFFF
#define COLOR_OK                0x66FF66FF
#define COLOR_ERR               0xFF6666FF
#define COLOR_INFO              0xFFFF66FF

#define GEO_LIBRE               0
#define GEO_OBSERVANDO          1   // fase 1: mira el lugar, ESC bloqueado
#define GEO_FUNDIDO             2   // fundido a negro
#define GEO_ADIVINANDO          3   // fase 2: pantalla negra, marca en el mapa
#define GEO_RESULTADO           4

#if GEO_RONDAS > GEO_RONDAS_MAX
    #error GEO_RONDAS no puede ser mayor que GEO_RONDAS_MAX
#endif

enum E_GEO_LOC
{
    Float:locX,
    Float:locY,
    Float:locZ,
    Float:locCX,
    Float:locCY,
    Float:locCZ,
    locNombre[GEO_NOMBRE_LEN]
}

new GeoLoc[MAX_LOCACIONES][E_GEO_LOC];
new GeoTotal = 0;

// Estado por jugador
new gEstado[MAX_PLAYERS];
new gRonda[MAX_PLAYERS];
new gRondasTotal[MAX_PLAYERS];
new gPuntos[MAX_PLAYERS];
new gTiempo[MAX_PLAYERS];
new gPausa[MAX_PLAYERS];
new gTimer[MAX_PLAYERS];
new bool:gTieneMarca[MAX_PLAYERS];
new Float:gMarcaX[MAX_PLAYERS];
new Float:gMarcaY[MAX_PLAYERS];
new gZona[MAX_PLAYERS];
new gOrden[MAX_PLAYERS][GEO_RONDAS_MAX];
new gHistPuntos[MAX_PLAYERS][GEO_RONDAS_MAX];
new Float:gHistDist[MAX_PLAYERS][GEO_RONDAS_MAX];   // -1.0 = sin respuesta

// Para devolver al jugador a donde estaba
new Float:gAntX[MAX_PLAYERS];
new Float:gAntY[MAX_PLAYERS];
new Float:gAntZ[MAX_PLAYERS];
new Float:gAntAng[MAX_PLAYERS];
new Float:gAntVida[MAX_PLAYERS];
new Float:gAntChaleco[MAX_PLAYERS];
new gAntInt[MAX_PLAYERS];
new gAntVW[MAX_PLAYERS];

// HUD
new PlayerText:gTdInfo[MAX_PLAYERS];
new PlayerText:gTdAyuda[MAX_PLAYERS];
new PlayerText:gTdNegro[MAX_PLAYERS];       // box negro a pantalla completa (fundido)
new gTimerFundido[MAX_PLAYERS];
new gFundidoPaso[MAX_PLAYERS];
new bool:gEscBloqueado[MAX_PLAYERS];
new bool:gAnulada[MAX_PLAYERS];             // pauso en la fase 1: la ronda no suma puntos

new gTexto[1536];   // buffer para dialogos

forward Geo_Tick(playerid);
forward Geo_Fundido(playerid);

// ============================== UTILIDADES ================================

stock Float:Geo_Distancia2D(Float:x1, Float:y1, Float:x2, Float:y2)
{
    new Float:dx = x1 - x2;
    new Float:dy = y1 - y2;
    return floatsqroot(dx * dx + dy * dy);
}

stock Geo_CalcularPuntos(Float:dist)
{
    if (dist <= GEO_RADIO_PERFECTO) return GEO_PUNTOS_MAX;
    new Float:p = float(GEO_PUNTOS_MAX) * floatpower(2.718281828, 0.0 - (dist / GEO_ESCALA_DISTANCIA));
    return floatround(p);
}

stock Geo_FormatearDistancia(Float:dist, out[], size = sizeof out)
{
    if (dist >= 1000.0) format(out, size, "%.1f km", dist / 1000.0);
    else format(out, size, "%d m", floatround(dist));
}

stock Geo_Calificacion(Float:dist, out[], size = sizeof out)
{
    if (dist <= 100.0) format(out, size, "PERFECTO!");
    else if (dist <= 500.0) format(out, size, "Muy cerca");
    else if (dist <= 1500.0) format(out, size, "Cerca");
    else if (dist <= 3000.0) format(out, size, "Lejos");
    else format(out, size, "Muy lejos");
}

stock Geo_RondasPartida()
{
    return (GeoTotal < GEO_RONDAS) ? GeoTotal : GEO_RONDAS;
}

// ========================= CARGA DEL ARCHIVO .TXT =========================

// Lee un campo terminado en coma. Devuelve 1 si encontro la coma, 0 si no.
stock Geo_SiguienteCampo(const linea[], &pos, campo[], size = sizeof campo)
{
    while (linea[pos] == ' ' || linea[pos] == '\t') pos++;
    new n = 0;
    while (linea[pos] != ',' && linea[pos] != '\0' && linea[pos] != '\r' && linea[pos] != '\n')
    {
        if (n < size - 1) campo[n++] = linea[pos];
        pos++;
    }
    if (linea[pos] != ',')
    {
        campo[0] = '\0';
        return 0;
    }
    pos++;
    while (n > 0 && (campo[n - 1] == ' ' || campo[n - 1] == '\t')) n--;
    campo[n] = '\0';
    return 1;
}

stock Geo_CampoNumerico(const s[])
{
    if (!s[0]) return 0;
    for (new i = 0; s[i] != '\0'; i++)
    {
        if ((s[i] >= '0' && s[i] <= '9') || s[i] == '-' || s[i] == '+' || s[i] == '.') continue;
        return 0;
    }
    return 1;
}

// Devuelve: 1 = locacion valida | 0 = linea vacia o comentario | -1 = formato invalido
stock Geo_ParsearLinea(const linea[], slot)
{
    new pos = 0;
    while (linea[pos] == ' ' || linea[pos] == '\t') pos++;

    if (linea[pos] == '\0' || linea[pos] == '\r' || linea[pos] == '\n' ||
        linea[pos] == '#' || linea[pos] == ';' ||
        (linea[pos] == '/' && linea[pos + 1] == '/')) return 0;

    new campo[32];
    new Float:v[6];
    for (new i = 0; i < 6; i++)
    {
        if (!Geo_SiguienteCampo(linea, pos, campo) || !Geo_CampoNumerico(campo)) return -1;
        v[i] = floatstr(campo);
    }

    // Lo que queda de la linea es el nombre de la zona
    while (linea[pos] == ' ' || linea[pos] == '\t') pos++;
    new nombre[GEO_NOMBRE_LEN];
    new n = 0;
    while (linea[pos] != '\0' && linea[pos] != '\r' && linea[pos] != '\n')
    {
        if (n < GEO_NOMBRE_LEN - 1) nombre[n++] = linea[pos];
        pos++;
    }
    while (n > 0 && (nombre[n - 1] == ' ' || nombre[n - 1] == '\t')) n--;
    nombre[n] = '\0';
    if (n == 0) return -1;

    GeoLoc[slot][locX] = v[0];
    GeoLoc[slot][locY] = v[1];
    GeoLoc[slot][locZ] = v[2];
    GeoLoc[slot][locCX] = v[3];
    GeoLoc[slot][locCY] = v[4];
    GeoLoc[slot][locCZ] = v[5];
    format(GeoLoc[slot][locNombre], GEO_NOMBRE_LEN, "%s", nombre);
    return 1;
}

stock Geo_CargarArchivo()
{
    GeoTotal = 0;
    if (!fexist(GEO_ARCHIVO))
    {
        printf("[GeoGuesser] ERROR: no existe scriptfiles/%s", GEO_ARCHIVO);
        return 0;
    }

    new File:f = fopen(GEO_ARCHIVO, io_read);
    if (!f)
    {
        printf("[GeoGuesser] ERROR: no se pudo abrir scriptfiles/%s", GEO_ARCHIVO);
        return 0;
    }

    new linea[256];
    new nlinea = 0;
    while (fread(f, linea))
    {
        nlinea++;
        if (GeoTotal >= MAX_LOCACIONES)
        {
            printf("[GeoGuesser] Limite de %d locaciones alcanzado, se ignora el resto.", MAX_LOCACIONES);
            break;
        }

        // Saltar BOM UTF-8 (algunos editores lo agregan al inicio del archivo)
        new off = 0;
        if (nlinea == 1 && linea[0] == 0xEF && linea[1] == 0xBB && linea[2] == 0xBF) off = 3;

        new res = Geo_ParsearLinea(linea[off], GeoTotal);
        if (res == 1) GeoTotal++;
        else if (res == -1) printf("[GeoGuesser] Linea %d invalida (formato: x, y, z, cx, cy, cz, nombre)", nlinea);
    }
    fclose(f);

    printf("[GeoGuesser] %d locaciones cargadas.", GeoTotal);
    return GeoTotal;
}

// Agrega la camara actual del jugador al .txt y a la lista en memoria
stock Geo_GuardarLocacion(playerid, const nombre[])
{
    if (GeoTotal >= MAX_LOCACIONES) return 0;

    new Float:cx, Float:cy, Float:cz;
    new Float:fx, Float:fy, Float:fz;
    GetPlayerCameraPos(playerid, cx, cy, cz);
    GetPlayerCameraFrontVector(playerid, fx, fy, fz);

    new linea[200];
    format(linea, sizeof linea, "%.2f, %.2f, %.2f, %.2f, %.2f, %.2f, %s\n",
        cx, cy, cz, cx + fx * 50.0, cy + fy * 50.0, cz + fz * 50.0, nombre);

    if (Geo_ParsearLinea(linea, GeoTotal) != 1) return 0;

    new File:f = fopen(GEO_ARCHIVO, io_append);
    if (!f) return 0;
    fwrite(f, linea);
    fclose(f);

    GeoTotal++;
    return 1;
}

// ================================== HUD ===================================

stock Geo_EstiloTd(playerid, PlayerText:td)
{
    PlayerTextDrawAlignment(playerid, td, 1);
    PlayerTextDrawFont(playerid, td, 1);
    PlayerTextDrawLetterSize(playerid, td, 0.33, 1.4);
    PlayerTextDrawColor(playerid, td, 0xFFFFFFFF);
    PlayerTextDrawSetOutline(playerid, td, 1);
    PlayerTextDrawSetShadow(playerid, td, 0);
    PlayerTextDrawBackgroundColor(playerid, td, 0x000000FF);
    PlayerTextDrawSetProportional(playerid, td, 1);
    PlayerTextDrawUseBox(playerid, td, 1);
    PlayerTextDrawBoxColor(playerid, td, 0x000000AA);
    PlayerTextDrawTextSize(playerid, td, 632.0, 0.0);
}

stock Geo_CrearHUD(playerid)
{
    // Box negro a pantalla completa. Queda oculto hasta que empieza el fundido.
    // Si queda un borde sin cubrir, subi el 52.0 del LetterSize.
    gTdNegro[playerid] = CreatePlayerTextDraw(playerid, -20.0, -20.0, "_");
    PlayerTextDrawLetterSize(playerid, gTdNegro[playerid], 0.5, 52.0);
    PlayerTextDrawTextSize(playerid, gTdNegro[playerid], 660.0, 0.0);
    PlayerTextDrawUseBox(playerid, gTdNegro[playerid], 1);
    PlayerTextDrawBoxColor(playerid, gTdNegro[playerid], 0x000000FF);

    gTdInfo[playerid] = CreatePlayerTextDraw(playerid, 472.0, 140.0, "_");
    Geo_EstiloTd(playerid, gTdInfo[playerid]);
    gTdAyuda[playerid] = CreatePlayerTextDraw(playerid, 472.0, 195.0, "_");
    Geo_EstiloTd(playerid, gTdAyuda[playerid]);
    PlayerTextDrawShow(playerid, gTdInfo[playerid]);
    PlayerTextDrawShow(playerid, gTdAyuda[playerid]);
}

stock Geo_ActualizarHUD(playerid)
{
    new s[160];
    if (gEstado[playerid] == GEO_OBSERVANDO || gEstado[playerid] == GEO_FUNDIDO)
    {
        format(s, sizeof s, "~y~RONDA ~w~%d/%d~n~~y~MEMORIZA ~w~%d s~n~~y~PUNTOS ~w~%d",
            gRonda[playerid], gRondasTotal[playerid], gTiempo[playerid], gPuntos[playerid]);
        PlayerTextDrawSetString(playerid, gTdInfo[playerid], s);
        PlayerTextDrawSetString(playerid, gTdAyuda[playerid], "~g~Mira bien el lugar~n~~w~Luego se pone negro~n~~w~y marcaras donde estabas");
    }
    else if (gEstado[playerid] == GEO_ADIVINANDO)
    {
        format(s, sizeof s, "~y~RONDA ~w~%d/%d~n~~y~TIEMPO ~w~%d s~n~~y~PUNTOS ~w~%d",
            gRonda[playerid], gRondasTotal[playerid], gTiempo[playerid], gPuntos[playerid]);
        PlayerTextDrawSetString(playerid, gTdInfo[playerid], s);

        if (gTieneMarca[playerid])
            PlayerTextDrawSetString(playerid, gTdAyuda[playerid], "~g~1 ~w~Abre el mapa con ESC~n~~g~2 ~w~Marca puesta!~n~~g~3 ~w~Escribe /confirmar");
        else
            PlayerTextDrawSetString(playerid, gTdAyuda[playerid], "~g~1 ~w~Abre el mapa con ESC~n~~g~2 ~w~Clic DERECHO donde creas~n~~g~3 ~w~Escribe /confirmar");
    }
    else
    {
        format(s, sizeof s, "~y~RONDA ~w~%d/%d~n~~y~PUNTOS ~w~%d",
            gRonda[playerid], gRondasTotal[playerid], gPuntos[playerid]);
        PlayerTextDrawSetString(playerid, gTdInfo[playerid], s);
        PlayerTextDrawSetString(playerid, gTdAyuda[playerid], "~g~Abre el mapa (ESC)~n~~w~Cuadro rojo = lugar real~n~~w~/siguiente para seguir");
    }
}

// ============================ FLUJO DEL JUEGO =============================

stock Geo_QuitarZona(playerid)
{
    if (gZona[playerid] != GEO_SIN_ZONA)
    {
        GangZoneDestroy(gZona[playerid]);
        gZona[playerid] = GEO_SIN_ZONA;
    }
}

// Limpieza basica (sin tocar al jugador). Se usa tambien al desconectarse.
stock Geo_Limpiar(playerid)
{
    if (gTimer[playerid])
    {
        KillTimer(gTimer[playerid]);
        gTimer[playerid] = 0;
    }
    Geo_QuitarZona(playerid);
    if (gTimerFundido[playerid])
    {
        KillTimer(gTimerFundido[playerid]);
        gTimerFundido[playerid] = 0;
    }
    gEscBloqueado[playerid] = false;
    gEstado[playerid] = GEO_LIBRE;
}

// Bloqueo de ESC: con el cursor de textdraws activo, ESC solo cancela el cursor y
// llama a OnPlayerClickTextDraw(INVALID_TEXT_DRAW). Ahi se vuelve a activar (ver
// OnPlayerClickTextDraw mas abajo). El hover transparente evita colores raros.
stock Geo_BloquearEsc(playerid)
{
    gEscBloqueado[playerid] = true;
    SelectTextDraw(playerid, 0x00000000);
}

stock Geo_LiberarEsc(playerid)
{
    // IMPORTANTE: apagar la bandera ANTES de cancelar. CancelSelectTextDraw tambien
    // dispara OnPlayerClickTextDraw(INVALID_TEXT_DRAW) y, si la bandera sigue en true,
    // volveria a activar el cursor en bucle.
    gEscBloqueado[playerid] = false;
    CancelSelectTextDraw(playerid);
}

stock Geo_MostrarFinal(playerid)
{
    new maximo = gRondasTotal[playerid] * GEO_PUNTOS_MAX;
    new pct = (maximo > 0) ? (gPuntos[playerid] * 100 / maximo) : 0;
    new s[200], dtxt[24];

    gTexto[0] = '\0';
    format(s, sizeof s, "{33CCFF}Puntaje final: {FFFFFF}%d de %d  ({FFFF66}%d%%{FFFFFF})\n\n", gPuntos[playerid], maximo, pct);
    strcat(gTexto, s, sizeof gTexto);

    for (new r = 0; r < gRondasTotal[playerid]; r++)
    {
        new loc = gOrden[playerid][r];
        if (gHistDist[playerid][r] < 0.0) format(dtxt, sizeof dtxt, "sin respuesta");
        else Geo_FormatearDistancia(gHistDist[playerid][r], dtxt);

        format(s, sizeof s, "{FFFFFF}%d. %s  -  {AAAAAA}%s  -  {66FF66}%d pts\n",
            r + 1, GeoLoc[loc][locNombre], dtxt, gHistPuntos[playerid][r]);
        strcat(gTexto, s, sizeof gTexto);
    }

    strcat(gTexto, "\n{FFFF66}", sizeof gTexto);
    if (pct >= 90) strcat(gTexto, "Increible! Conoces San Andreas como la palma de tu mano.", sizeof gTexto);
    else if (pct >= 70) strcat(gTexto, "Muy bien! Eres todo un local.", sizeof gTexto);
    else if (pct >= 40) strcat(gTexto, "Nada mal. Sigue explorando el mapa.", sizeof gTexto);
    else strcat(gTexto, "Hora de salir a recorrer San Andreas!", sizeof gTexto);
    strcat(gTexto, "\n{FFFFFF}Escribe /geo para jugar otra vez.", sizeof gTexto);

    ShowPlayerDialog(playerid, DIALOG_GEO_FIN, DIALOG_STYLE_MSGBOX, "GeoGuesser - Resultado final", gTexto, "Cerrar", "");
}

stock Geo_Terminar(playerid, bool:completo)
{
    if (gEstado[playerid] == GEO_LIBRE) return 0;

    Geo_Limpiar(playerid);
    Geo_LiberarEsc(playerid);
    SetPlayerDrunkLevel(playerid, 0);
    PlayerTextDrawDestroy(playerid, gTdNegro[playerid]);
    PlayerTextDrawDestroy(playerid, gTdInfo[playerid]);
    PlayerTextDrawDestroy(playerid, gTdAyuda[playerid]);

    // Devolver al jugador a donde estaba
    SetPlayerVirtualWorld(playerid, gAntVW[playerid]);
    SetPlayerInterior(playerid, gAntInt[playerid]);
    SetPlayerPos(playerid, gAntX[playerid], gAntY[playerid], gAntZ[playerid]);
    SetPlayerFacingAngle(playerid, gAntAng[playerid]);
    SetPlayerHealth(playerid, gAntVida[playerid]);
    SetPlayerArmour(playerid, gAntChaleco[playerid]);
    SetCameraBehindPlayer(playerid);
    TogglePlayerControllable(playerid, true);

    if (completo) Geo_MostrarFinal(playerid);
    else SendClientMessage(playerid, COLOR_GEO, "[GeoGuesser] Saliste del juego. Escribe /geo cuando quieras volver.");
    return 1;
}

stock Geo_SiguienteRonda(playerid)
{
    gRonda[playerid]++;
    if (gRonda[playerid] > gRondasTotal[playerid]) return Geo_Terminar(playerid, true);

    new loc = gOrden[playerid][gRonda[playerid] - 1];

    Geo_QuitarZona(playerid);
    gTieneMarca[playerid] = false;
    gAnulada[playerid] = false;
    gTiempo[playerid] = GEO_TIEMPO_OBSERVAR;
    gEstado[playerid] = GEO_OBSERVANDO;

    // Llevar al jugador (y a su camara) al lugar a adivinar
    TogglePlayerControllable(playerid, false);
    SetPlayerVirtualWorld(playerid, GEO_MUNDO_BASE + playerid);
    SetPlayerInterior(playerid, 0);
    SetPlayerPos(playerid, GeoLoc[loc][locX], GeoLoc[loc][locY], GeoLoc[loc][locZ]);
    SetPlayerCameraPos(playerid, GeoLoc[loc][locX], GeoLoc[loc][locY], GeoLoc[loc][locZ]);
    SetPlayerCameraLookAt(playerid, GeoLoc[loc][locCX], GeoLoc[loc][locCY], GeoLoc[loc][locCZ]);

    PlayerTextDrawHide(playerid, gTdNegro[playerid]);   // por si quedo de la ronda anterior
    SetPlayerDrunkLevel(playerid, GEO_NIVEL_HUD);        // oculta el HUD (radar y nombre de zona)
    Geo_BloquearEsc(playerid);                           // ESC bloqueado durante la fase 1

    Geo_ActualizarHUD(playerid);

    new s[144];
    format(s, sizeof s, "~y~Ronda %d de %d~n~~w~Memoriza el lugar", gRonda[playerid], gRondasTotal[playerid]);
    GameTextForPlayer(playerid, s, 3000, 3);

    format(s, sizeof s, "[GeoGuesser] Ronda %d/%d - Mira bien el lugar: en %d segundos la pantalla se pone negra y tendras que marcar donde estabas.",
        gRonda[playerid], gRondasTotal[playerid], GEO_TIEMPO_OBSERVAR);
    SendClientMessage(playerid, COLOR_GEO, s);
    return 1;
}

stock Geo_ResolverRonda(playerid)
{
    if (gEstado[playerid] != GEO_ADIVINANDO) return 0;

    new r = gRonda[playerid] - 1;
    new loc = gOrden[playerid][r];
    new Float:dist = -1.0;
    new puntos = 0;
    new msg[144], dtxt[24], calif[24];

    if (gTieneMarca[playerid] && !gAnulada[playerid])
    {
        dist = Geo_Distancia2D(gMarcaX[playerid], gMarcaY[playerid], GeoLoc[loc][locX], GeoLoc[loc][locY]);
        puntos = Geo_CalcularPuntos(dist);
    }

    gPuntos[playerid] += puntos;
    gHistPuntos[playerid][r] = puntos;
    gHistDist[playerid][r] = dist;
    gEstado[playerid] = GEO_RESULTADO;
    gPausa[playerid] = GEO_PAUSA_RESULTADO;

    // Ronda cerrada: sacar el negro, devolver el HUD y volver a mostrarle el lugar real
    PlayerTextDrawHide(playerid, gTdNegro[playerid]);
    SetPlayerDrunkLevel(playerid, 0);
    SetPlayerPos(playerid, GeoLoc[loc][locX], GeoLoc[loc][locY], GeoLoc[loc][locZ]);
    SetPlayerCameraPos(playerid, GeoLoc[loc][locX], GeoLoc[loc][locY], GeoLoc[loc][locZ]);
    SetPlayerCameraLookAt(playerid, GeoLoc[loc][locCX], GeoLoc[loc][locCY], GeoLoc[loc][locCZ]);

    // Revelar el lugar real en el mapa (cuadro rojo parpadeante)
    Geo_QuitarZona(playerid);
    gZona[playerid] = GangZoneCreate(
        GeoLoc[loc][locX] - GEO_TAM_ZONA, GeoLoc[loc][locY] - GEO_TAM_ZONA,
        GeoLoc[loc][locX] + GEO_TAM_ZONA, GeoLoc[loc][locY] + GEO_TAM_ZONA);
    GangZoneShowForPlayer(playerid, gZona[playerid], 0xFF0000AA);
    GangZoneFlashForPlayer(playerid, gZona[playerid], 0xFFFF00AA);

    format(msg, sizeof msg, "[GeoGuesser] Era: %s", GeoLoc[loc][locNombre]);
    SendClientMessage(playerid, COLOR_GEO, msg);

    if (gTieneMarca[playerid] && !gAnulada[playerid])
    {
        Geo_FormatearDistancia(dist, dtxt);
        Geo_Calificacion(dist, calif);
        format(msg, sizeof msg, "[GeoGuesser] Tu marca quedo a %s del lugar real: +%d puntos (total: %d)", dtxt, puntos, gPuntos[playerid]);
        SendClientMessage(playerid, COLOR_OK, msg);
        format(msg, sizeof msg, "~g~+%d puntos~n~~w~%s", puntos, calif);
        GameTextForPlayer(playerid, msg, 4000, 3);
        PlayerPlaySound(playerid, 1057, 0.0, 0.0, 0.0);
    }
    else if (gAnulada[playerid])
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Pausaste durante la fase 1: ronda anulada, 0 puntos.");
        GameTextForPlayer(playerid, "~r~Ronda anulada", 4000, 3);
    }
    else
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Se acabo el tiempo y no marcaste nada: 0 puntos.");
        GameTextForPlayer(playerid, "~r~Sin respuesta", 4000, 3);
    }

    if (gRonda[playerid] >= gRondasTotal[playerid])
        SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Abre el mapa (ESC) para ver el lugar real (cuadro rojo). Escribe /siguiente para ver tu resultado final.");
    else
        SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Abre el mapa (ESC) para ver el lugar real (cuadro rojo). Escribe /siguiente para seguir.");

    Geo_ActualizarHUD(playerid);
    return 1;
}

stock Geo_Iniciar(playerid)
{
    if (gEstado[playerid] != GEO_LIBRE)
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Ya estas jugando. Usa /salirgeo para abandonar.");
        return 0;
    }
    if (GeoTotal < 1)
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] No hay locaciones cargadas. Avisale a un admin.");
        return 0;
    }
    if (GetPlayerState(playerid) != PLAYER_STATE_ONFOOT)
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Tenes que estar a pie para jugar (bajate del vehiculo).");
        return 0;
    }

    // Guardar donde estaba el jugador
    GetPlayerPos(playerid, gAntX[playerid], gAntY[playerid], gAntZ[playerid]);
    GetPlayerFacingAngle(playerid, gAntAng[playerid]);
    GetPlayerHealth(playerid, gAntVida[playerid]);
    GetPlayerArmour(playerid, gAntChaleco[playerid]);
    gAntInt[playerid] = GetPlayerInterior(playerid);
    gAntVW[playerid] = GetPlayerVirtualWorld(playerid);

    // Elegir las locaciones de la partida sin repetir (Fisher-Yates)
    new idx[MAX_LOCACIONES];
    for (new i = 0; i < GeoTotal; i++) idx[i] = i;
    for (new i = GeoTotal - 1; i > 0; i--)
    {
        new j = random(i + 1);
        new t = idx[i];
        idx[i] = idx[j];
        idx[j] = t;
    }

    new rondas = Geo_RondasPartida();
    for (new r = 0; r < rondas; r++) gOrden[playerid][r] = idx[r];

    gRondasTotal[playerid] = rondas;
    gRonda[playerid] = 0;
    gPuntos[playerid] = 0;
    gTieneMarca[playerid] = false;
    gZona[playerid] = GEO_SIN_ZONA;

    Geo_CrearHUD(playerid);
    gTimer[playerid] = SetTimerEx("Geo_Tick", 1000, true, "i", playerid);

    Geo_SiguienteRonda(playerid);
    return 1;
}

// Muestra el box negro con el alfa dado (0 = transparente, 255 = negro total).
// Con RGB en 0 el color del box es solamente el alfa. Despues se vuelve a mostrar el
// HUD para que nunca quede tapado por el negro.
stock Geo_MostrarNegro(playerid, alfa)
{
    PlayerTextDrawBoxColor(playerid, gTdNegro[playerid], alfa);
    PlayerTextDrawShow(playerid, gTdNegro[playerid]);
    PlayerTextDrawShow(playerid, gTdInfo[playerid]);
    PlayerTextDrawShow(playerid, gTdAyuda[playerid]);
}

// Pasa a la fase 2. El orden importa: primero el senuelo y recien despues se libera
// ESC, asi la flecha del mapa de pausa nunca apunta al lugar real.
stock Geo_FaseAdivinar(playerid)
{
    gEstado[playerid] = GEO_ADIVINANDO;
    gTiempo[playerid] = GEO_TIEMPO_ADIVINAR;
    gTieneMarca[playerid] = false;

    SetPlayerPos(playerid, GEO_SENUELO_X, GEO_SENUELO_Y, GEO_SENUELO_Z);   // 1) senuelo
    Geo_LiberarEsc(playerid);                                              // 2) ahora si puede pausar

    Geo_ActualizarHUD(playerid);
    GameTextForPlayer(playerid, "~y~Ahora marca en el mapa~n~~w~donde creas que estabas", 4000, 3);
    SendClientMessage(playerid, COLOR_GEO, "[GeoGuesser] Pantalla negra! Abre el mapa (ESC), clic DERECHO donde creas que estabas y escribe /confirmar.");
}

// Empieza el fundido a negro (un paso cada 100 ms)
stock Geo_IniciarFundido(playerid)
{
    gEstado[playerid] = GEO_FUNDIDO;
    gFundidoPaso[playerid] = 0;
    Geo_MostrarNegro(playerid, 0);
    gTimerFundido[playerid] = SetTimerEx("Geo_Fundido", 100, true, "i", playerid);
}

public Geo_Fundido(playerid)
{
    if (!IsPlayerConnected(playerid) || gEstado[playerid] != GEO_FUNDIDO)
    {
        if (gTimerFundido[playerid])
        {
            KillTimer(gTimerFundido[playerid]);
            gTimerFundido[playerid] = 0;
        }
        return 0;
    }

    gFundidoPaso[playerid]++;
    new alfa = gFundidoPaso[playerid] * 255 / GEO_FUNDIDO_PASOS;
    if (alfa > 255) alfa = 255;
    Geo_MostrarNegro(playerid, alfa);

    if (gFundidoPaso[playerid] >= GEO_FUNDIDO_PASOS)
    {
        KillTimer(gTimerFundido[playerid]);
        gTimerFundido[playerid] = 0;
        Geo_FaseAdivinar(playerid);
    }
    return 1;
}

// Llamala desde el OnPlayerPause de tu libreria de pausa. Si pausa mientras ve el
// lugar (fase 1 o fundido) se lo manda al senuelo y la ronda queda anulada. Es la red
// de seguridad por si el bloqueo de ESC no alcanza.
stock Geo_PausaDetectada(playerid)
{
    if (gEstado[playerid] == GEO_OBSERVANDO || gEstado[playerid] == GEO_FUNDIDO)
    {
        SetPlayerPos(playerid, GEO_SENUELO_X, GEO_SENUELO_Y, GEO_SENUELO_Z);
        if (!gAnulada[playerid])
        {
            gAnulada[playerid] = true;
            SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Pausaste antes de tiempo: esta ronda no suma puntos.");
        }
    }
}

// Se ejecuta cada segundo mientras el jugador esta en partida
public Geo_Tick(playerid)
{
    if (!IsPlayerConnected(playerid) || gEstado[playerid] == GEO_LIBRE)
    {
        Geo_Limpiar(playerid);
        return 0;
    }

    SetPlayerHealth(playerid, 100.0);

    // El nivel de "borracho" baja solo con el tiempo: reaplicarlo mientras el HUD debe estar oculto
    if (gEstado[playerid] != GEO_RESULTADO) SetPlayerDrunkLevel(playerid, GEO_NIVEL_HUD);

    if (gEstado[playerid] == GEO_OBSERVANDO)
    {
        gTiempo[playerid]--;
        if (gTiempo[playerid] <= 0)
        {
            Geo_IniciarFundido(playerid);
            return 1;
        }
        if (gTiempo[playerid] <= 5) PlayerPlaySound(playerid, 1056, 0.0, 0.0, 0.0);
        Geo_ActualizarHUD(playerid);
    }
    else if (gEstado[playerid] == GEO_ADIVINANDO)
    {
        gTiempo[playerid]--;
        if (gTiempo[playerid] <= 0)
        {
            Geo_ResolverRonda(playerid);
            return 1;
        }
        if (gTiempo[playerid] <= 5) PlayerPlaySound(playerid, 1056, 0.0, 0.0, 0.0);
        Geo_ActualizarHUD(playerid);
    }
    else if (gEstado[playerid] == GEO_RESULTADO)
    {
        gPausa[playerid]--;
        if (gPausa[playerid] <= 0) Geo_SiguienteRonda(playerid);
    }
    return 1;
}

// ============================== REGLAS / AYUDA ============================

stock Geo_MostrarReglas(playerid)
{
    new s[200];
    gTexto[0] = '\0';

    strcat(gTexto, "{FFFFFF}Bienvenido al {33CCFF}GeoGuesser de San Andreas{FFFFFF}!\n", sizeof gTexto);
    format(s, sizeof s, "Te mostraremos %d lugares. Tu mision: descubrir donde estas parado.\n\n", Geo_RondasPartida());
    strcat(gTexto, s, sizeof gTexto);

    strcat(gTexto, "{FFFF66}Como se juega:\n", sizeof gTexto);
    format(s, sizeof s, "{FFFFFF}1. Tienes {FFFF66}%d segundos{FFFFFF} para mirar el lugar. La camara queda fija.\n", GEO_TIEMPO_OBSERVAR);
    strcat(gTexto, s, sizeof gTexto);
    strcat(gTexto, "2. La pantalla se pone negra: memoriza donde estabas.\n", sizeof gTexto);
    format(s, sizeof s, "3. Tienes otros {FFFF66}%d segundos{FFFFFF}: abre el mapa con {FFFF66}ESC{FFFFFF},\n", GEO_TIEMPO_ADIVINAR);
    strcat(gTexto, s, sizeof gTexto);
    strcat(gTexto, "    clic {FFFF66}DERECHO{FFFFFF} donde creas que estabas y escribe {FFFF66}/confirmar{FFFFFF}.\n\n", sizeof gTexto);

    format(s, sizeof s, "Mientras mas cerca marques, mas puntos (maximo %d por ronda).\n", GEO_PUNTOS_MAX);
    strcat(gTexto, s, sizeof gTexto);
    strcat(gTexto, "{FFFF66}Importante: {FFFFFF}si pausas durante la fase 1, esa ronda no suma puntos.\n\n", sizeof gTexto);

    strcat(gTexto, "{AAAAAA}Comandos: /confirmar  /siguiente  /salirgeo  /geoayuda", sizeof gTexto);

    ShowPlayerDialog(playerid, DIALOG_GEO_REGLAS, DIALOG_STYLE_MSGBOX, "GeoGuesser - Como jugar", gTexto, "Jugar", "Cancelar");
}

stock Geo_AyudaChat(playerid)
{
    SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] 1) Mira el lugar  2) Pantalla negra: ESC y clic DERECHO donde creas que estabas  3) /confirmar");
    SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Otros comandos: /siguiente (saltar resultado)  /salirgeo (abandonar)");
}

// =============================== CALLBACKS ================================

public OnFilterScriptInit()
{
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        gEstado[i] = GEO_LIBRE;
        gTimer[i] = 0;
        gZona[i] = GEO_SIN_ZONA;
    }
    Geo_CargarArchivo();
    print("[GeoGuesser] Filterscript cargado. Comando: /geo");
    return 1;
}

public OnFilterScriptExit()
{
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i) && gEstado[i] != GEO_LIBRE) Geo_Terminar(i, false);
    }
    return 1;
}

public OnPlayerConnect(playerid)
{
    gEstado[playerid] = GEO_LIBRE;
    gTimer[playerid] = 0;
    gZona[playerid] = GEO_SIN_ZONA;
    return 0;
}

public OnPlayerDisconnect(playerid, reason)
{
    Geo_Limpiar(playerid);
    return 0;
}

public OnPlayerDeath(playerid, killerid, reason)
{
    if (gEstado[playerid] != GEO_LIBRE) Geo_Terminar(playerid, false);
    return 0;
}

public OnPlayerClickTextDraw(playerid, Text:clickedid)
{
    // ESC cancela el cursor: mientras la ronda lo tiene bloqueado, se vuelve a activar
    if(clickedid == INVALID_TEXT_DRAW && gEscBloqueado[playerid])
    {
        SelectTextDraw(playerid, 0x00000000);
        return 1;
    }
    return 0;
}

public OnPlayerClickMap(playerid, Float:fX, Float:fY, Float:fZ)
{
    if (gEstado[playerid] == GEO_LIBRE) return 0;   // no esta jugando: que lo maneje otro script

    if (gEstado[playerid] != GEO_ADIVINANDO)
    {
        SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Espera a la siguiente ronda para poner una marca.");
        return 1;
    }

    gMarcaX[playerid] = fX;
    gMarcaY[playerid] = fY;
    gTieneMarca[playerid] = true;

#if GEO_CONFIRMAR_MANUAL
    Geo_ActualizarHUD(playerid);
    GameTextForPlayer(playerid, "~g~Marca puesta~n~~w~Escribe /confirmar", 2500, 3);
    SendClientMessage(playerid, COLOR_OK, "[GeoGuesser] Marca puesta. Cierra el mapa y escribe /confirmar (o marca otro punto para cambiarla).");
#else
    Geo_ResolverRonda(playerid);
#endif
    return 1;
}

public OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    if (dialogid == DIALOG_GEO_REGLAS)
    {
        if (response) Geo_Iniciar(playerid);
        return 1;
    }
    if (dialogid == DIALOG_GEO_FIN) return 1;
    return 0;
}

CMD:geo(playerid, params[])
{
    if (gEstado[playerid] != GEO_LIBRE) Geo_AyudaChat(playerid);
    else Geo_MostrarReglas(playerid);
    return 1;
}

CMD:confirmar(playerid, params[])
{
    if (gEstado[playerid] == GEO_LIBRE) return 0;
    if (gEstado[playerid] == GEO_OBSERVANDO || gEstado[playerid] == GEO_FUNDIDO)
    {
        SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Todavia estas mirando el lugar. Cuando la pantalla se ponga negra podras marcar en el mapa.");
        return 1;
    }
    if (gEstado[playerid] != GEO_ADIVINANDO)
    {
        SendClientMessage(playerid, COLOR_INFO, "[GeoGuesser] Ya respondiste esta ronda. Escribe /siguiente para seguir.");
        return 1;
    }
    if (!gTieneMarca[playerid])
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Primero marca un punto: ESC y clic DERECHO en el mapa.");
        return 1;
    }
    Geo_ResolverRonda(playerid);
    return 1;
}

CMD:siguiente(playerid, params[])
{
    if (gEstado[playerid] == GEO_LIBRE) return 0;
    if (gEstado[playerid] != GEO_RESULTADO)
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Primero responde la ronda actual.");
        return 1;
    }
    Geo_SiguienteRonda(playerid);
    return 1;
}

CMD:salir(playerid, params[])
{
    if (gEstado[playerid] == GEO_LIBRE)
    {
        SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] No estas jugando.");
        return 1;
    }
    Geo_Terminar(playerid, false);
    return 1;
}

#if defined DEBUG
CMD:geoguardar(playerid, params[])
{
    if (params[11] == '\0' || params[12] == '\0')
    {
        SendClientMessage(playerid, COLOR_INFO, "Uso: /geoguardar <nombre de la zona>  (guarda tu camara actual como locacion)");
        return 1;
    }
    if (Geo_GuardarLocacion(playerid, params[12]))
    {
        new s[96];
        format(s, sizeof s, "[GeoGuesser] Locacion guardada (#%d): %s", GeoTotal, params[12]);
        SendClientMessage(playerid, COLOR_OK, s);
    }
    else SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] No se pudo guardar la locacion.");
    return 1;
}

CMD:geocargar(playerid, params[])
{
    foreach(new i : Player)
	{
        if (IsPlayerConnected(i) && gEstado[i] != GEO_LIBRE)
        {
            SendClientMessage(playerid, COLOR_ERR, "[GeoGuesser] Hay jugadores en partida. Intenta de nuevo cuando terminen.");
            return 1;
        }
    }
    new s[64];
    format(s, sizeof s, "[GeoGuesser] Locaciones recargadas: %d", Geo_CargarArchivo());
    SendClientMessage(playerid, COLOR_OK, s);
    return 1;
}
#endif