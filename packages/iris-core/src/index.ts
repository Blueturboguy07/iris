/**
 * The logic both Iris clients run.
 *
 * Everything exported here is PURE — no file system, no processes, no network,
 * no platform APIs, no Node built-ins. That constraint is what lets the same
 * module load in Electron on Windows and in JavaScriptCore on macOS, and it is
 * the reason a host callback is taken for anything that touches the world
 * (see `computeBreakSignature`'s `hashHex`).
 *
 * A module that cannot be written without I/O does not belong here. Put the
 * decision here and the I/O behind a host function.
 */
export {
  BREAK_SIGNATURE_HEX_LENGTH,
  breakSignatureMaterial,
  computeBreakSignature,
  normalizeBreakMessage,
} from "./break-signature";
