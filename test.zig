const std = @import("std");
const main = @import("main.zig");

const isValidBucketName = main.isValidBucketName;
const isValidKey = main.isValidKey;
const parseRange = main.parseRange;
const hasQuery = main.hasQuery;
const getQueryParam = main.getQueryParam;
const uriEncode = main.uriEncode;
const sortQueryString = main.sortQueryString;
const xmlEscape = main.xmlEscape;
const SigV4 = main.SigV4;

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
    try std.testing.expect(isValidBucketName("MyBucket"));
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
