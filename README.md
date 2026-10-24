# AnyCast

Native macOS app that plays web videos, files, and mirrored windows on DLNA TVs (built for a Hisense TV with AnyView Cast), at the best quality the TV supports.

## Requirements

- macOS 26 or later, Xcode command line tools
- `brew install ffmpeg yt-dlp gh` and `gh auth login` (updates come from this private repo's releases)

## Build and install

```sh
./build.sh install    # builds, installs to /Applications, makes build/AnyCast.dmg
./release.sh 1.0.1    # commits, tags, pushes, and publishes a GitHub release
```

Builds are signed with the local "AnyCast Local Signing" certificate so macOS permissions survive updates. The updater only installs builds signed with that same certificate.

## How it works

- Finds the TV with SSDP and controls it over UPnP AVTransport.
- Serves files from a built-in HTTP server. Web videos go to the TV directly when it can play them, or are remuxed by ffmpeg without re-encoding.
- Mirroring uses ScreenCaptureKit and VideoToolbox H.264 in MPEG-TS with a constant mux rate.

Logs: `~/Library/Logs/AnyCast.log`
