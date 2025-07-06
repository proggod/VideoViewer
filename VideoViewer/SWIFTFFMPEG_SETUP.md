# SwiftFFmpeg Setup Instructions

To enable video conversion functionality, you need to add the SwiftFFmpeg package dependency to your Xcode project:

## Step 1: Add SwiftFFmpeg Package

1. Open `VideoViewer.xcodeproj` in Xcode
2. Select the VideoViewer project in the navigator
3. Select the VideoViewer target
4. Go to the "Package Dependencies" tab
5. Click the "+" button
6. Enter the repository URL: `https://github.com/sunlubo/SwiftFFmpeg`
7. Set the version rule to "Up to Next Major Version" with minimum version "2.2.0"
8. Click "Add Package"
9. When prompted, add SwiftFFmpeg to the VideoViewer target

## Step 2: Install FFmpeg Libraries

SwiftFFmpeg requires the FFmpeg libraries to be installed on your system.

### Using Homebrew (Recommended):

```bash
brew install ffmpeg
```

### Alternative: Download Pre-built Libraries

Visit https://evermeet.cx/ffmpeg/ to download pre-built FFmpeg libraries for macOS.

## Step 3: Configure Build Settings

If you encounter linking issues:

1. In Xcode, select the VideoViewer target
2. Go to Build Settings
3. Search for "Other Linker Flags"
4. Add the following flags if needed:
   - `-lavcodec`
   - `-lavformat`
   - `-lavutil`
   - `-lswscale`
   - `-lswresample`

## Step 4: Build and Run

After completing these steps, build and run the project. The video conversion feature should now work with full FFmpeg support.

## Troubleshooting

If you encounter issues:

1. Ensure FFmpeg is properly installed: `ffmpeg -version`
2. Check that the FFmpeg libraries are in your system's library path
3. Clean the build folder (Product → Clean Build Folder) and rebuild

## Features

With SwiftFFmpeg integrated, the app can now:
- Convert WMV files to MP4
- Convert MKV files with incompatible codecs to MP4
- Use hardware acceleration when available
- Show real-time conversion progress
- Cancel conversions in progress