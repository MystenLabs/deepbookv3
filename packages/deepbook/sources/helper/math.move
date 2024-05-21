// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::math {


    /// scaling setting for float
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const FLOAT_SCALING_U128: u128 = 1_000_000_000;

    /// Multiply two floating numbers.
    /// This function will round down the result.
    public(package) fun mul(x: u64, y: u64): u64 {
        let (_, result) = mul_internal(x, y);

        result
    }

    /// Multiply two floating numbers.
    /// This function will round up the result.
    public(package) fun mul_round_up(x: u64, y: u64): u64 {
        let (is_round_down, result) = mul_internal(x, y);

        result + is_round_down
    }

    /// Divide two floating numbers.
    /// This function will round down the result.
    public(package) fun div(x: u64, y: u64): u64 {
        let (_, result) = div_internal(x, y);

        result
    }

    /// Divide two floating numbers.
    /// This function will round up the result.
    public(package) fun div_round_up(x: u64, y: u64): u64 {
        let (is_round_down, result) = div_internal(x, y);

        result + is_round_down
    }

    public(package) fun min(x: u64, y: u64): u64 {
        if (x <= y) {
            x
        } else {
            y
        }
    }

    public(package) fun max(x: u64, y: u64): u64 {
        if (x > y) {
            x
        } else {
            y
        }
    }

    /// given a vector, return the median
    public(package) fun median(v: vector<u64>): u64 {
        let n = v.length();
        if (n == 0) {
            return 0
        };

        let sorted_v = quick_sort(v);
        if (n % 2 == 0) {
            mul((sorted_v[n / 2 - 1] + sorted_v[n / 2]), FLOAT_SCALING / 2)
        } else {
            sorted_v[n / 2]
        }
    }

    fun quick_sort(mut data: vector<u64>): vector<u64> {
        if (data.length() <= 1) {
            return data
        };

        let pivot = data[0];
        let mut less = vector<u64>[];
        let mut equal = vector<u64>[];
        let mut greater = vector<u64>[];

        while (data.length() > 0) {
            let value = data.remove(0);
            if (value < pivot) {
                less.push_back(value);
            } else if (value == pivot) {
                equal.push_back(value);
            } else {
                greater.push_back(value);
            };
        };

        let mut sortedData = vector<u64>[];
        sortedData.append(quick_sort(less));
        sortedData.append(equal);
        sortedData.append(quick_sort(greater));
        sortedData
    }

    fun mul_internal(x: u64, y: u64): (u64, u64) {
        let x = x as u128;
        let y = y as u128;
        let round = if((x * y) % FLOAT_SCALING_U128 == 0) 0 else 1;

        (round, (x * y / FLOAT_SCALING_U128) as u64)
    }

    fun div_internal(x: u64, y: u64): (u64, u64) {
        let x = x as u128;
        let y = y as u128;
        let round = if ((x * FLOAT_SCALING_U128 % y) == 0) 0 else 1;

        (round, (x * FLOAT_SCALING_U128 / y) as u64)
    }

    #[test]
    /// Test median function
    fun test_median() {
        let v = vector<u64>[
            1 * FLOAT_SCALING,
            2 * FLOAT_SCALING,
            3 * FLOAT_SCALING,
            4 * FLOAT_SCALING,
            5 * FLOAT_SCALING
        ];
        assert!(median(v) == 3 * FLOAT_SCALING);

        let v = vector<u64>[
            10 * FLOAT_SCALING,
            15 * FLOAT_SCALING,
            2 * FLOAT_SCALING,
            3 * FLOAT_SCALING,
            5 * FLOAT_SCALING
        ];
        assert!(median(v) == 5 * FLOAT_SCALING);

        let v = vector<u64>[
            10 * FLOAT_SCALING,
            9 * FLOAT_SCALING,
            23 * FLOAT_SCALING,
            4 * FLOAT_SCALING,
            5 * FLOAT_SCALING,
            28 * FLOAT_SCALING];
        assert!(median(v) == 9_500_000_000);
    }
}
