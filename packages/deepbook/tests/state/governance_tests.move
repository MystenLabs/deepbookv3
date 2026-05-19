// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::governance_tests;

use deepbook::{constants, governance};
use std::unit_test::{assert_eq, destroy};
use sui::{address, object::id_from_address, test_scenario::{next_tx, begin, end}};

const OWNER: address = @0xF;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CHARLIE: address = @0xC;
const MAX_PROPOSALS: u256 = 100;

#[test]
fun add_proposal_volatile_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));
    assert!(gov.proposals().length() == 1, 0);
    let (taker_fee, maker_fee, stake_required) = gov
        .proposals()
        .get(&id_from_address(alice))
        .params();
    assert!(taker_fee == 500000, 0);
    assert!(maker_fee == 200000, 0);
    assert!(stake_required == 10000, 0);

    destroy(gov);
    end(test);
}

#[test]
fun add_proposal_stake_required_at_max_ok() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);
    let mut gov = governance::empty(false, false, test.ctx());
    gov.add_proposal(
        500000,
        200000,
        constants::max_stake_required(),
        1000,
        id_from_address(ALICE),
    );
    let (_, _, stake_required) = gov.proposals().get(&id_from_address(ALICE)).params();
    assert_eq!(stake_required, constants::max_stake_required());
    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidStakeRequired)]
fun add_proposal_stake_required_above_max_e() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);
    let mut gov = governance::empty(false, false, test.ctx());
    gov.add_proposal(
        500000,
        200000,
        constants::max_stake_required() + 1,
        1000,
        id_from_address(ALICE),
    );
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_taker_not_multiple_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500100, 200000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_low_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(99000, 200000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_high_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(1010000, 200000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
fun add_proposal_volatile_high_maker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500000, 510000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test]
fun add_proposal_stable_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.add_proposal(50000, 20000, 10000, 1000, id_from_address(alice));
    assert!(gov.proposals().length() == 1, 0);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.add_proposal(500000, 20000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_low_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.add_proposal(9000, 20000, 10000, 10000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_high_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.add_proposal(110000, 20000, 10000, 10000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
fun add_proposal_stable_maker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    test.next_tx(alice);
    gov.add_proposal(50000, 200000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
fun add_proposal_whitelisted_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = true;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(ALICE);
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));
    abort 0
}

#[test]
fun adjust_voting_power_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let mut alice_stake = 0;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 1000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 2000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 3000, 0);
    assert!(gov.quorum() == 0, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 1500, 0);

    // alice removes stake by 1000 3 times. reverses the effects.
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    alice_stake = alice_stake - 1000;
    assert!(gov.voting_power() == 2000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    alice_stake = alice_stake - 1000;
    assert!(gov.voting_power() == 1000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    assert!(gov.voting_power() == 0, 0);

    destroy(gov);
    end(test);
}

#[test]
fun update_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    assert!(gov.voting_power() == 0, 0);
    assert!(gov.quorum() == 0, 0);
    assert!(gov.proposals().length() == 0, 0);
    assert_eq!(gov.trade_params(), gov.next_trade_params());
    gov.adjust_voting_power(0, 1000);
    assert!(gov.voting_power() == 1000, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    test.next_tx(alice);
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    assert!(gov.proposals().length() == 1, 0);
    assert!(gov.quorum() == 500, 0);
    let trade_params = gov.trade_params();
    assert!(trade_params.taker_fee() == 1000000, 0);
    assert!(trade_params.maker_fee() == 500000, 0);
    assert!(trade_params.stake_required() == constants::default_stake_required(), 0);
    let next_trade_params = gov.next_trade_params();
    assert!(next_trade_params.taker_fee() == 500000, 0);
    assert!(next_trade_params.maker_fee() == 200000, 0);
    assert!(next_trade_params.stake_required() == 10000, 0);

    // update doesn't apply proposal yet since epoch hasn't changed
    gov.update(test.ctx());
    assert_eq!(trade_params, gov.trade_params());
    assert_eq!(next_trade_params, gov.next_trade_params());
    assert!(gov.proposals().length() == 1, 0);
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    let trade_params = gov.trade_params();
    assert!(trade_params.taker_fee() == 500000, 0);
    assert!(trade_params.maker_fee() == 200000, 0);
    assert!(trade_params.stake_required() == 10000, 0);
    assert_eq!(trade_params, gov.next_trade_params());
    assert!(gov.proposals().length() == 0, 0);
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    destroy(gov);
    end(test);
}

#[test]
fun adjust_vote_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 500);
    assert!(gov.voting_power() == 500, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 250, 0);

    // alice proposes proposal 0, votes with 200 votes, not over quorum
    test.next_tx(alice);
    gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 200);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 200, 0);
    assert!(gov.next_trade_params().taker_fee() == 1000000, 0);
    assert_eq!(gov.trade_params(), gov.next_trade_params());

    // bob proposes proposal 1, votes with 300 votes, over quorum
    test.next_tx(bob);
    gov.add_proposal(600000, 300000, 10000, 300, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 300);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 200, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 300, 0);
    assert!(gov.next_trade_params().taker_fee() == 600000, 0);
    assert!(gov.next_trade_params().maker_fee() == 300000, 0);

    // alice moves her votes from proposal 0 to 1
    test.next_tx(alice);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        200,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 0, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 500, 0);
    assert!(gov.next_trade_params().taker_fee() == 600000, 0);
    assert!(gov.next_trade_params().maker_fee() == 300000, 0);

    // bob moves his votes from proposal 1 to 0, making it the next trade params
    test.next_tx(bob);
    gov.adjust_vote(
        option::some(id_from_address(bob)),
        option::some(id_from_address(alice)),
        300,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 300, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 200, 0);
    assert!(gov.next_trade_params().taker_fee() == 500000, 0);
    assert!(gov.next_trade_params().maker_fee() == 200000, 0);

    // bob removes his votes completely, making the default trade params the
    // next trade params
    test.next_tx(bob);
    gov.adjust_vote(option::some(id_from_address(alice)), option::none(), 300);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 0, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 200, 0);
    assert!(gov.next_trade_params().taker_fee() == 1000000, 0);
    assert!(gov.next_trade_params().maker_fee() == 500000, 0);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
