module deepbookv3::string_helper {
    use std::ascii::{Self, String};

    /// Compare two ASCII strings, return True if first string is less than to equal to the second string in lexicographic order
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