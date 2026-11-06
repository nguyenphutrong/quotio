#!/bin/sh
# Cargo runner on macOS: sign with a Developer ID so the Keychain keeps trusting
# the app across rebuilds. The default ad-hoc signature changes with every build,
# so macOS asks to grant access again. Without a Developer ID it runs unsigned.
binary=$1
identity=${QUOTIO_SIGN_IDENTITY:-Developer ID Application}
if security find-identity -v -p codesigning | grep -q "$identity"; then
    codesign --force --timestamp=none --identifier app.Quotio.desktop \
        --sign "$identity" "$binary" 2>/dev/null ||
        echo "warning: could not sign $binary with \"$identity\"" >&2
fi
exec "$@"
