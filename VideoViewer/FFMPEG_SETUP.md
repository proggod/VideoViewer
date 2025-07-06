# FFmpeg Integration Setup

This app uses FFmpegKit to provide video conversion functionality with FFmpeg bundled directly in the app. Users don't need to install anything separately.

## Adding FFmpegKit to the Project

1. **Open VideoViewer.xcodeproj in Xcode**

2. **Add the Swift Package**:
   - Select the VideoViewer project in the navigator
   - Select the VideoViewer target
   - Go to the "Package Dependencies" tab
   - Click the "+" button
   - Enter the repository URL: `https://github.com/kingslay/FFmpegKit`
   - Click "Add Package"
   - Select the latest version
   - Choose "FFmpegKit" product and add it to the VideoViewer target

3. **Build Settings** (if needed):
   - The package should automatically configure everything
   - FFmpeg binaries are embedded in the framework

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