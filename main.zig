const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const MAX_HEADER_SIZE = 8 * 1024;
const MAX_BODY_SIZE = 5 * 1024 * 1024 * 1024;
const MAX_KEY_LENGTH = 1024;
const MAX_BUCKET_LENGTH = 63;
const MAX_CONNECTIONS = 1024;

// Distributed mode constants
const CHUNK_SIZE = 4 * 1024 * 1024; // 4MB chunks for large files
const MAX_PEERS = 100;
const GOSSIP_INTERVAL_MS = 30_000;
const REPLICATION_TARGET = 3;

const ERROR_403 = "HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nDenied";

// ============================================================================
// DISTRIBUTED TYPES
// ============================================================================

const ContentHash = [20]u8; // 160-bit truncated BLAKE3
const NodeId = [20]u8; // 160-bit node identifier

/// Format bytes as lowercase hex string
fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Content-Addressed Store - stores objects by their hash
const CAS = struct {
    data_dir: []const u8,

    const Blake3 = std.crypto.hash.Blake3;

    /// Store data and return its content hash (deduplicates automatically)
    pub fn store(self: *const CAS, allocator: Allocator, data: []const u8) !ContentHash {
        var hasher = Blake3.init(.{});
        hasher.update(data);
        var full_hash: [32]u8 = undefined;
        hasher.final(&full_hash);

        const hash: ContentHash = full_hash[0..20].*;
        const path = try self.hashToPath(allocator, hash);
        defer allocator.free(path);

        // Check if already exists (deduplication)
        if (std.fs.cwd().access(path, .{})) |_| {
            return hash;
        } else |_| {}

        // Create parent directory (.cas/xx/)
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);

        return hash;
    }

    /// Retrieve data by content hash
    pub fn retrieve(self: *const CAS, allocator: Allocator, hash: ContentHash) ![]const u8 {
        const path = try self.hashToPath(allocator, hash);
        defer allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{}) catch return error.NotFound;
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        const bytes_read = try file.readAll(data);
        return data[0..bytes_read];
    }

    /// Check if content exists locally
    pub fn exists(self: *const CAS, allocator: Allocator, hash: ContentHash) bool {
        const path = self.hashToPath(allocator, hash) catch return false;
        defer allocator.free(path);
        return std.fs.cwd().access(path, .{}) != error.FileNotFound;
    }

    /// Convert hash to filesystem path: .cas/xx/xxxx....blob
    fn hashToPath(self: *const CAS, allocator: Allocator, hash: ContentHash) ![]const u8 {
        var hex: [40]u8 = undefined;
        bytesToHex(&hash, &hex);
        return std.fs.path.join(allocator, &.{ self.data_dir, ".cas", hex[0..2], hex[2..] ++ ".blob" });
    }

    /// Compute hash without storing
    pub fn computeHash(data: []const u8) ContentHash {
        var hasher = Blake3.init(.{});
        hasher.update(data);
        var full_hash: [32]u8 = undefined;
        hasher.final(&full_hash);
        return full_hash[0..20].*;
    }
};

/// Metadata Index - maps S3 paths to content hashes
const MetaIndex = struct {
    data_dir: []const u8,

    const ObjectMeta = struct {
        hash: ContentHash,
        size: u64,
        chunks: []ContentHash,
        created: i64,
        replicas: u8,
    };

    /// Store metadata for an S3 object
    pub fn put(self: *const MetaIndex, allocator: Allocator, bucket: []const u8, key: []const u8, hash: ContentHash, size: u64) !void {
        const path = try self.metaPath(allocator, bucket, key);
        defer allocator.free(path);

        // Create parent directories
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Simple format: hex_hash\nsize\ncreated_timestamp
        var hash_hex: [40]u8 = undefined;
        bytesToHex(&hash, &hash_hex);
        const created = std.time.timestamp();

        var buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "{s}\n{d}\n{d}\n", .{ hash_hex, size, created }) catch unreachable;
        try file.writeAll(content);
    }

    /// Get metadata for an S3 object
    pub fn get(self: *const MetaIndex, allocator: Allocator, bucket: []const u8, key: []const u8) !?struct { hash: ContentHash, size: u64 } {
        const path = try self.metaPath(allocator, bucket, key);
        defer allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        var buf: [128]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return null;
        const content = buf[0..bytes_read];

        // Parse: hex_hash\nsize\n...
        var lines = std.mem.splitScalar(u8, content, '\n');
        const hash_hex = lines.next() orelse return null;
        const size_str = lines.next() orelse return null;

        if (hash_hex.len != 40) return null;
        var hash: ContentHash = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch return null;

        const size = std.fmt.parseInt(u64, size_str, 10) catch return null;

        return .{ .hash = hash, .size = size };
    }

    /// Delete metadata for an S3 object
    pub fn delete(self: *const MetaIndex, allocator: Allocator, bucket: []const u8, key: []const u8) void {
        const path = self.metaPath(allocator, bucket, key) catch return;
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }

    fn metaPath(self: *const MetaIndex, allocator: Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
        const key_with_ext = try std.fmt.allocPrint(allocator, "{s}.meta", .{key});
        defer allocator.free(key_with_ext);
        return std.fs.path.join(allocator, &.{ self.data_dir, ".index", bucket, key_with_ext });
    }
};

/// Peer information for DHT
const PeerInfo = struct {
    id: NodeId,
    address: net.Address,
    last_seen: i64,
    content_count: u32,
};

