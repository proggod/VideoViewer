# VideoViewer

A native macOS video browser and player application built with SwiftUI, designed for efficient video library management with advanced filtering and categorization features.

## Features

### Video Browsing
- **Hierarchical file browser** - Navigate through your video folders with an intuitive tree view
- **Dual view modes** - Switch between grid view with thumbnails and compact list view
- **Adjustable thumbnail sizes** - Customize thumbnail size with a slider (100-480px)
- **Smart thumbnail generation** - Automatically generates and caches video thumbnails
- **Network drive detection** - Optimized performance for network mounted volumes
- **Inline filename editing** - Click any filename to rename it directly
- **Refresh button** - Rescan directories for new content
- **Persistent navigation** - Remembers your last selected directory

### Video Playback
- **Native video player** - Built on AVKit for smooth playback
- **Volume persistence** - Maintains volume and mute settings across videos
- **Capture screenshots** - Take snapshots while watching videos
- **Multi-window support** - Open multiple videos simultaneously

### Organization & Filtering
- **Category system** - Create and manage custom categories for your videos
- **Smart filtering** - Filter videos by:
  - Multiple categories (OR logic)
  - Video resolution (4K, 1080p, 720p, etc.)
- **Visual indicators** - Green checkmarks on thumbnails show categorized videos
- **Bulk operations** - Apply categories to videos quickly with checkbox grids

### File Management
- **Batch cleanup system** - Advanced filename cleanup with:
  - Search and replace rules with wildcard support (* matches any text)
  - Case-insensitive matching
  - Rule ordering with drag-and-drop
  - Preview changes before applying
  - Batch processing (20, 50, 100, 200, or all files)
  - Automatic space cleanup and normalization
- **Right-click delete** - Remove videos with confirmation dialog
- **Inline rename** - Click any filename to edit it directly

### Performance
- **Resolution caching** - Instant loading of video metadata after first scan
- **Lazy loading** - Efficient handling of large video libraries
- **Background processing** - Non-blocking UI while scanning video metadata

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)

## Supported Video Formats

- MP4, MOV, AVI, MKV, M4V
- WebM, FLV, WMV
- MPG, MPEG

## Installation

1. Clone the repository:
```bash
git clone [repository-url]
cd VideoViewer
```

2. Open the project in Xcode:
```bash
open VideoViewer.xcodeproj
```

3. Build and run (⌘R)

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
3. Use "Clear All" to reset filters quickly

### Video Player Features
- Click the camera icon to capture a screenshot
- Click the tag icon to show/hide category assignments
- Check/uncheck categories to organize videos
- Volume and mute settings persist between videos

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