class_name RulesVersion
extends RefCounted

## Bumped whenever game rules or card data (data/cards/*.json) change in a way
## that makes an old client's idea of the rules differ from the server's.
## Ranked matches run on the server (see specs/003-authoritative-ranked-server);
## a client whose version differs is told to update before it can queue.
## Bump rule: any change to scripts/game/{game_state,player_state,minion,abilities}.gd
## behavior, or to data/cards/*.json costs/stats/abilities/effects, increments this.
const RULES_VERSION := 1