fun adjust_vote_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    abort 0
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
fun adjust_vote2_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        1000,
    );
    abort 0
}

#[test]
fun adjust_vote_from_removed_proposal_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice));
    gov.adjust_vote(
        option::some(id_from_address(bob)),
        option::some(id_from_address(alice)),
        1000,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 1000, 0);

    destroy(gov);
    end(test);
}

/// Regression test for audit M-8. Two proposals can be above quorum
/// simultaneously because `voting_power` is mutable mid-epoch via
/// `adjust_voting_power` while `quorum` is frozen at `update()`. Withdrawing
/// a vote from one of them must NOT wipe the other one's win.
#[test]
fun adjust_vote_withdraw_from_a_keeps_b_when_b_above_quorum() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let mut gov = governance::empty(false, false, test.ctx());

    // Epoch-start voting power = 1000, quorum frozen at 500.
    gov.adjust_voting_power(0, 1000);
    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert_eq!(gov.quorum(), 500);

    // Alice proposes A and votes 1000 → A above quorum, A is the leader.
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);

    // Bob stakes 600 mid-epoch. voting_power becomes 1600 but quorum stays 500.
    gov.adjust_voting_power(0, 600);

    // Bob proposes B and votes 600 → B above quorum. A (1000) still beats B
    // (600), so the leader stays A.
    test.next_tx(bob);
    gov.add_proposal(600000, 300000, 20000, 600, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 600);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);

    // Alice withdraws her 1000 votes from A. The bug would now reset
    // next_trade_params to defaults, wiping B's win. The fix recomputes the
    // leader; B is still above quorum, so B wins.
    test.next_tx(alice);
    gov.adjust_vote(option::some(id_from_address(alice)), option::none(), 1000);
    assert_eq!(gov.proposals().get(&id_from_address(alice)).votes(), 0);
    assert_eq!(gov.proposals().get(&id_from_address(bob)).votes(), 600);
    assert_eq!(gov.next_trade_params().taker_fee(), 600000);
    assert_eq!(gov.next_trade_params().maker_fee(), 300000);
    assert_eq!(gov.next_trade_params().stake_required(), 20000);

    destroy(gov);
    end(test);
}

