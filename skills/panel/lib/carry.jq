# carry.jq — build the next round's disagreements draft from a tally:
# unresolved conflicts carried forward with held_by recomputed from the votes, new positions added under
# their letters, EFFECTIVE voter-declared equivalences (D9-A: every holder declared) turned into `aliases`;
# proposed (one-sided) equivalences are carried in the note only. PROMOTE lines (D5-A) mint new D-ids
# mechanically: position A = the quoted claim (refs: the cited file#anchor), position B = the promoter's sentence.
# A PROMOTE whose position is `SECOND` (U41, iteration 3) is a seconding, not a dispute: it is not minted, it is listed
# under `seconded` and panel-draft --auto puts it in the uncontested list. Unparseable PROMOTE lines are listed under
# unparseable_promotions and keep the round open (D16). Remaining free-text NEW items stay under pending_new_conflicts
# for the orchestrator (editorial, logged).
. as $t
| ([ $t.conflicts[].id | ltrimstr("D") | tonumber ] | max // 0) as $maxid
| { round_source: $t.round,
    written_by: "panel-matrix carry-forward (mechanical); PROMOTE lines minted as D-ids; orchestrator may structure pending_new_conflicts (logged)",
    conflicts: ([ $t.conflicts[] | select(.resolved | not) | select(.id != "D0") | . as $c
      | ( reduce ($c.votes[] | select(.choice | test("^[A-Z]$"))) as $v
            # D6-C (iteration 6): inherited aliases are dropped here; only THIS tally's effective equivalences (below) become aliases
            ( ($c.positions | map_values(.held_by = [] | del(.aliases) | del(.unheld))) ;
              .[$v.choice] = ((.[$v.choice] // {summary: $v.why, refs: ["rounds/r\($t.round)/in/\($v.panel).md#VOTES \($c.id)"]}) | .held_by += [$v.panel]) ) ) as $pos00
      # Q3(a) (iteration 8, 4/4): a position nobody present voted for stays on the ballot, keeps its recorded (absent) holders and is marked unheld
      | ( reduce (($c.unheld // [])[]) as $u ($pos00; if (.[$u.letter] != null) then .[$u.letter].held_by = $u.held_by | .[$u.letter].unheld = true else . end) ) as $pos0
      # effective equivalences: keep the alphabetically first letter as canonical, others become its aliases
      | ( reduce ($c.equivalences[]?) as $pr ($pos0; if (.[$pr[0]] != null) then .[$pr[0]].aliases = (((.[$pr[0]].aliases // []) + [$pr[1]]) | unique) else . end) ) as $pos
      | { id: $c.id, topic: $c.topic, positions: $pos,
          note: ((if $c.all_abstain then "all responders abstained" elif ($c.missing|length)>0 then "missing votes: \($c.missing|join(", "))" elif ($c.invalid|length)>0 then "invalid votes from: \([$c.invalid[].panel]|join(", "))" else "split \($c.tally|to_entries|map("\(.key):\(.value)")|join(" "))" end)
                 + (if (($c.proposed_equivalences // []) | length) > 0 then "; proposed equivalence(s) not merged (D9-A: holders who did not declare): " + ($c.proposed_equivalences | map("\(.pair|join("="))" + " declared by " + (.declared_by|join(",")) + ", silent: " + (.undeclared_holders|join(","))) | join("; ")) else "" end)) } ]
      + ([ ($t.promotions // [])[] | select(.ok and ((.seconding // false) | not)) ] | to_entries | map(.value as $pm | ($maxid + .key + 1) as $n
          | { id: "D\($n)",
              topic: "PROMOTED by \($pm.panel) (D5-A): \($pm.cited_panel)#\($pm.anchor) vs \($pm.panel)",
              positions: { A: { summary: $pm.quote, held_by: [ $pm.cited_panel ], refs: [ "rounds/r*/in/\($pm.cited_panel).md#\($pm.anchor)" ] },
                           B: { summary: $pm.mine,  held_by: [ $pm.panel ],       refs: [ "rounds/r\($t.round)/in/\($pm.panel).md#NEW CONFLICTS" ] } },
              promoted_by: $pm.panel, note: "minted mechanically from a PROMOTE line; panel-dispatch verifies both quotes (D6-A) — an unverifiable quote means the promoter must restate" } ))),
    pending_new_conflicts: $t.new_conflicts,
    unparseable_promotions: [ ($t.promotions // [])[] | select(.ok | not) | {panel, line} ],
    seconded: [ ($t.promotions // [])[] | select(.ok and (.seconding // false)) | {panel, cited_panel, anchor, quote, mine, round: $t.round} ],
    corrections: $t.corrections }
