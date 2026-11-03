"use strict";
/**
 * Upstream-drift guard for HookVaultV2.
 *
 * HookVaultV2._withdraw is a verbatim copy of VaultV1._withdraw with exactly two edits.
 * Solidity cannot enforce that: patching the *body* of VaultV1._withdraw recompiles
 * cleanly and leaves HookVaultV2's runtime bytecode byte-identical, i.e. the upstream
 * change is silently dropped for every vault running the Hook implementation. Only a
 * signature change, or removal of `virtual`, fails loudly at compile time.
 *
 * This guard closes the silent gap. Pure source analysis: no fork, no compile, ~10ms.
 *   npx mocha test/vault/hook-vault-upstream-drift.js
 */
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const VAULT_V1 = path.join(ROOT, "contracts", "base", "VaultV1.sol");
const HOOK = path.join(ROOT, "contracts", "base", "HookVaultV2.sol");
const read = (p) => fs.readFileSync(p, "utf8");

// The complete, exhaustive list of intentional differences between the two bodies.
const INTENTIONAL_EDITS = [
  {
    name: "signature: virtual -> virtual override",
    from: "function _withdraw(uint256 numberOfShares, address receiver, address owner) internal virtual returns (uint256) {",
    to: "function _withdraw(uint256 numberOfShares, address receiver, address owner) internal virtual override returns (uint256) {",
  },
  {
    name: "hard work hook inserted after the burn",
    from: "_burn(owner, numberOfShares);",
    to: "_burn(owner, numberOfShares);\n\n    if (compoundOnWithdraw()) {\n      _hardWorkOnWithdraw();\n    }",
  },
];

// The base vaults are kept at upstream parity except for these `virtual` keywords,
// which let HookVaultV2 override.
const ALLOWED_BASE_DIVERGENCE = new Set([
  "-  function _deposit(uint256 amount, address sender, address beneficiary) internal returns (uint256) {",
  "+  function _deposit(uint256 amount, address sender, address beneficiary) internal virtual returns (uint256) {",
  "-  function _withdraw(uint256 numberOfShares, address receiver, address owner) internal returns (uint256) {",
  "+  function _withdraw(uint256 numberOfShares, address receiver, address owner) internal virtual returns (uint256) {",
  // VaultV2: opened up so a flavour can report remaining capacity under a deposit cap.
  "-    function maxDeposit(address /*caller*/) public view override returns (uint256) {",
  "+    function maxDeposit(address /*caller*/) public view virtual override returns (uint256) {",
  "-    function maxMint(address /*caller*/) public view override returns (uint256) {",
  "+    function maxMint(address /*caller*/) public view virtual override returns (uint256) {",
  // VaultV2: opened up so the in-kind flavour can quote at the synced strategy balance.
  "-    function totalAssets() public view override returns (uint256) {",
  "+    function totalAssets() public view virtual override returns (uint256) {",
]);

function extractFunction(src, name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) return null;
  const open = src.indexOf("{", start);
  if (open < 0) return null;
  let depth = 0;
  for (let k = open; k < src.length; k++) {
    if (src[k] === "{") depth++;
    else if (src[k] === "}" && --depth === 0) return src.slice(start, k + 1);
  }
  return null;
}

// Strip comments / blank lines / indentation so formatting churn is not treated as drift.
const normalise = (body) =>
  body
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((l) => l.replace(/\/\/.*$/, "").trim())
    .filter(Boolean);

function checkParity(vaultV1Src, hookSrc) {
  const base = extractFunction(vaultV1Src, "_withdraw");
  const hook = extractFunction(hookSrc, "_withdraw");
  if (!base) return { ok: false, reason: "VaultV1._withdraw not found - the base vault was restructured" };
  if (!hook) return { ok: false, reason: "HookVaultV2._withdraw not found - the override was removed or renamed" };

  // Rebuild what the override *should* be from the current upstream body.
  let expected = base;
  const anchorProblems = [];
  for (const e of INTENTIONAL_EDITS) {
    const n = expected.split(e.from).length - 1;
    if (n === 0) anchorProblems.push(`${e.name}: anchor gone from VaultV1._withdraw -> "${e.from.trim()}"`);
    else if (n > 1) anchorProblems.push(`${e.name}: anchor now occurs ${n}x - ambiguous, re-anchor this edit`);
    else expected = expected.replace(e.from, e.to);
  }
  if (anchorProblems.length) return { ok: false, reason: "an intentional-edit anchor moved", detail: anchorProblems };

  const a = normalise(expected);
  const b = normalise(hook);
  if (a.length === b.length && a.every((l, i) => l === b[i])) return { ok: true };

  const detail = [];
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      detail.push(`line ${i + 1}:`);
      detail.push(`  expected (VaultV1 + intentional edits): ${a[i] ?? "<absent>"}`);
      detail.push(`  actual   (HookVaultV2)                : ${b[i] ?? "<absent>"}`);
    }
  }
  return { ok: false, reason: "HookVaultV2._withdraw has drifted from VaultV1._withdraw", detail };
}

const explain = (res) =>
  [
    "",
    `  ${res.reason}`,
    ...(res.detail || []).map((l) => "    " + l),
    "",
    "  VaultV1._withdraw changed and Solidity will NOT flag it: HookVaultV2 overrides",
    "  _withdraw, so it keeps the old body and the change never reaches vaults running",
    "  the Hook implementation. Re-copy VaultV1._withdraw and re-apply the two edits.",
  ].join("\n");

