# VideoViewer

A native macOS video browser and player application built with SwiftUI, designed for efficient video library management with advanced filtering and categorization features.

## Features

### Video Browsing
- **Hierarchical file browser** - Navigate through your video folders with an intuitive tree view
- **Dual view modes** - Switch between grid view with thumbnails and compact list view
- **Adjustable thumbnail sizes** - Customize thumbnail size with a slider (100-480px)
- **Smart thumbnail generation** - Automatically generates and caches video thumbnails
- **Network drive detection** - Optimized performance for network mounted volumes:
  - Local thumbnail caching for faster loading
  - Reduced concurrent operations on network drives
  - Visual "Network Drive" indicator in header
- **Unsupported file indicators** - Clear visual feedback for problematic files:
  - Red X overlay on files that can't be played
  - Counter badge showing number of unsupported files
  - Automatic detection of incompatible codecs
- **Inline filename editing** - Click any filename to rename it directly
- **Refresh button** - Rescan directories for new content
- **Persistent navigation** - Remembers your last selected directory

### Video Playback
- **Native video player** - Built on AVKit for smooth playback
- **Volume persistence** - Maintains volume and mute settings across videos
- **Frame-accurate screenshots** - Take snapshots of the exact paused frame:
  - No more off-by-a-second captures
  - Automatic cache invalidation for replaced screenshots
  - Instant updates in the browser
- **Multi-window support** - Open multiple videos simultaneously

### Organization & Filtering
- **Category system** - Create and manage custom categories for your videos
- **Smart filtering** - Filter videos by:
  - Multiple categories (OR logic)
  - Video resolution (4K, 1080p, 720p, etc.)
  - **Non-categorized videos** - Special filter to find videos without any categories
- **Visual indicators** - Green checkmarks on thumbnails show categorized videos
- **Bulk operations** - Apply categories to videos quickly with checkbox grids
- **Directory highlighting** - Currently selected folder is highlighted in the tree view

### File Management
- **Batch cleanup system** - Advanced filename cleanup with:
  - Search and replace rules with wildcard support (* matches any text)
  - Case-insensitive matching
  - Rule ordering with drag-and-drop
  - Preview changes before applying
  - Batch processing (20, 50, 100, 200, or all files)
  - Automatic space cleanup and normalization
- **Video format conversion** - Convert various formats to MP4:
  - Fast remuxing for MKV files with H.264/H.265 codecs
  - Full conversion support for WMV, AVI, MOV, MPG, MPEG, M4V, 3GP and more
  - **Quality sliders** - Adjust video quality (CRF 15-30) and audio bitrate (128-320 kbps)
  - **Maximum quality by default** - Sliders start at highest quality settings
  - Self-contained FFmpeg binary (152MB universal Intel/ARM64) - no installation needed
  - Hardware acceleration via VideoToolbox when available
  - Live FFmpeg terminal output with real-time debugging
  - Accurate per-file time estimation and progress tracking
  - 15-minute timeout protection against stuck conversions
  - Stop button to cancel conversions at any time
  - **Auto-cleanup** - Successfully converted files have .bak files automatically deleted
- **Batch screenshot generation** - Create thumbnails automatically:
  - Generates screenshots at random times (1-2 minutes into video)
  - Only processes videos without existing thumbnails
  - Shows preview of each screenshot as it's created
  - Stop button to cancel batch processing
- **Right-click delete** - Remove videos with confirmation dialog
- **Inline rename** - Click any filename to edit it directly

### Performance
- **Resolution caching** - Instant loading of video metadata after first scan
- **Lazy loading** - Efficient handling of large video libraries
- **Background processing** - Non-blocking UI while scanning video metadata
- **Network optimizations** - Adaptive batch sizes and timeouts for remote drives

## Header Controls

From left to right in the header:
- **Folder Access** (folder.badge.plus) - Grant permissions for protected folders
- **Network/Unsupported indicators** - Shows connection type and problem file count
- **Refresh** (arrow.clockwise) - Rescan current directory
- **Cleanup** (wand.and.stars) - Batch rename files with rules
- **Screenshots** (photo) - Generate missing thumbnails
- **Convert Videos** (film.stack) - Convert various video formats to MP4 with live debug output
- **Filters** (line.horizontal.3.decrease.circle) - Toggle filter sidebar
- **View Mode** (list.bullet/square.grid.2x2) - Switch between list and grid

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)

## Supported Video Formats

