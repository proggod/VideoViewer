# VideoViewer

A macOS video browser and player built with SwiftUI that allows you to browse directories and play video files.

## Features

- **Directory Browser**: Navigate through your file system with an expandable tree view
- **Video File Detection**: Automatically finds and lists video files (mp4, mov, avi, mkv, m4v, webm, flv, wmv, mpg, mpeg)
- **Permission Management**: Seamless access to external drives and network volumes through security-scoped bookmarks
- **Video Player**: Double-click any video to open it in a resizable, moveable player window
- **Clean Interface**: Split-view layout with directory browser on the left and video list on the right

## System Requirements

- macOS 14.0 or later
- Xcode 15.0 or later

## Installation

1. Clone this repository
2. Open `VideoViewer.xcodeproj` in Xcode
3. Build and run the project

## Usage

### Browsing Directories
- The app starts at the root directory showing system folders, your home directory, and mounted volumes
- Click on any folder to expand it and see subdirectories
- Click on any folder to view its video files in the right panel

### Accessing External Drives
- External drives and network volumes may show a lock icon initially
- Click on a locked folder to grant permission - you'll see a simple dialog
- Follow the file picker to select the drive/folder you want to access
- Permission is remembered for future app launches

### Playing Videos
- Video files appear in the right panel when you select a directory
- Double-click any video file to open it in a new player window
- The player window can be resized, moved, minimized, and closed like any normal macOS window

## Supported Video Formats

- MP4 (.mp4)
- QuickTime (.mov)
- AVI (.avi) 
- Matroska (.mkv)
- iTunes Video (.m4v)
- WebM (.webm)
- Flash Video (.flv)
- Windows Media (.wmv)
- MPEG (.mpg, .mpeg)

## Architecture

The app is built using:
- **SwiftUI** for the user interface
- **AVKit** for video playback
- **AppKit** for file system access and window management
- **Security-scoped bookmarks** for persistent file access permissions

## License

This project is available under the MIT License.