/// Full Kademlia DHT implementation
/// XOR metric, 160 k-buckets, iterative lookup
const Kademlia = struct {
    const K = 20; // Bucket size (replication parameter)
    const ALPHA = 3; // Concurrency parameter for lookups
    const ID_BITS = 160; // 20 bytes * 8 bits

    self_id: NodeId,
    buckets: [ID_BITS]KBucket,
    providers: std.AutoHashMap(ContentHash, std.ArrayListUnmanaged(NodeId)),
    allocator: Allocator,

    /// A single k-bucket holding up to K peers
    const KBucket = struct {
        peers: [K]?PeerInfo = [_]?PeerInfo{null} ** K,
        count: usize = 0,
        last_updated: i64 = 0,

        /// Add peer to bucket (LRU eviction if full)
        fn add(self: *KBucket, peer: PeerInfo) void {
            // Check if already exists, update if so
            for (&self.peers) |*slot| {
                if (slot.*) |*p| {
                    if (std.mem.eql(u8, &p.id, &peer.id)) {
                        p.* = peer;
                        self.last_updated = std.time.timestamp();
                        return;
                    }
                }
            }

            // Add to first empty slot
            if (self.count < K) {
                for (&self.peers) |*slot| {
                    if (slot.* == null) {
                        slot.* = peer;
                        self.count += 1;
                        self.last_updated = std.time.timestamp();
                        return;
                    }
                }
            }

            // Bucket full - replace oldest (LRU eviction)
            var oldest_idx: usize = 0;
            var oldest_time: i64 = std.math.maxInt(i64);
            for (self.peers, 0..) |slot, i| {
                if (slot) |p| {
                    if (p.last_seen < oldest_time) {
                        oldest_time = p.last_seen;
                        oldest_idx = i;
                    }
                }
            }
            self.peers[oldest_idx] = peer;
            self.last_updated = std.time.timestamp();
        }

        /// Remove peer from bucket
        fn remove(self: *KBucket, id: NodeId) void {
            for (&self.peers) |*slot| {
                if (slot.*) |p| {
                    if (std.mem.eql(u8, &p.id, &id)) {
                        slot.* = null;
                        self.count -= 1;
                        return;
                    }
                }
            }
        }

        /// Get all peers in bucket
        fn getPeers(self: *const KBucket, out: []PeerInfo) usize {
            var count: usize = 0;
            for (self.peers) |slot| {
                if (slot) |p| {
                    if (count < out.len) {
                        out[count] = p;
                        count += 1;
                    }
                }
            }
            return count;
        }
    };

    pub fn init(allocator: Allocator, self_id: NodeId) Kademlia {
        return .{
            .self_id = self_id,
            .buckets = [_]KBucket{.{}} ** ID_BITS,
            .providers = std.AutoHashMap(ContentHash, std.ArrayListUnmanaged(NodeId)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Kademlia) void {
        var it = self.providers.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.providers.deinit();
    }

    /// XOR distance between two node IDs
    pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
        var result: NodeId = undefined;
        for (0..20) |i| {
            result[i] = a[i] ^ b[i];
        }
        return result;
    }

    /// Find the bucket index for a given node ID (based on XOR distance from self)
    fn bucketIndex(self: *const Kademlia, id: NodeId) usize {
        const dist = xorDistance(self.self_id, id);
        // Find highest bit set (leading zeros of XOR)
        for (0..20) |byte_idx| {
            if (dist[byte_idx] != 0) {
                // Count leading zeros in this byte
                const lz = @clz(dist[byte_idx]);
                return ID_BITS - 1 - (byte_idx * 8 + lz);
            }
        }
        return 0; // Same ID (shouldn't happen)
    }

    /// Add or update a peer in the routing table
    pub fn addPeer(self: *Kademlia, peer: PeerInfo) void {
        if (std.mem.eql(u8, &peer.id, &self.self_id)) return; // Don't add self
        const idx = self.bucketIndex(peer.id);
        self.buckets[idx].add(peer);
    }

    /// Remove a peer from the routing table
    pub fn removePeer(self: *Kademlia, id: NodeId) void {
        const idx = self.bucketIndex(id);
        self.buckets[idx].remove(id);
    }

    /// Find the K closest peers to a target ID
    pub fn findClosest(self: *Kademlia, target: NodeId, out: []PeerInfo) usize {
        const DistPeer = struct {
            peer: PeerInfo,
            dist: NodeId,

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return compareDist(a.dist, b.dist) == .lt;
            }
        };

        var candidates: [ID_BITS * K]DistPeer = undefined;
        var count: usize = 0;

        // Collect all peers with their distances
        for (&self.buckets) |*bucket| {
            var peers: [K]PeerInfo = undefined;
            const n = bucket.getPeers(&peers);
            for (peers[0..n]) |peer| {
                if (count < candidates.len) {
                    candidates[count] = .{
                        .peer = peer,
                        .dist = xorDistance(peer.id, target),
                    };
                    count += 1;
                }
            }
        }

        // Sort by distance
        std.mem.sort(DistPeer, candidates[0..count], {}, DistPeer.lessThan);

        // Copy to output
        const result_count = @min(count, out.len);
        for (0..result_count) |i| {
            out[i] = candidates[i].peer;
        }
        return result_count;
    }

    /// Compare two XOR distances (returns ordering)
    fn compareDist(a: NodeId, b: NodeId) std.math.Order {
        for (0..20) |i| {
            if (a[i] < b[i]) return .lt;
            if (a[i] > b[i]) return .gt;
        }
        return .eq;
    }

    /// Announce that we have content (store provider record)
    pub fn announce(self: *Kademlia, hash: ContentHash) !void {
        const result = try self.providers.getOrPut(hash);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        // Add self as provider
        for (result.value_ptr.items) |id| {
            if (std.mem.eql(u8, &id, &self.self_id)) return;
        }
        try result.value_ptr.append(self.allocator, self.self_id);
    }

    /// Record that a peer has content
    pub fn addProvider(self: *Kademlia, hash: ContentHash, provider: NodeId) !void {
        const result = try self.providers.getOrPut(hash);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        for (result.value_ptr.items) |id| {
            if (std.mem.eql(u8, &id, &provider)) return;
        }
        try result.value_ptr.append(self.allocator, provider);
    }

    /// Find nodes that have content
    pub fn findProviders(self: *Kademlia, hash: ContentHash) []NodeId {
        if (self.providers.get(hash)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// Get total peer count across all buckets
    pub fn peerCount(self: *const Kademlia) usize {
        var count: usize = 0;
        for (self.buckets) |bucket| {
            count += bucket.count;
        }
        return count;
    }

    /// Get random peers for gossip
    pub fn getRandomPeers(self: *Kademlia, out: []PeerInfo, rng: std.Random) usize {
        var all_peers: [MAX_PEERS]PeerInfo = undefined;
        var total: usize = 0;

        for (&self.buckets) |*bucket| {
            var peers: [K]PeerInfo = undefined;
            const n = bucket.getPeers(&peers);
            for (peers[0..n]) |peer| {
                if (total < all_peers.len) {
                    all_peers[total] = peer;
                    total += 1;
                }
            }
        }

        if (total == 0) return 0;

        // Fisher-Yates shuffle and take first N
        const count = @min(out.len, total);
        for (0..count) |i| {
            const j = i + rng.uintLessThan(usize, total - i);
            const tmp = all_peers[i];
            all_peers[i] = all_peers[j];
            all_peers[j] = tmp;
            out[i] = all_peers[i];
        }
        return count;
    }

    /// Generate a random node ID in a specific bucket's range (for refresh)
    pub fn randomIdInBucket(self: *const Kademlia, bucket_idx: usize, rng: std.Random) NodeId {
        var id = self.self_id;
        // Flip the bit at bucket_idx position
        const byte_idx = (ID_BITS - 1 - bucket_idx) / 8;
        const bit_idx: u3 = @intCast(7 - ((ID_BITS - 1 - bucket_idx) % 8));
        id[byte_idx] ^= @as(u8, 1) << bit_idx;
        // Randomize lower bits
        for ((byte_idx + 1)..20) |i| {
            id[i] = rng.int(u8);
        }
        return id;
    }
};

/// Replication manager for background replication
const ReplicationManager = struct {
    pending: std.ArrayListUnmanaged(ContentHash),
    target_replicas: u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ReplicationManager {
        return .{
            .pending = .empty,
            .target_replicas = REPLICATION_TARGET,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReplicationManager) void {
        self.pending.deinit(self.allocator);
    }

    /// Schedule content for replication
    pub fn schedule(self: *ReplicationManager, hash: ContentHash) !void {
        // Avoid duplicates
        for (self.pending.items) |h| {
            if (std.mem.eql(u8, &h, &hash)) return;
        }
        try self.pending.append(self.allocator, hash);
    }
};

/// Distributed mode configuration
const DistributedConfig = struct {
    enabled: bool = false,
    node_id: NodeId = undefined,
    bootstrap_peers: []const []const u8 = &.{},
    target_replicas: u8 = REPLICATION_TARGET,
    http_port: u16 = 9000,
};

/// Extended context for distributed mode
const DistributedContext = struct {
    config: DistributedConfig,
    cas: CAS,
    meta_index: MetaIndex,
    kademlia: Kademlia,
    replication: ReplicationManager,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data_dir: []const u8, config: DistributedConfig) DistributedContext {
        return .{
            .config = config,
            .cas = .{ .data_dir = data_dir },
            .meta_index = .{ .data_dir = data_dir },
            .kademlia = Kademlia.init(allocator, config.node_id),
            .replication = ReplicationManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DistributedContext) void {
        self.kademlia.deinit();
        self.replication.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments
    var distributed_enabled = false;
    var bootstrap_peers: [10][]const u8 = undefined;
    var bootstrap_count: usize = 0;
    var port: u16 = 9000;

    var args = std.process.args();
    _ = args.skip(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--distributed") or std.mem.eql(u8, arg, "-d")) {
            distributed_enabled = true;
        } else if (std.mem.startsWith(u8, arg, "--bootstrap=")) {
            const peers_str = arg[12..];
            var it = std.mem.splitScalar(u8, peers_str, ',');
            while (it.next()) |peer| {
                if (bootstrap_count < bootstrap_peers.len) {
                    bootstrap_peers[bootstrap_count] = peer;
                    bootstrap_count += 1;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg[7..], 10) catch 9000;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\zs3 - Distributed S3-compatible storage
                \\
                \\Usage: zs3 [OPTIONS]
                \\
                \\Options:
                \\  --distributed, -d     Enable distributed mode (peer-to-peer)
                \\  --bootstrap=PEERS     Comma-separated bootstrap peer addresses
                \\  --port=PORT           HTTP port (default: 9000)
                \\  --help, -h            Show this help
                \\
                \\Examples:
                \\  zs3                                    # Standalone mode
                \\  zs3 --distributed                      # Distributed, auto-discover via mDNS
                \\  zs3 -d --bootstrap=10.0.0.1:9000       # Distributed with bootstrap peer
                \\
            , .{});
            return;
        }
    }

    std.fs.cwd().makeDir("data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Initialize distributed context if enabled
    var dist_ctx: ?DistributedContext = null;
    defer if (dist_ctx) |*d| d.deinit();

    if (distributed_enabled) {
        // Generate or load node ID
        const node_id = try getOrCreateNodeId(allocator, "data");
        const config = DistributedConfig{
            .enabled = true,
            .node_id = node_id,
            .http_port = port,
        };
        dist_ctx = DistributedContext.init(allocator, "data", config);

        var id_hex: [40]u8 = undefined;
        bytesToHex(&node_id, &id_hex);
        std.log.info("Distributed mode enabled. Node ID: {s}", .{id_hex});
        std.log.info("Known peers: {d}", .{dist_ctx.?.kademlia.peerCount()});

        // Create .cas and .index directories
        std.fs.cwd().makePath("data/.cas") catch {};
        std.fs.cwd().makePath("data/.index") catch {};
    }

    const address = net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    if (distributed_enabled) {
        std.log.info("dS3 server listening on http://0.0.0.0:{d}", .{port});
    } else {
        std.log.info("S3 server listening on http://0.0.0.0:{d}", .{port});
    }

    var ctx = S3Context{
        .allocator = allocator,
        .data_dir = "data",
        .access_key = "minioadmin",
        .secret_key = "minioadmin",
        .distributed = if (dist_ctx != null) &dist_ctx.? else null,
    };

    if (builtin.os.tag == .linux) {
        try eventLoopEpoll(allocator, &ctx, &server);
    } else if (builtin.os.tag == .macos) {
        try eventLoopKqueue(allocator, &ctx, &server);
    }
}

/// Generate or load persistent node ID
fn getOrCreateNodeId(allocator: Allocator, data_dir: []const u8) !NodeId {
    const id_path = try std.fs.path.join(allocator, &.{ data_dir, ".node_id" });
    defer allocator.free(id_path);

    // Try to load existing ID
    if (std.fs.cwd().openFile(id_path, .{})) |file| {
        defer file.close();
        var id: NodeId = undefined;
        const n = file.readAll(&id) catch return error.InvalidNodeId;
        if (n == 20) return id;
    } else |_| {}

    // Generate new random ID
    var id: NodeId = undefined;
    std.crypto.random.bytes(&id);

    // Save it
    if (std.fs.cwd().createFile(id_path, .{})) |file| {
        defer file.close();
        file.writeAll(&id) catch {};
    } else |_| {}

    return id;
}

fn setNonBlocking(fd: posix.fd_t) void {
    const O_NONBLOCK: usize = if (builtin.os.tag == .macos) 0x0004 else 0x800;
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) catch {};
}


fn eventLoopEpoll(allocator: Allocator, ctx: *const S3Context, server: *net.Server) !void {
    const linux = std.os.linux;
    const epfd = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (@as(isize, @bitCast(epfd)) < 0) return error.EpollCreate;
    defer _ = linux.close(@intCast(epfd));

    setNonBlocking(server.stream.handle);
    var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = server.stream.handle } };
    if (@as(isize, @bitCast(linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_ADD, server.stream.handle, &ev))) < 0)
        return error.EpollCtl;

    var events: [MAX_CONNECTIONS]linux.epoll_event = undefined;

    while (true) {
        const n = linux.epoll_wait(@intCast(epfd), &events, MAX_CONNECTIONS, -1);
        if (@as(isize, @bitCast(n)) < 0) continue;

        for (events[0..n]) |event| {
            if (event.data.fd == server.stream.handle) {
                while (true) {
                    const conn = server.accept() catch break;
                    var cev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .fd = conn.stream.handle } };
                    _ = linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_ADD, conn.stream.handle, &cev);
                }
            } else {
                const stream = net.Stream{ .handle = event.data.fd };
                handleConnectionWithStream(allocator, ctx, stream) catch {};
                _ = linux.epoll_ctl(@intCast(epfd), linux.EPOLL.CTL_DEL, event.data.fd, null);
                stream.close();
            }
        }
    }
}

