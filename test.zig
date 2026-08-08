const std = @import("std");
const main = @import("main.zig");

const isValidBucketName = main.isValidBucketName;
const isValidKey = main.isValidKey;
const parseRange = main.parseRange;
const hasQuery = main.hasQuery;
const getQueryParam = main.getQueryParam;
const uriEncode = main.uriEncode;
const uriDecode = main.uriDecode;
const sortQueryString = main.sortQueryString;
const xmlEscape = main.xmlEscape;
const SigV4 = main.SigV4;
const formatHttpDate = main.formatHttpDate;
const formatIso8601 = main.formatIso8601;
const decodeAwsChunked = main.decodeAwsChunked;

test "isValidBucketName" {
    try std.testing.expect(isValidBucketName("mybucket"));
    try std.testing.expect(isValidBucketName("my-bucket"));
    try std.testing.expect(isValidBucketName("my.bucket"));
    try std.testing.expect(isValidBucketName("my-bucket.test"));
    try std.testing.expect(isValidBucketName("abc"));
    try std.testing.expect(!isValidBucketName("ab"));
    try std.testing.expect(!isValidBucketName("-bucket"));
    try std.testing.expect(!isValidBucketName("bucket-"));
    try std.testing.expect(!isValidBucketName(".bucket"));
    try std.testing.expect(!isValidBucketName("bucket."));
    try std.testing.expect(!isValidBucketName("my_bucket"));
    try std.testing.expect(!isValidBucketName(""));
    try std.testing.expect(!isValidBucketName("MyBucket"));
}

test "isValidKey" {
    try std.testing.expect(isValidKey("file.txt"));
    try std.testing.expect(isValidKey("folder/file.txt"));
    try std.testing.expect(isValidKey("a/b/c/d.txt"));
    try std.testing.expect(isValidKey("file with spaces.txt"));
    try std.testing.expect(isValidKey("file-name_test.txt"));

    try std.testing.expect(!isValidKey(""));
    try std.testing.expect(!isValidKey("file\x00.txt"));
    try std.testing.expect(!isValidKey("file\x1f.txt"));
    try std.testing.expect(!isValidKey("file\x7f.txt"));

    // Path traversal
    try std.testing.expect(!isValidKey("../etc/passwd"));
    try std.testing.expect(!isValidKey("folder/../../etc/passwd"));
    try std.testing.expect(!isValidKey("a..b")); // any ".." is blocked
    // Absolute paths
    try std.testing.expect(!isValidKey("/etc/passwd"));
    // Max length
    try std.testing.expect(!isValidKey("a" ** 1025));
    // Valid edge cases
    try std.testing.expect(isValidKey("a" ** 1024));
    try std.testing.expect(isValidKey("folder/subfolder/deep/file.txt"));
    try std.testing.expect(isValidKey("file with spaces & special=chars.txt"));
}

test "parseRange" {
    const file_size: u64 = 1000;

    const r1 = parseRange("bytes=0-499", file_size);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqual(@as(u64, 0), r1.?.start);
    try std.testing.expectEqual(@as(u64, 499), r1.?.end);

    const r2 = parseRange("bytes=500-999", file_size);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(@as(u64, 500), r2.?.start);
    try std.testing.expectEqual(@as(u64, 999), r2.?.end);

    const r3 = parseRange("bytes=500-", file_size);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqual(@as(u64, 500), r3.?.start);
    try std.testing.expectEqual(@as(u64, 999), r3.?.end);

    // Suffix range: last 100 bytes
    const r4 = parseRange("bytes=-100", file_size);
    try std.testing.expect(r4 != null);
    try std.testing.expectEqual(@as(u64, 900), r4.?.start);
    try std.testing.expectEqual(@as(u64, 999), r4.?.end);

    // Suffix range larger than file size: clamp to entire file (RFC 7233)
    const r5 = parseRange("bytes=-2000", file_size);
    try std.testing.expect(r5 != null);
    try std.testing.expectEqual(@as(u64, 0), r5.?.start);
    try std.testing.expectEqual(@as(u64, 999), r5.?.end);

    try std.testing.expect(parseRange("bytes=-0", file_size) == null);
    try std.testing.expect(parseRange("bytes=1000-1000", file_size) == null);
    try std.testing.expect(parseRange("bytes=500-400", file_size) == null);
    try std.testing.expect(parseRange("invalid", file_size) == null);
    try std.testing.expect(parseRange("bytes=abc-def", file_size) == null);
}

