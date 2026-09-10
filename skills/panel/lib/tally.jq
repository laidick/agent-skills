# tally.jq — mechanical agreement check for a cross/focus round.
# Input: {panels:[<parsed answer>...], conflicts:[<conflict from previous disagreements.json>...]}
# A conflict is resolved when every responding panel voted, every vote is a valid letter or abstain,
# and all non-abstain votes fall in ONE equivalence class of letters. Letters are equivalent when
#   (a) disagreements.json declares them so (positions.X.aliases = ["Y"]) — panel-dispatch only accepts aliases
#       that were effective equivalences in the previous tally (U19), or
#   (b) voters declare it on the vote line ("D3: B (=C)") AND — D9-A, ratified 2026-09-05 — no panel holding
#       either letter voted without declaring it. A declaration that some holder did not make is recorded as
#       `proposed_equivalences` (visible in matrix.md, carried in the note) and does NOT merge.
# Nothing here weighs arguments — it only counts.
. as {panels: $P, conflicts: $C}
| {
    conflicts: [ $C[] | . as $c
      | ($c.positions | keys) as $known
      | ([ $c.positions | to_entries[] | .key as $k | (.value.aliases // [])[] | {key: ., value: $k} ] | from_entries) as $amap
      | def canon: if type == "string" and test("^[A-Z]$") then ($amap[.] // .) else . end;
        ([ $P[] | . as $p | ($p.votes // [])[] | select(.id == $c.id)
            | {panel: $p.panel, raw: .choice, choice: (.choice | canon), eq: ([(.eq // [])[] | canon] | unique), why: (.why // ""), carried: ($p.carried // false)} ]) as $votes
      | ([ $P[] | select(([(.votes // [])[].id] | index($c.id)) == null) | .panel ]) as $missing
      | ([ $votes[] | select(.choice != "abstain" and ((.choice | test("^[A-Z]$")) | not)) ]) as $invalid
      # every pair some voter declared
      | ([ $votes[] | select(.choice | test("^[A-Z]$")) | .choice as $a | .eq[] | select(test("^[A-Z]$") and . != $a) | [$a, .] | sort ] | unique) as $declared
      # D9-A: a pair is effective only if every holder of either letter declared the other letter
      | ([ $declared[] | . as [$x, $y]
            | ([ $votes[] | select(.choice == $x or .choice == $y) ]) as $holders
            | ([ $holders[] | select(((.choice == $x) and ((.eq | index($y)) == null)) or ((.choice == $y) and ((.eq | index($x)) == null))) | .panel ]) as $silent
            # iteration 7 (5090 r3 correction): a declarer of THIS pair, not any holder that declared some equivalence
            | { pair: [$x, $y], declared_by: [ $holders[] | select(((.choice == $x) and ((.eq | index($y)) != null)) or ((.choice == $y) and ((.eq | index($x)) != null))) | .panel ], undeclared_holders: $silent, effective: (($silent | length) == 0) } ]) as $eqinfo
      | ([ $eqinfo[] | select(.effective) | .pair ]) as $pairs
      | ([ $eqinfo[] | select(.effective | not) ]) as $proposed
      | def closure($s): ([$s[], ($pairs[] | select((.[0] as $a | $s | index($a)) != null or (.[1] as $b | $s | index($b)) != null) | .[])] | unique) as $n | if $n == $s then $s else closure($n) end;
        ([ $votes[] | select(.choice | test("^[A-Z]$")) | .choice ] | unique) as $distinct
      | ([ $distinct[] | closure([.]) ] | unique) as $classes
      | ([ $votes[] | .choice as $ch | select(($ch | test("^[A-Z]$")) and (($known | index($ch)) == null)) | {panel, letter: $ch, text: .why} ]) as $new_positions
      | { id: $c.id, topic: $c.topic, positions: $c.positions,
          votes: $votes, missing: $missing, invalid: $invalid, new_positions: $new_positions,
          equivalences: $pairs,
          proposed_equivalences: $proposed,
          tally: ($votes | group_by(.choice) | map({key: .[0].choice, value: length}) | from_entries),
          all_abstain: (($distinct | length) == 0 and ($votes | length) > 0),
          resolved: (($classes | length) == 1 and ($missing | length) == 0 and ($invalid | length) == 0),
          agreed: (if ($classes | length) == 1 then ($classes[0] | join("/")) else null end),
          agreed_letters: (if ($classes | length) == 1 then $classes[0] else [] end),
          via_equivalence: (($classes | length) == 1 and ($distinct | length) > 1),
          # Q3(a) (iteration 8, 4/4): a carried position no present panel voted for is UNHELD — kept on the ballot at zero weight, named in the
          # record; a resolution against it is "unopposed among the panels present", never a vote of its absent holders
          unheld: [ ($votes | map(.panel)) as $present | $c.positions | to_entries[] | .key as $k | select(($votes | map(.choice) | index($k)) == null)
                    | select(((.value.held_by // []) | length) > 0) | select([(.value.held_by // [])[] | select(. as $h | $present | index($h))] | length == 0) | {letter: $k, held_by: (.value.held_by // [])} ] } ],
    new_conflicts: [ $P[] | {panel, items: ((.new_conflicts // [])[:2]), dropped: (((.new_conflicts // []) | length) - (((.new_conflicts // [])[:2]) | length))} | select((.items | length) > 0) ],
    # D5-A: PROMOTE lines mint D-ids mechanically (carry.jq); unparseable ones are listed for the panel to restate
    promotions: [ $P[] | .panel as $p | (.promotions // [])[] | . + {panel: $p} ],
    unparsed_votes: [ $P[] | {panel, lines: (.unparsed_votes // [])} | select((.lines | length) > 0) ],
    corrections: [ $P[] | {panel, items: (.corrections // [])} | select((.items | length) > 0) ]
  }
# D0 (framing, D5-A) is an ordinary conflict here: it must resolve to A like any other; non-A votes are surfaced by panel-matrix (D17: any non-A, non-abstain letter keeps it open)
# D16 (iteration 3): a PROMOTE line keeps the round open whether it parsed or not — only a parsed *seconding* (`| SECOND`) is exempt: it goes to the uncontested list, not the ballot
| .all_resolved = (([.conflicts[] | .resolved] | all) and ((.new_conflicts | length) == 0) and (([.promotions[] | select((.ok and (.seconding // false)) | not)] | length) == 0))