fn eventLoopKqueue(allocator: Allocator, ctx: *const S3Context, server: *net.Server) !void {
    @setRuntimeSafety(false);
    const c = std.c;
    const kq = c.kqueue();
    if (kq < 0) return error.Kqueue;
    defer _ = c.close(kq);

    const server_fd = server.stream.handle;
    setNonBlocking(server_fd);

    var changes: [1]c.Kevent = .{.{
        .ident = @intCast(server_fd),
        .filter = c.EVFILT.READ,
        .flags = c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    var events: [MAX_CONNECTIONS]c.Kevent = undefined;
    if (c.kevent(kq, &changes, 1, &events, 0, null) < 0) return error.Kevent;

    while (true) {
        const nev = c.kevent(kq, &changes, 0, &events, MAX_CONNECTIONS, null);
        if (nev < 0) continue;

        for (events[0..@intCast(nev)]) |ev| {
            const fd: posix.fd_t = @intCast(ev.ident);
            if (fd == server_fd) {
                while (true) {
                    const conn = server.accept() catch break;
                    var add: [1]c.Kevent = .{.{
                        .ident = @intCast(conn.stream.handle),
                        .filter = c.EVFILT.READ,
                        .flags = c.EV.ADD | c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    }};
                    const r = c.kevent(kq, &add, 1, &events, 0, null);
                    if (r < 0) std.log.err("kevent add failed", .{});
                }
            } else {
                setNonBlocking(fd);
                const stream = net.Stream{ .handle = fd };
                const keep = handleConnectionWithStream(allocator, ctx, stream) catch false;
                if (keep) {
                    var add: [1]c.Kevent = .{.{
                        .ident = @intCast(fd),
                        .filter = c.EVFILT.READ,
                        .flags = c.EV.ADD | c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    }};
                    _ = c.kevent(kq, &add, 1, &events, 0, null);
                } else {
                    stream.close();
                }
            }
        }
    }
}

const S3Context = struct {
    allocator: Allocator,
    data_dir: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    distributed: ?*DistributedContext = null, // Optional distributed mode

    fn bucketPath(self: *const S3Context, allocator: Allocator, bucket: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket });
    }

    fn objectPath(self: *const S3Context, allocator: Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket, key });
    }
};

const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var lower_buf: [128]u8 = undefined;
        const lower_name = std.ascii.lowerString(&lower_buf, name);
        return self.headers.get(lower_name);
    }

    fn deinit(self: *Request) void {
        self.headers.deinit();
    }
};

const Response = struct {
    status: u16 = 200,
    status_text: []const u8 = "OK",
    headers: std.ArrayListUnmanaged(Header) = .empty,
    body: []const u8 = "",
    send_file: ?std.fs.File = null,
    send_file_size: usize = 0,
    send_file_offset: usize = 0,
    allocator: Allocator,

    const Header = struct { name: []const u8, value: []const u8 };

    fn init(allocator: Allocator) Response {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        if (self.send_file) |f| f.close();
    }

    fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.append(self.allocator, .{ .name = name, .value = value }) catch {};
    }

    fn ok(self: *Response) void {
        self.status = 200;
        self.status_text = "OK";
    }

    fn noContent(self: *Response) void {
        self.status = 204;
        self.status_text = "No Content";
    }

    fn setXmlBody(self: *Response, body: []const u8) void {
        self.setHeader("Content-Type", "application/xml");
        self.body = body;
    }

    fn setSendFile(self: *Response, file: std.fs.File, size: usize, offset: usize) void {
        self.send_file = file;
        self.send_file_size = size;
        self.send_file_offset = offset;
    }

    fn write(self: *Response, stream: net.Stream) !void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        const content_len = if (self.send_file != null) self.send_file_size else self.body.len;
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status, self.status_text });
        try w.print("Content-Length: {d}\r\nConnection: close\r\n", .{content_len});

        for (self.headers.items) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll("\r\n");

        try stream.writeAll(fbs.getWritten());

        if (self.send_file) |file| {
            // Use sendfile for zero-copy transfer
            if (builtin.os.tag == .macos) {
                var offset: i64 = @intCast(self.send_file_offset);
                var len: i64 = @intCast(self.send_file_size);
                while (len > 0) {
                    const rc = std.c.sendfile(file.handle, stream.handle, offset, &len, null, 0);
                    if (rc == -1) break;
                    offset += len;
                    len = @intCast(self.send_file_size - @as(usize, @intCast(offset - @as(i64, @intCast(self.send_file_offset)))));
                }
            } else if (builtin.os.tag == .linux) {
                var offset: i64 = @intCast(self.send_file_offset);
                var remaining: usize = self.send_file_size;
                while (remaining > 0) {
                    const rc = std.os.linux.sendfile(stream.handle, file.handle, &offset, remaining);
                    const sent = @as(isize, @bitCast(rc));
                    if (sent <= 0) break;
                    remaining -= @intCast(sent);
                }
            }
        } else if (self.body.len > 0) {
            try stream.writeAll(self.body);
        }
    }
};

fn parseRequestFromBuf(allocator: Allocator, data: []const u8, stream: net.Stream) !Request {
    const total_read = data.len;
    const line_end = std.mem.indexOf(u8, data, "\r\n") orelse return error.InvalidRequest;
    const request_line = data[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const full_path = parts.next() orelse return error.InvalidRequest;
    var path: []const u8 = full_path;
    var query: []const u8 = "";
    if (std.mem.indexOf(u8, full_path, "?")) |q_idx| {
        path = full_path[0..q_idx];
        query = full_path[q_idx + 1 ..];
    }

    var headers = std.StringHashMap([]const u8).init(allocator);
    var header_section = data[line_end + 2 ..];
    const header_end = std.mem.indexOf(u8, header_section, "\r\n\r\n") orelse header_section.len;
    header_section = header_section[0..header_end];

    var header_lines = std.mem.splitSequence(u8, header_section, "\r\n");
    while (header_lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        var name_buf: [128]u8 = undefined;
        const name = std.ascii.lowerString(&name_buf, std.mem.trim(u8, line[0..colon], " "));
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
    }

    var body: []const u8 = "";
    if (headers.get("content-length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
        if (content_length > MAX_BODY_SIZE) return error.PayloadTooLarge;
        if (content_length > 0) {
            const body_start_idx = std.mem.indexOf(u8, data, "\r\n\r\n").? + 4;
            const already_read = total_read - body_start_idx;

            const body_buf = try allocator.alloc(u8, content_length);
            if (already_read > 0) {
                @memcpy(body_buf[0..already_read], data[body_start_idx..total_read]);
            }

            var remaining = content_length - already_read;
            var offset = already_read;
            while (remaining > 0) {
                const n = stream.read(body_buf[offset..]) catch |err| return err;
                if (n == 0) break;
                offset += n;
                remaining -= n;
            }
            body = body_buf;
        }
    }

    return Request{
        .method = try allocator.dupe(u8, method),
        .path = try allocator.dupe(u8, path),
        .query = try allocator.dupe(u8, query),
        .headers = headers,
        .body = body,
    };
}

fn hasAuth(data: []const u8) bool {
    @setRuntimeSafety(false);
    if (data.len < 14) return false;
    const end = data.len - 13;
    const ptr = data.ptr;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        const p = ptr + i;
        if ((p[0] == 'A' or p[0] == 'a') and
            (p[1] == 'u' or p[1] == 'U') and
            p[2] == 't' and p[3] == 'h' and p[4] == 'o' and
            p[5] == 'r' and p[6] == 'i' and p[7] == 'z' and
            p[8] == 'a' and p[9] == 't' and p[10] == 'i' and
            p[11] == 'o' and p[12] == 'n' and p[13] == ':')
        {
            return true;
        }
    }
    return false;
}

fn findHeaderEnd(data: []const u8) ?usize {
    @setRuntimeSafety(false);
    if (data.len < 4) return null;
    const end = data.len - 3;
    const ptr = data.ptr;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (ptr[i] == '\r' and ptr[i + 1] == '\n' and ptr[i + 2] == '\r' and ptr[i + 3] == '\n') {
            return i;
        }
    }
    return null;
}