test "hasQuery" {
    try std.testing.expect(hasQuery("uploads", "uploads"));
    try std.testing.expect(hasQuery("uploadId=123", "uploadId"));
    try std.testing.expect(hasQuery("foo=bar&uploadId=123", "uploadId"));
    try std.testing.expect(hasQuery("uploadId=123&foo=bar", "uploadId"));

    try std.testing.expect(!hasQuery("myuploadId=123", "uploadId"));
    try std.testing.expect(!hasQuery("", "uploadId"));

    // Right-boundary: key must end at '=', '&', or end-of-string
    try std.testing.expect(!hasQuery("uploadIdFoo=123", "uploadId"));
    try std.testing.expect(!hasQuery("uploadIds", "uploadId"));
    try std.testing.expect(hasQuery("uploadId", "uploadId"));
    try std.testing.expect(hasQuery("foo=bar&delete", "delete"));
    try std.testing.expect(hasQuery("delete&foo=bar", "delete"));
}

test "getQueryParam" {
    try std.testing.expectEqualStrings("123", getQueryParam("uploadId=123", "uploadId").?);
    try std.testing.expectEqualStrings("456", getQueryParam("foo=bar&partNumber=456", "partNumber").?);
    try std.testing.expectEqualStrings("", getQueryParam("uploads", "uploads").?);
    try std.testing.expectEqualStrings("bar", getQueryParam("foo=bar", "foo").?);

    try std.testing.expect(getQueryParam("foo=bar", "baz") == null);
    try std.testing.expect(getQueryParam("", "foo") == null);
}

test "uriEncode" {
    const allocator = std.testing.allocator;

    const e1 = try uriEncode(allocator, "/bucket/key", false);
    defer allocator.free(e1);
    try std.testing.expectEqualStrings("/bucket/key", e1);

    const e2 = try uriEncode(allocator, "hello world", false);
    defer allocator.free(e2);
    try std.testing.expectEqualStrings("hello%20world", e2);

    const e3 = try uriEncode(allocator, "key=value&foo", true);
    defer allocator.free(e3);
    try std.testing.expectEqualStrings("key%3Dvalue%26foo", e3);

    const e4 = try uriEncode(allocator, "abc-123_test.txt~", false);
    defer allocator.free(e4);
    try std.testing.expectEqualStrings("abc-123_test.txt~", e4);

    const e5 = try uriEncode(allocator, "a/b/c", true);
    defer allocator.free(e5);
    try std.testing.expectEqualStrings("a%2Fb%2Fc", e5);
}

test "uriDecode" {
    const allocator = std.testing.allocator;

    const d1 = try uriDecode(allocator, "hello%20world");
    defer allocator.free(d1);
    try std.testing.expectEqualStrings("hello world", d1);

    const d2 = try uriDecode(allocator, "a%2Fb%2Fc");
    defer allocator.free(d2);
    try std.testing.expectEqualStrings("a/b/c", d2);

    const d3 = try uriDecode(allocator, "no+encoding+needed");
    defer allocator.free(d3);
    try std.testing.expectEqualStrings("no encoding needed", d3);

    const d4 = try uriDecode(allocator, "already-plain");
    defer allocator.free(d4);
    try std.testing.expectEqualStrings("already-plain", d4);

    // Empty string
    const d5 = try uriDecode(allocator, "");
    defer allocator.free(d5);
    try std.testing.expectEqualStrings("", d5);

    // Mixed encoded and plain
    const d6 = try uriDecode(allocator, "key%3Dvalue%26foo");
    defer allocator.free(d6);
    try std.testing.expectEqualStrings("key=value&foo", d6);

    // Lowercase hex
    const d7 = try uriDecode(allocator, "%2f%2F");
    defer allocator.free(d7);
    try std.testing.expectEqualStrings("//", d7);

    // Invalid percent encoding (not enough chars) - pass through
    const d8 = try uriDecode(allocator, "abc%2");
    defer allocator.free(d8);
    try std.testing.expectEqualStrings("abc%2", d8);

    // Invalid hex digits - pass through
    const d9 = try uriDecode(allocator, "abc%GG");
    defer allocator.free(d9);
    try std.testing.expectEqualStrings("abc%GG", d9);
}

