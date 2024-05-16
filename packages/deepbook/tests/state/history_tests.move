// module deepbook::history_tests {
//     use sui::{
//         address,
//         test_scenario::{next_tx, begin, end},
//         test_utils::{destroy, assert_eq},
//         object::id_from_address,
//     };
    
//     use deepbook::history;

//     const OWNER: address = @0xF;
//     const ALICE: address = @0xA;
//     const BOB: address = @0xB;
//     const CHARLIE: address = @0xC;
//     const MAX_PROPOSALS: u256 = 100;

//     #[test]
//     fun add_volume_ok() {
//         let mut test = begin(OWNER);
//         let alice = ALICE;
//         let bob = BOB;
        
//         test.next_tx(alice);
//         let mut history = history::empty(test.ctx());
//         history.add_volume(1000, 1000, false);
//         assert!(history.volumes().total_volume() == 1000, 0);
//         assert!(history.volumes().total_staked_volume() == 1000, 0);
//         assert!(history.volumes().accounts_with_rebates() == 0, 0);
        
//         test.next_tx(bob);
//         history.add_volume(2000, 2000, true);
//         assert!(history.volumes().total_volume() == 3000, 0);
//         assert!(history.volumes().total_staked_volume() == 3000, 0);
//         assert!(history.volumes().accounts_with_rebates() == 1, 0);

//         test.next_tx(alice);
//         history.add_volume(5000, 0, false);
//         assert!(history.volumes().total_volume() == 8000, 0);
//         assert!(history.volumes().total_staked_volume() == 3000, 0);
//         assert!(history.volumes().accounts_with_rebates() == 1, 0);

//         test.next_tx(bob);
//         history.add_volume(0, 0, false);
//         assert!(history.volumes().total_volume() == 8000, 0);
//         assert!(history.volumes().total_staked_volume() == 3000, 0);
//         assert!(history.volumes().accounts_with_rebates() == 1, 0);

//         destroy(history);
//         end(test);
//     }

//     #[test]
//     fun update_ok() {
//         let mut test = begin(OWNER);
//         let alice = ALICE;
//         let bob = BOB;
        
//         test.next_tx(alice);
//         let mut history = history::empty(test.ctx());
//         history.add_volume(1000, 1000, false);
//         assert!(history.volumes().total_volume() == 1000, 0);
//         assert!(history.volumes().total_staked_volume() == 1000, 0);
//         assert!(history.volumes().accounts_with_rebates() == 0, 0);

//         test.next_tx(alice);
//         history.update(test.ctx(), 2000); // epoch hasn't changed yet
//         assert!(history.volumes().total_volume() == 1000, 0);
//         assert!(history.volumes().stake_required() == 0, 0);

//         test.next_epoch(OWNER);
//         test.next_tx(bob);
//         history.update(test.ctx(), 2000);
//         assert!(history.volumes().total_volume() == 0, 0);
//         assert!(history.volumes().total_staked_volume() == 0, 0);
//         assert!(history.volumes().accounts_with_rebates() == 0, 0);
//         assert!(history.volumes().stake_required() == 2000, 0);
//         // volumes were not added to history because no staked accounts need it
//         assert!(!history.historic_volumes().contains(test.ctx().epoch() - 1), 0);

//         test.next_tx(alice);

//         destroy(history);
//         end(test);
//     }
// }