fn handleConnectionWithStream(allocator: Allocator, ctx: *const S3Context, stream: net.Stream) !bool {
    @setRuntimeSafety(false);
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const n = stream.read(buf[total_read..]) catch return false;
        if (n == 0) return false;
        total_read += n;
        if (findHeaderEnd(buf[0..total_read])) |_| break;
    }
    if (total_read == 0) return false;

    const data = buf[0..total_read];

    // Allow peer protocol endpoints without auth
    const is_peer_protocol = if (std.mem.indexOf(u8, data, "/_zs3/")) |_| true else false;
    if (!is_peer_protocol and !hasAuth(data)) {
        _ = stream.write(ERROR_403) catch return false;
        return true;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req = parseRequestFromBuf(alloc, data, stream) catch return false;
    var res = Response.init(alloc);

    route(ctx, alloc, &req, &res) catch |err| {
        std.log.err("Handler error: {}", .{err});
        sendError(&res, 500, "InternalError", "Internal server error");
    };

    res.write(stream) catch return false;
    return false;
}

pub fn isValidBucketName(name: []const u8) bool {
    if (name.len < 3 or name.len > MAX_BUCKET_LENGTH) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return false;
    }
    if (name[0] == '-' or name[0] == '.' or name[name.len - 1] == '-' or name[name.len - 1] == '.') return false;
    return true;
}

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY_LENGTH) return false;
    for (key) |c| {
        if (c < 32 or c == 127) return false; // no control chars
    }
    return true;
}

fn route(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response) !void {
    var path = req.path;
    if (path.len > 0 and path[0] == '/') path = path[1..];

    // Handle peer protocol (no auth required for peer-to-peer)
    if (std.mem.startsWith(u8, path, "_zs3/")) {
        if (ctx.distributed) |dist| {
            try handlePeerProtocol(ctx, dist, allocator, req, res, path[5..]);
        } else {
            sendError(res, 404, "NotFound", "Distributed mode not enabled");
        }
        return;
    }

    // S3 API requires authentication
    if (!SigV4.verify(ctx, req, allocator)) {
        sendError(res, 403, "AccessDenied", "Invalid credentials");
        return;
    }

    var path_parts = std.mem.splitScalar(u8, path, '/');
    const bucket = path_parts.next() orelse "";
    const key = path_parts.rest();

    if (bucket.len > 0 and !isValidBucketName(bucket)) {
        sendError(res, 400, "InvalidBucketName", "Bucket name is invalid");
        return;
    }
    if (key.len > 0 and !isValidKey(key)) {
        sendError(res, 400, "InvalidKey", "Object key is invalid");
        return;
    }

    // In distributed mode, use CAS for object storage
    if (ctx.distributed != null) {
        if (key.len > 0) {
            if (std.mem.eql(u8, req.method, "PUT") and !hasQuery(req.query, "uploadId")) {
                try handleDistributedPut(ctx, allocator, req, res, bucket, key);
                return;
            } else if (std.mem.eql(u8, req.method, "GET")) {
                try handleDistributedGet(ctx, allocator, req, res, bucket, key);
                return;
            } else if (std.mem.eql(u8, req.method, "DELETE") and !hasQuery(req.query, "uploadId")) {
                try handleDistributedDelete(ctx, allocator, res, bucket, key);
                return;
            } else if (std.mem.eql(u8, req.method, "HEAD")) {
                try handleDistributedHead(ctx, allocator, res, bucket, key);
                return;
            }
        } else if (bucket.len > 0 and std.mem.eql(u8, req.method, "GET")) {
            // Distributed LIST objects
            try handleDistributedList(ctx, allocator, req, res, bucket);
            return;
        }
    }

    // Standard S3 routing (standalone mode or bucket operations)
    if (std.mem.eql(u8, req.method, "GET")) {
        if (bucket.len == 0) {
            try handleListBuckets(ctx, allocator, res);
        } else if (key.len == 0) {
            try handleListObjects(ctx, allocator, req, res, bucket);
        } else {
            try handleGetObject(ctx, allocator, req, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "PUT")) {
        if (key.len == 0) {
            try handleCreateBucket(ctx, allocator, res, bucket);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleUploadPart(ctx, allocator, req, res, bucket, key);
        } else {
            try handlePutObject(ctx, allocator, req, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "DELETE")) {
        if (key.len == 0) {
            try handleDeleteBucket(ctx, allocator, res, bucket);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleAbortMultipart(ctx, allocator, req, res);
        } else {
            try handleDeleteObject(ctx, allocator, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "HEAD")) {
        if (key.len == 0) {
            try handleHeadBucket(ctx, allocator, res, bucket);
        } else {
            try handleHeadObject(ctx, allocator, res, bucket, key);
        }
    } else if (std.mem.eql(u8, req.method, "POST")) {
        if (hasQuery(req.query, "delete")) {
            try handleDeleteObjects(ctx, allocator, req, res, bucket);
        } else if (hasQuery(req.query, "uploads")) {
            try handleInitiateMultipart(ctx, allocator, res, bucket, key);
        } else if (hasQuery(req.query, "uploadId")) {
            try handleCompleteMultipart(ctx, allocator, req, res, bucket, key);
        } else {
            sendError(res, 400, "InvalidRequest", "Unknown POST operation");
        }
    } else {
        sendError(res, 405, "MethodNotAllowed", "Method not allowed");
    }
}

pub const SigV4 = struct {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const Sha256 = std.crypto.hash.sha2.Sha256;

    const ParsedAuth = struct {
        access_key: []const u8,
        date: []const u8,
        region: []const u8,
        service: []const u8,
        signed_headers: []const u8,
        signature: []const u8,
    };

    fn verify(ctx: *const S3Context, req: *const Request, allocator: Allocator) bool {
        const auth_header = req.header("authorization") orelse return false;
        const x_amz_date = req.header("x-amz-date") orelse return false;
        const x_amz_content_sha256 = req.header("x-amz-content-sha256") orelse "UNSIGNED-PAYLOAD";

        const parsed = parseAuthHeader(auth_header) orelse return false;

        if (!std.mem.eql(u8, parsed.access_key, ctx.access_key)) return false;

        const canonical = buildCanonicalRequest(
            allocator,
            req,
            parsed.signed_headers,
            x_amz_content_sha256,
        ) catch return false;
        defer allocator.free(canonical);

        const string_to_sign = buildStringToSign(
            allocator,
            x_amz_date,
            parsed.date,
            parsed.region,
            parsed.service,
            canonical,
        ) catch return false;
        defer allocator.free(string_to_sign);

        const calculated_sig = calculateSignature(
            allocator,
            ctx.secret_key,
            parsed.date,
            parsed.region,
            parsed.service,
            string_to_sign,
        ) catch return false;
        defer allocator.free(calculated_sig);

        return std.mem.eql(u8, calculated_sig, parsed.signature);
    }

    pub fn parseAuthHeader(header: []const u8) ?ParsedAuth {
        if (!std.mem.startsWith(u8, header, "AWS4-HMAC-SHA256 ")) return null;

        var result: ParsedAuth = undefined;

        const cred_start = std.mem.indexOf(u8, header, "Credential=") orelse return null;
        const cred_end = std.mem.indexOfPos(u8, header, cred_start, ",") orelse return null;
        const credential = header[cred_start + 11 .. cred_end];

        var cred_iter = std.mem.splitScalar(u8, credential, '/');
        result.access_key = cred_iter.next() orelse return null;
        result.date = cred_iter.next() orelse return null;
        result.region = cred_iter.next() orelse return null;
        result.service = cred_iter.next() orelse return null;

        const sh_start = std.mem.indexOf(u8, header, "SignedHeaders=") orelse return null;
        const sh_end = std.mem.indexOfPos(u8, header, sh_start, ",") orelse return null;
        result.signed_headers = header[sh_start + 14 .. sh_end];

        const sig_start = std.mem.indexOf(u8, header, "Signature=") orelse return null;
        result.signature = header[sig_start + 10 ..];

        return result;
    }

    fn buildCanonicalRequest(
        allocator: Allocator,
        req: *const Request,
        signed_headers: []const u8,
        payload_hash: []const u8,
    ) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, req.method);
        try result.append(allocator, '\n');

        const canonical_path = if (req.path.len == 0) "/" else req.path;
        const encoded_path = try uriEncode(allocator, canonical_path, false);
        defer allocator.free(encoded_path);
        try result.appendSlice(allocator, encoded_path);
        try result.append(allocator, '\n');

        const sorted_query = try sortQueryString(allocator, req.query);
        defer allocator.free(sorted_query);
        try result.appendSlice(allocator, sorted_query);
        try result.append(allocator, '\n');

        var header_iter = std.mem.splitScalar(u8, signed_headers, ';');
        while (header_iter.next()) |header_name| {
            const value = req.header(header_name) orelse "";
            try result.appendSlice(allocator, header_name);
            try result.append(allocator, ':');
            try result.appendSlice(allocator, std.mem.trim(u8, value, " \t"));
            try result.append(allocator, '\n');
        }
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, signed_headers);
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, payload_hash);

        return result.toOwnedSlice(allocator);
    }

    fn buildStringToSign(
        allocator: Allocator,
        amz_date: []const u8,
        date_stamp: []const u8,
        region: []const u8,
        service: []const u8,
        canonical_request: []const u8,
    ) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "AWS4-HMAC-SHA256\n");
        try result.appendSlice(allocator, amz_date);
        try result.append(allocator, '\n');

        try result.appendSlice(allocator, date_stamp);
        try result.append(allocator, '/');
        try result.appendSlice(allocator, region);
        try result.append(allocator, '/');
        try result.appendSlice(allocator, service);
        try result.appendSlice(allocator, "/aws4_request\n");

        const canonical_hash = hash(canonical_request);
        var hex_buf: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x}", .{canonical_hash}) catch unreachable;
        try result.appendSlice(allocator, &hex_buf);

        return result.toOwnedSlice(allocator);
    }

    fn calculateSignature(
        allocator: Allocator,
        secret_key: []const u8,
        date_stamp: []const u8,
        region: []const u8,
        service: []const u8,
        string_to_sign: []const u8,
    ) ![]const u8 {
        var k_secret_buf: [256]u8 = undefined;
        const k_secret_len = 4 + secret_key.len;
        @memcpy(k_secret_buf[0..4], "AWS4");
        @memcpy(k_secret_buf[4..k_secret_len], secret_key);

        const k_date = hmac(k_secret_buf[0..k_secret_len], date_stamp);
        const k_region = hmac(&k_date, region);
        const k_service = hmac(&k_region, service);
        const k_signing = hmac(&k_service, "aws4_request");
        const sig = hmac(&k_signing, string_to_sign);

        const hex = try allocator.alloc(u8, 64);
        _ = std.fmt.bufPrint(hex, "{x}", .{sig}) catch unreachable;

        return hex;
    }

    pub fn hmac(key: []const u8, msg: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        HmacSha256.create(&out, msg, key);
        return out;
    }

    pub fn hash(data: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        Sha256.hash(data, &out, .{});
        return out;
    }
};

