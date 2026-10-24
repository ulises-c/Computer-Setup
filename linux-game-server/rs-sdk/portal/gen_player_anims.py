#!/usr/bin/env python3
"""Generate player_anims.py from the game's seq.pack (human_* / emote_* rows only).

    python3 gen_player_anims.py ~/github/rs-sdk-fork/server/content/pack/seq.pack player_anims.py
"""
import sys
from pathlib import Path

HEAD = '''"""Player animation (seq) ids -> names and the action they show, for the live map.

The id -> name table is generated from rs-sdk-fork server/content/pack/seq.pack
(human_* and emote_* rows; regenerate with gen_player_anims.py). The SDK's
player animId is the primary sequence only (-1 when none), so walking/running is
inferred from movement by the publisher, not from this table.
"""
import re

SEQ_NAMES = {
'''

TAIL = '''}

# (pattern on the seq name, action label, skill trained or None); first match wins.
RULES = (
    (r'^human_mining_', 'Mining', 'Mining'),
    (r'^human_woodcutting_', 'Woodcutting', 'Woodcutting'),
    (r'^human_(harpoon|lobster|largenet|smallnet|fishing_casting|fish_onspot|octopus_pot)$', 'Fishing', 'Fishing'),
    (r'^human_(cooking|firecooking)$', 'Cooking', 'Cooking'),
    (r'^human_smithing$', 'Smithing', 'Smithing'),
    (r'^human_furnace$', 'Smelting', 'Smithing'),
    (r'^human_createfire$', 'Firemaking', 'Firemaking'),
    (r'^human_fletching$', 'Fletching', 'Fletching'),
    (r'^human_(.*cutting|potterywheel|glassblowing|spinningwheel|leather_crafting)$', 'Crafting', 'Crafting'),
    (r'^human_herbing_', 'Herblore', 'Herblore'),
    (r'^human_pickpocket$', 'Thieving', 'Thieving'),
    (r'^human_runecraft$', 'Runecrafting', 'Runecrafting'),
    (r'^human_pray$', 'Praying', 'Prayer'),
    (r'^human_(castteleport|castteleport_reverse|cast2_teleport|smokepuff_tele_.*)$', 'Teleporting', None),
    (r'^human_(cast|enchant|casting|trans_casting)', 'Casting a spell', 'Magic'),
    (r'^human_(bow|crossbow|throw|spear_throw)$', 'Ranged attack', 'Ranged'),
    (r'^human_(.*_block|.*_def|shield_defence|unarmedblock|unarmed_def|trans_axe_def)$', 'Blocking', None),
    (r'^human_(ddagger|dspear|sword|axe|trans_axe|blunt|dhsword|staff|stafforb|unarmed|spear|scythe|farmersfork|banner)_?', 'Attacking', None),
    (r'^human_(death|death_backwards|transdeath|unconscious)$', 'Dying', None),
    (r'^human_(eat|eat_banana|drink_rum)$', 'Eating', 'Hitpoints'),
    (r'^human_(pickupfloor|pickuptable)$', 'Picking up', None),
    (r'^human_dig', 'Digging', None),
    (r'^human_(climbing|reachforladder|reachforladdertop)', 'Climbing', None),
    (r'^human_.*(door|chest|cupboard)', 'Opening', None),
    (r'^human_(running|halberdrunning|bannerrunning)$', 'Running', None),
    (r'^human_.*walk', 'Walking', None),
    (r'^human_.*ready', 'Standing', None),
    (r'^(emote_|human_dancing)', 'Emote', None),
)
_COMPILED = tuple((re.compile(pattern), action, skill) for pattern, action, skill in RULES)


def anim_info(anim_id):
    """{'id', 'name', 'action', 'skill'} for a player animation id, or None for none/invalid."""
    if isinstance(anim_id, bool) or not isinstance(anim_id, int) or anim_id < 0:
        return None
    name = SEQ_NAMES.get(anim_id)
    if name is None:
        return {'id': anim_id, 'name': None, 'action': f'Animation #{anim_id}', 'skill': None}
    for pattern, action, skill in _COMPILED:
        if pattern.search(name):
            return {'id': anim_id, 'name': name, 'action': action, 'skill': skill}
    pretty = re.sub(r'^(human|emote)_', '', name).replace('_', ' ').strip().capitalize()
    return {'id': anim_id, 'name': name, 'action': pretty or f'Animation #{anim_id}', 'skill': None}
'''


def main():
    rows = []
    for line in Path(sys.argv[1]).read_text().splitlines():
        key, _, name = line.partition('=')
        if key.isdigit() and name.startswith(('human_', 'emote_')):
            rows.append((int(key), name.strip()))
    body = ''.join(f'    {i}: {name!r},\n' for i, name in sorted(rows))
    Path(sys.argv[2]).write_text(HEAD + body + TAIL)


if __name__ == '__main__':
    main()
