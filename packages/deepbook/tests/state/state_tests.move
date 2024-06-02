module deepbook::state_tests {
    use sui::{
        test_scenario::{next_tx, begin, end},
        test_utils::assert_eq,
        object::id_from_address,
    };
    use deepbook::{
        state,
        account,
        balances,
        fill,
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    #[test]
    fun process_create_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);

        end(test);
    }
}