test "uriEncode and uriDecode roundtrip" {
    const allocator = std.testing.allocator;

    const original = "folder/file with spaces & special=chars.txt";
    const encoded = try uriEncode(allocator, original, true);
    defer allocator.free(encoded);
    const decoded = try uriDecode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "sortQueryString" {
    const allocator = std.testing.allocator;

    const s1 = try sortQueryString(allocator, "c=3&a=1&b=2");
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("a=1&b=2&c=3", s1);

    const s2 = try sortQueryString(allocator, "uploadId=123");
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("uploadId=123", s2);

    const s3 = try sortQueryString(allocator, "");
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("", s3);

    // Params without '=' should be normalized to 'key=' format
    const s4 = try sortQueryString(allocator, "uploads");
    defer allocator.free(s4);
    try std.testing.expectEqualStrings("uploads=", s4);

    const s5 = try sortQueryString(allocator, "delete");
    defer allocator.free(s5);
    try std.testing.expectEqualStrings("delete=", s5);
}

test "xmlEscape" {
    const allocator = std.testing.allocator;

    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    try xmlEscape(allocator, &list, "hello");
    try std.testing.expectEqualStrings("hello", list.items);

    list.clearRetainingCapacity();
    try xmlEscape(allocator, &list, "<script>alert('xss')</script>");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&apos;xss&apos;)&lt;/script&gt;", list.items);

    list.clearRetainingCapacity();
    try xmlEscape(allocator, &list, "a&b\"c");
    try std.testing.expectEqualStrings("a&amp;b&quot;c", list.items);
}

test "SigV4.parseAuthHeader" {
    const header = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7";

    const parsed = SigV4.parseAuthHeader(header);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("AKIAIOSFODNN7EXAMPLE", parsed.?.access_key);
    try std.testing.expectEqualStrings("20130524", parsed.?.date);
    try std.testing.expectEqualStrings("us-east-1", parsed.?.region);
    try std.testing.expectEqualStrings("s3", parsed.?.service);
    try std.testing.expectEqualStrings("host;x-amz-content-sha256;x-amz-date", parsed.?.signed_headers);
    try std.testing.expectEqualStrings("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", parsed.?.signature);

    try std.testing.expect(SigV4.parseAuthHeader("Basic dXNlcjpwYXNz") == null);
    try std.testing.expect(SigV4.parseAuthHeader("") == null);
}

test "SigV4.hash" {
    const data = "hello";
    const result = SigV4.hash(data);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{result}) catch unreachable;
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hex);
}

test "SigV4.hmac" {
    const key = "key";
    const msg = "message";
    const result = SigV4.hmac(key, msg);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{result}) catch unreachable;
    try std.testing.expectEqualStrings("6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a", &hex);
}

test "formatHttpDate - Unix epoch" {
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
}

test "formatHttpDate - known date" {
    // 2024-01-15 11:30:45 UTC (Monday)
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 1705318245);
    try std.testing.expectEqualStrings("Mon, 15 Jan 2024 11:30:45 GMT", &buf);
}

test "formatHttpDate - end of month" {
    // 2023-12-31 23:59:59 UTC (Sunday)
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 1704067199);
    try std.testing.expectEqualStrings("Sun, 31 Dec 2023 23:59:59 GMT", &buf);
}

test "formatHttpDate - leap year" {
    // 2024-02-29 12:00:00 UTC (Thursday)
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 1709208000);
    try std.testing.expectEqualStrings("Thu, 29 Feb 2024 12:00:00 GMT", &buf);
}

test "formatHttpDate - negative timestamp clamps to epoch" {
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, -100);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
}

