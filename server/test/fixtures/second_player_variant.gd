extends GameState

## Offline experiment only. Live GameState opening rules remain the control.
var second_player_id := ""
var second_turns := 0

func _init(local_id: String, enemy_id: String, own_deck: Array[CardData], enemy_deck: Array[CardData], game_seed: int = -1) -> void:
	super(local_id, enemy_id, own_deck, enemy_deck, game_seed)

func start_game(first: String) -> void:
	var second := opponent if first == player.player_id else player
	second_player_id = second.player_id
	second_turns = 0
	# Preserve the actual shuffled definition; a hand instance is not a deck entry.
	var fourth_definition: CardData = second.deck[second.deck.size() - 4]
	super.start_game(first)
	second.hand.pop_back()
	second.deck.append(fourth_definition)
	second._next_card_uid -= 1 # Undo precisely the removed draw, which uses no RNG.

func _begin_turn() -> void:
	if active_player_id == second_player_id:
		second_turns += 1
		if second_turns <= 2:
			_get_active_player().max_mana = 1 # Existing turn start gains to 2 and refreshes spent mana.
	super._begin_turn()

func duplicate_for_sim() -> GameState:
	var copy = super.duplicate_for_sim()
	copy.second_player_id = second_player_id
	copy.second_turns = second_turns
	return copy

func state_hash() -> String:
	return (super.state_hash() + "|second_player_experiment|" + second_player_id + "|" + str(second_turns)).sha256_text()