### Playback
- MP4, MOV, AVI, MKV, M4V, WebM, FLV, WMV, MPG, MPEG

### Conversion (to MP4)
- **Fast remux**: MKV files with H.264/H.265 video and AAC/MP3 audio
- **Full conversion**: WMV, AVI, MOV, MPG, MPEG, M4V, 3GP, 3G2
- **Hardware accelerated**: Uses VideoToolbox on Apple Silicon and Intel Macs when available

## Installation

1. Clone the repository:
```bash
git clone [repository-url]
cd VideoViewer
```

2. Set up FFmpeg for video conversion (optional):
```bash
./setup_ffmpeg.sh
```
This downloads and creates a universal FFmpeg binary (Intel + ARM64).

3. Open the project in Xcode:
```bash
open VideoViewer.xcodeproj
```

4. Build and run (⌘R)

## Usage

### Basic Navigation
1. Use the file tree on the left to navigate to folders containing videos
2. Double-click any video to open it in a new player window
3. Toggle between grid and list view using the toolbar button

### Managing Categories
1. Click the "Categories" tab to manage your category list
2. Add new categories with the text field
3. Edit existing categories by clicking the pencil icon
4. Delete categories with the trash icon

### Filtering Videos
1. Click the filter icon to show/hide the filter panel
2. Check categories and/or resolutions to filter the video list
3. Use the "Non-categorized" filter to find videos without any categories assigned
4. Use "Clear All" to reset filters quickly

### Video Player Features
- Click the camera icon to capture a screenshot
- Click the tag icon to show/hide category assignments
- Check/uncheck categories to organize videos
- Volume and mute settings persist between videos

### Video Conversion Features
- Automatically detects convertible video formats in the current directory
- **Quality controls** - Adjust video quality (CRF) and audio bitrate before conversion
- Tries fast remuxing first for compatible MKV files (seconds vs minutes)
- Falls back to full FFmpeg conversion for other formats or incompatible codecs
- Live terminal output shows exactly what FFmpeg is doing
- Real-time progress bar with accurate time estimation per file
- Hardware acceleration automatically enabled when supported
- 15-minute timeout prevents infinite hangs on problematic files
- Stop button immediately terminates conversion process
- Successful conversions automatically delete .bak files (failed conversions keep backups)

## Data Storage

- **Thumbnails**: Stored in `.video_info` folders within each directory
- **Categories database**: SQLite database stored in Application Support
- **Preferences**: Volume, view settings stored in UserDefaults
- **Resolution cache**: Cached in UserDefaults for fast loading
- **Network thumbnails**: Cached in `~/Library/Caches/VideoViewer/thumbnails/`

## Troubleshooting

### "The file couldn't be opened" Error (Error Code 256)

If you see this error when trying to access folders like Downloads or Documents, it's a macOS permissions issue. Here's how to fix it:

#### Solution 1: Grant Permission via System Settings
1. Open **System Settings** → **Privacy & Security** → **Files and Folders**
2. Find **VideoViewer** in the list
3. Enable toggles for:
   - Downloads Folder
   - Movies Folder
   - Documents Folder
   - Any other folders you want to access

#### Solution 2: Use the Grant Access Button
- Click the folder icon (folder.badge.plus) in the header to explicitly grant folder access
- Select the folder you want to access in the dialog
- This will save persistent access permissions

#### Solution 3: Reset All Permissions (if needed)
```bash
tccutil reset All com.example.VideoViewer
```
Then restart the app and grant permissions when prompted.

#### Solution 4: For Developers - Disable Sandboxing
If building from source, you can temporarily disable sandboxing:
1. In Xcode, select the VideoViewer target
2. Go to "Signing & Capabilities"
3. Remove the "App Sandbox" capability
4. Or use the included `VideoViewer-NoSandbox.entitlements` file

**Note**: The app is sandboxed for security, which requires explicit permission to access user folders. This is standard macOS security behavior.

### Network Drive Performance
- Network drives are automatically detected and show a "Network Drive" badge
- Thumbnails are cached locally for better performance
- Cache expires after 7 days to ensure freshness

## Architecture

Built with SwiftUI and follows MVVM architecture:
- **ContentView**: Main navigation and layout
- **VideoListView**: Video browsing interface
- **VideoPlayerContent**: Playback interface
- **CategoryManager**: SQLite database operations
- **FilterSidebar**: Filtering interface

## Contributing

Feel free to submit issues and enhancement requests!

## License

[Your license here]