test "formatHttpDate - all days of week" {
    // Mon 2024-01-01 00:00:00
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 1704067200);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2024 00:00:00 GMT", &buf);

    // Tue 2024-01-02
    formatHttpDate(&buf, 1704153600);
    try std.testing.expectEqualStrings("Tue, 02 Jan 2024 00:00:00 GMT", &buf);

    // Wed 2024-01-03
    formatHttpDate(&buf, 1704240000);
    try std.testing.expectEqualStrings("Wed, 03 Jan 2024 00:00:00 GMT", &buf);

    // Thu 2024-01-04
    formatHttpDate(&buf, 1704326400);
    try std.testing.expectEqualStrings("Thu, 04 Jan 2024 00:00:00 GMT", &buf);

    // Fri 2024-01-05
    formatHttpDate(&buf, 1704412800);
    try std.testing.expectEqualStrings("Fri, 05 Jan 2024 00:00:00 GMT", &buf);

    // Sat 2024-01-06
    formatHttpDate(&buf, 1704499200);
    try std.testing.expectEqualStrings("Sat, 06 Jan 2024 00:00:00 GMT", &buf);

    // Sun 2024-01-07
    formatHttpDate(&buf, 1704585600);
    try std.testing.expectEqualStrings("Sun, 07 Jan 2024 00:00:00 GMT", &buf);
}

test "formatIso8601 - Unix epoch" {
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &buf);
}

test "formatIso8601 - known date" {
    // 2024-01-15 11:30:45 UTC
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, 1705318245);
    try std.testing.expectEqualStrings("2024-01-15T11:30:45Z", &buf);
}

test "formatIso8601 - end of year" {
    // 2023-12-31 23:59:59 UTC
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, 1704067199);
    try std.testing.expectEqualStrings("2023-12-31T23:59:59Z", &buf);
}

test "formatIso8601 - leap year" {
    // 2024-02-29 12:00:00 UTC
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, 1709208000);
    try std.testing.expectEqualStrings("2024-02-29T12:00:00Z", &buf);
}

test "formatIso8601 - negative timestamp clamps to epoch" {
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, -1);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &buf);
}

test "formatIso8601 - all months" {
    var buf: [20]u8 = undefined;
    // Jan 2024-01-15
    formatIso8601(&buf, 1705276800);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-01-15"));
    // Feb 2024-02-15
    formatIso8601(&buf, 1707955200);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-02-15"));
    // Mar 2024-03-15
    formatIso8601(&buf, 1710460800);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-03-15"));
    // Jun 2024-06-15
    formatIso8601(&buf, 1718409600);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-06-15"));
    // Sep 2024-09-15
    formatIso8601(&buf, 1726358400);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-09-15"));
    // Dec 2024-12-15
    formatIso8601(&buf, 1734220800);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "2024-12-15"));
}

test "formatHttpDate - output length is exactly 29 bytes" {
    var buf: [29]u8 = undefined;
    formatHttpDate(&buf, 1705318245);
    // Verify all 29 bytes are written (no null terminators or padding issues)
    try std.testing.expectEqual(@as(usize, 29), buf.len);
    // Verify the format structure: "Ddd, DD Mmm YYYY HH:MM:SS GMT"
    try std.testing.expectEqual(@as(u8, ','), buf[3]);
    try std.testing.expectEqual(@as(u8, ' '), buf[4]);
    try std.testing.expectEqual(@as(u8, ' '), buf[7]);
    try std.testing.expectEqual(@as(u8, ' '), buf[11]);
    try std.testing.expectEqual(@as(u8, ' '), buf[16]);
    try std.testing.expectEqual(@as(u8, ':'), buf[19]);
    try std.testing.expectEqual(@as(u8, ':'), buf[22]);
    try std.testing.expectEqual(@as(u8, ' '), buf[25]);
    try std.testing.expectEqualStrings("GMT", buf[26..29]);
}

test "formatIso8601 - output length is exactly 20 bytes" {
    var buf: [20]u8 = undefined;
    formatIso8601(&buf, 1705318245);
    try std.testing.expectEqual(@as(usize, 20), buf.len);
    // Verify the format structure: "YYYY-MM-DDTHH:MM:SSZ"
    try std.testing.expectEqual(@as(u8, '-'), buf[4]);
    try std.testing.expectEqual(@as(u8, '-'), buf[7]);
    try std.testing.expectEqual(@as(u8, 'T'), buf[10]);
    try std.testing.expectEqual(@as(u8, ':'), buf[13]);
    try std.testing.expectEqual(@as(u8, ':'), buf[16]);
    try std.testing.expectEqual(@as(u8, 'Z'), buf[19]);
}

