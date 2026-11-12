// The Swift side of the FM Starship plugin, defined with @_cdecl in StarshipPlugin.
#ifndef STARSHIP_PLUGIN_H
#define STARSHIP_PLUGIN_H

#include <stdbool.h>

// `game_app` is FM's bundle, fm.app, or NULL if start.c couldn't work it out.
void starship_plugin_start(const char *game_app);

// True when the executable at `executable` is FM itself, which is the only process the Swift side starts in. In start.c.
bool starship_plugin_is_game(const char *executable);

#endif
