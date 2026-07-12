# Feedback Delivery

The Settings feedback form is opt-in. No request is made until the user taps
Send. The app never attaches video, project files, transcripts, analytics, or a
device identifier. Optional diagnostics include only app version, build number,
iOS version, and device model.

## Email

With no backend endpoint configured, the app uses `ReelClipFeedbackEmail` from
`VideoSlicer/Info.plist`. Update the committed placeholder
`jude@reelclips.app` to a mailbox the team controls before release. The user
reviews and sends the generated mail themselves.

## Convex

Set `ReelClipFeedbackEndpoint` in `VideoSlicer/Info.plist` to an HTTPS route to
send JSON directly to a backend instead of opening email. The iOS client sends:

```json
{
  "category": "bug",
  "message": "The trim handle is hard to select.",
  "replyEmail": "creator@example.com",
  "diagnostics": {
    "appVersion": "1.0",
    "build": "135",
    "systemVersion": "26.5",
    "deviceModel": "iPhone"
  }
}
```

`replyEmail` and `diagnostics` are omitted unless the user supplies or enables
them. The app accepts only HTTPS endpoint URLs and must never contain a Convex
admin key, deployment key, or other secret.

Use a Convex table with `category`, `message`, optional `replyEmail`, optional
`diagnostics`, and a server-generated `createdAt` timestamp. Expose it through
a validated POST HTTP Action that accepts only the three app categories and a
4-4,000 character message. Put the public action behind an edge rate limiter,
such as Cloudflare, before configuring the production endpoint. The client has
no persistent user identifier by design, so abuse prevention belongs at the
edge, not in the app.