test "decodeAwsChunked - single chunk" {
    const allocator = std.testing.allocator;
    const input = "5;chunk-signature=abc123\r\nhello\r\n0;chunk-signature=def456\r\n\r\n";
    const result = try decodeAwsChunked(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "decodeAwsChunked - multiple chunks" {
    const allocator = std.testing.allocator;
    const input = "5;chunk-signature=abc\r\nhello\r\n6;chunk-signature=def\r\n world\r\n0;chunk-signature=end\r\n\r\n";
    const result = try decodeAwsChunked(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "decodeAwsChunked - empty body (zero-size chunk only)" {
    const allocator = std.testing.allocator;
    const input = "0;chunk-signature=abc\r\n\r\n";
    const result = try decodeAwsChunked(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decodeAwsChunked - hex size uppercase" {
    const allocator = std.testing.allocator;
    const input = "A;chunk-signature=sig\r\n0123456789\r\n0;chunk-signature=end\r\n\r\n";
    const result = try decodeAwsChunked(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0123456789", result);
}

// ============================================================================
// Distributed metadata replication helpers
// ============================================================================

const metaContentTimestamp = main.metaContentTimestamp;
const isTombstoneContent = main.isTombstoneContent;

const VALID_HASH = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "metaContentTimestamp - live entry uses created" {
    const content = VALID_HASH ++ "\n123\n1700000000\n0\n";
    try std.testing.expectEqual(@as(?i64, 1700000000), metaContentTimestamp(content));
}

test "metaContentTimestamp - tombstone uses deleted when newer" {
    const content = VALID_HASH ++ "\n123\n1700000000\n1700000500\n";
    try std.testing.expectEqual(@as(?i64, 1700000500), metaContentTimestamp(content));
}

test "metaContentTimestamp - inline data does not affect parsing" {
    const content = VALID_HASH ++ "\n5\n1700000001\n0\nhello";
    try std.testing.expectEqual(@as(?i64, 1700000001), metaContentTimestamp(content));
}

test "metaContentTimestamp - inline data with newlines and digits" {
    const content = VALID_HASH ++ "\n10\n1700000002\n0\n123\n456\n78";
    try std.testing.expectEqual(@as(?i64, 1700000002), metaContentTimestamp(content));
}

test "metaContentTimestamp - rejects malformed entries" {
    // Empty / truncated
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(""));
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH));
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\n123"));
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\n123\n1700000000"));
    // Wrong hash length
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp("abc\n1\n2\n0\n"));
    // Non-hex hash
    const bad_hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(bad_hash ++ "\n1\n2\n0\n"));
    // Non-numeric fields
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\nabc\n2\n0\n"));
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\n1\nabc\n0\n"));
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\n1\n2\nabc\n"));
    // Negative size is invalid (u64)
    try std.testing.expectEqual(@as(?i64, null), metaContentTimestamp(VALID_HASH ++ "\n-1\n2\n0\n"));
}

test "isTombstoneContent" {
    try std.testing.expect(!isTombstoneContent(VALID_HASH ++ "\n123\n1700000000\n0\n"));
    try std.testing.expect(isTombstoneContent(VALID_HASH ++ "\n123\n1700000000\n1700000500\n"));
    try std.testing.expect(isTombstoneContent(VALID_HASH ++ "\n123\n1700000000\n1\n"));
    // Malformed content is not a tombstone
    try std.testing.expect(!isTombstoneContent(""));
    try std.testing.expect(!isTombstoneContent(VALID_HASH));
    try std.testing.expect(!isTombstoneContent(VALID_HASH ++ "\n123\n1700000000"));
    try std.testing.expect(!isTombstoneContent(VALID_HASH ++ "\n123\n1700000000\nabc\n"));
    // Negative deleted timestamp is not a tombstone
    try std.testing.expect(!isTombstoneContent(VALID_HASH ++ "\n123\n1700000000\n-5\n"));
}
