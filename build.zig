const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;

const BuildType = enum {
    static,
    shared,
};

const PthreadType = enum {
    flag,
    link,
    none,
};

const WithSSL = enum {
    none,
    wintls,
    appletls,
    openssl,
    mbedtls,
    gnutls,
};

const BuildOptions = struct {
    // General options
    build_type: BuildType,
    pthread_type: PthreadType,

    use_kcp: bool,
    with_ssl: WithSSL,

    // Windows specific
    use_wepoll: bool,
    mt_build: bool,
    enable_windump: bool,

    // UNIX specific (but also applied to Windows in some cases)
    enable_uds: bool, // Can also build on Windows if it's Insider Build 17063 and so on (including W11)
    link_rt: bool,
};

const GeneratedConfig = struct {
    WITH_APPLETLS: u8,
    WITH_WINTLS: u8,
    WITH_OPENSSL: u8,
    WITH_MBEDTLS: u8,
    WITH_GNUTLS: u8,
};

comptime {
    const required_zig = "0.13.0";
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_zig.order(min_zig) == .lt)
        @compileError(std.fmt.comptimePrint(
            \\Required Zig version {s} to use zig-libhv, but got {s}
            \\
            \\Perhaps you meant to use different version/commit of zig-libhv?
        , .{ required_zig, builtin.zig_version_string }));
}

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var build_options = BuildOptions{
        .build_type = b.option(BuildType, "build-type", "Build library as static or shared library (Default is static)") orelse .static,
        .pthread_type = b.option(PthreadType, "with-pthread", "Use pthread by adding flag, linking, or none") orelse
            if (target.result.isAndroid()) .none else .flag,
        .enable_uds = b.option(bool, "enable-uds", "Enable Unix Domain Socket (Default is true if UNIX-based or Windows 10 that's newer than Insider Build 17062 or Windows 11)") orelse
            if (target.result.os.tag != .windows or (target.result.os.isAtLeast(.windows, .win10_rs4) orelse false)) true else false,
        .with_ssl = b.option(WithSSL, "with-ssl-tls", "Integrate with SSL/TLS library (Default is none)") orelse .none,
        .use_kcp = false,
        .link_rt = false,
        .enable_windump = false,
        .mt_build = false,
        .use_wepoll = false,
    };

    if (target.result.os.tag != .windows) {
        build_options.link_rt = b.option(bool, "link-rt", "Link with librt") orelse false;
    }

    if (target.result.os.tag == .windows) {
        build_options.use_wepoll = b.option(bool, "use-wepoll", "Use wepoll instead of iocp") orelse false;
        build_options.mt_build = b.option(bool, "build-mt", "Build with static runtime lib") orelse false;
        build_options.enable_windump = b.option(bool, "enable-windump", "Enable Windows coredump") orelse false;
    }

    if (target.result.os.tag == .ios)
        build_options.build_type = .static;

    if (build_options.with_ssl == .gnutls) {
        @panic("Building GnuTLS and linking it is not supported yet");
    }

    var generated_config = GeneratedConfig{
        .WITH_APPLETLS = 0,
        .WITH_WINTLS = 0,
        .WITH_OPENSSL = 0,
        .WITH_MBEDTLS = 0,
        .WITH_GNUTLS = 0,
    };

    const libhv = b.dependency("libhv", .{});

    const name = "hv";
    const lib = if (build_options.build_type == .static)
        b.addStaticLibrary(.{
            .name = name,
            .target = target,
            .optimize = optimize,
        })
    else
        b.addSharedLibrary(.{
            .name = name,
            .target = target,
            .optimize = optimize,
        });

    lib.linkLibC();

    lib.addIncludePath(libhv.path("."));
    lib.addIncludePath(libhv.path("./base"));
    lib.addIncludePath(libhv.path("./event"));
    lib.addIncludePath(libhv.path("./ssl"));
    lib.addIncludePath(libhv.path("./util"));

    if (target.result.os.tag != .windows) { // UNIX
        lib.linkSystemLibrary("m");
        lib.linkSystemLibrary("dl");
        if (build_options.pthread_type == .link)
            lib.linkSystemLibrary("pthread");
        if (build_options.link_rt)
            lib.linkSystemLibrary("rt");
    } else { // Windows
        lib.linkSystemLibrary("secur32");
        lib.linkSystemLibrary("crypt32");
        lib.linkSystemLibrary("winmm");
        lib.linkSystemLibrary("ws2_32");
        if (build_options.enable_windump)
            lib.linkSystemLibrary("dbghelp");
    }

    if (build_options.with_ssl == .openssl) {
        const openssl = b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        }).?;

        lib.linkLibrary(openssl.artifact("crypto"));
        lib.linkLibrary(openssl.artifact("ssl"));
        generated_config.WITH_OPENSSL = 1;
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.append("-std=gnu99");
    try flags.append(if (optimize == .Debug) "-DDEBUG" else "-DNDEBUG");
    if (build_options.pthread_type == .flag)
        try flags.append("-pthread");
    if (lib.isStaticLibrary())
        try flags.append("-DHV_STATICLIB");
    if (target.result.os.tag == .windows) {
        try flags.append("-DWIN32_LEAN_AND_MEAN");
        try flags.append("-D_CRT_SECURE_NO_WARNINGS");
        try flags.append(try std.mem.concat(b.allocator, u8, &.{ "-fms-runtime-lib=", if (build_options.mt_build and optimize != .Debug)
            "static"
        else if (build_options.mt_build)
            "static-dbg"
        else if (optimize != .Debug)
            "dll"
        else
            "dll-dbg" }));
        if (build_options.enable_windump)
            try flags.append("-DENABLE_WINDUMP");
    }

    var files = std.ArrayList([]const u8).init(b.allocator);
    defer files.deinit();

    try files.append("base/hbase.c");
    try files.append("base/herr.c");
    try files.append("base/hlog.c");
    try files.append("base/hmain.c");
    try files.append("base/hsocket.c");
    try files.append("base/htime.c");
    try files.append("base/hversion.c");
    try files.append("base/rbtree.c");
    try files.append("event/epoll.c");
    try files.append("event/evport.c");
    try files.append("event/hevent.c");
    try files.append("event/hloop.c");
    try files.append("event/iocp.c");
    try files.append("event/kqueue.c");
    try files.append("event/nio.c");
    try files.append("event/nlog.c");
    try files.append("event/noevent.c");
    try files.append("event/overlapio.c");
    try files.append("event/poll.c");
    try files.append("event/rudp.c");
    try files.append("event/select.c");
    try files.append("event/unpack.c");
    try files.append("ssl/appletls.c");
    try files.append("ssl/gnutls.c");
    try files.append("ssl/hssl.c");
    try files.append("ssl/mbedtls.c");
    try files.append("ssl/nossl.c");
    try files.append("ssl/openssl.c");
    try files.append("ssl/wintls.c");
    try files.append("util/base64.c");
    try files.append("util/md5.c");
    try files.append("util/sha1.c");
    if (build_options.use_wepoll)
        try files.append("event/wepoll/wepoll.c");
    if (build_options.use_kcp) {
        try files.append("event/kcp/hkcp.c");
        try files.append("event/kcp/ikcp.c");
    }

    lib.addCSourceFiles(.{
        .root = libhv.path("."),
        .flags = flags.items,
        .files = files.items,
    });

    b.installArtifact(lib);

    const module = b.addModule("hv", .{
        .root_source_file = b.path("./src/hv.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.linkLibrary(lib);
    module.addIncludePath(libhv.path("."));
    module.addIncludePath(libhv.path("./base"));
    module.addIncludePath(libhv.path("./event"));
    module.addIncludePath(libhv.path("./ssl"));
    module.addIncludePath(libhv.path("./util"));
}

fn buildMbedTLS(b: *Build, upstream: *Build.Dependency, target: *Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "mbedtls",
        .target = target,
        .optimize = optimize,
    });

    lib.addIncludePath(upstream.path("./library"));

    lib.addCSourceFiles(.{ // zig fmt: off
        .root = upstream.path("."),
        .files = &.{
            "library/debug.c",
            "library/mps_reader.c",
            "library/mps_trace.c",
            "library/net_sockets.c",
            "library/pkcs7.c",
            "library/ssl_cache.c",
            "library/ssl_ciphersuites.c",
            "library/ssl_client.c",
            "library/ssl_cookie.c",
            "library/ssl_msg.c",
            "library/ssl_ticket.c",
            "library/ssl_tls.c",
            "library/ssl_tls12_client.c",
            "library/ssl_tls12_server.c",
            "library/ssl_tls13_client.c",
            "library/ssl_tls13_generic.c",
            "library/ssl_tls13_keys.c",
            "library/ssl_tls13_server.c",
            "library/version.c",
            "library/x509.c",
            "library/x509_create.c",
            "library/x509_crl.c",
            "library/x509_crt.c",
            "library/x509_csr.c",
            "library/x509write.c",
            "library/x509write_crt.c",
            "library/x509write_csr.c",
            "tf-psa-crypto/core/psa_crypto.c",
            "tf-psa-crypto/core/psa_crypto_client.c",
            "tf-psa-crypto/core/psa_crypto_se.c",
            "tf-psa-crypto/core/psa_crypto_slot_management.c",
            "tf-psa-crypto/core/psa_crypto_storage.c",
            "tf-psa-crypto/core/psa_its_file.c",
            "tf-psa-crypto/drivers/builtin/src/aes.c",
            "tf-psa-crypto/drivers/builtin/src/aesce.c",
            "tf-psa-crypto/drivers/builtin/src/aesni.c",
            "tf-psa-crypto/drivers/builtin/src/aria.c",
            "tf-psa-crypto/drivers/builtin/src/asn1parse.c",
            "tf-psa-crypto/drivers/builtin/src/asn1write.c",
            "tf-psa-crypto/drivers/builtin/src/base64.c",
            "tf-psa-crypto/drivers/builtin/src/bignum.c",
            "tf-psa-crypto/drivers/builtin/src/bignum_core.c",
            "tf-psa-crypto/drivers/builtin/src/bignum_mod.c",
            "tf-psa-crypto/drivers/builtin/src/bignum_mod_raw.c",
            "tf-psa-crypto/drivers/builtin/src/block_cipher.c",
            "tf-psa-crypto/drivers/builtin/src/camellia.c",
            "tf-psa-crypto/drivers/builtin/src/ccm.c",
            "tf-psa-crypto/drivers/builtin/src/chacha20.c",
            "tf-psa-crypto/drivers/builtin/src/chachapoly.c",
            "tf-psa-crypto/drivers/builtin/src/cipher.c",
            "tf-psa-crypto/drivers/builtin/src/cipher_wrap.c",
            "tf-psa-crypto/drivers/builtin/src/cmac.c",
            "tf-psa-crypto/drivers/builtin/src/constant_time.c",
            "tf-psa-crypto/drivers/builtin/src/ctr_drbg.c",
            "tf-psa-crypto/drivers/builtin/src/des.c",
            "tf-psa-crypto/drivers/builtin/src/dhm.c",
            "tf-psa-crypto/drivers/builtin/src/ecdh.c",
            "tf-psa-crypto/drivers/builtin/src/ecdsa.c",
            "tf-psa-crypto/drivers/builtin/src/ecjpake.c",
            "tf-psa-crypto/drivers/builtin/src/ecp.c",
            "tf-psa-crypto/drivers/builtin/src/ecp_curves.c",
            "tf-psa-crypto/drivers/builtin/src/ecp_curves_new.c",
            "tf-psa-crypto/drivers/builtin/src/entropy.c",
            "tf-psa-crypto/drivers/builtin/src/entropy_poll.c",
            "tf-psa-crypto/drivers/builtin/src/gcm.c",
            "tf-psa-crypto/drivers/builtin/src/hkdf.c",
            "tf-psa-crypto/drivers/builtin/src/hmac_drbg.c",
            "tf-psa-crypto/drivers/builtin/src/lmots.c",
            "tf-psa-crypto/drivers/builtin/src/lms.c",
            "tf-psa-crypto/drivers/builtin/src/md.c",
            "tf-psa-crypto/drivers/builtin/src/md5.c",
            "tf-psa-crypto/drivers/builtin/src/memory_buffer_alloc.c",
            "tf-psa-crypto/drivers/builtin/src/nist_kw.c",
            "tf-psa-crypto/drivers/builtin/src/oid.c",
            "tf-psa-crypto/drivers/builtin/src/pem.c",
            "tf-psa-crypto/drivers/builtin/src/pk.c",
            "tf-psa-crypto/drivers/builtin/src/pk_ecc.c",
            "tf-psa-crypto/drivers/builtin/src/pk_wrap.c",
            "tf-psa-crypto/drivers/builtin/src/pkcs12.c",
            "tf-psa-crypto/drivers/builtin/src/pkcs5.c",
            "tf-psa-crypto/drivers/builtin/src/pkparse.c",
            "tf-psa-crypto/drivers/builtin/src/pkwrite.c",
            "tf-psa-crypto/drivers/builtin/src/platform.c",
            "tf-psa-crypto/drivers/builtin/src/platform_util.c",
            "tf-psa-crypto/drivers/builtin/src/poly1305.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_aead.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_cipher.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_ecp.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_ffdh.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_hash.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_mac.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_pake.c",
            "tf-psa-crypto/drivers/builtin/src/psa_crypto_rsa.c",
            "tf-psa-crypto/drivers/builtin/src/psa_util.c",
            "tf-psa-crypto/drivers/builtin/src/ripemd160.c",
            "tf-psa-crypto/drivers/builtin/src/rsa.c",
            "tf-psa-crypto/drivers/builtin/src/rsa_alt_helpers.c",
            "tf-psa-crypto/drivers/builtin/src/sha1.c",
            "tf-psa-crypto/drivers/builtin/src/sha256.c",
            "tf-psa-crypto/drivers/builtin/src/sha3.c",
            "tf-psa-crypto/drivers/builtin/src/sha512.c",
            "tf-psa-crypto/drivers/builtin/src/threading.c",
            "tf-psa-crypto/drivers/builtin/src/timing.c",
            "tf-psa-crypto/drivers/everest/library/Hacl_Curve25519.c",
            "tf-psa-crypto/drivers/everest/library/Hacl_Curve25519_joined.c",
            "tf-psa-crypto/drivers/everest/library/everest.c",
            "tf-psa-crypto/drivers/everest/library/kremlib/FStar_UInt128_extracted.c",
            "tf-psa-crypto/drivers/everest/library/kremlib/FStar_UInt64_FStar_UInt32_FStar_UInt16_FStar_UInt8.c",
            "tf-psa-crypto/drivers/everest/library/legacy/Hacl_Curve25519.c",
            "tf-psa-crypto/drivers/everest/library/x25519.c",
            "tf-psa-crypto/drivers/p256-m/p256-m/p256-m.c",
            "tf-psa-crypto/drivers/p256-m/p256-m_driver_entrypoints.c",
        }
    }); // zig fmt: on
return lib;
}
