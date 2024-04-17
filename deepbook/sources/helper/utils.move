/// Deepbook utility functions.
module deepbook::utils {
    use std::ascii::{Self, String};

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
    
    /// Compare two ASCII strings, return True if first string is less than or equal to the second string in lexicographic order
    public fun compare_ascii_strings(str1: &String, str2: &String): bool {
        let len1 = str1.length();
        let len2 = str2.length();
        let min_len = if (len1 < len2) { len1 } else { len2 };

        let bytes1 = str1.as_bytes();
        let bytes2 = str2.as_bytes();

        let mut i: u64 = 0;
        while (i < min_len) {
            if (bytes1[i] < bytes2[i]) {
                return true
            } else if (bytes1[i] > bytes2[i]) {
                return false
            };
            i = i + 1
        };

        if (len1 <= len2) {
            return true
        } else {
            return false
        }
    }

    /// Append two ASCII strings and return the result
    public fun append_strings(str1: &String, str2: &String): String {
        let mut result_bytes = vector::empty<u8>();

        // Append bytes from the first string
        let bytes1 = str1.as_bytes();
        let len1 = bytes1.length();
        let mut i = 0;
        while (i < len1) {
            result_bytes.push_back(bytes1[i]);
            i = i + 1;
        };

        // Append bytes from the second string
        let bytes2 = str2.as_bytes();
        let len2 = bytes2.length();
        i = 0;
        while (i < len2) {
            result_bytes.push_back(bytes2[i]);
            i = i + 1;
        };

        ascii::string(result_bytes)
    }
}