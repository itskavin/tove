# Tove privacy policy

Effective 19 November 2026 (updated the same day for approximate location and maps).

Tove is an app for talking to an AI assistant that runs on **a server you choose**: your own Tove server (the "bridge")
and the Hermes Agent behind it, or one that someone you trust runs for you. This policy explains what the app does with
your information. In short: the developer of Tove runs no servers for the app and collects nothing.

## Who is responsible for what

- **The developer** publishes the Tove app as a signed APK on GitHub (github.com/itskavin/tove). The developer does not operate a Tove service, has no user accounts, and
  receives no data from the app: no chats, no voice, no files, no analytics, no crash reports, no device identifiers.
- **The server operator** (usually you) runs the Tove server the app connects to. That server stores your chats and
  decides which AI providers your requests are sent to. Its own privacy terms, and those of the AI providers it uses,
  apply to what it receives.

## What the app sends, and where

The app talks only to the server address you enter on the connect screen, over HTTPS, using the access key you give
it. It sends that server:

- **Chats**: the messages you type or dictate, and your reply settings (for example custom instructions and the
  profile you fill in).
- **Attachments** you choose: photos, images, PDFs and other files.
- **Dictation audio**, when you use dictation in its default "on your server" mode, so the server can turn it into
  text.
- **Reports** you make with "Report reply", with the reason and any note you add.
- **Your approximate location**, only if you turn on Settings › Local answers › "Use my approximate location" (off
  by default): with each message, a position rounded on your phone to about 1 km. Your server turns it into one line
  for the assistant (for example "Mylapore, Chennai, IN") and keeps only that line with the message; it is deleted
  with the message or chat. Turn the setting off at any time.
- **A random device id** made by the app (not a hardware id), so the server can tell your devices apart for
  notifications and sync, and the app version.

The server may forward your messages, attachments and dictation audio to the AI providers it is configured to use
(for example OpenAI, or another model provider), which process them under their own terms. The developer has no access
to them.

**Live voice calls.** When you start a call, your server sets the call up with its voice provider (for example
OpenAI's real-time voice service). The audio then flows **directly between your device and that provider** over an
encrypted WebRTC connection. Your server receives the call's transcript and the tasks you ask for, not the audio. The
microphone is used only while a call or dictation is active, and Android shows that it is in use.

**Third-party services your server may contact for these features.** To label your approximate location, a Tove
server sends the rounded coordinates (about 1 km) to OpenStreetMap's Nominatim service, unless its operator turned
this off or uses their own. For "near me" answers it searches its own local copy of open map data (Overture Maps), may
look up place details through OpenStreetMap's Overpass API and area names through Photon (komoot); these requests
carry place names and areas, not your identity. Maps in replies load map tiles from OpenStreetMap's tile servers (or
the server operator's choice) through the app, which reveals the map area shown and your network address to that
tile server.

**Links and pictures in replies** are fetched by your server, not by your phone, so a reply cannot make your phone
contact other sites. When you tap a link, it opens in your browser or the app you pick.

**Optional downloads.** If you choose on-device dictation or read-aloud voices in Settings, the app downloads the
speech models from their public release page on GitHub. Those downloads contain no personal data;
the hosting site sees an ordinary download request.

**Update check.** Once a day, and when you tap Settings › About › Check for updates, the app asks GitHub's public
API (api.github.com) for the latest Tove release. The request carries no account, key or personal data; GitHub sees
an ordinary request from your network address. "Download" opens the APK in your browser; nothing is installed without
you. Turn the daily check off in Settings › About.

**System services you choose.** If you pick the phone's own speech recognition or text-to-speech, or a push app such
as ntfy for notifications, those services handle the data under their own terms.

## What is stored on your device

- The server address and settings (theme, voice, notification choices) in the app's private storage.
- The access key in the platform's secure storage (Android Keystore-backed encrypted storage).
- Temporary copies of images and attachments, and the ids of replies still being written or that you hid. You can
  clear the cache in Settings › Data controls.
- Speech models, if you downloaded them.

Uninstalling the app deletes all of this. Signing out removes the access key.

## What is stored on your server

Your chat history, uploaded files, synced settings, reports and notification events are stored by the Tove server you
connect to, under its operator's control. In the app you can delete single messages, whole chats, or all chats
(Settings › Data controls); deleting them removes them from that server. Anything already sent to an AI provider is
governed by that provider's retention policy.

## Permissions

- **Microphone**: live voice calls and dictation, only while you use them.
- **Notifications**: to tell you when a reply or task finishes, and to show an ongoing call.
- **Foreground services**: one keeps a live voice call running while you use other apps; the "Instant notifications"
  one (on unless you turn it off) keeps a single connection to your own server open so notifications arrive quickly.
  Both show a notification while they run, and you can turn instant notifications off in Settings.
- **Run in the background**: only if you tap "Allow in the background" in Settings › Notifications, Android asks you
  whether to exempt Tove from battery optimisation, so instant notifications stay connected while the phone sleeps.
- **Approximate location** (coarse only, never precise or in the background): asked for only when you turn on "Use
  my approximate location" or tap "Use my location" in a reply.
- **Network, vibration, start at boot** (to restart instant notifications after a restart, only while they are on).

The app does not access your contacts, precise location, camera (photos are taken by the system camera app only when you
choose to attach one), call logs or advertising id.

## No ads, no tracking, no sale

Tove shows no ads, contains no analytics or tracking SDKs, and does not sell or share personal information. The
developer does not use your data for training AI models.

## Children

Tove is not directed at children and is intended for adults (18+).

## Security

All traffic between the app and your server uses HTTPS (TLS). Live voice audio is encrypted by WebRTC (DTLS-SRTP).
The access key is kept in secure storage and never written to logs. Replies are drawn as text and native widgets; they
never run as code.

## Changes

If this policy changes, the new version ships with the next app release and is published in the Tove repository on
GitHub, with a new effective date.

## Contact

Questions about this policy: open an issue at https://github.com/itskavin/tove/issues. For questions about the data on a server you did not set up
yourself, contact that server's operator.
