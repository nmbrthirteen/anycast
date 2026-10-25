<p align="center"><img src="docs/icon.png" width="128" alt="AnyCast icon"></p>

# AnyCast

Free, open-source casting from your Mac to almost any smart TV. Send a browser tab, a video link, a file, or a single app window to the TV, with sound, the way AirPlay works for Apple TV.

AnyCast talks to TVs over DLNA, the casting standard most Samsung, LG, Sony, Hisense, TCL, and Philips TVs already support. You don't need a dongle, an account, or an app on the TV.

## What it does

- **Browser tabs:** see every open tab and cast its video in one click. YouTube and most sites play at up to 1080p60 without re-encoding.
- **Files:** drop a video, song, or photo on the window.
- **Send to TV:** moves the app that's playing onto a virtual TV screen and streams it with sound. It keeps playing on another desktop or with the lid closed.
- **Mirror:** stream any window or display, muting the Mac so sound only comes from the TV.
- **Chrome extension:** cast the current tab with its sound, even on sites that block downloads.

## Install

1. Install the tools AnyCast uses: `brew install ffmpeg yt-dlp`
2. Download `AnyCast.dmg` from [Releases](../../releases) and drag AnyCast to Applications.
3. Open it. Allow local network access when macOS asks, so it can find your TV.

Requires macOS 26 or later on an Apple silicon Mac.

## Build from source

Needs Xcode 26.

```sh
scripts/make-signing-cert.sh   # once: a local signing identity so macOS remembers permissions
./build.sh install             # builds, installs to /Applications, makes build/AnyCast.dmg
```

## Compatibility

AnyCast is tested on a Hisense TV with AnyView Cast. Other DLNA TVs should play files and browser videos. Live streams (Mirror, Send to TV) depend on how the TV handles MPEG-TS, and some TVs add a few seconds of delay. Please open an issue with your TV model if something doesn't play.

It doesn't support Chromecast, Apple TV, or Roku, since those use other protocols. Sites with DRM, like most paid sports and movie services, show a black picture: macOS blocks capture of protected video.

## How it works

- Finds TVs with SSDP and controls them over UPnP AVTransport.
- A built-in HTTP server streams files with range support. Web videos go to the TV directly when it can play them, or ffmpeg remuxes them without re-encoding.
- Mirroring uses ScreenCaptureKit and hardware H.264 in MPEG-TS at a constant rate, with live latency correction.
- The TV screen is a virtual display created through private SkyLight APIs, so a future macOS update could break it.

Logs are in `~/Library/Logs/AnyCast.log`.

## License

MIT
