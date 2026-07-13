# Internal QA TestFlight Build

Use this only while StoreKit products are unavailable and only for the sole
internal tester. It grants Creator features without a StoreKit transaction so
the editor, export, and feature gates can be tested quickly.

## Safety boundary

- The entitlement exists only when the archive is compiled with
  `REELCLIP_INTERNAL_QA`.
- It is active only when the app has an Apple sandbox receipt, which includes
  TestFlight. A production App Store receipt cannot enable it.
- It is not a user setting, launch argument, remote flag, or persisted value.
- A normal Release archive has no QA entitlement and continues to require a
  verified StoreKit transaction.

## Build and upload

Choose a new unused TestFlight build number, then run from the repository root:

```zsh
./scripts/archive_internal_qa.sh 138
```

Open Xcode, choose **Window > Organizer**, select **ReelClip Internal QA 138**,
then distribute it through App Store Connect to the internal-only TestFlight
group. Do not use that archive for App Store review or external testers.

The app's Settings tab displays an `Internal QA access` notice whenever the
override is active. Verify that notice before exercising paid features.

## Before launch

1. Create the live StoreKit products in App Store Connect.
2. Upload a normal Release archive without the QA script.
3. Confirm the Settings notice is absent and the paywall resolves products.
4. Test a free user and a Sandbox Creator purchase in TestFlight.