/// When two proposals are simultaneously above quorum, the higher-vote one
/// wins. The pre-fix behaviour was "the most recently touched", which let a
/// smaller proposal replace a larger one — orthogonal to M-8 but the same
/// recompute-from-leader fix corrects it.
#[test]
fun adjust_vote_higher_above_quorum_wins_over_lower_above_quorum() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let mut gov = governance::empty(false, false, test.ctx());
    gov.adjust_voting_power(0, 1000);
    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());

    // Alice proposes A, votes 800 — above quorum 500.
    gov.add_proposal(500000, 200000, 10000, 800, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 800);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);

    // Bob stakes 600 mid-epoch; Bob proposes B and votes 600 — also above
    // quorum but with fewer votes than A. Leader stays A.
    gov.adjust_voting_power(0, 600);
    test.next_tx(bob);
    gov.add_proposal(600000, 300000, 20000, 600, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 600);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);
    assert_eq!(gov.next_trade_params().maker_fee(), 200000);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
/// Test two proposals that were added by two different people A and B
/// A with less voting power than B (A had 100000, B had 200000, C had 150000)
/// C votes on A's proposal and pushes it over quorum
/// C then makes a new proposal. The proposal that's removed should be A
/// Check to make sure A's removed by voting on proposal A, which will error
/// (EProposalDoesNotExist)
fun remove_proposal_vote_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;
    let charlie = CHARLIE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 450000);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 225000, 0);

    let dummy_proposals = MAX_PROPOSALS - 2;

    let mut i = 0;
    while (i < dummy_proposals) {
        let address = address::from_u256(i + (1 << 10));
        gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(address));
        // Bigger vote than Alice to make sure proposal doesn't get removed
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            110000,
        );
        i = i + 1;
    };

    // Alice proposes and votes with 100000 stake, not enough to push proposal
    // ALICE over quorum
    gov.add_proposal(500000, 200000, 10000, 100000, id_from_address(alice));
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(alice)),
        100000,
    );
    assert_eq!(gov.trade_params(), gov.next_trade_params());
    // Bob proposes and votes with 200000 stake, not enough to push proposal Bob
    // over quorum
    gov.add_proposal(600000, 300000, 20000, 200000, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 200000);
    assert_eq!(gov.trade_params(), gov.next_trade_params());

    // Charlie votes with 150000 stake, enough to push proposal ALICE over
    // quorum
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(alice)),
        150000,
    );
    // assert winning proposal is ALICE
    let trade_params = gov.next_trade_params();
    assert!(trade_params.taker_fee() == 500000, 0);
    assert!(trade_params.maker_fee() == 200000, 0);
    assert!(trade_params.stake_required() == 10000, 0);

    assert!(gov.proposals().length() == 100u64, 0);

    // Charlie makes a new proposal, proposal ALICE should be removed, not BOB
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::none(),
        150000,
    );
    gov.add_proposal(700000, 400000, 30000, 150000, id_from_address(charlie));
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(charlie)),
        150000,
    );
    assert!(gov.proposals().contains(&id_from_address(bob)), 0);
    assert!(!gov.proposals().contains(&id_from_address(alice)), 0);

    // Voting on proposal ALICE should error
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 100);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EMaxProposalsReachedNotEnoughVotes)]
fun remove_proposal_stake_too_low_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    let mut i = 0;
    while (i < MAX_PROPOSALS) {
        let address = address::from_u256(i + (1 << 10));
        gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(address));
        // Bigger vote than Alice to make sure proposal doesn't get removed
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            110000,
        );
        i = i + 1;
    };

    assert!(gov.proposals().length() == (MAX_PROPOSALS as u64), 0);
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));

    abort 0
}

#[test]
fun adjust_votes_remove_from_removed_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 1000, 0);

    let mut i = 0;
    while (i < MAX_PROPOSALS - 1) {
        let address = address::from_u256(i + (1 << 10));
        gov.add_proposal(500000, 200000, 10000, 2000, id_from_address(address));
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            2000,
        );
        i = i + 1;
    };
    assert!(gov.proposals().length() == 100, 0);

    test.next_tx(bob);
    gov.add_proposal(500000, 200000, 10000, 3000, id_from_address(bob));
    assert!(!gov.proposals().contains(&id_from_address(alice)), 0);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        3000,
    );
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 3000, 0);

    destroy(gov);
    end(test);
}