pub fn uriEncode(allocator: Allocator, input: []const u8, encode_slash: bool) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (isUnreserved(c) or (c == '/' and !encode_slash)) {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try result.append(allocator, hex[c >> 4]);
            try result.append(allocator, hex[c & 0x0F]);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

pub fn sortQueryString(allocator: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return try allocator.dupe(u8, "");

    var pairs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pairs.deinit(allocator);

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len > 0) {
            try pairs.append(allocator, pair);
        }
    }

    std.mem.sort([]const u8, pairs.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (pairs.items, 0..) |pair, i| {
        if (i > 0) try result.append(allocator, '&');
        try result.appendSlice(allocator, pair);
    }

    return result.toOwnedSlice(allocator);
}

fn handlePutObject(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    var file = std.fs.cwd().createFile(path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create file");
        return;
    };
    defer file.close();

    file.writeAll(req.body) catch {
        sendError(res, 500, "InternalError", "Cannot write file");
        return;
    };

    // Use fast hash for ETag (wyhash is ~10x faster than SHA256)
    const hash = std.hash.Wyhash.hash(0, req.body);
    var etag_hex: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&etag_hex, "\"{x}\"", .{hash}) catch unreachable;

    res.ok();
    res.setHeader("ETag", &etag_hex);
}

fn handleGetObject(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };
    // File will be closed by Response.deinit()

    const stat = file.stat() catch {
        file.close();
        sendError(res, 500, "InternalError", "Stat failed");
        return;
    };

    if (req.header("range")) |range_header| {
        if (parseRange(range_header, stat.size)) |range| {
            const len = range.end - range.start + 1;

            var range_buf: [64]u8 = undefined;
            const content_range = std.fmt.bufPrint(&range_buf, "bytes {d}-{d}/{d}", .{ range.start, range.end, stat.size }) catch unreachable;

            res.status = 206;
            res.status_text = "Partial Content";
            res.setHeader("Content-Range", content_range);
            res.setHeader("Accept-Ranges", "bytes");
            res.setSendFile(file, len, range.start);
            return;
        }
    }

    res.ok();
    res.setHeader("Accept-Ranges", "bytes");
    res.setSendFile(file, stat.size, 0);
}

fn handleDeleteObject(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    deleteObjectInternal(ctx, allocator, bucket, path);
    res.noContent();
}

fn deleteObjectInternal(ctx: *const S3Context, allocator: Allocator, bucket: []const u8, path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("delete failed: {}", .{err}),
    };

    // Clean up empty parent directories up to bucket level
    const bucket_path = ctx.bucketPath(allocator, bucket) catch return;
    defer allocator.free(bucket_path);

    var dir_path = std.fs.path.dirname(path);
    while (dir_path) |dp| {
        if (dp.len <= bucket_path.len) break;
        std.fs.cwd().deleteDir(dp) catch break;
        dir_path = std.fs.path.dirname(dp);
    }
}

fn handleDeleteObjects(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8) !void {
    // Parse XML body: <Delete><Object><Key>...</Key></Object>...</Delete>
    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");

    // Simple XML parsing - find all <Key>...</Key> pairs
    var body = req.body;

    while (std.mem.indexOf(u8, body, "<Key>")) |start| {
        const key_start = start + 5;
        const end = std.mem.indexOf(u8, body[key_start..], "</Key>") orelse break;
        const key = body[key_start .. key_start + end];

        if (key.len > 0 and isValidKey(key)) {
            // In distributed mode, also delete from metadata index
            if (ctx.distributed) |dist| {
                dist.meta_index.delete(allocator, bucket, key);
            }

            const path = ctx.objectPath(allocator, bucket, key) catch continue;
            defer allocator.free(path);

            deleteObjectInternal(ctx, allocator, bucket, path);

            try xml.appendSlice(allocator, "<Deleted><Key>");
            try xml.appendSlice(allocator, key);
            try xml.appendSlice(allocator, "</Key></Deleted>");
        }

        body = body[key_start + end + 6 ..];
    }

    try xml.appendSlice(allocator, "</DeleteResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleHeadObject(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        sendError(res, 500, "InternalError", "Stat failed");
        return;
    };

    var buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&buf, "{d}", .{stat.size}) catch unreachable;

    res.ok();
    res.setHeader("Content-Length", len_str);
    res.setHeader("Accept-Ranges", "bytes");
}

