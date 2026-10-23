# Contributing

Read the root README for this app, then build only the app or package you are changing. The apps have independent executables and user data; a shared source package does not require running every app.

## Changes

- Explain the user-visible problem and the intended behavior. Keep changes focused and preserve existing configuration and file formats.
- Use the existing language and formatting conventions. Keep English, Traditional Chinese and Simplified Chinese UI catalogs aligned.
- Test consequential behavior and failure paths with synthetic data. Report unavailable permissions, skipped hardware checks and untested macOS versions accurately.
- For UI changes, include a screenshot with personal content removed. For file operations, verify collision handling, cancellation and recovery using disposable files.
- Preserve upstream attribution, bundled dependency licenses and data/media notices.

## Pull requests

Describe what changed, why, which checks ran and any remaining limitations. Link an issue when relevant. Do not include generated app bundles, dependency caches, signing certificates, local profiles, credentials or private research material.

Native repositories include the shared packages needed for their own apps. Their initial copies came from the same maintained workspace; compare shared-source hashes in `SOURCE-MANIFEST.json` when coordinating a change across repositories. Package tests should cover each affected consumer before that change is synchronized.

Source archives describe the exported snapshot; after contributing changes, Git history is authoritative. Contributions to original application code use this repository's GPL-3.0-only license. Separately licensed material retains its own terms.