#[test]
/// Any stake over 100k DEEP will be subject to voting power decrease
fun adjust_voting_power_over_threshold_ok() {
    let mut test = begin(OWNER);

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 100_000 * constants::deep_unit());
    assert!(gov.voting_power() == 100_000 * constants::deep_unit(), 0);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.quorum() == 50_000 * constants::deep_unit(), 0);
    gov.adjust_voting_power(
        100_000 * constants::deep_unit(),
        150_000 * constants::deep_unit(),
    );
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    // The additional power is calculated as sqrt(total_stake = 150k) -
    // sqrt(threshold = 100k)
    // 387.298334620 - 316.227766016 = 71.070568604
    // total voting power = 100000 + 71.070568604 = 100071.070568604
    // quorum = 50035.535284302
    // The total voting power is therefore 52.928, with quorum being half of
    // that = 26.464.
    assert!(gov.voting_power() == 100_071_070_568, 0);

    assert!(gov.quorum() == 50_035_535_284, 0);
    gov.adjust_voting_power(
        150_000 * constants::deep_unit(),
        200_000 * constants::deep_unit(),
    );
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    // The additional power is calculated as sqrt(total_stake = 200k) -
    // sqrt(threshold = 100k)
    // 447.213595499 - 316.227766016 = 130.985829483
    // total voting power = 100000 + 130.985829484 = 100130.985829483
    // quorum = 50065.492914741
    assert!(gov.voting_power() == 100_130_985_829, 0);
    assert!(gov.quorum() == 50_065_492_914, 0);

    destroy(gov);
    end(test);
}

/// Mid-epoch upgrade safety. Simulates a state left by old code (a single
/// winning proposal already set as `next_trade_params`), then invokes the new
/// `adjust_vote` recompute as a no-op (empty options, zero stake). The
/// recompute must not flip the winner.
#[test]
fun mid_epoch_upgrade_no_op_recompute_preserves_winner() {
    let mut test = begin(OWNER);
    test.next_tx(OWNER);
    let mut gov = governance::empty(false, false, test.ctx());

    gov.adjust_voting_power(0, 1000);
    test.next_epoch(OWNER);
    test.next_tx(ALICE);
    gov.update(test.ctx());
    assert_eq!(gov.quorum(), 500);

    gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(ALICE));
    gov.adjust_vote(option::none(), option::some(id_from_address(ALICE)), 1000);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);
    assert_eq!(gov.next_trade_params().maker_fee(), 200000);

    // Simulate the moment immediately after a mid-epoch upgrade: any subsequent
    // `adjust_vote` call recomputes `next_trade_params` from current proposal
    // state. With zero stake and no proposal changes, the leader is unchanged.
    gov.adjust_vote(option::none(), option::none(), 0);
    assert_eq!(gov.next_trade_params().taker_fee(), 500000);
    assert_eq!(gov.next_trade_params().maker_fee(), 200000);

    // Epoch boundary consumes the winner as expected.
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert_eq!(gov.trade_params().taker_fee(), 500000);
    assert_eq!(gov.trade_params().maker_fee(), 200000);

    destroy(gov);
    end(test);
}

/// Mid-epoch upgrade safety. With no proposal above quorum, recompute returns
/// the current `trade_params` (defaults). Exercises the empty-leader path of
/// `leader_above_quorum_params`.
#[test]
fun mid_epoch_upgrade_no_op_recompute_no_winner_keeps_defaults() {
    let mut test = begin(OWNER);
    test.next_tx(OWNER);
    let mut gov = governance::empty(false, false, test.ctx());

    gov.adjust_voting_power(0, 1000);
    test.next_epoch(OWNER);
    test.next_tx(ALICE);
    gov.update(test.ctx());

    let default_taker = gov.trade_params().taker_fee();
    let default_maker = gov.trade_params().maker_fee();

    // Below-quorum proposal exists but no leader.
    gov.add_proposal(500000, 200000, 10000, 200, id_from_address(ALICE));
    gov.adjust_vote(option::none(), option::some(id_from_address(ALICE)), 200);
    assert_eq!(gov.next_trade_params().taker_fee(), default_taker);
    assert_eq!(gov.next_trade_params().maker_fee(), default_maker);

    // No-op recompute leaves defaults in place.
    gov.adjust_vote(option::none(), option::none(), 0);
    assert_eq!(gov.next_trade_params().taker_fee(), default_taker);
    assert_eq!(gov.next_trade_params().maker_fee(), default_maker);

    destroy(gov);
    end(test);
}
