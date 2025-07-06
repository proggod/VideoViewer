#!/bin/bash

# Script to download and set up universal FFmpeg binary for VideoViewer

set -e

echo "🎬 Setting up FFmpeg for VideoViewer..."

# Save current directory
ORIGINAL_DIR=$(pwd)

# Get the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "📥 Downloading FFmpeg for Intel..."
curl -L -o ffmpeg-intel.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip"
unzip -q ffmpeg-intel.zip
mv ffmpeg ffmpeg-intel

echo "📥 Downloading FFmpeg for Apple Silicon..."
curl -L -o ffmpeg-arm64.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
unzip -q ffmpeg-arm64.zip
mv ffmpeg ffmpeg-arm64

echo "🔨 Creating universal binary..."
lipo -create ffmpeg-intel ffmpeg-arm64 -output VideoViewer/ffmpeg
chmod +x VideoViewer/ffmpeg

echo "🧹 Cleaning up..."
rm -f ffmpeg-intel ffmpeg-arm64 ffmpeg-intel.zip ffmpeg-arm64.zip

echo "🔍 Verifying universal binary..."
lipo -info VideoViewer/ffmpeg

echo "🧪 Testing FFmpeg..."
VideoViewer/ffmpeg -version | head -n 1

# Return to original directory
cd "$ORIGINAL_DIR"

echo ""
echo "✨ Done! FFmpeg universal binary is ready at VideoViewer/ffmpeg"
echo ""
echo "The app will automatically use this bundled FFmpeg!"
echo ""
echo "To add it to Xcode:"
echo "1. Drag VideoViewer/ffmpeg into your Xcode project"
echo "2. Make sure 'Copy items if needed' is checked"
echo "3. Ensure it's added to 'Copy Bundle Resources' build phase"