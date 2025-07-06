# FFmpeg Integration Setup

This app uses FFmpeg for video conversion. Due to SDL2 dependency issues with some FFmpeg packages, we have several options:

## Option 1: Use System FFmpeg (Simplest for Development)

For development, you can install FFmpeg locally:
```bash
brew install ffmpeg
```

The app will use the system FFmpeg if available.

## Option 2: Bundle FFmpeg Binary (For Distribution)

1. **Download precompiled FFmpeg binary** (without SDL2 dependency):
   - Visit https://evermeet.cx/ffmpeg/
   - Download the static build (doesn't require external libraries)
   
2. **Add to Xcode project**:
   - Drag the ffmpeg binary into your Xcode project
   - Add it to "Copy Bundle Resources" build phase
   - Update the code to use the bundled binary

## Option 3: Use FFmpeg-iOS Package

1. **Add the package**:
   - URL: `https://github.com/kewlbear/FFmpeg-iOS`
   - This allows building custom FFmpeg without SDL2

## Current Implementation

The app currently tries to use FFmpeg from these locations:
- `/usr/local/bin/ffmpeg` (Homebrew Intel)
- `/opt/homebrew/bin/ffmpeg` (Homebrew Apple Silicon)
- `/usr/bin/ffmpeg` (System)

For a fully self-contained app, Option 2 with a static FFmpeg binary is recommended.

## Features Provided

- **Full FFmpeg functionality** without requiring user installation
- **Hardware acceleration** support via VideoToolbox on macOS
- **Progress tracking** during conversion
- **All major codecs** included (H.264, H.265, AAC, MP3, etc.)

## Supported Formats

With FFmpegKit integrated, the app can convert:
- MKV (all codecs, not just H.264/H.265)
- WMV
- AVI
- FLV
- WebM
- MOV
- MPG/MPEG
- And many more formats

## License Note

FFmpegKit uses GPL license by default. If you need LGPL for commercial distribution, contact the FFmpegKit maintainers for their paid LGPL version.

## Testing

After adding the package:
1. Build and run the app
2. Try converting a video file
3. The conversion should work without any external FFmpeg installation