/**
 * Local (personal) macOS build config.
 *
 * Extends the upstream electron-builder config but drops everything that
 * requires Bruno Software Inc's Apple Developer account:
 *   - `identity`   : their signing certificate (not available locally)
 *   - `afterSign`  : notarize.js, which needs their notarization credentials
 *   - `requirements` / `hardenedRuntime`: only meaningful for a signed build
 *
 * Builds a single dmg for the host architecture instead of all six
 * (pkg/dmg/zip x x64/arm64), which is all that's needed for personal use.
 *
 * The packaged app is ad-hoc signed afterwards by scripts/build-electron-local.sh
 * (`codesign --sign -`), which macOS requires on Apple Silicon.
 *
 * appId and productName are intentionally left as upstream so this build is a
 * drop-in replacement and keeps using the existing
 * ~/Library/Application Support/bruno data directory.
 */
const base = require('./electron-builder-config');

const arch = process.env.BRUNO_LOCAL_ARCH || (process.arch === 'x64' ? 'x64' : 'arm64');

const config = { ...base };

// Notarization requires Apple credentials we don't have.
delete config.afterSign;

config.mac = {
  ...base.mac,
  identity: null,
  hardenedRuntime: false,
  notarize: false,
  target: [
    {
      target: 'dmg',
      arch: [arch]
    }
  ]
};

// Only enforced when signing with a real identity.
delete config.mac.requirements;

module.exports = config;