fn handleListObjects(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8) !void {
    const prefix = getQueryParam(req.query, "prefix") orelse "";
    const max_keys_str = getQueryParam(req.query, "max-keys") orelse "1000";
    const max_keys = std.fmt.parseInt(usize, max_keys_str, 10) catch 1000;
    const delimiter = getQueryParam(req.query, "delimiter");
    const continuation = getQueryParam(req.query, "continuation-token");

    const bucket_path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(bucket_path);

    var dir = std.fs.cwd().openDir(bucket_path, .{ .iterate = true }) catch {
        sendError(res, 404, "NoSuchBucket", "Bucket not found");
        return;
    };
    defer dir.close();

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Name>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Name><Prefix>");
    try xml.appendSlice(allocator, prefix);
    try xml.appendSlice(allocator, "</Prefix><MaxKeys>");
    try xml.appendSlice(allocator, max_keys_str);
    try xml.appendSlice(allocator, "</MaxKeys>");

    var keys: std.ArrayListUnmanaged(KeyInfo) = .empty;
    defer keys.deinit(allocator);

    try collectKeys(allocator, bucket_path, "", prefix, &keys);

    std.mem.sort(KeyInfo, keys.items, {}, struct {
        fn lessThan(_: void, a: KeyInfo, b: KeyInfo) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    var start_idx: usize = 0;
    if (continuation) |cont| {
        for (keys.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.key, cont)) {
                start_idx = i + 1;
                break;
            }
        }
    }

    var common_prefixes = std.StringHashMap(void).init(allocator);
    defer common_prefixes.deinit();

    var count: usize = 0;
    var is_truncated = false;
    var next_token: ?[]const u8 = null;

    for (keys.items[start_idx..]) |item| {
        if (count >= max_keys) {
            is_truncated = true;
            next_token = item.key;
            break;
        }

        if (delimiter) |delim| {
            const after_prefix = if (prefix.len > 0 and std.mem.startsWith(u8, item.key, prefix))
                item.key[prefix.len..]
            else
                item.key;

            if (std.mem.indexOf(u8, after_prefix, delim)) |delim_idx| {
                const common_prefix = item.key[0 .. prefix.len + delim_idx + 1];
                if (!common_prefixes.contains(common_prefix)) {
                    try common_prefixes.put(common_prefix, {});
                    try xml.appendSlice(allocator, "<CommonPrefixes><Prefix>");
                    try xml.appendSlice(allocator, common_prefix);
                    try xml.appendSlice(allocator, "</Prefix></CommonPrefixes>");
                    count += 1;
                }
                continue;
            }
        }

        try xml.appendSlice(allocator, "<Contents><Key>");
        try xmlEscape(allocator, &xml, item.key);
        try xml.appendSlice(allocator, "</Key><Size>");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{item.size}) catch "0";
        try xml.appendSlice(allocator, size_str);
        try xml.appendSlice(allocator, "</Size><StorageClass>STANDARD</StorageClass></Contents>");
        count += 1;
    }

    if (is_truncated) {
        try xml.appendSlice(allocator, "<IsTruncated>true</IsTruncated>");
        if (next_token) |token| {
            try xml.appendSlice(allocator, "<NextContinuationToken>");
            try xml.appendSlice(allocator, token);
            try xml.appendSlice(allocator, "</NextContinuationToken>");
        }
    } else {
        try xml.appendSlice(allocator, "<IsTruncated>false</IsTruncated>");
    }

    try xml.appendSlice(allocator, "</ListBucketResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

const KeyInfo = struct {
    key: []const u8,
    size: u64,
};

fn collectKeys(allocator: Allocator, base_path: []const u8, current_prefix: []const u8, filter_prefix: []const u8, keys: *std.ArrayListUnmanaged(KeyInfo)) !void {
    const full_path = if (current_prefix.len > 0)
        try std.fs.path.join(allocator, &[_][]const u8{ base_path, current_prefix })
    else
        try allocator.dupe(u8, base_path);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;

        const full_key = if (current_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.kind == .directory) {
            try collectKeys(allocator, base_path, full_key, filter_prefix, keys);
            allocator.free(full_key);
        } else if (entry.kind == .file) {
            if (filter_prefix.len == 0 or std.mem.startsWith(u8, full_key, filter_prefix)) {
                // Use statFile instead of open+stat+close - much faster
                const size = blk: {
                    const stat = dir.statFile(entry.name) catch break :blk 0;
                    break :blk stat.size;
                };
                try keys.append(allocator, .{ .key = full_key, .size = size });
            } else {
                allocator.free(full_key);
            }
        }
    }
}

fn handleCreateBucket(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8) !void {
    const path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(path);

    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            sendError(res, 500, "InternalError", "Cannot create bucket");
            return;
        },
    };

    res.ok();
}

fn handleHeadBucket(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8) !void {
    const path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(path);

    var dir = std.fs.cwd().openDir(path, .{}) catch {
        sendError(res, 404, "NoSuchBucket", "Bucket not found");
        return;
    };
    dir.close();

    res.ok();
}

fn handleDeleteBucket(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8) !void {
    const path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(path);

    std.fs.cwd().deleteDir(path) catch |err| switch (err) {
        error.DirNotEmpty => {
            sendError(res, 409, "BucketNotEmpty", "Bucket is not empty");
            return;
        },
        else => std.log.warn("delete bucket failed: {}", .{err}),
    };

    res.noContent();
}

fn handleListBuckets(ctx: *const S3Context, allocator: Allocator, res: *Response) !void {
    var dir = std.fs.cwd().openDir(ctx.data_dir, .{ .iterate = true }) catch {
        sendError(res, 500, "InternalError", "Cannot open data dir");
        return;
    };
    defer dir.close();

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Owner><ID>minioadmin</ID><DisplayName>minioadmin</DisplayName></Owner>");
    try xml.appendSlice(allocator, "<Buckets>");

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;

        try xml.appendSlice(allocator, "<Bucket><Name>");
        try xmlEscape(allocator, &xml, entry.name);
        try xml.appendSlice(allocator, "</Name><CreationDate>2024-01-01T00:00:00.000Z</CreationDate></Bucket>");
    }

    try xml.appendSlice(allocator, "</Buckets></ListAllMyBucketsResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleInitiateMultipart(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const timestamp: u64 = @intCast(std.time.timestamp());
    var upload_id_buf: [32]u8 = undefined;
    const upload_id = std.fmt.bufPrint(&upload_id_buf, "{x}", .{timestamp}) catch unreachable;

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch return;
    defer allocator.free(parts_dir);
    std.fs.cwd().makePath(parts_dir) catch {};

    const meta_path = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}/.meta", .{ ctx.data_dir, upload_id }) catch return;
    defer allocator.free(meta_path);

    var meta_file = std.fs.cwd().createFile(meta_path, .{}) catch return;
    defer meta_file.close();
    const meta_content = std.fmt.allocPrint(allocator, "{s}\n{s}", .{ bucket, key }) catch return;
    defer allocator.free(meta_content);
    meta_file.writeAll(meta_content) catch {};

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Bucket>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Bucket><Key>");
    try xmlEscape(allocator, &xml, key);
    try xml.appendSlice(allocator, "</Key><UploadId>");
    try xml.appendSlice(allocator, upload_id);
    try xml.appendSlice(allocator, "</UploadId></InitiateMultipartUploadResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleUploadPart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    _ = bucket;
    _ = key;

    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };
    const part_number = getQueryParam(req.query, "partNumber") orelse {
        sendError(res, 400, "InvalidRequest", "Missing partNumber");
        return;
    };

    const part_path = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}/{s}", .{ ctx.data_dir, upload_id, part_number }) catch return;
    defer allocator.free(part_path);

    var file = std.fs.cwd().createFile(part_path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create part file");
        return;
    };
    defer file.close();

    file.writeAll(req.body) catch {
        sendError(res, 500, "InternalError", "Cannot write part");
        return;
    };

    const etag = SigV4.hash(req.body);
    var etag_hex: [66]u8 = undefined;
    _ = std.fmt.bufPrint(&etag_hex, "\"{x}\"", .{etag}) catch unreachable;

    res.ok();
    res.setHeader("ETag", &etag_hex);
}

