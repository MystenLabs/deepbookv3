// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Deepbook utility functions.
module deepbook::utils {
    use std::ascii::String;
    use sui::math;

    /// Pop elements from the back of `v` until its length equals `n`,
    /// returning the elements that were popped in the order they
    /// appeared in `v`.
    public(package) fun pop_until<T>(v: &mut vector<T>, n: u64): vector<T> {
        let mut res = vector[];
        while (v.length() > n) {
            res.push_back(v.pop_back());
        };

        res.reverse();
        res
    }

    /// Pop `n` elements from the back of `v`, returning the elements
    /// that were popped in the order they appeared in `v`.
    ///
    /// Aborts if `v` has fewer than `n` elements.
    public(package) fun pop_n<T>(v: &mut vector<T>, mut n: u64): vector<T> {
        let mut res = vector[];
        while (n > 0) {
            res.push_back(v.pop_back());
            n = n - 1;
        };

        res.reverse();
        res
    }

    /// Compare two ASCII strings, return True if first string is less than or
    /// equal to the second string in lexicographic order
    public fun compare(str1: &String, str2: &String): bool {
        if (str1 == str2) return true;
        
        let min_len = math::min(str1.length(), str2.length());
        let (bytes1, bytes2) = (str1.as_bytes(), str2.as_bytes());

        // skip until bytes are different or one of the strings ends;
        let mut i: u64 = 0;
        while (i < min_len && bytes1[i] == bytes2[i]) {
            i = i + 1
        };

        if (i == min_len) {
            (str1.length() <= str2.length())
        } else {
            (bytes1[i] <= bytes2[i])
        }
    }

    /// Concatenate two ASCII strings and return the result.
    public fun concat_ascii(str1: String, str2: String): String {
        // Append bytes from the first string
        let mut bytes1 = str1.into_bytes();
        let bytes2 = str2.into_bytes();

        bytes1.append(bytes2);
        bytes1.to_ascii_string()
    }
    
    /// first bit is 0 for bid, 1 for ask
    /// next 63 bits are price (assertion for price is done in order function)
    /// last 64 bits are order_id
    public(package) fun encode_order_id(
        is_bid: bool,
        price: u64,
        order_id: u64
    ): u128 {
        if (is_bid) {
            ((price as u128) << 64) + (order_id as u128)
        } else {
            (1u128 << 127) + ((price as u128) << 64) + (order_id as u128)
        }
    }

    #[test]
    fun test_concat() {
        use sui::test_utils;

        let str1 = b"Hello, ".to_ascii_string();
        let str2 = b"World!".to_ascii_string();
        let result = concat_ascii(str1, str2);

        test_utils::assert_eq(result, b"Hello, World!".to_ascii_string());
    }

    #[test]
    fun test_compare() {
        use sui::test_utils::assert_eq;

        // same length, first is less
        assert_eq(compare(
            &b"A".to_ascii_string(),
            &b"B".to_ascii_string()
        ), true);

        // same length, first is greater
        assert_eq(compare(
            &b"B".to_ascii_string(),
            &b"A".to_ascii_string()
        ), false);

        // same length, last character is less
        assert_eq(compare(
            &b"AAAA".to_ascii_string(),
            &b"AAAB".to_ascii_string()
        ), true);

        // 2nd string is longer
        assert_eq(compare(
            &b"AAAA".to_ascii_string(),
            &b"AAAAB".to_ascii_string()
        ), true);

        // strings are identical, defaults to true
        assert_eq(compare(
            &b"AAAA".to_ascii_string(),
            &b"AAAA".to_ascii_string()
        ), true);
}
