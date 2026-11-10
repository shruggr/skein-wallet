// skein-wallet: the wallet, a skein app — the record keeper of every output an instance owns.
// Zig 0.16.0, wasm32-wasi, over the SDK's chain library (skein-sdk `chain`, a URL+hash
// dependency; bsvz comes through it, lazily), as skein-chain is built.
//
//   zig build         → zig-out/bin/wallet.wasm
//   zig build bin     the same, written to bin/wallet.wasm (the app tree's module; committed)
//   zig build test    the book (src/book.zig) and the call's pure parts, natively
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const chain = b.dependency("skein_sdk", .{ .target = wasi, .optimize = .ReleaseSafe, .wallet = false }).module("chain");
    const exe = b.addExecutable(.{
        .name = "wallet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasi,
            .optimize = .ReleaseSafe,
            .strip = true,
            .imports = &.{.{ .name = "chain", .module = chain }},
        }),
    });
    b.installArtifact(exe);
    const bin = b.addUpdateSourceFiles();
    bin.addCopyFileToSource(exe.getEmittedBin(), "bin/wallet.wasm");
    b.step("bin", "write the module into the app tree: bin/wallet.wasm").dependOn(&bin.step);

    const target = b.standardTargetOptions(.{});
    const native = b.dependency("skein_sdk", .{ .target = target, .optimize = .Debug, .wallet = false }).module("chain");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "chain", .module = native }},
    }) });
    b.step("test", "the book and the call's pure parts, natively").dependOn(&b.addRunArtifact(tests).step);
}
