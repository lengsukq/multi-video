// AWS's browser builds can reference the Node-style `global` binding.
// Install the alias before Chime/IVS bundles load; do not add other Node shims.
if (typeof globalThis.global === 'undefined') {
  globalThis.global = globalThis;
}
