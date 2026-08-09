import assert from "node:assert/strict";
import { argsAreEmpty, makeLoopTracker } from "./qwen-loop-guard.ts";

assert.equal(argsAreEmpty(null), true);
assert.equal(argsAreEmpty(undefined), true);
assert.equal(argsAreEmpty({}), true);
assert.equal(argsAreEmpty({ command: "ls" }), false);

// two identical empty-arg calls -> abort on the second
let t = makeLoopTracker(2);
assert.equal(t("bash", {}), false);
assert.equal(t("bash", {}), true);

// non-empty identical repeats never abort (legit re-reads)
t = makeLoopTracker(2);
assert.equal(t("read", { path: "a" }), false);
assert.equal(t("read", { path: "a" }), false);
assert.equal(t("read", { path: "a" }), false);

// a different call resets the empty streak
t = makeLoopTracker(2);
assert.equal(t("bash", {}), false);
assert.equal(t("read", { path: "a" }), false);
assert.equal(t("bash", {}), false);

console.log("qwen-loop-guard: all checks passed");
