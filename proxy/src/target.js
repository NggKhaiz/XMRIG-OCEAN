// Difficulty <-> target, and the share test.
//
// A proxy that computes targets even slightly differently from the pool it
// feeds is worse than no proxy: every forwarded share is rejected upstream
// while the local ledger says everything is fine. Rather than copy the maths
// (and let it drift), this is the pool's module, with a test that asserts the
// two stay identical.

'use strict';

module.exports = require('../../pool/src/target');
