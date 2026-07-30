const std = @import("std");

// 252 = SigV4 k_secret buffer (256) minus the 4-byte "AWS4" prefix.
pub const MAX_KEY_LEN: usize = 252;

pub const Role = enum {
    Admin,
    Reader,
    Writer,
};

pub const Credential = struct {
    access_key: []const u8,
    secret_key: []const u8,
    role: Role,
};

pub fn stringToRole(role_str: []const u8) !Role {
    if (std.mem.eql(u8, role_str, "admin")) return .Admin;
    if (std.mem.eql(u8, role_str, "reader")) return .Reader;
    if (std.mem.eql(u8, role_str, "writer")) return .Writer;
    return error.BadCredentialRole;
}

// Permission model:
//   Admin  : all methods
//   Writer : read + write (GET, HEAD, OPTIONS, PUT, POST, DELETE)
//   Reader : read-only    (GET, HEAD, OPTIONS)
pub fn roleAllowsMethod(role: Role, method: []const u8) bool {
    return switch (role) {
        .Admin => true,
        .Reader => std.mem.eql(u8, method, "GET") or
            std.mem.eql(u8, method, "HEAD") or
            std.mem.eql(u8, method, "OPTIONS"),
        .Writer => std.mem.eql(u8, method, "GET") or
            std.mem.eql(u8, method, "HEAD") or
            std.mem.eql(u8, method, "OPTIONS") or
            std.mem.eql(u8, method, "PUT") or
            std.mem.eql(u8, method, "POST") or
            std.mem.eql(u8, method, "DELETE"),
    };
}

// Parse a single credential string: "role:access_key:secret_key".
// Note: secret_key cannot contain ':'.
pub fn parseCredential(cred_str: []const u8) !Credential {
    var itr = std.mem.splitScalar(u8, cred_str, ':');

    const role_str = itr.next() orelse return error.BadCredentialFormat;
    const access_key = itr.next() orelse return error.BadCredentialFormat;
    const secret_key = itr.next() orelse return error.BadCredentialFormat;

    if (itr.next() != null) return error.BadCredentialFormat;

    if (role_str.len == 0 or access_key.len == 0 or secret_key.len == 0)
        return error.BadCredentialFormat;

    if (access_key.len > MAX_KEY_LEN or secret_key.len > MAX_KEY_LEN)
        return error.CredentialKeyTooLong;

    return Credential{
        .role = try stringToRole(role_str),
        .access_key = access_key,
        .secret_key = secret_key,
    };
}

pub fn parseCredentials(allocator: std.mem.Allocator, input: []const u8) ![]Credential {
    if (input.len == 0) return error.BadCredentialInputFormat;

    var credentials: std.ArrayListUnmanaged(Credential) = .empty;
    errdefer credentials.deinit(allocator);

    var itr = std.mem.splitScalar(u8, input, ',');
    while (itr.next()) |record| {
        if (record.len == 0) return error.BadCredentialInputFormat;
        const pc = try parseCredential(record);
        try credentials.append(allocator, pc);
    }

    if (credentials.items.len == 0) return error.BadCredentialInputFormat;

    return credentials.toOwnedSlice(allocator);
}
