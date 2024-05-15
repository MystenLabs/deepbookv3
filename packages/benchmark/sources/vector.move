module benchmark::vector {
    use sui::table::{Self, Table};

    public struct Test has key, store {
        id: UID,
        push_back_vec: vector<u64>,
        prepend_vec: vector<u64>,
        tbl: Table<u64, u64>,

    }

    fun init(ctx: &mut TxContext) {
        let test = Test {
            id: object::new(ctx),
            push_back_vec: vector::empty(),
            prepend_vec: vector::empty(),
            tbl: table::new(ctx),
        };
        
        transfer::share_object(test)
    }

    public fun add_to_table(self: &mut Test, val: u64) {
        self.tbl.add(val, val);
    }

    public fun remove_from_table(self: &mut Test, val: u64) {
        self.tbl.remove(val);
    }

    public fun push_back_vec(self: &mut Test, val: u64) {
        self.push_back_vec.push_back(val);
    }

    public fun prepend_vec(self: &mut Test, val: u64) {
        self.prepend_vec.insert(0, val);
    }
}