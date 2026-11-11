// The Swift side of the FM Starship plugin, defined with @_cdecl in StarshipPlugin.
#ifndef STARSHIP_PLUGIN_H
#define STARSHIP_PLUGIN_H

#include <stdbool.h>

void starship_plugin_start(void);

// True when the executable at `executable` is FM itself, which is the only process the Swift side starts in. In start.c.
bool starship_plugin_is_game(const char *executable);

#endif