describe("HookVaultV2 upstream-drift guard", function () {
  it("HookVaultV2._withdraw is VaultV1._withdraw plus exactly the two intentional edits", function () {
    const res = checkParity(read(VAULT_V1), read(HOOK));
    assert.ok(res.ok, explain(res));
  });

  it("HookVaultV2 overrides only the withdraw hook and the deposit-cap surface", function () {
    const src = read(HOOK);
    const overrides = (src.match(/function\s+(\w+)\s*\([^)]*\)[^{;]*\boverride\b/g) || []).map(
      (m) => m.match(/function\s+(\w+)/)[1]
    );
    assert.deepStrictEqual(
      overrides.sort(),
      ["_deposit", "_withdraw", "maxDeposit", "maxMint"],
      "HookVaultV2 must override only the withdraw hook and the deposit-cap surface"
    );
    // _deposit is a cap check in front of the inherited body, never a copy of it: it must
    // delegate to super, and must not restate VaultV1's deposit logic.
    const dep = extractFunction(src, "_deposit");
    assert.ok(dep, "HookVaultV2 must define _deposit");
    assert.ok(
      /return super\._deposit\(amount, sender, beneficiary\);/.test(dep),
      "HookVaultV2._deposit must delegate to super._deposit"
    );
    assert.ok(
      !/safeTransferFrom|_mint\(/.test(dep),
      "HookVaultV2._deposit must not duplicate VaultV1._deposit's body"
    );
  });

  it("VaultV1/VaultV2/VaultStorage differ from upstream only by the known opened-up signatures", function () {
    let diff;
    try {
      diff = execFileSync(
        "git",
        ["diff", "upstream/master", "--",
         "contracts/base/VaultV1.sol", "contracts/base/VaultV2.sol", "contracts/base/VaultStorage.sol"],
        { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
      );
    } catch (e) {
      this.skip(); // `git fetch upstream` has not been run here
      return;
    }
    const unexpected = diff
      .split("\n")
      .filter((l) => /^[+-]/.test(l) && !/^(\+\+\+|---)/.test(l))
      .filter((l) => !ALLOWED_BASE_DIVERGENCE.has(l));
    assert.deepStrictEqual(
      unexpected, [],
      "\n  The base vaults drifted from upstream beyond the known opened-up signatures:\n" +
        unexpected.map((l) => "    " + l).join("\n") +
        "\n  Fold the change upstream, or move it into a vault flavour."
    );
  });

  // A guard that quietly stops guarding is worse than no guard. These synthetic
  // mutations must all be caught.
  describe("self-test: the guard must fail on real drift", function () {
    const v1 = () => read(VAULT_V1);
    const hook = () => read(HOOK);
    const mustFail = (label, mutate) =>
      it(label, () => assert.strictEqual(checkParity(mutate(v1()), hook()).ok, false, "guard failed to catch: " + label));

    mustFail("upstream inserts a clamp line into the body (the silent case)", (s) =>
      s.replace(
        "    IERC20Upgradeable(underlying()).safeTransfer(receiver, underlyingAmountToWithdraw);",
        "    underlyingAmountToWithdraw = MathUpgradeable.min(underlyingAmountToWithdraw, underlyingBalanceInVault());\n" +
        "    IERC20Upgradeable(underlying()).safeTransfer(receiver, underlyingAmountToWithdraw);"
      ));

    mustFail("upstream moves _burn after the strategy withdrawal", (s) =>
      s.replace("    _burn(owner, numberOfShares);\n", "")
       .replace("    IERC20Upgradeable(underlying()).safeTransfer(receiver, underlyingAmountToWithdraw);",
                "    _burn(owner, numberOfShares);\n    IERC20Upgradeable(underlying()).safeTransfer(receiver, underlyingAmountToWithdraw);"));

    mustFail("upstream changes the _withdraw signature", (s) =>
      s.replace(
        "function _withdraw(uint256 numberOfShares, address receiver, address owner) internal virtual returns (uint256) {",
        "function _withdraw(uint256 numberOfShares, address receiver, address owner, uint256 minOut) internal virtual returns (uint256) {"
      ));

    mustFail("upstream changes the pricing math", (s) =>
      s.replace("    uint256 underlyingAmountToWithdraw = underlyingBalanceWithInvestment()\n        .mul(numberOfShares)\n        .div(totalSupply);",
                "    uint256 underlyingAmountToWithdraw = underlyingBalanceWithInvestment()\n        .mul(numberOfShares)\n        .div(totalSupply.add(1));"));

    mustFail("the burn anchor becomes ambiguous (appears twice)", (s) =>
      s.replace("    _burn(owner, numberOfShares);\n", "    _burn(owner, numberOfShares);\n    _burn(owner, numberOfShares);\n"));

    it("tolerates cosmetic reformatting (must NOT false-positive)", function () {
      const cosmetic = v1().replace("    _burn(owner, numberOfShares);", "    _burn(owner, numberOfShares); // accounting");
      assert.strictEqual(checkParity(cosmetic, hook()).ok, true, "guard false-positived on a comment-only change");
    });
  });
});

module.exports = { checkParity, extractFunction, normalise, INTENTIONAL_EDITS };