fn handleCompleteMultipart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch {
        sendError(res, 500, "InternalError", "Allocation failed");
        return;
    };
    defer allocator.free(parts_dir);

    const final_path = try ctx.objectPath(allocator, bucket, key);
    defer allocator.free(final_path);

    if (std.fs.path.dirname(final_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            std.log.warn("makePath failed: {}", .{err});
        };
    }

    var final_file = std.fs.cwd().createFile(final_path, .{}) catch {
        sendError(res, 500, "InternalError", "Cannot create final file");
        return;
    };
    defer final_file.close();

    var dir = std.fs.cwd().openDir(parts_dir, .{ .iterate = true }) catch {
        sendError(res, 404, "NoSuchUpload", "Upload not found");
        return;
    };
    defer dir.close();

    var parts: std.ArrayListUnmanaged(u32) = .empty;
    defer parts.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and entry.name[0] != '.') {
            const num = std.fmt.parseInt(u32, entry.name, 10) catch continue;
            try parts.append(allocator, num);
        }
    }

    std.mem.sort(u32, parts.items, {}, std.sort.asc(u32));

    var hasher = std.crypto.hash.Md5.init(.{});
    var parts_assembled: usize = 0;

    for (parts.items) |part_num| {
        var part_num_buf: [16]u8 = undefined;
        const part_num_str = std.fmt.bufPrint(&part_num_buf, "{d}", .{part_num}) catch continue;
        const part_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ parts_dir, part_num_str }) catch {
            std.log.warn("allocation failed for part path", .{});
            continue;
        };
        defer allocator.free(part_path);

        var part_file = std.fs.cwd().openFile(part_path, .{}) catch |err| {
            std.log.warn("failed to open part {d}: {}", .{ part_num, err });
            continue;
        };
        defer part_file.close();

        const stat = part_file.stat() catch continue;
        const data = allocator.alloc(u8, stat.size) catch continue;
        defer allocator.free(data);

        const bytes_read = part_file.readAll(data) catch continue;
        final_file.writeAll(data[0..bytes_read]) catch |err| {
            std.log.warn("failed to write part {d}: {}", .{ part_num, err });
            continue;
        };

        var part_hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data[0..bytes_read], &part_hash, .{});
        hasher.update(&part_hash);
        parts_assembled += 1;
    }

    std.fs.cwd().deleteTree(parts_dir) catch |err| {
        std.log.warn("failed to cleanup upload dir: {}", .{err});
    };

    var final_hash: [16]u8 = undefined;
    hasher.final(&final_hash);

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Bucket>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Bucket><Key>");
    try xmlEscape(allocator, &xml, key);

    var etag_buf: [48]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "</Key><ETag>\"{x}-{d}\"</ETag>", .{ final_hash, parts_assembled }) catch "</Key><ETag>\"\"</ETag>";
    try xml.appendSlice(allocator, etag);
    try xml.appendSlice(allocator, "</CompleteMultipartUploadResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

fn handleAbortMultipart(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response) !void {
    const upload_id = getQueryParam(req.query, "uploadId") orelse {
        sendError(res, 400, "InvalidRequest", "Missing uploadId");
        return;
    };

    const parts_dir = std.fmt.allocPrint(allocator, "{s}/.uploads/{s}", .{ ctx.data_dir, upload_id }) catch {
        sendError(res, 500, "InternalError", "Allocation failed");
        return;
    };
    defer allocator.free(parts_dir);

    std.fs.cwd().deleteTree(parts_dir) catch |err| {
        std.log.warn("abort multipart cleanup failed: {}", .{err});
    };

    res.noContent();
}

pub const Range = struct { start: u64, end: u64 };

pub fn parseRange(header: []const u8, file_size: u64) ?Range {
    if (!std.mem.startsWith(u8, header, "bytes=")) return null;
    const range_spec = header[6..];

    const dash = std.mem.indexOf(u8, range_spec, "-") orelse return null;
    const start_str = range_spec[0..dash];
    const end_str = range_spec[dash + 1 ..];

    const start = if (start_str.len > 0) std.fmt.parseInt(u64, start_str, 10) catch return null else 0;
    const end = if (end_str.len > 0) std.fmt.parseInt(u64, end_str, 10) catch return null else file_size - 1;

    if (start > end or end >= file_size) return null;
    return .{ .start = start, .end = end };
}

pub fn hasQuery(query: []const u8, key: []const u8) bool {
    if (std.mem.indexOf(u8, query, key)) |idx| {
        if (idx == 0) return true;
        if (query[idx - 1] == '&') return true;
    }
    return false;
}

pub fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
            if (std.mem.eql(u8, pair[0..eq_idx], key)) {
                return pair[eq_idx + 1 ..];
            }
        } else {
            if (std.mem.eql(u8, pair, key)) {
                return "";
            }
        }
    }
    return null;
}

pub fn xmlEscape(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '&' => try list.appendSlice(allocator, "&amp;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&apos;"),
            else => try list.append(allocator, c),
        }
    }
}

// ============================================================================
// DISTRIBUTED HANDLERS
// ============================================================================

/// Handle peer-to-peer protocol endpoints (/_zs3/*)
fn handlePeerProtocol(ctx: *const S3Context, dist: *DistributedContext, allocator: Allocator, req: *Request, res: *Response, path: []const u8) !void {
    if (std.mem.eql(u8, path, "ping")) {
        // Health check - returns node ID
        var id_hex: [40]u8 = undefined;
        bytesToHex(&dist.config.node_id, &id_hex);
        res.ok();
        res.body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"peers\":{d}}}", .{ id_hex, dist.kademlia.peerCount() });
    } else if (std.mem.eql(u8, path, "peers")) {
        // Return known peers for gossip
        var json: std.ArrayListUnmanaged(u8) = .empty;
        try json.appendSlice(allocator, "[");

        var peers: [20]PeerInfo = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        const count = dist.kademlia.getRandomPeers(&peers, prng.random());

        for (peers[0..count], 0..) |peer, i| {
            if (i > 0) try json.appendSlice(allocator, ",");
            var id_hex: [40]u8 = undefined;
            bytesToHex(&peer.id, &id_hex);

            var buf: [128]u8 = undefined;
            const peer_json = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"port\":{d}}}", .{ id_hex, peer.address.getPort() }) catch continue;
            try json.appendSlice(allocator, peer_json);
        }

        try json.appendSlice(allocator, "]");
        res.ok();
        res.setHeader("Content-Type", "application/json");
        res.body = try json.toOwnedSlice(allocator);
    } else if (std.mem.startsWith(u8, path, "blob/")) {
        // Content transfer by hash
        const hash_hex = path[5..];
        if (hash_hex.len != 40) {
            sendError(res, 400, "InvalidRequest", "Invalid hash");
            return;
        }

        var hash: ContentHash = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
            sendError(res, 400, "InvalidRequest", "Invalid hash format");
            return;
        };

        if (std.mem.eql(u8, req.method, "GET")) {
            // Fetch blob by hash
            const data = dist.cas.retrieve(allocator, hash) catch {
                sendError(res, 404, "NotFound", "Content not found");
                return;
            };
            res.ok();
            res.body = data;
        } else if (std.mem.eql(u8, req.method, "PUT")) {
            // Store blob (pushed from another node)
            _ = dist.cas.store(allocator, req.body) catch {
                sendError(res, 500, "InternalError", "Failed to store");
                return;
            };
            res.ok();
        } else {
            sendError(res, 405, "MethodNotAllowed", "Method not allowed");
        }
    } else if (std.mem.startsWith(u8, path, "providers/")) {
        // Find providers for content
        const hash_hex = path[10..];
        if (hash_hex.len != 40) {
            sendError(res, 400, "InvalidRequest", "Invalid hash");
            return;
        }

        var hash: ContentHash = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
            sendError(res, 400, "InvalidRequest", "Invalid hash format");
            return;
        };

        const providers = dist.kademlia.findProviders(hash);

        var json: std.ArrayListUnmanaged(u8) = .empty;
        try json.appendSlice(allocator, "[");
        for (providers, 0..) |id, i| {
            if (i > 0) try json.appendSlice(allocator, ",");
            var id_hex: [40]u8 = undefined;
            bytesToHex(&id, &id_hex);
            try json.append(allocator, '"');
            try json.appendSlice(allocator, &id_hex);
            try json.append(allocator, '"');
        }
        try json.appendSlice(allocator, "]");

        res.ok();
        res.setHeader("Content-Type", "application/json");
        res.body = try json.toOwnedSlice(allocator);
    } else if (std.mem.eql(u8, path, "announce")) {
        // Announce content availability
        if (!std.mem.eql(u8, req.method, "POST")) {
            sendError(res, 405, "MethodNotAllowed", "Use POST");
            return;
        }
        // Body should contain: hash_hex\nnode_id_hex
        var lines = std.mem.splitScalar(u8, req.body, '\n');
        const hash_hex = lines.next() orelse {
            sendError(res, 400, "InvalidRequest", "Missing hash");
            return;
        };
        const provider_hex = lines.next() orelse {
            sendError(res, 400, "InvalidRequest", "Missing provider");
            return;
        };

        if (hash_hex.len != 40 or provider_hex.len != 40) {
            sendError(res, 400, "InvalidRequest", "Invalid format");
            return;
        }

        var hash: ContentHash = undefined;
        var provider: NodeId = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
            sendError(res, 400, "InvalidRequest", "Invalid hash");
            return;
        };
        _ = std.fmt.hexToBytes(&provider, provider_hex) catch {
            sendError(res, 400, "InvalidRequest", "Invalid provider");
            return;
        };

        dist.kademlia.addProvider(hash, provider) catch {};
        res.ok();
    } else if (std.mem.eql(u8, path, "findnode")) {
        // Kademlia FIND_NODE
        const target_hex = req.header("x-target-id") orelse {
            sendError(res, 400, "InvalidRequest", "Missing X-Target-Id header");
            return;
        };

        if (target_hex.len != 40) {
            sendError(res, 400, "InvalidRequest", "Invalid target ID");
            return;
        }

        var target: NodeId = undefined;
        _ = std.fmt.hexToBytes(&target, target_hex) catch {
            sendError(res, 400, "InvalidRequest", "Invalid target format");
            return;
        };

        var closest: [Kademlia.K]PeerInfo = undefined;
        const count = dist.kademlia.findClosest(target, &closest);

        var json: std.ArrayListUnmanaged(u8) = .empty;
        try json.appendSlice(allocator, "[");
        for (closest[0..count], 0..) |peer, i| {
            if (i > 0) try json.appendSlice(allocator, ",");
            var id_hex: [40]u8 = undefined;
            bytesToHex(&peer.id, &id_hex);
            var buf: [128]u8 = undefined;
            const peer_json = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"port\":{d}}}", .{ id_hex, peer.address.getPort() }) catch continue;
            try json.appendSlice(allocator, peer_json);
        }
        try json.appendSlice(allocator, "]");

        res.ok();
        res.setHeader("Content-Type", "application/json");
        res.body = try json.toOwnedSlice(allocator);
    } else {
        _ = ctx;
        sendError(res, 404, "NotFound", "Unknown peer endpoint");
    }
}

