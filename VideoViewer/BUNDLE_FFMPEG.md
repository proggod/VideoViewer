# How to Bundle FFmpeg with VideoViewer

To make the app fully self-contained without requiring users to install FFmpeg, follow these steps:

## Option 1: Download Static FFmpeg Binary (Recommended)

1. **Download FFmpeg static build for macOS**:
   - Visit: https://evermeet.cx/ffmpeg/
   - Download the latest **ffmpeg** static build (not ffprobe)
   - The static build includes all dependencies

2. **Add to Xcode Project**:
   - Unzip the downloaded file to get the `ffmpeg` binary
   - In Xcode, right-click on the VideoViewer folder
   - Select "Add Files to VideoViewer..."
   - Select the `ffmpeg` binary file
   - Make sure "Copy items if needed" is checked
   - Make sure "VideoViewer" target is selected
   - Click "Add"

3. **Configure Build Phases**:
   - Select VideoViewer target in Xcode
   - Go to "Build Phases" tab
   - Expand "Copy Bundle Resources"
   - Make sure `ffmpeg` is listed there
   - If not, click "+" and add it

4. **Test**:
   - Build and run the app
   - Try converting a video
   - The app should show "Using bundled FFmpeg" in the console

## Option 2: Use Universal Binary

For maximum compatibility across Intel and Apple Silicon Macs:

1. Download both Intel and Apple Silicon versions from https://evermeet.cx/ffmpeg/
2. Create a universal binary:
   ```bash
   lipo -create ffmpeg-intel ffmpeg-arm64 -output ffmpeg
   ```
3. Add the universal binary to your project as described above

## Distribution

When you distribute your app:
- The FFmpeg binary will be included in the .app bundle
- Users won't need to install anything
- The app will work immediately after download

## File Size Consideration

The static FFmpeg binary is approximately 70-80 MB. This will increase your app size but ensures it works everywhere without dependencies.

## Alternative: Minimal Build

If size is a concern, you can build a minimal FFmpeg with only the codecs you need:
- H.264/H.265 for video
- AAC for audio
- Container formats: MP4, MKV, AVI, WMV

This can reduce the binary size significantly.