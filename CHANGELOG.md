# Changelog

## Unreleased — Multi-profile Chrome cookie fix

**Compared to:** [MattRuff/DD-Homerun-Output-Script](https://github.com/MattRuff/DD-Homerun-Output-Script)

### Bug fixes

#### Chrome cookie auto-auth now works when Homerun is in a non-default Chrome profile

**Problem:** `rookiepy.chrome()` only reads the Chrome `Default` profile. If your Homerun session lives in a different profile (e.g. `Profile 1`, a work profile), the script found 0 cookies and exited with `"No Homerun cookies in Chrome. Log in first."` — even though you were logged in.

**Root causes found:**
1. `rookiepy.chrome()` is hardcoded to the `Default` profile directory.
2. Chrome 127+ embeds a random 16-byte IV directly inside each encrypted cookie value (after the `v10` prefix) and also prepends a 16-byte random nonce to the plaintext before encrypting. The original code used a hardcoded space-character IV and didn't strip the nonce, so all decrypted values were garbled.

**Changes:**

- **`pull_info_from_opp.py`** — added `_chrome_cookies_all_profiles()` (new function, ~80 lines):
  - On macOS, reads the Chrome encryption key from the macOS Keychain (`security find-generic-password -s "Chrome Safe Storage"`) and scans every profile directory under `~/Library/Application Support/Google/Chrome/*/Cookies`.
  - Copies each `Cookies` SQLite database to a temp file to avoid locking Chrome's live database, queries all rows matching `homerunpresales.com`, and decrypts each value using the correct `v10` format: embedded IV at `enc[3:19]`, AES-CBC ciphertext at `enc[19:]`, PKCS7 padding removal, then strip the 16-byte random prefix from the plaintext.
  - Deduplicates cookies by name across profiles (last profile wins).
  - Falls back to `rookiepy.chrome()` on non-macOS platforms or if the Keychain key is unavailable.
  - Falls back to `rookiepy.chrome()` if the `cryptography` package is not installed.

- **`pull_info_from_opp.py`** — `_get_cookies()` now calls `_chrome_cookies_all_profiles()` instead of `rookiepy.chrome()` directly. All existing fallback paths (`--cookies`, `-f`, `HOMERUN_COOKIES` env var) are unchanged.

- **`requirements.txt`** — added `cryptography>=41.0.0` (used for AES-CBC decryption of Chrome cookie values).
