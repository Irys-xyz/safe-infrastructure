# expect-fail-against-base: yes
#
# The download path checked the PNG magic bytes, with a comment explaining exactly why: "an
# HTML error page written here would be served to the wallet as the currency icon". The
# local-file path -- the documented way to supply the icon by hand -- checked only that the
# result was non-empty, so a mistyped argument was installed as the native currency's image.

d=$TMP
media="$d/media"

printf '<html><body>404 Not Found</body></html>' > "$d/not-an-image.png"
assert_status "a non-PNG local file is refused" 1 \
  env CFG_MEDIA_DIR="$media" bash "$SUT/scripts/install_currency_logo.sh" "$d/not-an-image.png"
assert_contains "and says what it got" "not a PNG" "$OUT"
assert_file_absent "and installs nothing" "$media/chains/3282/irys_currency.png"

# An empty file was already refused; make sure that still holds.
: > "$d/empty.png"
assert_status "an empty local file is refused" 1 \
  env CFG_MEDIA_DIR="$media" bash "$SUT/scripts/install_currency_logo.sh" "$d/empty.png"

# The real icon must still install, or the check is just an obstacle.
assert_status "the bundled icon installs" 0 \
  env CFG_MEDIA_DIR="$media" bash "$SUT/scripts/install_currency_logo.sh"
assert_file_present "at the per-chain path the config service points at" \
  "$media/chains/3282/irys_currency.png"

# The path is per-chain, because a fork runs under a different id.
assert_status "a fork's chain id gets its own path" 0 \
  env CFG_MEDIA_DIR="$media" IRYS_CHAIN_ID=31337 bash "$SUT/scripts/install_currency_logo.sh"
assert_file_present "installed under the fork's id" "$media/chains/31337/irys_currency.png"
