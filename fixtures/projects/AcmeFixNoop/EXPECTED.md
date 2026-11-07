# AcmeFixNoop: a planted no-op (SET-011)

Same layout as AcmeFixWin (macOS SwiftUI app `AcmeFixNoop`, settings only in `Config/<Configuration>.xcconfig`).

- Planted: Debug `VALIDATE_PRODUCT = YES`. Product validation runs for install and archive only, so turning it off in
  Debug changes nothing measurable on this tiny app.
- `xcblame fix --rules SET-011` plans one `overlay` step through the `hook` (`VALIDATE_PRODUCT = NO`),
  `verifyKind` `zero-change`.
- Expected verify verdict: `reverted (within noise)`.
