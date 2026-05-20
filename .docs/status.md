# Project Status

## What's Working

- Card data system loading from per-color JSON files
- Board scene with all zones (hand, board, heroes, center bar)
- Drag and drop card playing from hand to board
- Stratagem targeting (drag to any creature or hero)
- Mana system (1 crystal per turn, refreshes each turn)
- Draw card each turn
- End turn flow
- Card preview on hover (right side of screen)
- Board zone highlights when dragging cards
- Target highlights when dragging stratagems
- Attack target highlights (purple) when attacker selected
- Taunt enforcement
- Gold glow on attackable minions
- Color theming on cards (5 faction colors)
- Keywords shown in card description text
- Tribe tags (Yeti, Mech) displayed as a badge in the bottom-right of the StatsRow
- Challenge ability (on-play mini-combat: pick an enemy to fight)
- Yeti tag and deathrattle draw (teal faction mechanics, Yeti Rancher)
- Tank ability (on-play hero damage + reinforce death-trigger shot)
- Pilot/Mech system (pilot merges into a Mech, buffing its stats)
- Rummage system (retrieve cards from graveyard; on-play, on-death, and spell variants)
- Safeguard keyword (cannot be targeted by any stratagem from either player)
- Tactical Officer (passive: reinforce copies get +1 attack per Officer on board)
- Drone Pilot deathrattle (on death: return a stratagem from graveyard to hand)
- Commanding Shout (buff_all_friendly_attack: +1 attack to all friendly creatures, no target)
- Mortar (deal_damage 4 to target creature)
- AI controller (tactical: plays cards, trades minions, goes face, checks lethal, handles Challenge, Pilot, on-play damage, Safeguard filtering, Commanding Shout)
- Win/loss overlay (modal with "You Win!" / "You Lose!" and Play Again button)
- Transform system: attack-count transform (`transform_N`) and max-health-threshold transform (`transform_at_max_health_N`); Haven Guard → Haven Warden (5/4 Rush at 5 max health)

## TODO / Not Working Yet

- Dead minions not visually confirmed working (need to test with AI)
- Card art (images not added to cards yet)
- Networking (Nakama — planned after AI is solid)
- Deck builder UI
- Main menu
- Creature-vs-creature attack animation (attacker slides to target and back, ~0.33s)
- Sound

## Next Steps

1. Test that dead minions are properly removed after combat
2. Test the full AI turn loop
3. Add card art support
4. Move to Nakama networking