/// Distributed PUT - store in CAS, update metadata, announce to DHT
fn handleDistributedPut(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const dist = ctx.distributed.?;

    // Ensure bucket directory exists in index
    const bucket_path = try ctx.bucketPath(allocator, bucket);
    defer allocator.free(bucket_path);
    std.fs.cwd().makePath(bucket_path) catch {};

    // Store content in CAS
    const hash = try dist.cas.store(allocator, req.body);

    // Update metadata index
    try dist.meta_index.put(allocator, bucket, key, hash, req.body.len);

    // Announce to DHT
    dist.kademlia.announce(hash) catch {};

    // Schedule replication
    dist.replication.schedule(hash) catch {};

    // Return ETag as content hash
    var etag_hex: [42]u8 = undefined;
    etag_hex[0] = '"';
    bytesToHex(&hash, etag_hex[1..41]);
    etag_hex[41] = '"';

    res.ok();
    res.setHeader("ETag", &etag_hex);
}

/// Distributed GET - lookup metadata, retrieve from CAS or peers
fn handleDistributedGet(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8, key: []const u8) !void {
    const dist = ctx.distributed.?;

    // Lookup metadata
    const meta = try dist.meta_index.get(allocator, bucket, key) orelse {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };

    // Try local CAS first
    if (dist.cas.retrieve(allocator, meta.hash)) |data| {
        // Handle range requests
        if (req.header("range")) |range_header| {
            if (parseRange(range_header, data.len)) |range| {
                var range_buf: [64]u8 = undefined;
                const content_range = std.fmt.bufPrint(&range_buf, "bytes {d}-{d}/{d}", .{ range.start, range.end, data.len }) catch unreachable;

                res.status = 206;
                res.status_text = "Partial Content";
                res.setHeader("Content-Range", content_range);
                res.setHeader("Accept-Ranges", "bytes");
                res.body = data[range.start .. range.end + 1];
                return;
            }
        }

        res.ok();
        res.setHeader("Accept-Ranges", "bytes");

        var etag_hex: [42]u8 = undefined;
        etag_hex[0] = '"';
        bytesToHex(&meta.hash, etag_hex[1..41]);
        etag_hex[41] = '"';
        res.setHeader("ETag", &etag_hex);
        res.body = data;
        return;
    } else |_| {}

    // Content not local - query DHT for providers
    const providers = dist.kademlia.findProviders(meta.hash);
    if (providers.len == 0) {
        sendError(res, 404, "NoSuchKey", "Content not available (no providers)");
        return;
    }

    // TODO: Fetch from remote peer
    // For now, return not found if not local
    sendError(res, 404, "NoSuchKey", "Content not available locally");
}

/// Distributed DELETE - remove metadata (CAS content can be garbage collected)
fn handleDistributedDelete(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const dist = ctx.distributed.?;
    dist.meta_index.delete(allocator, bucket, key);
    res.noContent();
}

/// Distributed LIST - list objects from metadata index
fn handleDistributedList(ctx: *const S3Context, allocator: Allocator, req: *Request, res: *Response, bucket: []const u8) !void {
    const dist = ctx.distributed.?;

    const prefix = getQueryParam(req.query, "prefix") orelse "";
    const max_keys_str = getQueryParam(req.query, "max-keys") orelse "1000";
    const max_keys = std.fmt.parseInt(usize, max_keys_str, 10) catch 1000;
    const delimiter = getQueryParam(req.query, "delimiter");
    const continuation = getQueryParam(req.query, "continuation-token");

    // Path to the bucket's index directory
    const index_path = try std.fs.path.join(allocator, &.{ dist.meta_index.data_dir, ".index", bucket });
    defer allocator.free(index_path);

    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml.appendSlice(allocator, "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    try xml.appendSlice(allocator, "<Name>");
    try xml.appendSlice(allocator, bucket);
    try xml.appendSlice(allocator, "</Name><Prefix>");
    try xml.appendSlice(allocator, prefix);
    try xml.appendSlice(allocator, "</Prefix><MaxKeys>");
    try xml.appendSlice(allocator, max_keys_str);
    try xml.appendSlice(allocator, "</MaxKeys>");

    var keys: std.ArrayListUnmanaged(KeyInfo) = .empty;
    defer keys.deinit(allocator);

    // Collect keys from metadata index
    collectMetaKeys(allocator, index_path, "", prefix, &keys, &dist.meta_index, bucket) catch {};

    std.mem.sort(KeyInfo, keys.items, {}, struct {
        fn lessThan(_: void, a: KeyInfo, b: KeyInfo) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    var start_idx: usize = 0;
    if (continuation) |cont| {
        for (keys.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.key, cont)) {
                start_idx = i + 1;
                break;
            }
        }
    }

    var common_prefixes = std.StringHashMap(void).init(allocator);
    defer common_prefixes.deinit();

    var count: usize = 0;
    var is_truncated = false;
    var next_token: ?[]const u8 = null;

    for (keys.items[start_idx..]) |item| {
        if (count >= max_keys) {
            is_truncated = true;
            next_token = item.key;
            break;
        }

        if (delimiter) |delim| {
            const after_prefix = if (prefix.len > 0 and std.mem.startsWith(u8, item.key, prefix))
                item.key[prefix.len..]
            else
                item.key;

            if (std.mem.indexOf(u8, after_prefix, delim)) |delim_idx| {
                const common_prefix = item.key[0 .. prefix.len + delim_idx + 1];
                if (!common_prefixes.contains(common_prefix)) {
                    try common_prefixes.put(common_prefix, {});
                    try xml.appendSlice(allocator, "<CommonPrefixes><Prefix>");
                    try xml.appendSlice(allocator, common_prefix);
                    try xml.appendSlice(allocator, "</Prefix></CommonPrefixes>");
                    count += 1;
                }
                continue;
            }
        }

        try xml.appendSlice(allocator, "<Contents><Key>");
        try xmlEscape(allocator, &xml, item.key);
        try xml.appendSlice(allocator, "</Key><Size>");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{item.size}) catch "0";
        try xml.appendSlice(allocator, size_str);
        try xml.appendSlice(allocator, "</Size><StorageClass>STANDARD</StorageClass></Contents>");
        count += 1;
    }

    if (is_truncated) {
        try xml.appendSlice(allocator, "<IsTruncated>true</IsTruncated>");
        if (next_token) |token| {
            try xml.appendSlice(allocator, "<NextContinuationToken>");
            try xml.appendSlice(allocator, token);
            try xml.appendSlice(allocator, "</NextContinuationToken>");
        }
    } else {
        try xml.appendSlice(allocator, "<IsTruncated>false</IsTruncated>");
    }

    try xml.appendSlice(allocator, "</ListBucketResult>");

    res.ok();
    res.setXmlBody(try xml.toOwnedSlice(allocator));
}

/// Collect keys from the metadata index directory
fn collectMetaKeys(allocator: Allocator, base_path: []const u8, current_prefix: []const u8, filter_prefix: []const u8, keys: *std.ArrayListUnmanaged(KeyInfo), meta_index: *const MetaIndex, bucket: []const u8) !void {
    const full_path = if (current_prefix.len > 0)
        try std.fs.path.join(allocator, &[_][]const u8{ base_path, current_prefix })
    else
        try allocator.dupe(u8, base_path);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;

        const full_name = if (current_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.kind == .directory) {
            try collectMetaKeys(allocator, base_path, full_name, filter_prefix, keys, meta_index, bucket);
            allocator.free(full_name);
        } else if (entry.kind == .file) {
            // Strip .meta extension to get the key
            if (std.mem.endsWith(u8, entry.name, ".meta")) {
                const key_name_len = full_name.len - 5; // Remove ".meta"
                const key = full_name[0..key_name_len];

                if (filter_prefix.len == 0 or std.mem.startsWith(u8, key, filter_prefix)) {
                    // Get size from metadata
                    const meta = meta_index.get(allocator, bucket, key) catch null;
                    const size = if (meta) |m| m.size else 0;

                    const key_copy = try allocator.dupe(u8, key);
                    try keys.append(allocator, .{ .key = key_copy, .size = size });
                }
            }
            allocator.free(full_name);
        }
    }
}

/// Distributed HEAD - return metadata without body
fn handleDistributedHead(ctx: *const S3Context, allocator: Allocator, res: *Response, bucket: []const u8, key: []const u8) !void {
    const dist = ctx.distributed.?;

    const meta = try dist.meta_index.get(allocator, bucket, key) orelse {
        sendError(res, 404, "NoSuchKey", "Object not found");
        return;
    };

    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{meta.size}) catch unreachable;

    var etag_hex: [42]u8 = undefined;
    etag_hex[0] = '"';
    bytesToHex(&meta.hash, etag_hex[1..41]);
    etag_hex[41] = '"';

    res.ok();
    res.setHeader("Content-Length", size_str);
    res.setHeader("ETag", &etag_hex);
    res.setHeader("Accept-Ranges", "bytes");
}

fn sendError(res: *Response, status: u16, code: []const u8, message: []const u8) void {
    res.status = status;
    res.status_text = switch (status) {
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        else => "Error",
    };
    res.setHeader("Content-Type", "application/xml");

    res.body = std.fmt.allocPrint(res.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>{s}</Code><Message>{s}</Message></Error>", .{ code, message }) catch return;
}

